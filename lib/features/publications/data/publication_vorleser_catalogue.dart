import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const vorleserPublicationSource = 'panda-vorleser';
final vorleserHome = Uri.https('www.vorleser.net', '/');
final vorleserEndpoint = vorleserHome.resolve('/suche');
final _bookPath = RegExp(r'^/hoerbuch/[a-z0-9][a-z0-9-]{0,135}$');
final _overlayQuery = RegExp(r'\?pop=1$');
final _pdfPath = RegExp(
  r'^/files/user/audiobook/text/[a-zA-Z0-9_-]{1,135}\.pdf$',
);

final class VorleserCatalogue implements DownloadablePublicationCatalogue {
  const VorleserCatalogue(this.http);

  final PublicationHttp http;
  PublicListingCatalogue get _listing => PublicListingCatalogue(
    http,
    address: (query, page) => query.isEmpty
        ? vorleserHome
        : vorleserEndpoint.replace(
            queryParameters: {
              'tx_kesearch_pi1[sword]': query,
              if (page > 1) 'tx_kesearch_pi1[page]': '$page',
            },
          ),
    parse: parseVorleserCatalogue,
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
  }) async {
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final books = await _listing.search(
      query,
      token,
      maxPages: maxPages,
      allowed: allowed,
      filter: filter,
    );
    if (query.isEmpty) return books;
    final enriched = await Future.wait(
      books.take(6).map((book) async {
        try {
          return book.withCandidates(await _files(book.page!, token));
        } on RequestCancelled {
          rethrow;
        } on Exception {
          return book;
        }
      }),
    );
    return [...enriched, ...books.skip(enriched.length)];
  }

  Future<List<AcquisitionCandidate>> _files(
    Uri page,
    CancellationToken token,
  ) async {
    final document = html.parse(await publicListingText(http, page, token));
    final files = <Uri>{};
    for (final anchor in document.querySelectorAll('main a[href]')) {
      final file = publicListingLink(
        vorleserHome,
        anchor.attributes['href'],
        _pdfPath,
      );
      if (file != null) files.add(file);
    }
    return [
      for (final file in files)
        AcquisitionCandidate(
          source: vorleserPublicationSource,
          link: file,
          page: page,
          format: PublicationFormat.pdf,
        ),
    ];
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    if (page == null ||
        candidate.source != vorleserPublicationSource ||
        candidate.format != PublicationFormat.pdf ||
        publicListingLink(vorleserHome, page.toString(), _bookPath) != page ||
        publicListingLink(vorleserHome, candidate.link.toString(), _pdfPath) !=
            candidate.link) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!(await _files(
      page,
      token,
    )).any((file) => file.link == candidate.link)) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      candidate.link,
      scope: (target) {
        if (target != candidate.link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }
}

PublicationListingPage parseVorleserCatalogue(String body) {
  final document = html.parse(body);
  if (document.querySelector('form[action="/suche"] input[type="search"]') ==
      null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final card in document.querySelectorAll('main article.audiobook')) {
    final heading = card.querySelector('.audiobook__header .title a[href]');
    final href = heading?.attributes['href']?.replaceFirst(_overlayQuery, '');
    final page = publicListingLink(vorleserHome, href, _bookPath);
    final title = publicationLabel(heading?.text);
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$vorleserPublicationSource\n$page'),
      title: title,
      author: publicationLabel(
        card.querySelector('.audiobook__header .author')?.text,
      ),
      language: 'de',
      cover: publicationCoverUrl(
        vorleserHome,
        card.querySelector('.audiobook-cover img')?.attributes['src'],
        (uri) =>
            uri.host == vorleserHome.host &&
            (uri.path.startsWith('/files/user/audiobook/image/') ||
                uri.path.startsWith('/fileadmin/_processed_/files_user/')),
      ),
      page: page,
    );
  }
  return (
    books: books.values.toList(),
    hasNext: document.querySelector('#searched .pagination a.-next') != null,
  );
}
