import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const tstrsSource = 'tstrs-catalogue';
const _host = 'tstrs.me';
const _boards = ['classics', 'hot', 'top-rated', 'hidden'];
final tstrsCatalogueEndpoint = _board(_boards.first);
final _slug = RegExp(r'^[\p{L}\p{M}\p{N}_-]{1,160}$', unicode: true);

/// Reads public ranking pages. The site's search and API routes are excluded
/// by its robots.txt, so user queries only filter the published charts locally.
final class TstrsCatalogue implements PublicationCatalogue {
  const TstrsCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _page(tstrsCatalogueEndpoint, token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final words = query.toLowerCase().trim().split(RegExp(r'\s+'));
    final boards = query.trim().isEmpty
        ? _boards.take(maxPages.clamp(1, _boards.length))
        : _boards;
    final errors = <Exception>[];
    final pages = await Future.wait(
      boards.map((name) async {
        try {
          return await _page(_board(name), token);
        } on Exception catch (error) {
          token.check();
          if (error is PublicationFailure &&
              error.problem == PublicationProblem.blocked) {
            rethrow;
          }
          errors.add(error);
          return const <PublicationEdition>[];
        }
      }),
    );
    if (pages.every((page) => page.isEmpty) && errors.isNotEmpty) {
      throw errors.first;
    }
    final editions = <String, PublicationEdition>{};
    for (final entries in pages) {
      for (final entry in entries) {
        token.check();
        final searchable = '${entry.title} ${entry.author} ${entry.edition}';
        if (allowed(searchable) &&
            (filter?.matches(entry) ??
                words.every(searchable.toLowerCase().contains))) {
          editions.putIfAbsent(entry.id, () => entry);
        }
      }
    }
    return editions.values.toList();
  }

  Future<List<PublicationEdition>> _page(
    Uri address,
    CancellationToken token,
  ) async {
    final content = await http.text(
      address,
      token,
      scope: (target) {
        if (target != address) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
      maxBytes: 192 << 10,
    );
    token.check();
    return parseTstrsChart(content);
  }
}

Uri _board(String name) => Uri.https(_host, '/charts', {'board': name});

List<PublicationEdition> parseTstrsChart(String content) {
  final rows = html.parse(content).querySelectorAll('main a.rank-item[href]');
  if (rows.isEmpty || rows.length > 80) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final editions = <String, PublicationEdition>{};
  for (final row in rows) {
    final page = _bookPage(row.attributes['href']!);
    final title = publicationLabel(
      row.querySelector('.search-row-title')?.text,
    );
    if (page == null || title.isEmpty) continue;
    final id = publicationId('$tstrsSource:$page');
    editions.putIfAbsent(
      id,
      () => PublicationEdition(
        id: id,
        title: title,
        author: publicationLabel(row.querySelector('.search-row-author')?.text),
        edition: publicationLabel(row.querySelector('.search-row-press')?.text),
        license: '仅书目信息',
        page: page,
      ),
    );
  }
  if (editions.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return editions.values.toList();
}

Uri? _bookPage(String href) {
  final reference = Uri.tryParse(href);
  if (reference == null ||
      (reference.hasAuthority
          ? reference.scheme != 'https'
          : !href.startsWith('/b/'))) {
    return null;
  }
  final page = tstrsCatalogueEndpoint.resolveUri(reference);
  if (page.scheme != 'https' ||
      page.host != _host ||
      page.port != 443 ||
      page.userInfo.isNotEmpty ||
      page.hasQuery ||
      page.hasFragment ||
      page.pathSegments.length != 2 ||
      page.pathSegments.first != 'b' ||
      !_slug.hasMatch(page.pathSegments.last)) {
    return null;
  }
  return Uri(scheme: 'https', host: _host, pathSegments: page.pathSegments);
}
