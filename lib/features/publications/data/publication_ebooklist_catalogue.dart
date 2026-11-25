import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_share_provider.dart';

const ebookListPublicationSource = 'panda-ebooklist';
final ebookListHome = Uri.https('ebooklist.mobi', '/books');
final _bookPath = RegExp(r'^/books/[1-9][0-9]{0,9}$');
final _search = ebookListHome.resolve('/books/search');
final _payloadQuery = RegExp(r'^_b=[a-zA-Z0-9-]{10,64}$');

final class EbookListCatalogue
    implements
        ProgressivePublicationCatalogue,
        ResourcePublicationCatalogue,
        SharedPublicationCatalogue {
  const EbookListCatalogue(this.http);

  final PublicationHttp http;
  static const _deadline = Duration(seconds: 18);

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => query.isEmpty && page == 1
        ? ebookListHome
        : (query.isEmpty ? ebookListHome : _search).replace(
            queryParameters: {
              if (query.isNotEmpty) 'q': query,
              if (page > 1) 'page': '$page',
            },
          ),
    parse: parseEbookListCatalogue,
    deadline: _deadline,
  );

  @override
  Future<void> check(CancellationToken token) => _listing.check(token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) => _listing.search(
    query,
    token,
    maxPages: maxPages,
    allowed: allowed,
    filter: filter,
    onProgress: onProgress,
  );

  @override
  void restrictShare(Uri? page, Uri link) {
    if (_validatedBook(page) == null ||
        publishedCatalogueShare(
              ebookListPublicationSource,
              link.toString(),
              provider: PublicationShareProvider.quark,
            )?.link !=
            link) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) async {
    final id = _validatedBook(page);
    if (id == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final doc = html.parse(await _readResource(page, token, 640 << 10));
    final raw = doc
        .querySelector('script#__NUXT_DATA__[data-ssr="true"][data-src]')
        ?.attributes['data-src'];
    final reference = Uri.tryParse(raw ?? '');
    if (reference == null) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final payload = page.resolveUri(reference);
    if (payload.scheme != 'https' ||
        payload.origin != page.origin ||
        payload.userInfo.isNotEmpty ||
        payload.hasFragment ||
        payload.path != '${page.path}/_payload.json' ||
        (payload.hasQuery && !_payloadQuery.hasMatch(payload.query))) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final response = await _readResource(payload, token, 256 << 10);
    return parseEbookListResources(response, id);
  }

  Future<String> _readResource(
    Uri target,
    CancellationToken token,
    int maxBytes,
  ) => publicListingText(
    http,
    target,
    token,
    maxBytes: maxBytes,
    deadline: _deadline,
    completeRange: true,
  );
}

int? _validatedBook(Uri? page) => page == null
    ? null
    : publicListingLink(ebookListHome, page.toString(), _bookPath) == page
    ? int.tryParse(page.pathSegments.last)
    : null;

PublicationListingPage parseEbookListCatalogue(String body) {
  final document = html.parse(body);
  final main = document.querySelector('main.app-main');
  if (main == null ||
      document.querySelector('.site-nav a[href="/books"]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final card in main.querySelectorAll('a.resource-card[href]')) {
    final page = publicListingLink(
      ebookListHome,
      card.attributes['href'],
      _bookPath,
    );
    final title = publicationLabel(card.querySelector('.card-title')?.text);
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$ebookListPublicationSource\n$page'),
      title: title,
      cover: publicationCoverUrl(
        page,
        card.querySelector('.card-cover img[src]')?.attributes['src'],
        (uri) =>
            (uri.host == 'ebooklist.mobi' &&
                uri.path.startsWith('/uploads/books/')) ||
            (uri.host == 'img.ebooklist.mobi' && uri.path.startsWith('/docs/')),
      ),
      page: page,
      resources: [
        if (card.querySelector('.card-badges .disk') != null)
          PublicationResource.lookup(
            source: ebookListPublicationSource,
            link: page,
          ),
      ],
    );
  }
  return (
    books: books.values.toList(),
    hasNext: main
        .querySelectorAll('.pagination a[href]')
        .any((link) => link.text.trim().startsWith('下一页')),
  );
}

List<PublicationResource> parseEbookListResources(String body, int id) {
  final nodes = jsonDecode(body);
  if (nodes is! List || nodes.isEmpty || nodes.length > 10000) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  // Nuxt's public static payload stores entries as references into a flat array.
  Object? value(Object? index) =>
      index is int && index >= 0 && index < nodes.length ? nodes[index] : null;
  final root = nodes.first;
  final data = switch (root is Map ? value(root['data']) : null) {
    ['ShallowReactive', final index] => value(index),
    _ => null,
  };
  final record = data is Map ? value(data['book-$id']) : null;
  if (record is! Map || value(record['id']) != id) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  if (value(record['isPaid']) != false) return const [];
  final links = value(record['netDiskLinks']);
  if (links is! List) return const [];
  final resources = <Uri, PublicationResource>{};
  for (final index in links.take(12)) {
    final item = value(index);
    if (item is! Map || value(item['url']) is! String) continue;
    final raw = value(item['url']) as String;
    final url = Uri.tryParse(raw);
    if (url == null) continue;
    final code = value(item['password']);
    final format = value(item['fileFormat']);
    final resource = publishedCatalogueShare(
      ebookListPublicationSource,
      raw,
      provider: PublicationShareProvider.of(url),
      code: code is String ? code : null,
      format: format is String
          ? PublicationFormat.fromName('book.$format')
          : null,
    );
    if (resource != null) resources[resource.link] = resource;
  }
  return resources.values.toList();
}
