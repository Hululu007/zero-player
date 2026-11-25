import 'package:xml/xml.dart';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const gallicaPublicationSource = 'bnf-gallica-public-catalogue';
final gallicaCatalogueEndpoint = Uri.https('catalogue.bnf.fr', '/api/SRU');
final gallicaCataloguePage = Uri.https('gallica.bnf.fr', '/');
const _srw = 'http://www.loc.gov/zing/srw/';
const _marc = 'info:lc/xmlns/marcxchange-v2';
const _printedBooks =
    'bib.digitized all "freeAccess" and bib.recordtype all "mon" and bib.doctype all "a"';
final _arkPath = RegExp(r'^/ark:/12148/bpt6k[a-z0-9]{3,24}$');
final _word = RegExp(
  r"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*",
  unicode: true,
);

final class GallicaCatalogue implements PublicationCatalogue {
  const GallicaCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _page(_printedBooks, 1, token);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final expression = gallicaCatalogueQuery(
      query,
      field: filter?.field ?? PublicationSearchField.all,
    );
    if (expression == null) return const [];
    final found = <String, PublicationEdition>{};
    var start = 1;
    for (var number = 1; number <= maxPages; number++) {
      final ({List<PublicationEdition> books, int? next}) page;
      try {
        page = await _page(expression, start, token);
      } on Exception catch (error) {
        token.check();
        if (number == 1 || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      for (final book in page.books) {
        if ((filter?.matches(book) ?? true) &&
            allowed('${book.title} ${book.author}')) {
          found.putIfAbsent(book.id, () => book);
        }
      }
      final next = page.next;
      if (query.isEmpty || next != start + 10 || found.length >= 30) break;
      start = next!;
    }
    return found.values.take(30).toList();
  }

  Future<({List<PublicationEdition> books, int? next})> _page(
    String query,
    int start,
    CancellationToken token,
  ) async {
    final address = gallicaCatalogueEndpoint.replace(
      queryParameters: {
        'version': '1.2',
        'operation': 'searchRetrieve',
        'query': query,
        'recordSchema': 'unimarcXchange',
        'maximumRecords': '10',
        'startRecord': '$start',
      },
    );
    final body = await http.text(
      address,
      token,
      maxBytes: 512 << 10,
      deadline: publicationCatalogueDeadline,
      scope: (uri) {
        if (uri != address) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
    token.check();
    return parseGallicaCatalogue(body);
  }
}

String? gallicaCatalogueQuery(
  String raw, {
  PublicationSearchField field = PublicationSearchField.all,
}) {
  if (raw.isEmpty) return _printedBooks;
  final isbn = normalizedIsbn(raw);
  if (field == PublicationSearchField.isbn ||
      (field == PublicationSearchField.all && isbn.isNotEmpty)) {
    return isbn.isEmpty ? null : '$_printedBooks and bib.fuzzyISBN all "$isbn"';
  }
  final terms = _word
      .allMatches(raw)
      .take(12)
      .map((match) => match[0]!)
      .join(' ');
  if (terms.isEmpty) return null;
  final criterion = switch (field) {
    PublicationSearchField.title => 'bib.title all "$terms"',
    PublicationSearchField.author => 'bib.author all "$terms"',
    _ => '(bib.title all "$terms" or bib.author all "$terms")',
  };
  return '$_printedBooks and $criterion';
}

({List<PublicationEdition> books, int? next}) parseGallicaCatalogue(
  String body,
) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlException {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final root = document.childElements.singleOrNull;
  if (root == null ||
      root.localName != 'searchRetrieveResponse' ||
      root.namespaceUri != _srw ||
      root.getElement('diagnostics', namespaceUri: _srw) != null ||
      document.children.any((node) => node is XmlDoctype)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final records = root.getElement('records', namespaceUri: _srw);
  final count = int.tryParse(_value(root, 'numberOfRecords'));
  if (count == null || (count > 0 && records == null)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <Uri, PublicationEdition>{};
  for (final row
      in records?.findElements('record', namespaceUri: _srw) ??
          const <XmlElement>[]) {
    final marc = row
        .getElement('recordData', namespaceUri: _srw)
        ?.getElement('record', namespaceUri: _marc);
    if (marc == null ||
        marc.getAttribute('format') != 'UNIMARC' ||
        marc.getAttribute('type') != 'Bibliographic') {
      continue;
    }
    for (final book in _editions(marc)) {
      books.putIfAbsent(book.page!, () => book);
    }
  }
  return (
    books: books.values.toList(),
    next: int.tryParse(_value(root, 'nextRecordPosition')),
  );
}

String _value(XmlElement record, String name) =>
    record.getElement(name, namespaceUri: _srw)?.innerText ?? '';

Iterable<PublicationEdition> _editions(XmlElement marc) sync* {
  final fields = marc.findElements('datafield', namespaceUri: _marc);
  Iterable<XmlElement> tagged(String tag) =>
      fields.where((field) => field.getAttribute('tag') == tag);
  String? field(String tag, String code) =>
      _subfield(tagged(tag).firstOrNull, code);
  final title = publicationLabel(field('200', 'a'));
  if (title.isEmpty) return;
  final authors = [...tagged('700'), ...tagged('701')]
      .take(6)
      .map(
        (person) =>
            [_subfield(person, 'a'), _subfield(person, 'b')].nonNulls.join(' '),
      )
      .where((person) => person.isNotEmpty)
      .join('、');
  for (final related in tagged('856').take(12)) {
    final page = _digitalPage(_subfield(related, 'u'));
    if (page == null) continue;
    yield PublicationEdition(
      id: publicationId('$gallicaPublicationSource\n${page.path}'),
      title: title,
      author: publicationLabel(authors.isEmpty ? field('200', 'f') : authors),
      isbn: normalizedIsbn(publicationLabel(field('010', 'a'))),
      language: publicationLabel(field('101', 'a')),
      edition: publicationLabel(field('214', 'd') ?? field('210', 'd')),
      page: page,
    );
  }
}

String? _subfield(XmlElement? field, String code) => field
    ?.findElements('subfield', namespaceUri: _marc)
    .where((node) => node.getAttribute('code') == code)
    .firstOrNull
    ?.innerText;

Uri? _digitalPage(String? raw) {
  if (raw == null || raw.length > 256) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host != gallicaCataloguePage.host ||
      uri.port != (uri.scheme == 'https' ? 443 : 80) ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !_arkPath.hasMatch(uri.path)) {
    return null;
  }
  return gallicaCataloguePage.resolve(uri.path);
}
