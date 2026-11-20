import 'dart:convert';
import 'dart:isolate';

import 'package:enough_convert/gbk.dart';
import 'package:html/dom.dart' as dom show Document, Element;
import 'package:xml/xml.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/document_encoding.dart';
import '../../../core/network/header_policy.dart';
import '../domain/book.dart';
import '../domain/book_catalog_rules.dart';
import '../domain/book_search.dart';
import '../domain/legado_source.dart';
import 'book_html.dart';
import 'book_mixed_content.dart';
import 'book_request_guard.dart';
import 'bookan_audio_client.dart';
import 'lit2go_audio_client.dart';
import 'legado/legado_client.dart';
import 'shuyin_audio_client.dart';
import 'ximalaya_audio_client.dart';

part 'book_native_catalog.dart';

List<Uri> parseBookImageAddresses(BookSource source, Uri base, String body) {
  if (!body.trimLeft().startsWith('[')) return const [];
  final Object? parsed;
  try {
    parsed = jsonDecode(body);
  } on FormatException {
    return const [];
  }
  if (parsed is! List ||
      parsed.isEmpty ||
      parsed.length > 100 ||
      parsed.any(
        (item) =>
            item is! String ||
            !(item.startsWith('https://') ||
                item.startsWith('http://') ||
                item.startsWith('//') ||
                item.startsWith('/')),
      )) {
    return const [];
  }
  final images = <Uri>[];
  for (final item in parsed.cast<String>()) {
    try {
      images.add(source.resolve(base, item, media: true));
    } on FormatException {
      return const [];
    }
  }
  return images;
}

List<Uri> extractBookChapterImages(
  BookSource source,
  Uri base,
  String html,
  String rule,
) {
  final selector = rule
      .replaceFirst(RegExp(r'^@css:'), '')
      .replaceFirst(RegExp(r'@(text|ownText|html)$'), '');
  final document = parseBookHtml(html);
  final images = <Uri>{};
  for (final element in bookElements(document, selector)) {
    final nodes = element.localName == 'img'
        ? [element]
        : element.querySelectorAll('img');
    for (final node in nodes) {
      final address =
          node.attributes['data-src'] ??
          node.attributes['data-original'] ??
          node.attributes['src'];
      if (address == null || address.isEmpty) continue;
      try {
        images.add(source.resolve(base, address, media: true));
      } on FormatException {
        // Ignore an undeclared image host without expanding network access.
      }
      if (images.length >= 100) break;
    }
    if (images.length >= 100) break;
  }
  return images.toList();
}

final class BookClient {
  const BookClient(this.network);
  final DocumentClient network;
  LegadoBookClient get _legado => LegadoBookClient(network);
  ShuYinAudioClient get _shuyin => ShuYinAudioClient(network);
  BookanAudioClient get _bookan => BookanAudioClient(network);
  XimalayaAudioClient get _ximalaya => XimalayaAudioClient(network);
  Lit2GoAudioClient get _lit2go => Lit2GoAudioClient(network);

  Future<Book> details(
    BookSource source,
    Book book,
    CancellationToken token, {
    BookRequestGuard? requestGuard,
  }) async {
    _requireNovelSource(source);
    if (source.format == BookFormat.shuyin) {
      return _shuyin.details(source, book, token);
    }
    if (source.format == BookFormat.bookan) return book;
    if (source.format == BookFormat.ximalaya) return book;
    if (source.format == BookFormat.lit2go) return book;
    if (source.format != BookFormat.html) return book;
    if (source.legado != null) {
      return _legado.details(source, book, token, requestGuard: requestGuard);
    }
    if (!source.rules.keys.any((key) => key.startsWith('info'))) return book;
    final response = await fetch(
      source,
      book.uri,
      token,
      requestGuard: requestGuard,
    );
    token.check();
    final document = parseBookHtml(response.text);
    String info(String key, [int limit = 160]) =>
        bookLabel(bookField(document, source.rules[key] ?? ''), limit);
    return book.withDetails(
      Book(
        book.sourceId,
        book.kind,
        book.title,
        '',
        book.uri,
        description: info('infoDescription', 4000),
        category: info('infoCategory'),
        wordCount: info('infoWordCount'),
        latestChapter: info('infoLatest'),
        updatedLabel: info(
          'infoUpdated',
        ).replaceFirst(RegExp(r'^更新时间[:：]\s*'), ''),
      ),
    );
  }

  bool _hasLegadoRules(BookSource source) =>
      source.legado != null &&
      (source.format != BookFormat.feed ||
          (source.legado!.rules['articles'] ?? '').isNotEmpty);

  Future<List<LegadoCategory>> categories(
    BookSource source,
    CancellationToken token, {
    bool Function(LegadoCategory)? allowCategory,
    void Function(LegadoCategory)? onDenied,
    bool allowDiscoveryNetworkExpansion = true,
  }) => _hasLegadoRules(source)
      ? _legado.categories(
          source,
          token,
          allowCategory: allowCategory,
          onDenied: onDenied,
          allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
        )
      : source.format == BookFormat.shuyin
      ? _shuyin.categories(source, token)
      : source.format == BookFormat.bookan
      ? Future.value(BookanAudioClient.categories)
      : source.format == BookFormat.ximalaya
      ? Future.value(XimalayaAudioClient.categories(source))
      : source.format == BookFormat.lit2go
      ? Future.value(Lit2GoAudioClient.categories)
      : Future.value(source.discoveryCategories);

  Future<Document> fetch(
    BookSource source,
    Uri uri,
    CancellationToken token, {
    bool media = false,
    int maxBytes = 2 * 1024 * 1024,
    bool allowRedirects = true,
    BookRequestGuard? requestGuard,
  }) {
    requestGuard?.call(uri, null);
    return network.get(
      uri,
      cancellation: token,
      maxBytes: maxBytes,
      networkTimeout: Duration(seconds: media ? 90 : 12),
      validateTarget: (target) {
        source.requestTarget(target, media: media);
        requestGuard?.call(target, null);
      },
      mapRedirect: allowRedirects
          ? null
          : (_) => throw const FormatException('成人过滤期间不跟随发现页面重定向'),
    );
  }

  Future<BookDiscoveryPage> discover(
    BookSource source,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    String? cursor,
    bool allowDiscoveryNetworkExpansion = true,
  }) async {
    _requireNovelSource(source);
    if (source.format == BookFormat.shuyin) {
      return _shuyin.discover(source, token, category: category, page: page);
    }
    if (source.format == BookFormat.bookan) {
      return _bookan.discover(
        source,
        token,
        category: category,
        page: page,
        allowRedirects: allowDiscoveryNetworkExpansion,
      );
    }
    if (source.format == BookFormat.ximalaya) {
      return _ximalaya.discover(
        source,
        token,
        category: category,
        page: page,
        allowRedirects: allowDiscoveryNetworkExpansion,
      );
    }
    if (source.format == BookFormat.lit2go) {
      return _lit2go.discover(
        source,
        token,
        page: page,
        allowRedirects: allowDiscoveryNetworkExpansion,
      );
    }
    if (_hasLegadoRules(source) && source.format == BookFormat.html) {
      return _legado.discover(
        source,
        token,
        category: category,
        page: page,
        cursor: cursor,
        allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
      );
    }
    if (source.format == BookFormat.featured &&
        source.rules['catalogSearch'] == 'true') {
      final books = await _mappedFeatured(
        source,
        category,
        token,
        allowRedirects: allowDiscoveryNetworkExpansion,
      );
      return (books: books, next: null);
    }
    if (source.format != BookFormat.html) {
      return (books: await books(source, '', token), next: null);
    }
    final path =
        cursor ??
        category?.address ??
        source.discoveryCategories.firstOrNull?.address ??
        source.discover;
    if (path.isEmpty) return (books: <Book>[], next: null);
    final target = source.resolve(source.endpoint, path);
    final response = await fetch(
      source,
      target,
      token,
      allowRedirects: allowDiscoveryNetworkExpansion,
    );
    return _parseHtmlBooks(source, response, token, discovery: true);
  }

  Future<List<Book>> books(
    BookSource source,
    String query,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    Uri? bookAddress,
    bool allowDiscoveryNetworkExpansion = true,
  }) async {
    _requireNovelSource(source);
    if (source.format == BookFormat.shuyin) {
      return _shuyin.books(source, query, token, page: page);
    }
    if (source.format == BookFormat.bookan) {
      return _bookan.books(source, query, token, page: page);
    }
    if (source.format == BookFormat.ximalaya) {
      return _ximalaya.books(source, query, token, page: page);
    }
    if (source.format == BookFormat.lit2go) {
      return _lit2go.books(source, query, token, page: page);
    }
    if (query.isEmpty &&
        bookAddress == null &&
        source.format == BookFormat.html) {
      return (await discover(
        source,
        token,
        category: category,
        page: page,
        allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
      )).books;
    }
    if (_hasLegadoRules(source)) {
      return _legado.books(
        source,
        query,
        token,
        category: category,
        page: page,
        bookAddress: bookAddress,
        allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
      );
    }
    if (bookAddress != null) return [];
    if (source.format == BookFormat.featured) {
      final hasCatalog = source.rules['catalogSearch'] == 'true';
      final listing = hasCatalog
          ? await _mappedFeatured(
              source,
              category,
              token,
              allowRedirects: allowDiscoveryNetworkExpansion,
            )
          : source.featured;
      if (query.trim().isEmpty) return listing;
      final match = BookSearchQuery(query, BookSearchField.all);
      return listing.where((book) => match.rank(book) != null).toList();
    }
    if (source.format == BookFormat.feed) {
      final feed = await _feed(source, token);
      final book = feed.$1;
      final text = bookIdentity(
        '${book.title} ${book.author} ${book.description}',
      );
      final key = bookIdentity(query);
      return key.isEmpty ||
              text.contains(key) ||
              feed.$2.any(
                (chapter) => bookIdentity(chapter.title).contains(key),
              )
          ? [book]
          : [];
    }
    final discovery = query.isEmpty;
    final path = discovery
        ? source.discover
        : source.search.replaceAll('{key}', _encodeQuery(source, query));
    if (path.isEmpty) return [];
    final target = source.resolve(source.endpoint, path);
    final response = discovery || source.searchForm.isEmpty
        ? await fetch(source, target, token)
        : await network.postForm(target, {
            for (final entry in source.searchForm.entries)
              entry.key: entry.value.replaceAll('{key}', query),
          }, cancellation: token);
    return (await _parseHtmlBooks(
      source,
      response,
      token,
      discovery: discovery,
    )).books;
  }

  Future<BookDiscoveryPage> _parseHtmlBooks(
    BookSource source,
    Document response,
    CancellationToken token, {
    required bool discovery,
  }) async {
    token.check();
    final text = response.text;
    final uri = response.uri;
    final mapping = source.jsonCatalog[discovery ? 'discover' : 'search'];
    final parsed = await Isolate.run(
      () => mapping == null
          ? _htmlBooks(source, uri, text, discovery)
          : _jsonBooks(source, uri, text, mapping),
    );
    token.check();
    return parsed;
  }

  static BookDiscoveryPage _jsonBooks(
    BookSource source,
    Uri base,
    String text,
    BookCatalogRules mapping,
  ) {
    final payload = jsonDecode(text);
    final rows = mapping.read(payload, 'list');
    if (rows is! List) throw const FormatException('JSON 书目列表无效');
    final books = <Uri, Book>{};
    for (final row in rows.take(5000)) {
      final title = bookLabel(mapping.read(row, 'title'));
      final link = mapping.read(row, 'url');
      if (title.isEmpty || link is! String || link.trim().isEmpty) continue;
      try {
        final uri = source.resolve(base, link);
        books.putIfAbsent(
          uri,
          () => Book(
            source.id,
            source.kind,
            title,
            bookLabel(mapping.read(row, 'author')),
            uri,
            description: bookLabel(mapping.read(row, 'description'), 600),
            cover: bookCoverAddress(
              base,
              '${mapping.read(row, 'cover') ?? ''}',
            ),
          ),
        );
      } on FormatException {
        continue;
      }
    }
    final next = mapping.read(payload, 'next');
    final target = next is String && next.trim().isNotEmpty
        ? source.resolve(base, next)
        : null;
    return (
      books: books.values.toList(),
      next: target == base ? null : target?.toString(),
    );
  }

  Future<List<Book>> _mappedFeatured(
    BookSource source,
    LegadoCategory? category,
    CancellationToken token, {
    required bool allowRedirects,
  }) async {
    final defaultTarget = source.resolve(source.endpoint, source.discover);
    final target = source.resolve(
      source.endpoint,
      category?.address ?? source.discover,
    );
    try {
      final response = await fetch(
        source,
        target,
        token,
        allowRedirects: allowRedirects,
      );
      final listing = await _parseHtmlBooks(
        source,
        response,
        token,
        discovery: true,
      );
      return [
        if (target == defaultTarget) ...source.featured,
        ...listing.books.where(
          (book) =>
              target != defaultTarget ||
              !source.featured.any((featured) => featured.uri == book.uri),
        ),
      ];
    } on RemoteFailure catch (error) {
      token.check();
      if (target != defaultTarget || error.kind == FailureKind.cancelled) {
        rethrow;
      }
      return source.featured;
    }
  }

  static BookDiscoveryPage _htmlBooks(
    BookSource source,
    Uri base,
    String text,
    bool discovery,
  ) {
    final document = parseBookHtml(text, keepNavigation: true);
    String rule(String key) {
      final discoverKey = 'discover${key[0].toUpperCase()}${key.substring(1)}';
      return (discovery ? source.rules[discoverKey] : null) ??
          source.rules[key] ??
          '';
    }

    final results = <Uri, Book>{};
    final heading = discovery ? source.rules['discoverAuthorHeading'] : null;
    final list = rule('list');
    final headings = heading == null
        ? const <dom.Element>{}
        : bookElements(document, heading).toSet();
    var author = '';
    final rows = heading == null
        ? bookElements(document, list)
        : bookElements(document, '$heading, $list');
    for (final row in rows) {
      if (headings.contains(row)) {
        author = bookLabel(plainBookText(row));
        continue;
      }
      final title = bookLabel(bookField(row, rule('title')));
      final link = bookField(row, rule('book'));
      if (title.isEmpty || link.isEmpty) continue;
      try {
        final uri = source.resolve(base, link);
        final cover = bookField(
          row,
          rule('cover').isEmpty ? 'img@src' : rule('cover'),
        );
        final category = bookLabel(bookField(row, rule('category')));
        results.putIfAbsent(
          uri,
          () => Book(
            source.id,
            source.kind,
            title,
            rule('author').isEmpty
                ? author
                : bookLabel(
                    bookField(
                      row,
                      rule('author'),
                    ).replaceFirst(RegExp(r'^作者[:：]\s*'), ''),
                  ),
            uri,
            description: bookLabel(bookField(row, rule('description')), 600),
            cover: bookCoverAddress(base, cover),
            category: category,
            wordCount: bookLabel(
              bookField(
                row,
                rule('wordCount'),
              ).replaceFirst(RegExp(r'^字数[:：]\s*'), ''),
            ),
            latestChapter: bookLabel(bookField(row, rule('latest'))),
            updatedLabel: bookLabel(bookField(row, rule('updated'))),
            rankLabel: bookLabel(bookField(row, rule('rank'))),
          ),
        );
      } on FormatException {
        continue;
      }
    }
    final next = discovery
        ? bookField(document, source.rules['nextDiscover'] ?? '')
        : '';
    final target = next.isEmpty ? null : source.resolve(base, next);
    return (
      books: results.values.toList(),
      next: target == base ? null : target?.toString(),
    );
  }

  Future<List<BookChapter>> chapters(
    BookSource source,
    Book book,
    CancellationToken token, {
    BookRequestGuard? requestGuard,
  }) async {
    _requireNovelSource(source);
    if (source.format == BookFormat.shuyin) {
      return _shuyin.chapters(source, book, token);
    }
    if (source.format == BookFormat.bookan) {
      return _bookan.chapters(source, book, token);
    }
    if (source.format == BookFormat.ximalaya) {
      return _ximalaya.chapters(source, book, token);
    }
    if (source.format == BookFormat.lit2go) {
      return _lit2go.chapters(source, book, token);
    }
    if (_hasLegadoRules(source)) {
      return _legado.chapters(source, book, token, requestGuard: requestGuard);
    }
    if (source.format == BookFormat.feed) {
      return (await _feed(source, token)).$2;
    }
    return _nativeChapters(source, book, token, requestGuard);
  }

  Future<String> text(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    void Function(List<BookChapterSegment>)? onSegments,
    BookRequestGuard? requestGuard,
  }) async {
    if (_hasLegadoRules(source)) {
      return _legado.text(
        source,
        chapter,
        token,
        book: book,
        requestGuard: requestGuard,
      );
    }
    if (source.format == BookFormat.feed) {
      if (chapter.body.isNotEmpty) return chapter.body;
      final feed = await _feed(source, token);
      final body = feed.$2.where((c) => c.id == chapter.id).firstOrNull?.body;
      if (body == null || body.isEmpty) {
        throw const FormatException('订阅未提供该篇正文');
      }
      return body;
    }
    final parts = <String>[];
    final mixed = <BookChapterSegment>[];
    final visited = <Uri>{};
    var next = chapter.uri;
    for (var page = 0; page < 10 && visited.add(next); page++) {
      final response = await fetch(
        source,
        next,
        token,
        requestGuard: requestGuard,
      );
      if (response.contentType?.toLowerCase().startsWith('image/') == true) {
        throw const FormatException('章节仅提供图片，文本阅读器无法打开');
      }
      final document = parseBookHtml(response.text);
      final body = bookField(document, source.rules['content']!, long: true);
      if (body.isEmpty) {
        final selector = source.rules['content']!.replaceFirst(
          RegExp(r'@(?:text|html)$'),
          '',
        );
        final imageOnly = bookElements(document, selector).any(
          (node) =>
              node.localName == 'img' || node.querySelector('img') != null,
        );
        throw FormatException(imageOnly ? '章节仅提供图片，文本阅读器无法打开' : '来源未返回章节正文');
      }
      if (!parts.contains(body)) parts.add(body);
      if (onSegments != null) {
        try {
          mixed.addAll(
            extractBookChapterSegments(
              source,
              response.uri,
              response.text,
              source.rules['content']!,
            ),
          );
        } on FormatException {
          // Unsupported mixed layout must not hide valid text.
        }
      }
      if (parts.fold<int>(0, (sum, part) => sum + part.length) > 500000) {
        throw const FormatException('章节正文超过大小限制');
      }
      final pagination = source.rules['nextContent'] ?? '';
      if (pagination.isEmpty) break;
      final more = bookField(
        parseBookHtml(response.text, keepNavigation: true),
        pagination,
      );
      if (more.isEmpty) break;
      next = source.resolve(response.uri, more);
      if (page == 9 && !visited.contains(next)) {
        throw const FormatException('章节分页超过限制，正文未完整获取');
      }
    }
    final result = parts.join('\n\n');
    if (result.length > 500000) throw const FormatException('章节正文超过大小限制');
    if (mixed.any((part) => part is BookImageSegment)) onSegments?.call(mixed);
    return result;
  }

  /// Static image chapters. Every media address is resolved through the
  /// source's declared host policy before it reaches the reader.
  Future<List<Uri>> chapterImages(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    BookRequestGuard? requestGuard,
  }) async {
    if (source.kind == BookKind.audio || source.format != BookFormat.html) {
      return const [];
    }
    if (RegExp(
      r'\.(?:png|jpe?g|webp|gif)$',
      caseSensitive: false,
    ).hasMatch(chapter.uri.path)) {
      final uri = source.requestTarget(chapter.uri, media: true);
      requestGuard?.call(uri, chapter.request);
      return [uri];
    }
    if (source.legado != null) {
      return _legado.images(
        source,
        chapter,
        token,
        book: book,
        requestGuard: requestGuard,
      );
    }
    final response = await fetch(
      source,
      chapter.uri,
      token,
      maxBytes: 4 * 1024 * 1024,
      requestGuard: requestGuard,
    );
    token.check();
    if (response.contentType?.toLowerCase().startsWith('image/') == true) {
      return [source.requestTarget(response.uri, media: true)];
    }
    final rule = source.legado?.rules['content'] ?? source.rules['content'];
    if (rule == null || rule.isEmpty) return const [];
    final images = extractBookChapterImages(
      source,
      response.uri,
      response.text,
      rule,
    );
    for (final image in images) {
      requestGuard?.call(image, null);
    }
    return images;
  }

  Future<Uri> audio(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    BookRequestGuard? requestGuard,
  }) async {
    if (source.format == BookFormat.shuyin) {
      return _shuyin.audio(source, chapter, token);
    }
    if (source.format == BookFormat.bookan) {
      return _bookan.audio(source, chapter);
    }
    if (source.format == BookFormat.ximalaya) {
      return _ximalaya.audio(source, chapter, token);
    }
    if (source.format == BookFormat.lit2go) {
      return _lit2go.audio(source, chapter, token);
    }
    if (_hasLegadoRules(source)) {
      return _legado.audio(
        source,
        chapter,
        token,
        book: book,
        requestGuard: requestGuard,
      );
    }
    if (source.format == BookFormat.feed || source.directAudio) {
      final uri = source.resolve(
        source.endpoint,
        chapter.uri.toString(),
        media: true,
      );
      requestGuard?.call(uri, chapter.request);
      return uri;
    }
    final response = await fetch(
      source,
      chapter.uri,
      token,
      requestGuard: requestGuard,
    );
    final address = bookField(
      parseBookHtml(response.text),
      source.rules['content']!,
    );
    if (address.isEmpty) throw const FormatException('来源未提供直连音频');
    final uri = source.resolve(response.uri, address, media: true);
    requestGuard?.call(uri, null);
    return uri;
  }

  Future<(Uri, List<int>)> sampleAudio(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    BookRequestGuard? requestGuard,
  }) async {
    final uri = await audio(
      source,
      chapter,
      token,
      book: book,
      requestGuard: requestGuard,
    );
    final payload = await network.http.open(
      uri,
      policy: HeaderPolicy({uri: const {}}),
      range: 'bytes=0-127',
      cancellation: token,
      validateTarget: (target) {
        source.requestTarget(target, media: true);
        requestGuard?.call(target, null);
      },
    );
    if (!{200, 206}.contains(payload.response.statusCode)) {
      await payload.body.take(0).drain<void>();
      throw const FormatException('音频地址请求失败');
    }
    return (
      payload.uri,
      await payload.body.expand((chunk) => chunk).take(64).toList(),
    );
  }

  Future<(Book, List<BookChapter>)> _feed(
    BookSource source,
    CancellationToken token,
  ) async {
    final response = source.legado == null
        ? await fetch(source, source.endpoint, token)
        : await _legado.feedDocument(source, token);
    final raw = response.text;
    if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(raw)) {
      throw const FormatException('订阅不能包含 XML 实体或文档类型声明');
    }
    final root = XmlDocument.parse(raw).rootElement;
    final atom = root.name.local == 'feed';
    final channel = atom ? root : root.getElement('channel');
    if (channel == null) throw const FormatException('地址没有返回 RSS 或 Atom');
    String field(XmlElement node, String key) =>
        node.childElements
            .where((e) => e.name.local == key)
            .firstOrNull
            ?.innerText ??
        '';
    final title = bookLabel(field(channel, 'title'));
    if (title.isEmpty) throw const FormatException('订阅缺少标题');
    final author = bookLabel(field(channel, 'author'));
    final book = Book(
      source.id,
      source.kind,
      title,
      author,
      source.endpoint,
      description: bookLabel(
        plainBookText(
          parseBookHtml(field(channel, atom ? 'subtitle' : 'description')),
        ),
        600,
      ),
    );
    final items = <Uri, BookChapter>{};
    for (final entry
        in channel.childElements
            .where((e) => e.name.local == (atom ? 'entry' : 'item'))
            .take(500)) {
      final name = bookLabel(field(entry, 'title'));
      if (name.isEmpty) continue;
      if (source.kind == BookKind.audio) {
        for (final element in entry.childElements.where(
          (e) =>
              e.name.local == 'enclosure' ||
              (e.name.local == 'link' && e.getAttribute('rel') == 'enclosure'),
        )) {
          final path = element.getAttribute(atom ? 'href' : 'url') ?? '';
          if (path.isEmpty) continue;
          try {
            final address = Uri.parse(path);
            // Some HTTPS publishers still advertise legacy HTTP enclosures.
            final secure = address.scheme == 'http' && !address.hasPort
                ? address.replace(scheme: 'https')
                : address;
            final uri = source.resolve(
              response.uri,
              secure.toString(),
              media: true,
            );
            items.putIfAbsent(uri, () => BookChapter(name, uri));
            break;
          } on FormatException {
            continue;
          }
        }
      } else {
        final rawBody = [
          field(entry, 'encoded'),
          field(entry, 'content'),
          field(entry, 'description'),
          field(entry, 'summary'),
        ].firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
        final body = plainBookText(parseBookHtml(rawBody));
        if (body.isEmpty) continue;
        final id = [
          field(entry, 'guid'),
          field(entry, 'id'),
          field(entry, 'link'),
          name,
        ].firstWhere((value) => value.trim().isNotEmpty);
        final uri = source.endpoint.replace(
          fragment: base64Url.encode(
            utf8.encode(id.length > 512 ? id.substring(0, 512) : id),
          ),
        );
        items.putIfAbsent(uri, () => BookChapter(name, uri, body: body));
      }
    }
    return (book, items.values.toList());
  }
}

String _encodeQuery(BookSource source, String query) => encodeDocumentComponent(
  query,
  source.searchCharset == 'utf-8' ? utf8 : gbk,
);

void _requireNovelSource(BookSource source) {
  if (source.kind == BookKind.text &&
      source.endpoint.host.replaceFirst(RegExp(r'^www\.'), '') == 'dict.cn') {
    throw const FormatException('海词渠道提供词典释义，缺少小说详情、目录和章节正文');
  }
}
