import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const bookStackSource = 'panda-bookstack';
final bookStackHome = Uri.https('www.bookstack.cn', '/');
final bookStackEndpoint = bookStackHome.resolve('/search/result');
final _stackBook = RegExp(r'^/books/[a-zA-Z0-9_.-]{1,120}/?$');

PublicListingCatalogue bookStackCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => query.isEmpty
          ? bookStackHome
          : bookStackEndpoint.replace(
              queryParameters: {
                'wd': query,
                'tab': 'book',
                if (page > 1) 'page': '$page',
              },
            ),
      parse: parseBookStackCatalogue,
    );

PublicationListingPage parseBookStackCatalogue(String body) {
  final document = html.parse(body);
  final books = <Uri, PublicationEdition>{};
  for (final item in document.querySelectorAll('.wd-book-item, li.clearfix')) {
    final anchor = item.querySelector('a h4, a .wd-book-title')?.parent;
    final page = publicListingLink(
      bookStackHome,
      anchor?.attributes['href'],
      _stackBook,
    );
    final title = publicationLabel(anchor?.text);
    if (page == null || title.isEmpty || page.path == '/books/help') continue;
    books[page] = PublicationEdition(
      id: publicationId('$bookStackSource\n$page'),
      title: title,
      page: page,
      cover: publicationCoverUrl(
        bookStackHome,
        item.querySelector('img')?.attributes['src'],
        (uri) =>
            uri.host == 'static.bookstack.cn' &&
            uri.path.startsWith('/projects/'),
      ),
    );
  }
  if (books.isEmpty &&
      document.querySelector('ul.nav-tabs a[href*="tab=book"]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return (
    books: books.values.toList(),
    hasNext:
        books.isNotEmpty &&
        document.querySelector('.pagination .active + li a.num') != null,
  );
}

const taiwanEbookSource = 'panda-taiwan-ebook';
final taiwanEbookHome = Uri.https('taiwanebook.ncl.edu.tw', '/zh-tw');
final _taiwanBook = RegExp(r'^/zh-tw/book/[A-Z0-9]+-[0-9A-Z-]{3,35}$');
final _taiwanPhrase = RegExp(r'^[^\s"/]+$');

PublicListingCatalogue taiwanEbookCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => query.isEmpty
          ? taiwanEbookHome.resolve('/zh-tw/time/Other/publish-time/desc/table')
          : Uri(
              scheme: 'https',
              host: taiwanEbookHome.host,
              pathSegments: [
                'zh-tw',
                'search',
                'all',
                _taiwanPhrase.hasMatch(query)
                    ? '"$query"'
                    : query.replaceAll('/', ' '),
                'maintitle',
                'asc',
                'table',
                '$page',
              ],
            ),
      parse: parseTaiwanEbookCatalogue,
      maxBytes: 2 << 20,
      deadline: const Duration(seconds: 17),
    );

PublicationListingPage parseTaiwanEbookCatalogue(String body) {
  final document = html.parse(body);
  final books = <PublicationEdition>[];
  for (final row in document.querySelectorAll('table tbody tr')) {
    final cells = row.children;
    if (cells.length != 7) continue;
    final page = publicListingLink(
      taiwanEbookHome,
      cells.last.querySelector('a[href]')?.attributes['href'],
      _taiwanBook,
    );
    final title = publicationLabel(cells[1].text);
    if (page == null || title.isEmpty) continue;
    books.add(
      PublicationEdition(
        id: publicationId('$taiwanEbookSource\n$page'),
        title: title,
        author: publicationLabel(cells[2].text),
        edition: publicationLabel(cells[3].text),
        publisher: publicationLabel(cells[4].text),
        page: page,
        language: 'zh-Hant',
      ),
    );
  }
  if (books.isEmpty &&
      !document
          .querySelectorAll('main h2')
          .any((item) => item.text.trim() == '查無資料')) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return (
    books: books,
    hasNext:
        document.querySelector('[rel=next], option[selected] + option') !=
            null &&
        books.isNotEmpty,
  );
}

const shukuiPublicationSource = 'panda-shukui';
final shukuiHome = Uri.https('www.shukui.net', '/');
final shukuiEndpoint = shukuiHome.resolve('/so/search.php');
final _shukuiBook = RegExp(r'^/(?:book|ebook)/[1-9][0-9]{0,9}\.html$');

final class ShukuiCatalogue implements PublicationCatalogue {
  const ShukuiCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) =>
      _library(shukuiEndpoint).check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    if (query.isEmpty) return const [];
    final errors = <Exception>[];
    final pages = await Future.wait([
      for (final endpoint in [
        shukuiEndpoint,
        shukuiHome.resolve('/s/search.php'),
      ])
        _library(endpoint)
            .search(
              query,
              token,
              maxPages: maxPages,
              allowed: allowed,
              filter: filter,
            )
            .onError<Exception>((error, stack) {
              token.check();
              if (error is PublicationFailure &&
                  error.problem == PublicationProblem.blocked) {
                throw error;
              }
              errors.add(error);
              return const <PublicationEdition>[];
            }),
    ]);
    if (errors.length == pages.length) throw errors.first;
    return [for (final page in pages) ...page];
  }

  PublicListingCatalogue _library(Uri endpoint) => PublicListingCatalogue(
    http,
    address: (query, page) => endpoint.replace(
      queryParameters: {'q': query, if (page > 1) 'p': '$page'},
    ),
    parse: parseShukuiCatalogue,
    allowEmptyBrowse: true,
  );
}

PublicationListingPage parseShukuiCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('#header input[name=q]') == null ||
      document.querySelector('#main') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final item in document.querySelectorAll('#main .cate-item')) {
    final anchor = item.querySelector('h2 a[href]');
    final page = publicListingLink(
      shukuiHome,
      anchor?.attributes['href'],
      _shukuiBook,
    );
    final title = publicationLabel(anchor?.text);
    if (page == null || title.isEmpty) continue;
    final metadata = <String, String>{};
    for (final field in item.querySelectorAll('.cate-info > p')) {
      final parts = field.text.trim().split('：');
      if (parts.length >= 2) {
        metadata[parts.first] = publicationLabel(parts.skip(1).join('：'));
      }
    }
    books[page] = PublicationEdition(
      id: publicationId('$shukuiPublicationSource\n$page'),
      title: title,
      author: metadata['作者'] ?? '',
      isbn: normalizedIsbn(metadata['ISBN'] ?? ''),
      publisher: metadata['出版社'] ?? '',
      edition: metadata['出版时间'] ?? '',
      page: page,
      cover: publicationCoverUrl(
        page,
        item.querySelector('img')?.attributes['data-original'],
        (uri) =>
            uri.host == page.host &&
            RegExp(r'^/cover/\d+/\d+\.jpg$').hasMatch(uri.path),
      ),
    );
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('.page-navi a.next[href]') != null,
  );
}

const moreReadPublicationSource = 'panda-moreread';
final moreReadHome = Uri.https('moreread.me', '/');
final moreReadEndpoint = moreReadHome.resolve('/search');
final _moreReadBook = RegExp(r'^/book/[1-9][0-9]{0,9}$');

PublicListingCatalogue moreReadCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) =>
          (query.isEmpty ? moreReadHome : moreReadEndpoint).replace(
            queryParameters: {
              if (query.isNotEmpty) 'term': query,
              if (page > 1) 'page': '$page',
            },
          ),
      parse: parseMoreReadCatalogue,
    );

PublicationListingPage parseMoreReadCatalogue(String body) {
  final section = html.parse(body).querySelector('div.site-section');
  if (section?.querySelector('#dataTable_info') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in section!.querySelectorAll('.entry2')) {
    final anchor = row.querySelector('.excerpt h6 a[href]');
    final page = publicListingLink(
      moreReadHome,
      anchor?.attributes['href'],
      _moreReadBook,
    );
    final title = publicationLabel(anchor?.text);
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$moreReadPublicationSource\n$page'),
      title: title,
      author: publicationLabel(
        row.querySelector('.post-meta .d-inline-block')?.text,
      ),
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext:
        section.querySelector('#dataTable_next:not(.disabled) a[href]') != null,
  );
}
