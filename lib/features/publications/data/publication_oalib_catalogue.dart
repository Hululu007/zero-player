import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const oalibPublicationSource = 'panda-oalib';
final oalibHome = Uri.https('www.oalib.com', '/');
final oalibEndpoint = oalibHome.resolve('journal/');
final _articlePath = RegExp(r'^/articles/[1-9][0-9]{0,9}$');
final _articleDoi = RegExp(r'^10\.4236/oalib\.([1-9][0-9]{0,9})$');
final _downloadId = RegExp(r'^paperID=[1-9][0-9]{0,9}$');
const _downloadPath = '/journal/PaperDownload.aspx';
const _canonicalDownload = '/journal/PaperDownload';

final class OalibCatalogue
    implements
        ProgressivePublicationCatalogue,
        DownloadablePublicationCatalogue {
  const OalibCatalogue(this.http);

  final PublicationHttp http;

  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => oalibEndpoint.replace(
      queryParameters: {
        if (query.isNotEmpty) 'kw': query,
        if (page > 1) 'page': '$page',
      },
    ),
    parse: parseOalibCatalogue,
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
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    if (page == null ||
        candidate.source != oalibPublicationSource ||
        candidate.format != PublicationFormat.pdf ||
        publicListingLink(oalibHome, page.toString(), _articlePath) != page ||
        _publishedPdf(candidate.link.toString()) != candidate.link) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final document = html.parse(await publicListingText(http, page, token));
    final original = _publishedPdf(
      document
          .querySelector('meta[name="citation_pdf_url"]')
          ?.attributes['content'],
    );
    final doi = document
        .querySelector('meta[name="citation_doi"]')
        ?.attributes['content'];
    final number = _articleDoi.firstMatch(doi ?? '')?[1];
    if (original != candidate.link || number == null) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    final canonical = candidate.link.replace(path: _canonicalDownload);
    final file = Uri.https('content.scirp.org', '/pdf/oalib_$number.pdf');
    return PublicationDownload(
      candidate.link,
      scope: (target) {
        if (target != candidate.link && target != canonical && target != file) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }
}

PublicationListingPage parseOalibCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector(
        'input[name="kw"][placeholder="Search OALib Journal Articles"]',
      ) ==
      null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  final rows = document.querySelectorAll('div.paperlist');
  for (final row in rows) {
    final heading = row.querySelector('h3 a[href]');
    final page = publicListingLink(
      oalibHome,
      heading?.attributes['href'],
      _articlePath,
    );
    final title = publicationLabel(heading?.text);
    if (page == null || title.isEmpty) continue;
    final authors =
        row
            .querySelector('h5')
            ?.querySelectorAll('a[href*="searchField=authors"]') ??
        const [];
    final file = _publishedPdf(
      row.querySelector('p a .oagr')?.parent?.attributes['href'],
    );
    books[page] = PublicationEdition(
      id: publicationId('$oalibPublicationSource\n$page'),
      title: title,
      author: publicationLabel(
        authors.map((author) => author.text.trim()).join('、'),
      ),
      publisher: 'Open Access Library Journal',
      page: page,
      candidates: [
        if (file != null)
          AcquisitionCandidate(
            source: oalibPublicationSource,
            link: file,
            page: page,
            format: PublicationFormat.pdf,
          ),
      ],
    );
  }
  return (books: books.values.toList(), hasNext: rows.length >= 10);
}

Uri? _publishedPdf(String? raw) {
  final value = Uri.tryParse(raw ?? '');
  if (value == null ||
      value.host != 'www.scirp.org' ||
      value.userInfo.isNotEmpty ||
      value.hasFragment ||
      !const {'', 'http', 'https'}.contains(value.scheme) ||
      value.hasPort ||
      !const {_downloadPath, _canonicalDownload}.contains(value.path) ||
      !_downloadId.hasMatch(value.query)) {
    return null;
  }
  return Uri.https('www.scirp.org', _downloadPath, value.queryParameters);
}
