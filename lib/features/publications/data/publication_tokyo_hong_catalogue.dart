import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const tokyoHongSource = 'tokyo-hong-catalogue';
const _host = 'hong.ioc.u-tokyo.ac.jp';
const _recordHost = 'kanseki.ioc.u-tokyo.ac.jp';
final tokyoHongCatalogueEndpoint = Uri.https(_host, '/list.php');
final _searchEndpoint = tokyoHongCatalogueEndpoint.replace(
  queryParameters: {'order': 'rn_no'},
);
final _catalogueAnchor = RegExp(
  r"^javascript:HelpClick\('([A-Z][0-9]{4,10})'\)$",
);

final class TokyoHongCatalogue implements PublicationCatalogue {
  const TokyoHongCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    if ((await _request('', token)).isEmpty) {
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
    final terms = publicationLabel(query, max: 100);
    return (await _request(terms, token))
        .where(
          (edition) =>
              (filter?.matches(edition) ?? true) && allowed(edition.title),
        )
        .toList();
  }

  Future<List<PublicationEdition>> _request(
    String query,
    CancellationToken token,
  ) async {
    // The public search form keeps pagination state in the browser. A single
    // submission avoids collecting the entire catalogue or opening images.
    final endpoint = query.isEmpty
        ? tokyoHongCatalogueEndpoint
        : _searchEndpoint;
    final source = await http.text(
      endpoint,
      token,
      maxBytes: 256 << 10,
      form: query.isEmpty ? null : {'col': 'ti', 'str': query, 'submits': '檢索'},
      scope: (uri) {
        if (uri != endpoint) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    return parseTokyoHongListing(source);
  }
}

List<PublicationEdition> parseTokyoHongListing(String source) {
  final document = html.parse(source);
  if (document.querySelector('form[name="qform"] select[name="col"]') == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final entries = <String, PublicationEdition>{};
  for (final row in document.querySelectorAll(
    'tr.line_color_a, tr.line_color_b',
  )) {
    final cells = row.children;
    if (cells.length != 5) continue;
    final title = publicationLabel(cells[1].text);
    if (title.isEmpty) continue;
    final anchors = cells[4].querySelectorAll('a[href]');
    final book = anchors
        .where((anchor) => anchor.querySelector('img[alt="目錄data"]') != null)
        .firstOrNull;
    final id = _catalogueAnchor
        .firstMatch(book?.attributes['href'] ?? '')
        ?.group(1);
    if (id == null) continue;
    entries.putIfAbsent(
      id,
      () => PublicationEdition(
        id: publicationId('tokyo-hong:$id'),
        title: title,
        language: '中文',
        edition: publicationLabel(cells[3].text),
        tags: [publicationLabel(cells[2].text)],
        // The catalogue's legacy popup redirects through HTTP. Use the same
        // official library record at its verified HTTPS address.
        page: Uri.https(_recordHost, '/kanzi/user/query_detail_im.php', {
          'nu': id,
        }),
      ),
    );
  }
  return entries.values.toList();
}
