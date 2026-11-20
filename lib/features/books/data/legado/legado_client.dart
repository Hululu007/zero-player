import '../../../../core/network/cancellation_token.dart';
import '../../../../core/network/document_client.dart';
import '../../domain/book.dart';
import '../../domain/book_search.dart';
import '../../domain/legado_source.dart';
import '../book_request_guard.dart';
import 'legado_request.dart';
import 'kuwo_discovery.dart';
import 'legado_rule_tokens.dart';
import 'legado_script.dart';
import 'legado_worker.dart';
import 'yuque_book_list.dart';

final class LegadoBookClient {
  const LegadoBookClient(this.network);
  final DocumentClient network;

  Future<List<LegadoCategory>> categories(
    BookSource source,
    CancellationToken token, {
    bool Function(LegadoCategory)? allowCategory,
    void Function(LegadoCategory)? onDenied,
    bool allowDiscoveryNetworkExpansion = true,
  }) async {
    final spec = source.legado!;
    if (!spec.enabledExplore || source.format == BookFormat.feed) return [];
    final denied = <String>{};
    if (allowCategory != null) {
      for (final category in spec.categories) {
        if (!allowCategory(category)) {
          denied.add(category.address);
          onDenied?.call(category);
        }
      }
    }
    if (isKuwoAuditedDiscovery(source)) {
      if (denied.contains(spec.categories.single.address)) return [];
      final request = LegadoRequest.parse(
        source,
        source.endpoint,
        spec.categories.single.address,
      );
      final document = await _fetch(
        source,
        request,
        token,
        maxBytes: 512 * 1024,
        allowRedirects: allowDiscoveryNetworkExpansion,
      );
      token.check();
      return parseKuwoCategories(document.text);
    }
    final categories = <(String, String, String), LegadoCategory>{};
    Exception? failure;
    for (final category in spec.categories) {
      if (denied.contains(category.address)) continue;
      try {
        final entries =
            legadoScriptMarker.matchAsPrefix(category.address) == null
            ? [category]
            : (await _run(
                LegadoJob(
                  source,
                  source.endpoint,
                  LegadoOperation.discovery,
                  address: category.address,
                ),
                token,
                allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
              )).categories;
        for (final item in entries) {
          final grouped = category.group.isEmpty || item.group.isNotEmpty
              ? item
              : LegadoCategory(item.title, item.address, group: category.group);
          categories.putIfAbsent((
            grouped.group,
            grouped.title,
            grouped.address,
          ), () => grouped);
        }
      } on Exception catch (error) {
        token.check();
        failure = error;
      }
    }
    if (categories.isEmpty && failure != null) throw failure;
    return categories.values.toList();
  }

  Future<BookDiscoveryPage> discover(
    BookSource source,
    CancellationToken token, {
    LegadoCategory? category,
    int page = 1,
    String? cursor,
    bool allowDiscoveryNetworkExpansion = true,
  }) async {
    final options = category != null
        ? [category.address]
        : (await categories(
            source,
            token,
            allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
          )).map((item) => item.address);
    final request = cursor == null
        ? await _firstAddress(
            source,
            options,
            token,
            page: page,
            allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
          )
        : LegadoRequest.parse(source, source.endpoint, cursor, page: page);
    if (request == null) return (books: <Book>[], next: null);
    final parsed = await _list(
      source,
      request,
      token,
      page: page,
      discovery: true,
      allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
    );
    String? next;
    if (parsed.books.isNotEmpty) {
      final link = parsed.links.firstOrNull;
      final nextRequest = link != null
          ? _link(source, parsed.uri, link, page + 1)
          : (source.legado!.rules['nextExplore'] ?? '').isEmpty &&
                category?.paginated == true
          ? await _firstAddress(
              source,
              options,
              token,
              page: page + 1,
              allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
            )
          : null;
      if (nextRequest?.targetKey != request.targetKey) {
        next = nextRequest?.targetKey;
      }
    }
    return (books: parsed.books, next: next);
  }

  Future<Document> feedDocument(
    BookSource source,
    CancellationToken token,
  ) async {
    final address = source.legado!.search;
    final request = await _firstAddress(source, [address], token);
    if (request == null) throw const FormatException('Legado 订阅未提供可用地址');
    return _fetch(source, request, token);
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
    final spec = source.legado!;
    if (source.format == BookFormat.feed) {
      final book = Book(
        source.id,
        source.kind,
        source.name,
        '',
        source.endpoint,
      );
      final key = bookIdentity(query);
      if (key.isEmpty || bookIdentity(source.name).contains(key)) return [book];
      final articles = await chapters(source, book, token);
      return articles.any((item) => bookIdentity(item.title).contains(key))
          ? [book]
          : [];
    }
    if (bookAddress != null) {
      return _openAddress(
        source,
        bookAddress,
        token,
        allowNetworkExpansion: allowDiscoveryNetworkExpansion,
      );
    }
    final discovery = query.isEmpty || spec.search.isEmpty;
    final addresses = !discovery
        ? [spec.search]
        : category != null
        ? [category.address]
        : (await categories(
            source,
            token,
            allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
          )).map((item) => item.address);
    final request = await _firstAddress(
      source,
      addresses,
      token,
      query: query,
      page: page,
      allowDiscoveryNetworkExpansion:
          !discovery || allowDiscoveryNetworkExpansion,
    );
    if (request == null) return [];
    final parsed = await _list(
      source,
      request,
      token,
      query: query,
      page: page,
      discovery: discovery,
      allowDiscoveryNetworkExpansion:
          !discovery || allowDiscoveryNetworkExpansion,
    );
    if (discovery && query.trim().isNotEmpty) {
      final match = BookSearchQuery(query, BookSearchField.all);
      return parsed.books.where((book) => match.rank(book) != null).toList();
    }
    return parsed.books;
  }

  Future<({Uri uri, List<Book> books, List<String> links})> _list(
    BookSource source,
    LegadoRequest request,
    CancellationToken token, {
    String query = '',
    required int page,
    required bool discovery,
    bool allowDiscoveryNetworkExpansion = true,
  }) async {
    final document = await _fetch(
      source,
      request,
      token,
      allowRedirects: !discovery || allowDiscoveryNetworkExpansion,
    );
    final parsed = await _run(
      LegadoJob(
        source,
        document.uri,
        LegadoOperation.books,
        input: document.text,
        address: request.reference,
        query: query,
        page: page,
        discovery: discovery,
      ),
      token,
      allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
    );
    return (uri: document.uri, books: parsed.books, links: parsed.links);
  }

  Future<List<Book>> _openAddress(
    BookSource source,
    Uri address,
    CancellationToken token, {
    bool allowNetworkExpansion = true,
  }) async {
    if (!source.acceptsBookAddress(address)) return [];
    final safe = source.requestTarget(address);
    final match = await _run(
      LegadoJob(source, safe, LegadoOperation.matchBookUrl),
      token,
    );
    if (!match.matches) return [];
    final request = LegadoRequest.parse(source, source.endpoint, '$safe');
    final document = await _fetch(
      source,
      request,
      token,
      allowRedirects: allowNetworkExpansion,
    );
    return (await _run(
      LegadoJob(
        source,
        document.uri,
        LegadoOperation.details,
        input: document.text,
      ),
      token,
      allowDiscoveryNetworkExpansion: allowNetworkExpansion,
    )).books;
  }

  Future<List<BookChapter>> chapters(
    BookSource source,
    Book book,
    CancellationToken token, {
    BookRequestGuard? requestGuard,
  }) async {
    final articles = source.format == BookFormat.feed;
    final first = articles
        ? await _firstAddress(source, [
            source.legado!.search,
            ...source.legado!.explore,
          ], token)
        : _stored(source, book.uri, book.request);
    if (first == null) return [];
    final chapters = <String, BookChapter>{};
    final scheduled = <String>{first.targetKey};
    final queue = <LegadoRequest>[first];
    for (var index = 0; index < queue.length; index++) {
      final next = queue[index];
      final page = index + 1;
      final document = await _fetch(
        source,
        next,
        token,
        requestGuard: requestGuard,
      );
      final result = await _run(
        LegadoJob(
          source,
          document.uri,
          articles ? LegadoOperation.articles : LegadoOperation.toc,
          input: document.text,
          page: page,
          book: book,
        ),
        token,
        requestGuard: requestGuard,
      );
      for (final item in result.chapters) {
        if (chapters.containsKey(item.id)) continue;
        if (chapters.length == bookChapterCatalogLimit) {
          throw const FormatException('目录超过 $bookChapterCatalogLimit 章，未完整加载');
        }
        chapters[item.id] = item;
      }
      for (final address in result.links) {
        final request = _link(source, document.uri, address, page + 1);
        if (request == null || !scheduled.add(request.targetKey)) continue;
        if (queue.length >= bookChapterPageLimit) {
          throw const FormatException('目录分页超过安全上限，未完整加载');
        }
        queue.add(request);
      }
    }
    return chapters.values.toList();
  }

  Future<Book> details(
    BookSource source,
    Book book,
    CancellationToken token, {
    BookRequestGuard? requestGuard,
  }) async {
    final rules = source.legado!.rules;
    if (!rules.keys.any((key) => key.startsWith('info'))) return book;
    final request = _stored(source, book.uri, book.request);
    final document = await _fetch(
      source,
      request,
      token,
      requestGuard: requestGuard,
    );
    final result = await _run(
      LegadoJob(
        source,
        document.uri,
        LegadoOperation.details,
        input: document.text,
        book: book,
        address: book.request,
      ),
      token,
      requestGuard: requestGuard,
    );
    final details = result.books.firstOrNull;
    return details == null ? book : book.withDetails(details);
  }

  Future<String> text(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    BookRequestGuard? requestGuard,
  }) async {
    if (chapter.body.isNotEmpty) return chapter.body;
    if (source.format == BookFormat.feed &&
        (source.legado!.rules['content'] ?? '').isEmpty) {
      final series =
          book ??
          Book(source.id, source.kind, source.name, '', source.endpoint);
      final item = (await chapters(
        source,
        series,
        token,
        requestGuard: requestGuard,
      )).where((item) => item.id == chapter.id).firstOrNull;
      if (item != null && item.body.isNotEmpty) return item.body;
      throw const FormatException('订阅没有提供此篇正文规则');
    }
    var next = _stored(source, chapter.uri, chapter.request);
    final visited = <String>{};
    final parts = <String>[];
    var length = 0;
    for (var page = 1; page <= 10 && visited.add(next.targetKey); page++) {
      final document = await _fetch(
        source,
        next,
        token,
        requestGuard: requestGuard,
      );
      if (document.contentType?.toLowerCase().startsWith('image/') == true) {
        throw const FormatException('章节仅提供图片，文本阅读器无法打开');
      }
      final result = await _run(
        LegadoJob(
          source,
          document.uri,
          LegadoOperation.content,
          input: document.text,
          page: page,
          book: book,
          chapter: chapter,
        ),
        token,
        requestGuard: requestGuard,
      );
      if (result.content.isEmpty) {
        throw const FormatException('Legado 规则未提取到正文');
      }
      if (!parts.contains(result.content)) {
        length += result.content.length;
        if (length > 500000) throw const FormatException('章节正文超过大小限制');
        parts.add(result.content);
      }
      final more = result.links
          .map((link) => _link(source, document.uri, link, page + 1))
          .whereType<LegadoRequest>()
          .where((link) => !visited.contains(link.targetKey))
          .firstOrNull;
      if (more == null) break;
      if (page == 10) throw const FormatException('章节分页超过限制，正文未完整获取');
      next = more;
    }
    return parts.join('\n\n');
  }

  Future<List<Uri>> images(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    BookRequestGuard? requestGuard,
  }) async {
    if (RegExp(
      r'\.(?:png|jpe?g|webp|gif)$',
      caseSensitive: false,
    ).hasMatch(chapter.uri.path)) {
      final uri = source.requestTarget(chapter.uri, media: true);
      requestGuard?.call(uri, chapter.request);
      return [uri];
    }
    final document = await _fetch(
      source,
      _stored(source, chapter.uri, chapter.request),
      token,
      requestGuard: requestGuard,
    );
    if (document.contentType?.toLowerCase().startsWith('image/') == true) {
      return [source.requestTarget(document.uri, media: true)];
    }
    final result = await _run(
      LegadoJob(
        source,
        document.uri,
        LegadoOperation.images,
        input: document.text,
        book: book,
        chapter: chapter,
      ),
      token,
      requestGuard: requestGuard,
    );
    final images = <Uri>{};
    for (final address in result.links.take(100)) {
      Uri image;
      try {
        image = source.resolve(document.uri, address, media: true);
      } on FormatException {
        // A rule cannot authorize an undeclared media host.
        continue;
      }
      requestGuard?.call(image, null);
      images.add(image);
    }
    return images.toList();
  }

  Future<Uri> audio(
    BookSource source,
    BookChapter chapter,
    CancellationToken token, {
    Book? book,
    BookRequestGuard? requestGuard,
  }) async {
    if ((source.legado!.rules['content'] ?? '').isEmpty) {
      final uri = source.requestTarget(chapter.uri, media: true);
      requestGuard?.call(uri, chapter.request);
      return uri;
    }
    final document = await _fetch(
      source,
      _stored(source, chapter.uri, chapter.request),
      token,
      requestGuard: requestGuard,
    );
    final result = await _run(
      LegadoJob(
        source,
        document.uri,
        LegadoOperation.audio,
        input: document.text,
        book: book,
        chapter: chapter,
      ),
      token,
      requestGuard: requestGuard,
    );
    if (result.links.isEmpty) {
      throw const FormatException('Legado 规则未提取到已授权域名的音频');
    }
    final uri = source.requestTarget(
      Uri.parse(result.links.first),
      media: true,
    );
    requestGuard?.call(uri, null);
    return uri;
  }

  Future<LegadoRequest?> _firstAddress(
    BookSource source,
    Iterable<String> options,
    CancellationToken token, {
    String query = '',
    int page = 1,
    bool allowDiscoveryNetworkExpansion = true,
  }) async {
    FormatException? invalid;
    for (final address in options.where((address) => address.isNotEmpty)) {
      token.check();
      try {
        final links = legadoScriptMarker.hasMatch(address)
            ? (await _run(
                LegadoJob(
                  source,
                  source.endpoint,
                  LegadoOperation.address,
                  address: address,
                  query: query,
                  page: page,
                ),
                token,
                allowDiscoveryNetworkExpansion: allowDiscoveryNetworkExpansion,
              )).links
            : [address];
        for (final value in links) {
          try {
            return LegadoRequest.parse(
              source,
              source.endpoint,
              value,
              key: query,
              page: page,
            );
          } on FormatException catch (error) {
            invalid = error;
          }
        }
      } on FormatException catch (error) {
        invalid = error;
      }
    }
    if (invalid != null) throw invalid;
    return null;
  }

  Future<LegadoPage> _run(
    LegadoJob job,
    CancellationToken token, {
    bool allowDiscoveryNetworkExpansion = true,
    BookRequestGuard? requestGuard,
  }) async {
    if (isRepairedYuqueBookList(job.source) &&
        const {
          LegadoOperation.books,
          LegadoOperation.details,
          LegadoOperation.toc,
        }.contains(job.operation)) {
      if (job.uri.toString() != job.source.endpoint.toString()) {
        throw const FormatException('语雀书单页面地址不符');
      }
      job = LegadoJob(
        job.source,
        job.uri,
        job.operation,
        input: normalizeYuqueBookList(job.input),
        address: job.address,
        query: job.query,
        page: job.page,
        discovery: job.discovery,
        book: job.book,
        chapter: job.chapter,
      );
    }
    final documents = <String, String>{};
    for (var attempt = 0; ; attempt++) {
      try {
        return await runLegadoJob(job.withDocuments(documents), token);
      } on LegadoNeedsDocument catch (pending) {
        if (!allowDiscoveryNetworkExpansion) {
          throw const FormatException('成人过滤期间发现规则不支持脚本辅助网络请求');
        }
        if (attempt >= 3 || documents.containsKey(pending.address)) {
          throw const FormatException('Legado 脚本请求超过限制');
        }
        final request = LegadoRequest.parse(
          job.source,
          job.uri,
          pending.address,
        );
        if (request.form != null || request.json != null) {
          throw const FormatException('Legado 脚本辅助请求仅支持同站 GET');
        }
        documents[pending.address] = (await _fetch(
          job.source,
          request,
          token,
          requestGuard: requestGuard,
        )).text;
      }
    }
  }

  Future<Document> _fetch(
    BookSource source,
    LegadoRequest request,
    CancellationToken token, {
    int maxBytes = 2 * 1024 * 1024,
    bool allowRedirects = true,
    BookRequestGuard? requestGuard,
  }) {
    final uri = source.requestTarget(request.uri);
    requestGuard?.call(uri, request.targetKey);
    if (request.json case final Map<String, Object?> body) {
      return network.postJson(
        uri,
        body,
        headers: request.headers,
        maxBytes: maxBytes,
        cancellation: token,
      );
    }
    if (request.form case final Map<String, String> body) {
      return network.postForm(
        uri,
        body,
        headers: request.headers,
        maxBytes: maxBytes,
        cancellation: token,
        encoding: request.encoding,
      );
    }
    return network.get(
      uri,
      headers: request.headers,
      maxBytes: maxBytes,
      networkTimeout: const Duration(seconds: 12),
      cancellation: token,
      validateTarget: (target) {
        source.requestTarget(target);
        requestGuard?.call(target, null);
      },
      mapRedirect: allowRedirects
          ? null
          : (_) => throw const FormatException('成人过滤期间不跟随发现页面重定向'),
    );
  }
}

LegadoRequest _stored(BookSource source, Uri uri, String reference) {
  final safe = source.requestTarget(uri);
  final request = LegadoRequest.parse(
    source,
    safe,
    reference.isEmpty ? '$safe' : reference,
  );
  if (request.uri != safe) throw const FormatException('已保存的 Legado 请求地址不一致');
  return request;
}

LegadoRequest? _link(BookSource source, Uri base, String raw, int page) {
  try {
    return LegadoRequest.parse(source, base, raw, page: page);
  } on FormatException {
    return null;
  }
}
