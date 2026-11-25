import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_obp_distribution.dart';

const obpPublicationSource = 'open-book-publishers-kbart';
const _publisher = 'Open Book Publishers';
const _publisherId = '85fd969a-a16c-480b-b641-cb9adf979c3b';
final obpCatalogueEndpoint = Uri.https(
  'export.thoth.pub',
  '/specifications/kbart::oclc/publisher/$_publisherId',
);
final obpCataloguePage = Uri.https('www.openbookpublishers.com');
final _doi = RegExp(r'^10\.11647/obp\.[0-9]{4,8}$');
const _columns = [
  'publication_title',
  'print_identifier',
  'online_identifier',
  'title_url',
  'title_id',
  'first_author',
  'first_editor',
  'publisher_name',
  'publication_type',
  'date_monograph_published_online',
  'monograph_edition',
];

final class ObpCatalogue implements DownloadablePublicationCatalogue {
  ObpCatalogue(this.http) : _distribution = ObpDistribution(http);
  final PublicationHttp http;
  final ObpDistribution _distribution;
  List<(PublicationEdition, String)>? _books;

  @override
  Future<void> check(CancellationToken token) async {
    await _load(token, refresh: true);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final isbn = normalizedIsbn(query);
    final books = await _load(token);
    final matches = [
      for (final (book, printIsbn) in books)
        if ((filter?.matches(book) ??
                (book.matches(query) ||
                    (isbn.isNotEmpty && isbn == printIsbn))) &&
            allowed('${book.title} ${book.author}'))
          book,
    ];
    final limit = maxPages * 20;
    if (matches.isEmpty) return matches;
    final Map<String, String> titles;
    try {
      titles = await _distribution.titles(token);
    } on Exception {
      token.check();
      return matches.take(limit).toList();
    }
    final byTitle = <String, List<PublicationEdition>>{};
    for (final book in matches) {
      byTitle.putIfAbsent(obpDistributionTitle(book.title), () => []).add(book);
    }
    final selected = [
      for (final MapEntry(key: title, value: work) in titles.entries)
        if (work.isNotEmpty)
          for (final book in byTitle[title] ?? const <PublicationEdition>[])
            (book, work),
    ];
    final verified = await Future.wait(
      selected.take(5).map((row) => _withCopies(row.$1, row.$2, token)),
    );
    token.check();
    final available = {for (final book in verified.nonNulls) book.id: book};
    return [
      if (query.isEmpty) ...available.values,
      for (final book in matches)
        if (query.isNotEmpty || !available.containsKey(book.id))
          available[book.id] ?? book,
    ].take(limit).toList();
  }

  Future<PublicationEdition?> _withCopies(
    PublicationEdition book,
    String work,
    CancellationToken token,
  ) async {
    try {
      final copies = await _distribution.copies(book, work, token);
      if (copies.isEmpty) return null;
      return book.withCandidates([
        for (final copy in copies) _candidate(book, work, copy),
      ], license: copies.map((copy) => copy.license).toSet().join(' · '));
    } on Exception {
      token.check();
      return null;
    }
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final work = candidate.fileId;
    if (candidate.source != obpPublicationSource ||
        candidate.page == null ||
        work == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final books = await _load(token, refresh: true);
    final book = books
        .map((row) => row.$1)
        .where((row) => row.page == candidate.page)
        .firstOrNull;
    if (book != null) {
      for (final copy in await _distribution.copies(book, work, token)) {
        if (_candidate(book, work, copy).id == candidate.id) {
          return _distribution.resolve(copy, token);
        }
      }
    }
    throw const PublicationFailure(PublicationProblem.missing);
  }

  Future<List<(PublicationEdition, String)>> _load(
    CancellationToken token, {
    bool refresh = false,
  }) async {
    token.check();
    http.authorize(obpCatalogueEndpoint);
    final books = _books;
    if (!refresh && books != null) return books;
    final body = await http.text(
      obpCatalogueEndpoint,
      token,
      maxBytes: 1 << 20,
      deadline: publicationCatalogueDeadline,
      scope: (uri) {
        if (uri != obpCatalogueEndpoint) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    token.check();
    return _books = parseObpCatalogue(body);
  }
}

AcquisitionCandidate _candidate(
  PublicationEdition book,
  String work,
  ObpHostedCopy copy,
) => AcquisitionCandidate(
  source: obpPublicationSource,
  page: book.page,
  link: copy.link,
  format: copy.format,
  fileId: work,
);

List<(PublicationEdition, String)> parseObpCatalogue(String body) {
  final lines = body.split(RegExp(r'\r?\n'));
  final header = lines.first.replaceFirst('\uFEFF', '').split('\t');
  final index = {for (final name in _columns) name: header.indexOf(name)};
  if (lines.length > 2500 || index.values.contains(-1)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, (PublicationEdition, String)>{};
  for (final line in lines.skip(1)) {
    final cells = line.split('\t');
    if (cells.length != header.length) continue;
    String field(String name) => cells[index[name]!].trim();
    final title = publicationLabel(field('publication_title'));
    final id = field('title_id').toLowerCase();
    final page = Uri.tryParse(field('title_url'));
    if (title.isEmpty ||
        field('publication_type') != 'Monograph' ||
        field('publisher_name') != _publisher ||
        !_doi.hasMatch(id) ||
        page == null ||
        page.scheme != 'https' ||
        page.host != obpCataloguePage.host ||
        page.port != 443 ||
        page.userInfo.isNotEmpty ||
        page.hasQuery ||
        page.hasFragment ||
        page.path.toLowerCase() != '/books/$id') {
      continue;
    }
    final author = field('first_author');
    final editor = field('first_editor');
    final edition = [
      field('date_monograph_published_online'),
      field('monograph_edition'),
    ].where((value) => value.isNotEmpty).join(' · ');
    books.putIfAbsent(
      id,
      () => (
        PublicationEdition(
          id: publicationId('$obpPublicationSource\n$id'),
          title: title,
          author: publicationLabel(author.isEmpty ? editor : author),
          edition: publicationLabel(edition),
          isbn: normalizedIsbn(field('online_identifier')),
          alternateIsbns: [
            if (normalizedIsbn(field('print_identifier')) case final isbn
                when isbn.isNotEmpty)
              isbn,
          ],
          page: page,
        ),
        normalizedIsbn(field('print_identifier')),
      ),
    );
  }
  if (books.isEmpty) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return books.values.toList();
}
