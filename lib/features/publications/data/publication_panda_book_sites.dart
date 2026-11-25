import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const taoshudangPublicationSource = 'panda-taoshudang';
final taoshudangHome = Uri.https('www.taoshudang.com', '/');
final _taoshudangBook = RegExp(r'^/[1-9][0-9]{0,9}\.html$');
final _formats = RegExp(
  r'\s*[-–—]\s*(?:pdf|epub|mobi|azw3|azw)(?:\s*[+,/]\s*(?:pdf|epub|mobi|azw3|azw))*\s*$',
  caseSensitive: false,
);

PublicListingCatalogue taoshudangCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) =>
          (page == 1 ? taoshudangHome : taoshudangHome.resolve('/page/$page/'))
              .replace(queryParameters: {if (query.isNotEmpty) 's': query}),
      parse: parseTaoshudangCatalogue,
      deadline: const Duration(seconds: 12),
    );

PublicationListingPage parseTaoshudangCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('#content') == null ||
      document.querySelector('form input[name=s]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in document.querySelectorAll('#content article')) {
    final anchor = row.querySelector('h2.entry-title a[href]');
    final page = publicListingLink(
      taoshudangHome,
      anchor?.attributes['href'],
      _taoshudangBook,
    );
    final heading = publicationLabel(anchor?.text);
    final closing = heading.lastIndexOf('》');
    final suffix = _formats.firstMatch(heading);
    if (page == null ||
        !heading.startsWith('《') ||
        closing < 2 ||
        suffix == null ||
        closing >= suffix.start) {
      continue;
    }
    books[page] = PublicationEdition(
      id: publicationId('$taoshudangPublicationSource\n$page'),
      title: heading.substring(1, closing).trim(),
      author: heading
          .substring(closing + 1, suffix.start)
          .trim()
          .replaceFirst(RegExp(r'[（(]作者[）)]$'), '')
          .trim(),
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('a.next.page-numbers[href]') != null,
  );
}

const huiyankanPublicationSource = 'panda-huiyankan';
final huiyankanHome = Uri.https('www.huiyankan.com', '/');
final huiyankanEndpoint = huiyankanHome.resolve('/wp-json/wp/v2/posts');
final _huiyankanBook = RegExp(r'^/\d{12,18}\.html$');
const _pageSize = 4;

PublicListingCatalogue huiyankanCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => query.isEmpty
          ? huiyankanHome
          : huiyankanEndpoint.replace(
              queryParameters: {
                'search': query,
                'per_page': '$_pageSize',
                if (page > 1) 'page': '$page',
                '_fields': 'id,link,title',
              },
            ),
      parse: (body) => body.trimLeft().startsWith('<')
          ? parseHuiyankanHomepage(body)
          : parseHuiyankanCatalogue(body),
      deadline: const Duration(seconds: 15),
    );

PublicationListingPage parseHuiyankanHomepage(String body) {
  final document = html.parse(body);
  final main = document.querySelector('main#main');
  if (main == null || document.querySelector('form input[name=s]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final anchor in main.querySelectorAll(
    'article.type-post h2.entry-title a[rel=bookmark][href]',
  )) {
    final book = _huiyankanEdition(anchor.attributes['href'], anchor.text);
    if (book != null) books[book.id] = book;
  }
  return (books: books.values.toList(), hasNext: false);
}

PublicationListingPage parseHuiyankanCatalogue(String body) {
  final rows = jsonDecode(body);
  if (rows is! List || rows.length > _pageSize) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final row in rows) {
    if (row case {
      'link': final String link,
      'title': {'rendered': final String label},
    }) {
      final book = _huiyankanEdition(link, html.parseFragment(label).text);
      if (book != null) books[book.id] = book;
    }
  }
  return (books: books.values.toList(), hasNext: rows.length == _pageSize);
}

PublicationEdition? _huiyankanEdition(String? link, String? label) {
  final page = publicListingLink(huiyankanHome, link, _huiyankanBook);
  final title = publicationLabel(label);
  if (page == null || title.isEmpty) return null;
  return PublicationEdition(
    id: publicationId('$huiyankanPublicationSource\n$page'),
    title: title,
    page: page,
  );
}

const klibRankingPublicationSource = 'panda-klib-ranking';
final klibRankingPage = Uri.https('klib.me', '/weread/hot/all.html');
final _klibBook = RegExp(r'^/([1-9][0-9]{0,10})\.html$');

PublicationListingPage parseKlibRankingCatalogue(String body) {
  final document = html.parse(body);
  final books = <Uri, PublicationEdition>{};
  for (final row in document.querySelectorAll('li.fcm68')) {
    final raw = row.querySelector('a.fcm69[href]')?.attributes['href'];
    final link = Uri.tryParse(raw ?? '');
    if (link == null ||
        !const {'http', 'https'}.contains(link.scheme) ||
        link.port != (link.scheme == 'https' ? 443 : 80) ||
        link.host != 's.klib.me' ||
        link.userInfo.isNotEmpty ||
        link.hasQuery ||
        link.hasFragment ||
        !_klibBook.hasMatch(link.path)) {
      continue;
    }
    final page = Uri.https('s.klib.me', link.path);
    final title = publicationLabel(row.querySelector('.book_title')?.text);
    if (title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$klibRankingPublicationSource\n$page'),
      title: title,
      author: publicationLabel(row.querySelector('.book_author')?.text),
      page: page,
      rating: publicationLabel(row.querySelector('.book_star')?.text),
    );
  }
  if (books.isEmpty) throw const PublicationFailure(PublicationProblem.invalid);
  return (books: books.values.toList(), hasNext: false);
}
