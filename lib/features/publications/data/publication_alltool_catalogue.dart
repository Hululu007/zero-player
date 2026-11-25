import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const alltoolSource = 'alltool-public-catalogue';
final alltoolCatalogueEndpoint = Uri.https('alltool.top', '/book/rank/latest');
final _bookPath = RegExp(r'^/book/(?:[a-z0-9]{5}|[0-9a-f]{32})$');
const _lastPage = 10;

typedef AlltoolPage = ({List<PublicationEdition> editions, Uri? next});

final class AlltoolCatalogue implements PublicationCatalogue {
  const AlltoolCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _page(alltoolCatalogueEndpoint, token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final found = <String, PublicationEdition>{};
    Uri? next = alltoolCatalogueEndpoint;
    // The site's robots.txt excludes remote keyword search and the client API.
    // Match against the public ranking pages locally.
    for (var i = 0; i < maxPages.clamp(1, _lastPage) && next != null; i++) {
      final page = await _page(next, token);
      for (final edition in page.editions) {
        token.check();
        if (edition.matches(query, filter: filter) &&
            allowed('${edition.title} ${edition.author}')) {
          found.putIfAbsent(edition.id, () => edition);
        }
      }
      next = page.next;
    }
    return found.values.toList();
  }

  Future<AlltoolPage> _page(Uri address, CancellationToken token) async {
    final body = await http.text(
      address,
      token,
      maxBytes: 512 << 10,
      scope: (target) {
        if (target != address) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    final page = parseAlltoolCatalogue(body, address);
    if (page.editions.isEmpty) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return page;
  }
}

AlltoolPage parseAlltoolCatalogue(String body, Uri address) {
  final document = html.parse(body);
  final editions = <String, PublicationEdition>{};
  for (final section in document.querySelectorAll('section')) {
    final anchor = section.querySelector('h2 a[href]');
    final title = publicationLabel(anchor?.text);
    final page = _address(address, anchor?.attributes['href']);
    if (title.isEmpty ||
        page == null ||
        !_bookPath.hasMatch(page.path) ||
        page.path == '/book/ranks' ||
        page.hasQuery) {
      continue;
    }
    final author = section
        .querySelector('[class~="i-lucide:user"]')
        ?.parent
        ?.querySelector('span.line-clamp-1')
        ?.text;
    editions.putIfAbsent(
      page.path,
      () => PublicationEdition(
        id: publicationId('$alltoolSource\n${page.path}'),
        title: title,
        author: publicationLabel(author),
        page: page,
        resources: [
          PublicationResource(
            source: alltoolSource,
            link: page.replace(fragment: 'download'),
            label: '原站获取下载地址',
          ),
        ],
      ),
    );
  }

  final current = int.tryParse(address.queryParameters['page'] ?? '1') ?? 1;
  final next = _address(
    address,
    document.querySelector('a[data-slot="next"]')?.attributes['href'],
  );
  final expected = alltoolCatalogueEndpoint.replace(
    queryParameters: {'page': '${current + 1}'},
  );
  return (
    editions: editions.values.toList(),
    next: current < _lastPage && next == expected ? next : null,
  );
}

Uri? _address(Uri base, String? href) {
  if (href == null || href.length > 256) return null;
  final reference = Uri.tryParse(href);
  if (reference == null) return null;
  final target = base.resolveUri(reference);
  if (target.scheme != 'https' ||
      target.host != 'alltool.top' ||
      target.port != 443 ||
      target.userInfo.isNotEmpty ||
      target.hasFragment) {
    return null;
  }
  return target;
}
