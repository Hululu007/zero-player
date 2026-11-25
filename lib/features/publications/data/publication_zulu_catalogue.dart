import 'package:html/parser.dart' as html;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_public_listing.dart';

const zuluPublicationSource = 'panda-zulu-ebooks';
final zuluCatalogueHome = Uri.https('zulu-ebooks.com', '/');
final zuluCatalogueEndpoint = zuluCatalogueHome.resolve('/suche');
final _bookPath = RegExp(
  r'^/(?:belletristik|sachliteratur|ratgeber|kinder-und-jugend)/[a-z0-9-]{1,160}$',
);
final _filePath = RegExp(r'/pdf(?:/epub|/mobi)?$');
const _formats = {
  PublicationFormat.pdf: 'pdf',
  PublicationFormat.epub: 'pdf/epub',
  PublicationFormat.mobi: 'pdf/mobi',
};

final class ZuluCatalogue implements DownloadablePublicationCatalogue {
  const ZuluCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    final rows = await _listing('', token);
    if (rows.isEmpty) {
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
    if (filter?.field == PublicationSearchField.isbn) return const [];
    final books = (await _listing(query, token))
        .where(
          (book) =>
              filter?.matches(book) != false &&
              allowed('${book.title} ${book.author}'),
        )
        .take(20 * maxPages.clamp(1, 3))
        .toList();
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

  Future<List<PublicationEdition>> _listing(
    String query,
    CancellationToken token,
  ) async {
    final uri = query.isEmpty
        ? zuluCatalogueHome
        : zuluCatalogueEndpoint.replace(queryParameters: {'q': query});
    return parseZuluCatalogue(
      await publicListingText(http, uri, token),
      searching: query.isNotEmpty,
    );
  }

  Future<List<AcquisitionCandidate>> _files(
    Uri page,
    CancellationToken token,
  ) async => parseZuluFiles(await publicListingText(http, page, token), page);

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    final suffix = _formats[candidate.format];
    if (page == null ||
        suffix == null ||
        publicListingLink(zuluCatalogueHome, page.toString(), _bookPath) !=
            page ||
        candidate.source != zuluPublicationSource ||
        candidate.link != page.replace(path: '${page.path}/$suffix')) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (!(await _files(page, token)).any((item) => item.id == candidate.id)) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      candidate.link,
      scope: (uri) {
        if (uri != candidate.link) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }
}

List<PublicationEdition> parseZuluCatalogue(
  String body, {
  required bool searching,
}) {
  final document = html.parse(body);
  final container = searching
      ? document.querySelector('#search-results')
      : document.body;
  if (container == null) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row in container.querySelectorAll(
    searching ? 'li[data-zid] .z-liste-ebook__text' : 'li[data-zid].z-cover',
  )) {
    final heading = row.querySelector(
      '.z-liste-ebook__titel a, a.z-cover__link',
    );
    final page = publicListingLink(
      zuluCatalogueHome,
      heading?.attributes['href'],
      _bookPath,
    );
    final title = publicationLabel(
      searching
          ? heading?.text
          : heading?.querySelector('.z-cover__title')?.text,
    );
    final author = publicationLabel(
      row.querySelector('.z-liste-ebook__autor, .z-cover__author')?.text,
    );
    if (page == null || title.isEmpty) continue;
    books[page] = PublicationEdition(
      id: publicationId('$zuluPublicationSource\n$page'),
      title: title,
      author: author,
      page: page,
      language: 'de',
    );
  }
  return books.values.toList();
}

List<AcquisitionCandidate> parseZuluFiles(String body, Uri page) {
  if (publicListingLink(zuluCatalogueHome, page.toString(), _bookPath) !=
      page) {
    return const [];
  }
  final document = html.parse(body);
  final canonical = document
      .querySelector('link[rel=canonical]')
      ?.attributes['href'];
  if (Uri.tryParse(canonical ?? '') != page) return const [];
  final candidates = <Uri, AcquisitionCandidate>{};
  for (final button in document.querySelectorAll('.z-ebook__formate a[href]')) {
    final label = button.text.trim().toLowerCase();
    final format = _formats.keys
        .where((item) => item.name == label)
        .firstOrNull;
    if (format == null) continue;
    final expected = page.replace(path: '${page.path}/${_formats[format]}');
    if (publicListingLink(page, button.attributes['href'], _filePath) !=
        expected) {
      continue;
    }
    candidates[expected] = AcquisitionCandidate(
      source: zuluPublicationSource,
      link: expected,
      format: format,
      page: page,
    );
  }
  return candidates.values.toList();
}
