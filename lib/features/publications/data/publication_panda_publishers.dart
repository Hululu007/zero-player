import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const hinabookPublicationSource = 'panda-hinabook';
final hinabookCataloguePage = Uri.https('www.hinabook.com', '/shop');
final _hinaProduct = RegExp(r'^/product-page/[^/]{1,200}$');

final class HinabookCatalogue implements PublicationCatalogue {
  HinabookCatalogue(this.http);

  final PublicationHttp http;
  Future<List<PublicationEdition>>? _index;

  @override
  Future<void> check(CancellationToken token) async {
    await _books(token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final books = await _books(token);
    return books
        .where(
          (book) => book.matches(query, filter: filter) && allowed(book.title),
        )
        .toList();
  }

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(hinabookCataloguePage);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final rows = jsonDecode(
      await rootBundle.loadString('assets/catalogs/books/panda-hinabook.json'),
    );
    if (rows is! List || rows.isEmpty || rows.length > 5000) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final books = <PublicationEdition>[];
    for (final row in rows) {
      if (row case {'title': final String title, 'page': final String raw}) {
        final page = publicListingLink(
          hinabookCataloguePage,
          raw,
          _hinaProduct,
        );
        if (page == null || title.trim().isEmpty) continue;
        books.add(
          PublicationEdition(
            id: publicationId('$hinabookPublicationSource\n$page'),
            title: publicationLabel(title),
            publisher: '后浪',
            language: 'zh',
            page: page,
            cover: publicationCoverUrl(
              page,
              row['cover'],
              (uri) =>
                  uri.host == 'static.wixstatic.com' &&
                  uri.path.startsWith('/media/'),
            ),
          ),
        );
      }
    }
    if (books.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return books;
  }
}

const commercialPressSource = 'panda-commercial-press';
final commercialPressHome = Uri.https('www.cp.com.cn', '/book/');
final commercialPressEndpoint = commercialPressHome.resolve('search.dhtml');
final _pressBook = RegExp(r'^/book/[a-zA-Z0-9_-]{4,64}\.html$');
final _pressIsbn = RegExp(r'^/book/([0-9X-]{10,22})(?:_\d+)?\.html$');
final _pressCredit = RegExp(r"^zith2\('([^'\\]{1,640})'\);?$");

PublicListingCatalogue commercialPressCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => query.isEmpty
          ? commercialPressHome.resolve('new.dhtml')
          : commercialPressEndpoint.replace(
              queryParameters: {
                'fenlei_text': query,
                if (page > 1) 'page': '$page',
              },
            ),
      parse: parseCommercialPressCatalogue,
    );

PublicationListingPage parseCommercialPressCatalogue(String body) {
  final document = html.parse(body);
  final container = document.querySelector('#picture_list');
  if (container == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final item in container.children) {
    final anchor = item.querySelector('.dt h2 a[href]');
    final page = publicListingLink(
      commercialPressHome,
      anchor?.attributes['href'],
      _pressBook,
    );
    final title = publicationLabel(anchor?.text);
    if (page == null || title.isEmpty) continue;
    // The publisher calls a formatter with a literal credit list.
    final credits = <String>{};
    for (final script in item.querySelectorAll('.dt .material script')) {
      final field = _pressCredit.firstMatch(script.text.trim())?[1] ?? '';
      for (final segment in field.split(',')) {
        final columns = segment.split('|');
        if (columns.length == 3 && columns[1].isNotEmpty) {
          credits.add(columns[1].trim());
        }
      }
    }
    books[page] = PublicationEdition(
      id: publicationId('$commercialPressSource\n$page'),
      title: title,
      author: publicationLabel(credits.join('、')),
      isbn: normalizedIsbn(_pressIsbn.firstMatch(page.path)?[1] ?? ''),
      publisher: '商务印书馆',
      page: page,
      cover: publicationCoverUrl(
        page,
        item.querySelector('.dt .pho img')?.attributes['src'],
        (uri) => uri.host == 'pic.cp.com.cn' && uri.path.startsWith('/Images/'),
      ),
    );
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('a.Pnext[href]') != null,
  );
}

const imaginistPublicationSource = 'panda-imaginist';
final imaginistHome = Uri.https('www.ilixiangguo.com', '/book/book/index');
final imaginistEndpoint = imaginistHome.resolve('/portal/search/index');
final _imaginistBook = RegExp(r'^/book/book/view/id/[1-9][0-9]{0,8}$');

PublicListingCatalogue imaginistCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, _) => query.isEmpty
          ? imaginistHome
          : imaginistEndpoint.replace(queryParameters: {'keyword': query}),
      parse: parseImaginistCatalogue,
      maxBytes: 1200 << 10,
    );

PublicationListingPage parseImaginistCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector(
        'form[action="/portal/search/index"] input[name=keyword]',
      ) ==
      null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in document.querySelectorAll('.k')) {
    final heading = row.querySelector('.t1.h1');
    final page = publicListingLink(
      imaginistHome,
      heading?.parent?.attributes['href'],
      _imaginistBook,
    );
    final title = publicationLabel(heading?.text);
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$imaginistPublicationSource\n$page'),
      title: title,
      author: publicationLabel(
        row.querySelector('.t1.h2')?.text,
      ).replaceFirst(RegExp(r'\s+著$'), ''),
      publisher: '理想国',
      page: page,
      cover: publicationCoverUrl(
        page,
        row.querySelector('img.imgbot')?.attributes['src'],
        (uri) =>
            uri.host == page.host && uri.path.startsWith('/data/upload/thumb/'),
      ),
    );
  }
  return (books: books.values.toList(), hasNext: false);
}

const thinkingdomPublicationSource = 'panda-thinkingdom';
final thinkingdomCataloguePage = Uri.https(
  'www.readinglife.com',
  '/books.html',
  {'currentPage': 'books', 'langType': 'ZH'},
);
final _thinkingdomSection = RegExp(r'^nav[1-9][0-9]?$');
final _thinkingdomCover = RegExp(
  r'^/product_image/upload/imageRealUrl/cover/\d{4}-\d{2}-\d{2}/\d+\.(jpe?g|png)$',
  caseSensitive: false,
);
final _thinkingdomAuthors = thinkingdomCataloguePage.replace(
  path: '/writer.html',
  queryParameters: {'currentPage': 'writer', 'langType': 'ZH'},
);
final _thinkingdomAuthorPage = RegExp(
  r'^/writer/[1-9]\d{0,8}/[^/]{1,180}\.html$',
);

final class ThinkingdomCatalogue implements PublicationCatalogue {
  const ThinkingdomCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _featured => PublicListingCatalogue(
    http,
    address: (_, _) => thinkingdomCataloguePage,
    parse: parseThinkingdomCatalogue,
    searchLocally: true,
  );

  @override
  Future<void> check(CancellationToken token) => _featured.check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    if (filter?.field == PublicationSearchField.author) {
      return _searchAuthors(filter!, token, allowed);
    }
    return _featured.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
    );
  }

  Future<List<PublicationEdition>> _searchAuthors(
    PublicationFieldSearch filter,
    CancellationToken token,
    bool Function(String) allowed,
  ) async {
    final document = html.parse(
      await publicListingText(http, _thinkingdomAuthors, token),
    );
    final directory = document.querySelector('.key-writers');
    if (directory == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final authors = <Uri, String>{};
    for (final row in directory.querySelectorAll('li')) {
      final page = publicListingLink(
        _thinkingdomAuthors,
        row.querySelector('a.writer-img')?.attributes['href'],
        _thinkingdomAuthorPage,
      );
      final name = row
          .querySelectorAll('.writer-name em')
          .map((label) => publicationLabel(label.text))
          .where((label) => label.isNotEmpty)
          .toSet()
          .join(' / ');
      if (page != null && filter.matchesFields(author: name) && allowed(name)) {
        authors[page.replace(queryParameters: {'langType': 'ZH'})] = name;
      }
    }
    return _publisherAuthorWorks(http, authors, token, allowed, (
      document,
      author,
      name,
    ) {
      final works = document.querySelector('.author-works .body');
      if (works == null) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      return works
          .querySelectorAll('li')
          .map((row) => _thinkingdomBook(row, author, author: name))
          .nonNulls;
    });
  }
}

PublicationListingPage parseThinkingdomCatalogue(String body) {
  final document = html.parse(body);
  final sections = document.querySelectorAll('#work-container .works-box[id]');
  final books = <Uri, PublicationEdition>{};
  for (final section in sections) {
    final id = section.id;
    if (!_thinkingdomSection.hasMatch(id)) continue;
    final page = thinkingdomCataloguePage.replace(fragment: id);
    for (final row in section.querySelectorAll('.works-body li')) {
      final book = _thinkingdomBook(row, page);
      if (book != null) books[book.cover!] = book;
    }
  }
  if (books.isEmpty) throw const PublicationFailure(PublicationProblem.invalid);
  return (books: books.values.toList(), hasNext: false);
}

PublicationEdition? _thinkingdomBook(
  Element row,
  Uri page, {
  String author = '',
}) {
  final title = publicationLabel(row.querySelector('em')?.text);
  final cover = publicationCoverUrl(
    page,
    row.querySelector('img[alt]')?.attributes['src'],
    (uri) => uri.host == page.host && _thinkingdomCover.hasMatch(uri.path),
  );
  if (title.isEmpty || cover == null) return null;
  return PublicationEdition(
    id: publicationId('$thinkingdomPublicationSource\n$cover'),
    title: title,
    author: author,
    publisher: '新经典文化',
    page: page,
    cover: cover,
  );
}

const dookbookPublicationSource = 'panda-dookbook';
final dookbookCataloguePage = Uri.https('www.dookbook.com', '/books/');
final _dookbookProduct = RegExp(r'^/[1-9][0-9]{5,11}\.html$');
final _dookbookBookDetails = RegExp(r'^/subject/[1-9][0-9]{5,11}/$');
final _dookbookCover = RegExp(
  r'^/pic/[A-Za-z0-9_.-]{5,120}\.(jpe?g|png)$',
  caseSensitive: false,
);
final _dookbookAuthors = dookbookCataloguePage.resolve('/author/');
final _dookbookAuthorPage = RegExp(r'^/author/authorLook/id-[1-9][0-9]{0,7}$');

final class DookbookCatalogue implements PublicationCatalogue {
  const DookbookCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _featured => PublicListingCatalogue(
    http,
    address: (_, _) => dookbookCataloguePage,
    parse: parseDookbookCatalogue,
    searchLocally: true,
  );

  @override
  Future<void> check(CancellationToken token) => _featured.check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    if (filter?.field != PublicationSearchField.author) {
      return _featured.search(
        query,
        token,
        maxPages: maxPages,
        allowed: allowed,
        filter: filter,
      );
    }
    final initial = html.parse(
      await publicListingText(http, _dookbookAuthors, token),
    );
    final pages = <int>{};
    for (final link in initial.querySelectorAll('.pagination a[href]')) {
      final address = Uri.tryParse(link.attributes['href'] ?? '');
      if (address == null) continue;
      final target = _dookbookAuthors.resolveUri(address);
      final page = int.tryParse(target.queryParameters['p'] ?? '');
      if (target.scheme == 'https' &&
          target.origin == _dookbookAuthors.origin &&
          target.userInfo.isEmpty &&
          target.path == '/author/Home' &&
          page != null &&
          page >= 2 &&
          page <= 20) {
        pages.add(page);
      }
    }
    final extra = await Future.wait(
      pages.map((page) async {
        final target = _dookbookAuthors.resolve('/author/Home?&p=$page');
        return html.parse(await publicListingText(http, target, token));
      }),
    );
    final authors = <Uri, String>{};
    for (final document in [initial, ...extra]) {
      for (final row in document.querySelectorAll('.writlist')) {
        final page = publicListingLink(
          _dookbookAuthors,
          row.querySelector('a')?.attributes['href'],
          _dookbookAuthorPage,
        );
        final label = row.children
            .where((element) => element.localName == 'span')
            .firstOrNull;
        // The site separates the two names with a line break.
        final names =
            label?.nodes
                .map((node) => publicationLabel(node.text))
                .where((name) => name.isNotEmpty)
                .toSet()
                .join(' / ') ??
            '';
        if (page != null &&
            filter!.matchesFields(author: names) &&
            allowed(names)) {
          authors[page] = names;
        }
      }
    }
    return _publisherAuthorWorks(http, authors, token, allowed, (
      document,
      _,
      name,
    ) {
      final works = document.querySelector('.dele_cot');
      if (works == null) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      return _dookbookBooks(works.querySelectorAll('a[href]'), author: name);
    });
  }
}

PublicationListingPage parseDookbookCatalogue(String body) {
  final books = _dookbookBooks(html.parse(body).querySelectorAll('a[href]'));
  if (books.isEmpty) throw const PublicationFailure(PublicationProblem.invalid);
  return (books: books, hasNext: false);
}

List<PublicationEdition> _dookbookBooks(
  List<Element> links, {
  String author = '',
}) {
  final books = <Uri, PublicationEdition>{};
  for (final anchor in links) {
    final image = anchor.querySelector('img[alt][src]');
    final title = publicationLabel(image?.attributes['alt']);
    if (title.isEmpty) continue;
    final page = _publisherHttpsLink(
      anchor.attributes['href'],
      (uri) =>
          (uri.host == 'product.dangdang.com' &&
              _dookbookProduct.hasMatch(uri.path)) ||
          (uri.host == 'book.douban.com' &&
              _dookbookBookDetails.hasMatch(uri.path)),
    );
    final cover = _publisherHttpsLink(
      image?.attributes['src'],
      (uri) =>
          uri.host == 'static.dookbook.com' &&
          _dookbookCover.hasMatch(uri.path),
    );
    if (page == null || cover == null) continue;
    books[page] = PublicationEdition(
      id: publicationId('$dookbookPublicationSource\n$page'),
      title: title,
      author: author,
      publisher: '读客文化',
      page: page,
      cover: cover,
    );
  }
  return books.values.toList();
}

Future<List<PublicationEdition>> _publisherAuthorWorks(
  PublicationHttp http,
  Map<Uri, String> authors,
  CancellationToken token,
  bool Function(String) allowed,
  Iterable<PublicationEdition> Function(Document, Uri, String) parse,
) async {
  Exception? error;
  final groups = await Future.wait(
    authors.entries.take(6).map((author) async {
      try {
        return parse(
          html.parse(await publicListingText(http, author.key, token)),
          author.key,
          author.value,
        );
      } on Exception catch (cause) {
        token.check();
        error ??= cause;
        return const <PublicationEdition>[];
      }
    }),
  );
  final results = <String, PublicationEdition>{};
  for (final book in groups.expand((books) => books)) {
    if (allowed('${book.title} ${book.author}')) results[book.id] = book;
  }
  if (results.isEmpty && error != null) throw error!;
  return results.values.take(60).toList();
}

Uri? _publisherHttpsLink(String? raw, bool Function(Uri) accepts) {
  if (raw == null || raw.length > 2048) return null;
  final input = Uri.tryParse(raw.trim());
  if (input == null ||
      (input.scheme != 'https' && input.scheme != 'http') ||
      input.userInfo.isNotEmpty ||
      input.port != (input.scheme == 'https' ? 443 : 80) ||
      !accepts(input)) {
    return null;
  }
  return Uri.https(input.host, input.path);
}
