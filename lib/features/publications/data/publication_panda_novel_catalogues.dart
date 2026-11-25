import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const bookLinkPublicationSource = 'panda-booklink';
final bookLinkHome = Uri.https('booklink.me', '/');
final bookLinkEndpoint = bookLinkHome.resolve('/after_search.php');
final _bookLinkBrowse = bookLinkHome.resolve('/top_click.php');
final _bookLinkPath = RegExp(r'^/book-[1-9]\d{0,4}-[1-9]\d{0,14}\.html$');

final class BookLinkCatalogue implements PublicationCatalogue {
  const BookLinkCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    final books = parseBookLinkCatalogue(
      await publicListingText(http, _bookLinkBrowse, token),
    );
    if (books.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final modes = switch (filter?.field) {
      PublicationSearchField.isbn => const <String>[],
      PublicationSearchField.title => const ['book'],
      PublicationSearchField.author => const ['author'],
      _ => const ['book', 'author'],
    };
    final results = query.isEmpty
        ? [
            parseBookLinkCatalogue(
              await publicListingText(http, _bookLinkBrowse, token),
            ),
          ]
        : await Future.wait(modes.map((mode) => _search(query, mode, token)));
    final books = <String, PublicationEdition>{};
    for (final book in results.expand((rows) => rows)) {
      if (filter?.matches(book) != false &&
          allowed('${book.title} ${book.author}')) {
        books[book.id] = book;
      }
    }
    return books.values.take(60).toList();
  }

  Future<List<PublicationEdition>> _search(
    String query,
    String mode,
    CancellationToken token,
  ) async {
    final body = await http.text(
      bookLinkEndpoint,
      token,
      maxBytes: 650 << 10,
      allowGzip: true,
      deadline: const Duration(seconds: 12),
      referer: bookLinkHome,
      form: {'name': query, 'search_type': mode, 'book': 'BookLink小说搜索'},
      scope: (target) {
        if (target != bookLinkEndpoint) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    return parseBookLinkCatalogue(body);
  }
}

List<PublicationEdition> parseBookLinkCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('form[name="search_form"] input[name="name"]') ==
      null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final authorLink in document.querySelectorAll(
    'td a[href^="/author-"]',
  )) {
    final row = authorLink.parent?.parent;
    if (row?.localName != 'tr') continue;
    final heading = row!.querySelector('td a[href^="/book-"]');
    final page = publicListingLink(
      bookLinkHome,
      heading?.attributes['href'],
      _bookLinkPath,
    );
    final title = publicationLabel(heading?.text);
    final author = publicationLabel(authorLink.text);
    if (page == null || title.isEmpty || author.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$bookLinkPublicationSource\n$page'),
      title: title,
      author: author,
      page: page,
    );
  }
  return books.values.toList();
}

const dpdfPublicationSource = 'panda-dpdf';
final dpdfHome = Uri.https('d-pdf.com', '/');
final dpdfEndpoint = dpdfHome.resolve('/search');
final _dpdfBookPath = RegExp(r'^/book/[a-z0-9][a-z0-9-]{1,210}$');

PublicListingCatalogue dpdfCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => query.isEmpty
          ? dpdfHome
          : dpdfEndpoint.replace(
              queryParameters: {'q': query, if (page > 1) 'page': '$page'},
            ),
      parse: parseDpdfCatalogue,
  completeRange: true,
      deadline: const Duration(seconds: 15),
    );

PublicationListingPage parseDpdfCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('form.header-search input[name="q"]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final card in document.querySelectorAll('article.book-card')) {
    final heading = card.querySelector('.card-title a[href]');
    final page = publicListingLink(
      dpdfHome,
      heading?.attributes['href'],
      _dpdfBookPath,
    );
    final author = publicationLabel(card.querySelector('.card-author a')?.text);
    var title = publicationLabel(heading?.text);
    final suffix = ' by $author';
    if (author.isNotEmpty && title.endsWith(suffix)) {
      title = title.substring(0, title.length - suffix.length);
    }
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$dpdfPublicationSource\n$page'),
      title: title,
      author: author,
      cover: publicationCoverUrl(
        dpdfHome,
        card.querySelector('.card-cover img')?.attributes['src'],
        (uri) =>
            uri.host == page.host && uri.path.startsWith('/uploads/covers/'),
      ),
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext:
        document.querySelector('.pagination a[rel="next"]') != null ||
        document
            .querySelectorAll('.pagination a[href]')
            .any((link) => link.text.trim().startsWith('Next')),
  );
}
