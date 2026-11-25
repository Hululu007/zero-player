import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

const dushupaiSource = 'dushupai-public-catalogue';
const _host = 'www.dushupai.com';
const _category = '/book-category-xiaoshuo';
final dushupaiCatalogueEndpoint = Uri.https(_host, '$_category.html');
final _searchEndpoint = Uri.https(_host, '/search.html');
final _bookPath = RegExp(r'^/book-content-([1-9][0-9]{0,9})\.html$');
final _displayedCode = RegExp(r'提取码\s*[:：]\s*([A-Za-z0-9]{2,16})\b');

typedef DushupaiPage = ({List<PublicationEdition> editions, Uri? next});

final class DushupaiCatalogue
    implements
        ProgressivePublicationCatalogue,
        ResourcePublicationCatalogue,
        SharedPublicationCatalogue {
  const DushupaiCatalogue(this.http);

  final PublicationHttp http;

  @override
  void restrictShare(Uri? page, Uri link) {
    if (_downloadPage(page) == null ||
        publishedCatalogueShare(
              dushupaiSource,
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
    final download = _downloadPage(page);
    if (download == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final detail = html.parse(await _read(page, token));
    final declared = detail.querySelectorAll('.post-download a[href]');
    if (!declared.any(
      (node) => _address(page, node.attributes['href']) == download,
    )) {
      throw const PublicationFailure(PublicationProblem.noPublishedResources);
    }

    final document = html.parse(await _read(download, token, referer: page));
    final container = document.querySelector('.block-download');
    final book = container?.querySelector('#download_declaration h1 a[href]');
    if (_address(download, book?.attributes['href']) != page) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final resources = <Uri, PublicationResource>{};
    for (final row
        in container!.querySelectorAll('.download_blcok .list .box').take(12)) {
      final href = row.querySelector('.button a[href]')?.attributes['href'];
      final address = Uri.tryParse(href ?? '');
      if (address == null) continue;
      final info = row.querySelector('.source-info');
      final code =
          info
              ?.querySelector('[data-clipboard-text]')
              ?.attributes['data-clipboard-text'] ??
          _displayedCode.firstMatch(info?.text ?? '')?.group(1);
      final resource = publishedCatalogueShare(
        dushupaiSource,
        href,
        provider: PublicationShareProvider.of(address),
        code: code,
      );
      if (resource != null) {
        resources.putIfAbsent(resource.link, () => resource);
      }
    }
    return resources.values.toList();
  }

  @override
  Future<void> check(CancellationToken token) async {
    await _page(dushupaiCatalogueEndpoint, token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    final found = <String, PublicationEdition>{};
    Uri? next = query.isEmpty
        ? dushupaiCatalogueEndpoint
        : _searchEndpoint.replace(queryParameters: {'k': query});
    for (var index = 0; index < maxPages.clamp(1, 5) && next != null; index++) {
      final DushupaiPage page;
      try {
        page = await _page(next, token);
      } on Exception catch (error) {
        token.check();
        if (index == 0 || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      final before = found.length;
      for (final edition in page.editions) {
        token.check();
        if ((filter?.matches(edition) ?? true) &&
            allowed('${edition.title} ${edition.author}')) {
          found.putIfAbsent(edition.id, () => edition);
        }
      }
      next = page.next;
      if (next != null && index + 1 < maxPages && found.length != before) {
        await onProgress?.call(found.values.toList());
      }
    }
    return found.values.toList();
  }

  Future<DushupaiPage> _page(Uri address, CancellationToken token) async =>
      parseDushupaiCatalogue(await _read(address, token), address);

  Future<String> _read(Uri address, CancellationToken token, {Uri? referer}) =>
      http.text(
        address,
        token,
        maxBytes: 256 << 10,
        deadline: publicationCatalogueDeadline,
        allowGzip: true,
        referer: referer,
        scope: (target) {
          if (target != address) {
            throw const PublicationFailure(PublicationProblem.unsupported);
          }
        },
      );
}

Uri? _downloadPage(Uri? page) {
  if (page == null ||
      _address(page, page.toString()) != page ||
      page.hasQuery) {
    return null;
  }
  final match = _bookPath.firstMatch(page.path);
  return match == null
      ? null
      : Uri.https(_host, '/download-book-${match[1]}.html');
}

DushupaiPage parseDushupaiCatalogue(String body, Uri address) {
  final document = html.parse(body);
  final listing = document.querySelector('ul.portfolio-book');
  final pageTitle = document.querySelector('title')?.text ?? '';
  final term = address.queryParameters['k'];
  final isSearch = term != null;
  if (listing == null && (!isSearch || !pageTitle.contains('电子书搜索结果-读书派'))) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  final editions = <String, PublicationEdition>{};
  for (final row
      in listing?.querySelectorAll('li.portfolio-item') ?? const []) {
    final link = row.querySelector('.portfolio-title a[href]');
    final title = publicationLabel(link?.attributes['title'] ?? link?.text);
    final page = _address(address, link?.attributes['href']);
    if (title.isEmpty ||
        page == null ||
        !_bookPath.hasMatch(page.path) ||
        page.hasQuery) {
      continue;
    }
    editions.putIfAbsent(
      page.path,
      () => PublicationEdition(
        id: publicationId('$dushupaiSource\n${page.path}'),
        title: title,
        author: publicationLabel(row.querySelector('.portfolio-author')?.text),
        cover: _cover(
          address,
          row.querySelector('img')?.attributes ?? const {},
        ),
        page: page,
        resources: [
          PublicationResource.lookup(source: dushupaiSource, link: page),
        ],
      ),
    );
  }

  if (!isSearch && editions.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final expected = _nextPage(address, term);
  final hasNext =
      editions.isNotEmpty &&
      document.querySelectorAll('a[href]').any((link) {
        final target = _address(address, link.attributes['href']);
        if (target == null || target.path != expected.path) return false;
        return isSearch
            ? target.queryParametersAll.length == 2 &&
                  target.queryParametersAll['k']?.singleOrNull == term &&
                  target.queryParametersAll['p']?.singleOrNull ==
                      expected.queryParameters['p']
            : !target.hasQuery;
      });
  return (editions: editions.values.toList(), next: hasNext ? expected : null);
}

Uri? _cover(Uri base, Map<Object, String> attributes) => publicationCoverUrl(
  base,
  attributes['data-original'] ?? attributes['src'],
  (uri) =>
      uri.host == base.host ||
      (uri.host == 'tc-new.z.wiki' && uri.path.startsWith('/autoupload/')),
);

Uri _nextPage(Uri address, String? term) {
  if (term != null) {
    final current = int.tryParse(address.queryParameters['p'] ?? '') ?? 1;
    return _searchEndpoint.replace(
      queryParameters: {'k': term, 'p': '${current + 1}'},
    );
  }
  final group = RegExp(r'-(\d+)\.html$').firstMatch(address.path)?.group(1);
  final current = int.tryParse(group ?? '') ?? 1;
  return Uri.https(_host, '$_category-${current + 1}.html');
}

Uri? _address(Uri base, String? href) {
  if (href == null || href.length > 2048) return null;
  final reference = Uri.tryParse(href);
  if (reference == null) return null;
  final target = base.resolveUri(reference);
  if (target.scheme != 'https' ||
      target.host != _host ||
      target.port != 443 ||
      target.userInfo.isNotEmpty ||
      target.hasFragment) {
    return null;
  }
  return target;
}
