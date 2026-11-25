import 'package:html/parser.dart' as html;

import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const scienceReadingPublicationSource = 'panda-science-reading';
final scienceReadingHome = Uri.https(
  'book.sciencereading.cn',
  '/shop/main/Login/shopFrame.do',
);
final scienceReadingEndpoint = scienceReadingHome.resolve(
  '/shop/book/Booksimple/list.do',
);
final _bookId = RegExp(r'^[A-Za-z0-9]{28,48}$');
final _detailQuery = RegExp(r'^id=[a-zA-Z0-9]+$');
const _searchName = 'showQueryModel.nameIsbnAuthor';

PublicListingCatalogue scienceReadingCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => query.isEmpty
          ? scienceReadingHome
          : scienceReadingEndpoint.replace(
              queryParameters: {
                if (query.isNotEmpty) _searchName: query,
                if (page > 1) 'pageSplit.nowPageNumber': '$page',
              },
            ),
      parse: parseScienceReadingCatalogue,
      maxBytes: 1200 << 10,
      deadline: const Duration(seconds: 15),
      completeRange: true,
    );

PublicationListingPage parseScienceReadingCatalogue(String body) {
  final document = html.parse(body);
  final form = document.querySelector('form#bookListForm');
  if (form == null && document.querySelector('#subjectNavLink') != null) {
    final books = <Uri, PublicationEdition>{};
    for (final row in document.querySelectorAll(
      '.recommend_books_lg, .book_sm_container',
    )) {
      final heading = row.querySelector('.book_name a[href]');
      final link = Uri.tryParse(heading?.attributes['href'] ?? '');
      final page = link == null ? null : _bookPage(link);
      final title = publicationLabel(heading?.attributes['title']);
      if (page == null || title.isEmpty) continue;
      final author = row.querySelector('.book_author_detail');
      books[page] = _edition(
        page,
        title,
        author: author?.attributes['title'] ?? author?.text,
        image: row.querySelector('img.books_img_hover')?.attributes['src'],
      );
    }
    return (books: books.values.toList(), hasNext: false);
  }
  if (form == null ||
      form.querySelector('input[name="$_searchName"]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in form.querySelectorAll('.book_content')) {
    final heading = row.querySelector('.book_detail_title a[href]');
    final link = Uri.tryParse(heading?.attributes['href'] ?? '');
    final page = link == null ? null : _bookPage(link);
    final title = publicationLabel(heading?.querySelector('.kc_title')?.text);
    if (page == null || title.isEmpty) continue;
    books[page] = _edition(
      page,
      title,
      author: row.querySelector('.kc_author')?.text,
      isbn: normalizedIsbn(row.querySelector('.kc_ISBN')?.text ?? ''),
      image: row.querySelector('img[src]')?.attributes['src'],
    );
  }
  return (
    books: books.values.toList(),
    hasNext: form.querySelector('.pagination a[onclick="nextPage();"]') != null,
  );
}

PublicationEdition _edition(
  Uri page,
  String title, {
  String? author,
  String isbn = '',
  String? image,
}) {
  final id = page.queryParameters['id']!;
  return PublicationEdition(
    id: publicationId('$scienceReadingPublicationSource\n$id'),
    title: title,
    author: publicationLabel(author),
    isbn: isbn,
    cover: publicationCoverUrl(
      scienceReadingHome,
      image,
      (uri) =>
          uri.host == page.host &&
          uri.path.startsWith('/kxwk4/bookImages/$id/') &&
          !uri.hasQuery,
    ),
    page: page,
  );
}

Uri? _bookPage(Uri link) {
  final page = scienceReadingHome.resolveUri(link);
  if (page.scheme != 'https' ||
      page.origin != scienceReadingHome.origin ||
      page.userInfo.isNotEmpty ||
      page.path != '/shop/book/Booksimple/show.do' ||
      page.hasFragment ||
      !_detailQuery.hasMatch(page.query) ||
      !_bookId.hasMatch(page.queryParameters['id'] ?? '')) {
    return null;
  }
  return page;
}
