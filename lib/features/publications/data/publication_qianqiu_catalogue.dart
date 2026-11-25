import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';
import 'publication_share_provider.dart';

const qianqiuPublicationSource = 'panda-qianqiu';
final qianqiuHome = Uri.https('www.35ppt.com', '/');
final qianqiuEndpoint = qianqiuHome.resolve('wp-json/wp/v2/posts');
final _guestEndpoint = qianqiuHome.resolve(
  'wp-content/plugins/ordown/down.php',
);
final _qianqiuBook = RegExp(r'^/([1-9][0-9]{0,9})\.html$');
final _ctFile = RegExp(r'^/fs/[0-9]{1,20}-[0-9]{1,20}$');
final _kindle = RegExp(
  r'\s+(?:azw3|mobi|epub|txt|pdf)(?:[,，+](?:azw3|mobi|epub|txt|pdf))*\s+.*$',
  caseSensitive: false,
);
final _comic = RegExp(r'[-—\s]+PDF漫画.*下载$', caseSensitive: false);
final _creditSuffix = RegExp(r'^(.+)[-—]([^\s/]{2,30})$');
const _pageSize = 10;

final class QianqiuCatalogue
    implements ProgressivePublicationCatalogue, ResourcePublicationCatalogue {
  const QianqiuCatalogue(this.http);

  final PublicationHttp http;
  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => qianqiuEndpoint.replace(
      queryParameters: {
        if (query.isNotEmpty) 'search': query,
        'per_page': '$_pageSize',
        'page': '$page',
        '_fields': 'link,title,content',
      },
    ),
    parse: parseQianqiuCatalogue,
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
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) async {
    final path = _qianqiuBook.firstMatch(page.path);
    if (path == null ||
        publicListingLink(qianqiuHome, page.toString(), _qianqiuBook) != page) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final document = html.parse(await publicListingText(http, page, token));
    final guest = _guestEndpoint.replace(queryParameters: {'id': path[1]!});
    final button = document.querySelector('#erphpdown a.erphpdown-down[href]');
    if (button == null ||
        !button.parent!.text.contains('游客免费下载') ||
        page.resolve(button.attributes['href']!) != guest) {
      return const [];
    }
    final body = await http.text(
      guest,
      token,
      scope: (target) {
        if (target != guest) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
      referer: page,
      deadline: const Duration(seconds: 10),
      maxBytes: 192 << 10,
      allowGzip: true,
    );
    return parseQianqiuShares(body);
  }
}

PublicationListingPage parseQianqiuCatalogue(String body) {
  final rows = jsonDecode(body);
  if (rows is! List) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in rows) {
    if (row case {
      'link': final String raw,
      'title': {'rendered': final String label},
      'content': {'rendered': final String content},
    }) {
      final page = publicListingLink(qianqiuHome, raw, _qianqiuBook);
      final original = publicationLabel(html.parseFragment(label).text);
      if (page == null || !original.contains('下载')) continue;
      final document = html.parseFragment(content);
      var title = original
          .replaceFirst(_kindle, '')
          .replaceFirst(_comic, '')
          .trim();
      final credit = _creditSuffix.firstMatch(title);
      var author = '';
      if (credit case final match?) {
        final name = match[2]!;
        final text = document.text ?? '';
        if (text.contains('$name创作') || text.contains('$name著')) {
          author = name;
          title = match[1]!.trim();
        }
      }
      if (title.isEmpty) continue;
      books[page] = PublicationEdition(
        id: publicationId('$qianqiuPublicationSource\n$page'),
        title: title,
        author: author,
        language: 'zh',
        cover: publicationCoverUrl(
          page,
          document.querySelector('img[src]')?.attributes['src'],
          (uri) =>
              uri.origin == qianqiuHome.origin &&
              uri.path.startsWith('/wp-content/uploads/'),
        ),
        page: page,
        resources: [
          PublicationResource.lookup(
            source: qianqiuPublicationSource,
            link: page,
          ),
        ],
      );
    }
  }
  return (books: books.values.toList(), hasNext: rows.length == _pageSize);
}

List<PublicationResource> parseQianqiuShares(String body) {
  final document = html.parse(body);
  final resources = <Uri, PublicationResource>{};
  for (final button in document.querySelectorAll(
    '.ordown-buy a.ordown-button[href]',
  )) {
    final raw = button.attributes['href']!;
    if (raw.length > 512) continue;
    final format = PublicationFormat.fromName(
      '.${button.text.trim().replaceFirst(RegExp(r'\s*下载$'), '').toLowerCase()}',
    );
    if (format == null) continue;
    final link = Uri.tryParse(raw);
    if (link == null ||
        link.scheme != 'https' ||
        link.userInfo.isNotEmpty ||
        link.port != 443 ||
        link.hasFragment) {
      continue;
    }
    if (link.host == 'a56666.ctfile.com' &&
        _ctFile.hasMatch(link.path) &&
        !link.hasQuery) {
      resources[link] = PublicationResource(
        source: qianqiuPublicationSource,
        link: link,
        label: '城通网盘',
        format: format,
      );
      continue;
    }
    for (final provider in const [
      PublicationShareProvider.ctfile,
      PublicationShareProvider.baidu,
      PublicationShareProvider.xunlei,
    ]) {
      final resource = publishedCatalogueShare(
        qianqiuPublicationSource,
        raw,
        provider: provider,
        format: format,
      );
      if (resource != null) resources[resource.link] = resource;
    }
  }
  return resources.values.toList();
}
