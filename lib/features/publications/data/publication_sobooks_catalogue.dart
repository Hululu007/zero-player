import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_catalogue_shares.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

const sobooksPublicationSource = 'sobooks-public-catalogue';
final sobooksCatalogueEndpoint = Uri.https('sobooks.cc', '/');
final _bookPath = RegExp(r'^/books/[1-9][0-9]{0,9}\.html$');
final _goQuery = RegExp(r'^url=[A-Za-z0-9_+/%=-]{8,1024}$');

final class SobooksCatalogue
    implements ResourcePublicationCatalogue, SharedPublicationCatalogue {
  const SobooksCatalogue(this.http);
  final PublicationHttp http;

  @override
  void restrictShare(Uri? page, Uri link) {
    if (!_bookPage(page) ||
        !supportsCatalogueShareDownload(sobooksPublicationSource, link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) async {
    if (!_bookPage(page)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final document = html.parse(
      await _read(page, token, deadline: const Duration(seconds: 14)),
    );
    final routes = <Uri, PublicationShareProvider>{};
    for (final anchor
        in document.querySelectorAll('a.cloud-download-btn[href]').take(8)) {
      final provider =
          const {
                'cloud-ctfile': PublicationShareProvider.ctfile,
                'cloud-baidu': PublicationShareProvider.baidu,
                'cloud-quark': PublicationShareProvider.quark,
              }.entries
              .where((item) => anchor.classes.contains(item.key))
              .singleOrNull
              ?.value;
      final href = anchor.attributes['href']!;
      if (provider == null || href.length > 1200) continue;
      final reference = Uri.tryParse(href);
      if (reference == null) continue;
      final route = page.resolveUri(reference);
      if (_sameSite(route) &&
          route.path == '/go.html' &&
          _goQuery.hasMatch(route.query)) {
        routes.putIfAbsent(route, () => provider);
      }
    }

    final errors = <Exception>[];
    final results = await Future.wait(
      routes.entries.map((entry) async {
        try {
          final go = html.parse(
            await _read(
              entry.key,
              token,
              referer: page,
              deadline: const Duration(seconds: 8),
            ),
          );
          return publishedCatalogueShare(
            sobooksPublicationSource,
            go.querySelector('a#goLink[href]')?.attributes['href'],
            provider: entry.value,
            baiduDownloads: true,
            code: go.querySelector('button#copyBtn')?.attributes['data-code'],
          );
        } on RequestCancelled {
          rethrow;
        } on Exception catch (error) {
          errors.add(error);
          return null;
        }
      }),
    );
    token.check();
    final resources = {
      for (final resource in results.nonNulls) resource.link: resource,
    };
    if (resources.isEmpty && errors.isNotEmpty) throw errors.first;
    return resources.values.toList();
  }

  @override
  Future<void> check(CancellationToken token) async {
    await _page(1, token);
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
    for (var number = 1; number <= maxPages; number++) {
      final List<PublicationEdition> books;
      try {
        books = await _page(number, token);
      } on Exception catch (error) {
        token.check();
        if (number == 1 || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      for (final book in books) {
        if (book.matches(query, filter: filter) &&
            allowed('${book.title} ${book.author}')) {
          found.putIfAbsent(book.id, () => book);
        }
      }
      if (query.isEmpty || found.length >= 40) break;
    }
    return found.values.take(40).toList();
  }

  Future<List<PublicationEdition>> _page(
    int number,
    CancellationToken token,
  ) async {
    // The search form requires browser verification. Filter the public list.
    final address = number == 1
        ? sobooksCatalogueEndpoint
        : sobooksCatalogueEndpoint.resolve('/page/$number');
    final body = await _read(address, token);
    token.check();
    return parseSobooksCatalogue(body);
  }

  Future<String> _read(
    Uri address,
    CancellationToken token, {
    Duration deadline = publicationCatalogueDeadline,
    Uri? referer,
  }) => http.text(
    address,
    token,
    maxBytes: 256 << 10,
    deadline: deadline,
    referer: referer,
    allowGzip: true,
    scope: (uri) {
      if (uri != address) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    },
  );
}

bool _sameSite(Uri page) =>
    page.scheme == 'https' &&
    page.host == sobooksCatalogueEndpoint.host &&
    page.port == 443 &&
    page.userInfo.isEmpty &&
    !page.hasFragment;

bool _bookPage(Uri? page) =>
    page != null &&
    _sameSite(page) &&
    !page.hasQuery &&
    _bookPath.hasMatch(page.path);

List<PublicationEdition> parseSobooksCatalogue(String body) {
  final books = <Uri, PublicationEdition>{};
  final document = html.parse(body);
  for (final row in document.querySelectorAll('.card-item')) {
    final anchor = row.querySelector('h3 a[href]');
    final title = publicationLabel(anchor?.text);
    final raw = anchor?.attributes['href'];
    final reference = raw == null || raw.length > 256
        ? null
        : Uri.tryParse(raw);
    if (title.isEmpty || reference == null) continue;
    final page = sobooksCatalogueEndpoint.resolveUri(reference);
    if (!_bookPage(page)) continue;
    books.putIfAbsent(
      page,
      () => PublicationEdition(
        id: publicationId('$sobooksPublicationSource\n${page.path}'),
        title: title,
        author: publicationLabel(row.querySelector('p')?.text),
        cover: publicationCoverUrl(
          page,
          row.querySelector('img')?.attributes['src'],
          (uri) => uri.host == page.host,
        ),
        page: page,
        resources: [
          PublicationResource.lookup(
            source: sobooksPublicationSource,
            link: page,
          ),
        ],
      ),
    );
  }
  if (books.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return books.values.toList();
}
