import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_share_provider.dart';

const library361PublicationSource = 'panda-361-library';
final library361Home = Uri.https('361tsg.top', '/');
final _library361Book = RegExp(r'^/[1-9][0-9]{0,9}\.html$');
final _library361Format = RegExp(
  r'(?:\.(?:epub|pdf|mobi|azw3|txt|djvu)|[（(](?:epub|pdf|mobi|azw3|txt|djvu)电子书[）)])$',
  caseSensitive: false,
);
final _library361Credit = RegExp(r'^(.*)（([^（）]{1,96})）$');
final _library361Author = RegExp(r'^作者\s*[:：]\s*([^·。\n]{1,80})');
final _library361Shelves = RegExp(r'^/(?:freebook|ebook)$');

PublicListingCatalogue library361Catalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => library361Home.replace(
        path: page == 1 ? '/' : '/page/$page',
        queryParameters: query.isEmpty ? null : {'s': query},
      ),
      parse: parseLibrary361Catalogue,
    );

PublicationListingPage parseLibrary361Catalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('input[name="s"]') == null ||
      document.querySelector('main') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final post in document.querySelectorAll('main article.post-item')) {
    final anchor = post.querySelector('h2.entry-title a[href]');
    final page = publicListingLink(
      library361Home,
      anchor?.attributes['href'],
      _library361Book,
    );
    final label = publicationLabel(anchor?.text);
    if (page == null || label.isEmpty) continue;
    final shelf = publicListingLink(
      library361Home,
      post.querySelector('.entry-cat-dot a[href]')?.attributes['href'],
      _library361Shelves,
    );
    if (!_library361Format.hasMatch(label) && shelf == null) {
      continue;
    }
    var title = label.replaceFirst(_library361Format, '').trim();
    final summary = publicationLabel(post.querySelector('.entry-desc')?.text);
    var author = publicationLabel(_library361Author.firstMatch(summary)?[1]);
    final credit = _library361Credit.firstMatch(title);
    final creditedTitle = credit?[1];
    final name = credit?[2];
    if (creditedTitle != null &&
        name != null &&
        creditedTitle.endsWith('-$name')) {
      author = name;
      title = creditedTitle.substring(
        0,
        creditedTitle.length - name.length - 1,
      );
    }
    if (title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$library361PublicationSource\n$page'),
      title: title,
      author: author,
      description: summary,
      language: 'zh',
      cover: publicationCoverUrl(
        library361Home,
        post.querySelector('.entry-media [data-bg]')?.attributes['data-bg'],
        (uri) =>
            uri.origin == library361Home.origin &&
            uri.path.startsWith('/wp-content/uploads/'),
      ),
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('nav.page-nav a.page-next[href]') != null,
  );
}

const saltTigerSource = 'panda-salttiger';
final saltTigerHome = Uri.https('salttiger.com', '/');
final _saltPosts = saltTigerHome.resolve('/wp-json/wp/v2/posts');
final _saltBook = RegExp(r'^/[a-z0-9-]{2,160}/$');
const _pageSize = 15;

PublicListingCatalogue saltTigerCatalogue(PublicationHttp http) =>
    PublicListingCatalogue(
      http,
      address: (query, page) => _saltPosts.replace(
        queryParameters: {
          if (query.isNotEmpty) 'search': query,
          'per_page': '$_pageSize',
          'page': '$page',
          '_fields': 'id,link,title,content',
        },
      ),
      parse: parseSaltTigerCatalogue,
    );

PublicationListingPage parseSaltTigerCatalogue(String body) {
  final posts = _posts(body);
  return (
    books: [for (final post in posts) ?_saltEdition(post)],
    hasNext: posts.length == _pageSize,
  );
}

PublicationEdition? _saltEdition(Object? raw) {
  if (raw case {
    'link': final String link,
    'title': {'rendered': final String label},
    'content': {'rendered': final String body},
  }) {
    final page = publicListingLink(saltTigerHome, link, _saltBook);
    final title = _text(label);
    if (page == null || title.isEmpty) return null;
    final doc = html.parseFragment(body);
    final resources = <Uri, PublicationResource>{};
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final published = publishedCatalogueShare(
        saltTigerSource,
        anchor.attributes['href'],
        provider: PublicationShareProvider.baidu,
      );
      if (published != null) resources[published.link] = published;
    }
    if (resources.isEmpty && doc.text?.contains('官网链接') != true) return null;
    return PublicationEdition(
      id: publicationId('$saltTigerSource\n$page'),
      title: title,
      page: page,
      resources: resources.values.toList(),
      cover: publicationCoverUrl(
        page,
        doc.querySelector('img')?.attributes['src'],
        (uri) =>
            uri.host == page.host &&
            uri.path.startsWith('/wp-content/uploads/'),
      ),
    );
  }
  return null;
}

const ibooksPublicationSource = 'panda-ibooks';
final ibooksCatalogueHome = Uri.https('ibooks.org.cn', '/');
final _ibooksPosts = ibooksCatalogueHome.resolve('/wp-json/wp/v2/posts');
final _ibooksAuthors = ibooksCatalogueHome.resolve(
  '/wp-json/wp/v2/book_author',
);
final _ibooksBook = RegExp(r'^/archives/[1-9][0-9]{0,9}$');

final class IBooksCatalogue implements ProgressivePublicationCatalogue {
  const IBooksCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) => _listing().check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    var authors = const <int>[];
    if (filter?.field == PublicationSearchField.author) {
      final target = _ibooksAuthors.replace(
        queryParameters: {
          'search': query,
          '_fields': 'id,name',
          'per_page': '10',
        },
      );
      final data = _posts(await publicListingText(http, target, token));
      authors = [
        for (final row in data)
          if (row case {
            'id': final int id,
            'name': final String name,
          } when id > 0 && filter!.matchesFields(author: _text(name)))
            id,
      ];
      if (authors.isEmpty) return const [];
    }
    return _listing(authors).search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
      onProgress: onProgress,
    );
  }

  PublicListingCatalogue _listing([List<int> authors = const []]) =>
      PublicListingCatalogue(
        http,
        address: (query, page) => _ibooksPosts.replace(
          queryParameters: {
            if (authors.isNotEmpty)
              'book_author': authors.join(',')
            else if (query.isNotEmpty)
              'search': query,
            'per_page': '$_pageSize',
            'page': '$page',
            '_fields': 'id,link,title,book_author,_links,_embedded',
            '_embed': 'wp:term',
          },
        ),
        parse: parseIBooksCatalogue,
      );
}

PublicationListingPage parseIBooksCatalogue(String body) {
  final posts = _posts(body);
  final books = <PublicationEdition>[];
  for (final post in posts) {
    if (post case {
      'link': final String link,
      'title': {'rendered': final String titleValue},
      'book_author': final List authorIds,
      '_embedded': {'wp:term': final List terms},
    }) {
      final page = publicListingLink(ibooksCatalogueHome, link, _ibooksBook);
      final title = _text(titleValue);
      final authors = {
        for (final group in terms.whereType<List>())
          for (final term in group)
            if (term case {
              'taxonomy': 'book_author',
              'id': final int id,
              'name': final String name,
            } when authorIds.contains(id) && _text(name).isNotEmpty)
              _text(name),
      };
      if (page == null || title.isEmpty || authors.isEmpty) continue;
      final namedBook = RegExp(r'^《([^》]{1,140})》').firstMatch(title);
      books.add(
        PublicationEdition(
          id: publicationId('$ibooksPublicationSource\n$page'),
          title: namedBook?[1] ?? title,
          author: publicationLabel(authors.join('、')),
          page: page,
        ),
      );
    }
  }
  return (books: books, hasNext: posts.length == _pageSize);
}

List<dynamic> _posts(String body) {
  final value = jsonDecode(body);
  if (value is! List || value.length > _pageSize) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return value;
}

String _text(String raw) => publicationLabel(html.parseFragment(raw).text);
