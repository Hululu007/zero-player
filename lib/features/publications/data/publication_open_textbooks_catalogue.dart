import 'dart:convert';
import 'dart:isolate';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const openTextbooksSource = 'open-textbooks';
const _host = 'open.umn.edu';
const _catalogue = '/opentextbooks/textbooks';
final openTextbooksEndpoint = Uri.https(_host, '$_catalogue.json');
final _bookPath = RegExp('^$_catalogue/[A-Za-z0-9_-]{1,180}\$');

final class OpenTextbooksCatalogue
    implements
        DownloadablePublicationCatalogue,
        ProgressivePublicationCatalogue {
  const OpenTextbooksCatalogue(this.http);

  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _page('Think Python', 1, token);
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
    final isbn = filter?.isbn ?? normalizedIsbn(query);
    final term = isbn.isEmpty ? query : isbn;
    final results = <String, PublicationEdition>{};
    for (var number = 1; number <= maxPages; number++) {
      final page = await _page(
        term,
        number,
        token,
        isbn: filter == null ? isbn : '',
      );
      token.check();
      for (final book in page.books) {
        if ((filter?.matches(book) ?? true) &&
            allowed('${book.title} ${book.author}')) {
          results[book.id] = book;
        }
      }
      if (number >= page.totalPages ||
          results.length >= 30 ||
          isbn.isNotEmpty) {
        break;
      }
      if (results.isNotEmpty && number < maxPages) {
        await onProgress?.call(results.values.toList());
      }
    }
    return results.values.take(30).toList();
  }

  Future<({List<PublicationEdition> books, int totalPages})> _page(
    String term,
    int page,
    CancellationToken token, {
    String isbn = '',
  }) async {
    final target = openTextbooksEndpoint.replace(
      queryParameters: {'page': '$page', if (term.isNotEmpty) 'q': term},
    );
    final text = await _read(target, token);
    token.check();
    return Isolate.run(() => parseOpenTextbooksPage(text, isbn: isbn));
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final page = candidate.page;
    if (candidate.source != openTextbooksSource ||
        page == null ||
        !_isBookPage(page)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final document = jsonDecode(
      await _read(page.replace(path: '${page.path}.json'), token),
    );
    token.check();
    final edition = document is Map ? _edition(document['data'])?.$1 : null;
    if (edition?.page != page ||
        !edition!.candidates.any((item) => item.id == candidate.id)) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    final original = candidate.link;
    return PublicationDownload(
      original,
      scope: (target) {
        if (target.origin != original.origin) {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
      },
    );
  }

  Future<String> _read(Uri address, CancellationToken token) => http.text(
    address,
    token,
    maxBytes: 4 << 20,
    deadline: publicationCatalogueDeadline,
    allowGzip: true,
    scope: (target) {
      if (target != address) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    },
  );
}

({List<PublicationEdition> books, int totalPages}) parseOpenTextbooksPage(
  String text, {
  String isbn = '',
}) {
  final payload = jsonDecode(text);
  if (payload case {
    'data': final List rows,
    'links': {'total_pages': final int pages},
  } when rows.length <= 100 && pages >= 0) {
    return (
      books: [
        for (final row in rows)
          if (_edition(row) case (
            final book,
            final identifiers,
          ) when isbn.isEmpty || identifiers.contains(isbn))
            book,
      ],
      totalPages: pages,
    );
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

(PublicationEdition, Set<String>)? _edition(Object? item) {
  if (item is! Map || item['id'] is! int) return null;
  final title = publicationLabel(item['title']);
  final page = _publicUrl(item['url']);
  if (title.isEmpty || page == null || !_isBookPage(page)) return null;
  final id = item['id'] as int;
  final authors = <String>[], translators = <String>[];
  _contributors(item['contributors'], authors, translators);
  final formats = item['formats'];
  final license = publicationLabel(item['license']);
  final isbns = <String>{};
  final candidates = <Uri, AcquisitionCandidate>{};
  final resources = <Uri, PublicationResource>{};
  for (final value in [item['isbn13'], item['isbn10']]) {
    final isbn = normalizedIsbn(publicationLabel(value));
    if (isbn.isNotEmpty) isbns.add(isbn);
  }
  if (formats is List && _licenses.contains(license)) {
    for (final row in formats.take(24).whereType<Map>()) {
      final isbn = normalizedIsbn(publicationLabel(row['isbn']));
      if (isbn.isNotEmpty) isbns.add(isbn);
      final link = _publicUrl(row['url']);
      if (link == null ||
          (row['price'] is! Map || row['price']['cents'] != 0) ||
          !{'PDF', 'eBook'}.contains(row['type'] ?? row['format'])) {
        continue;
      }
      final type = PublicationFormat.fromName(link.path);
      if (type != null && !link.hasQuery && !link.hasFragment) {
        candidates[link] = _candidate(link, page, type);
      } else {
        resources[link] = PublicationResource(
          source: openTextbooksSource,
          link: link,
          label: '出版方下载',
        );
      }
    }
  }
  final legacy = switch (id) {
    43 => Uri.https('greenteapress.com', '/thinkpython2/thinkpython2.pdf'),
    677 => Uri.https('inventwithpython.com', '/makinggames.pdf'),
    _ => null,
  };
  if (legacy != null && _licenses.contains(license)) {
    candidates[legacy] = _candidate(legacy, page, PublicationFormat.pdf);
  }
  return (
    PublicationEdition(
      id: publicationId('$openTextbooksSource:$id'),
      title: title,
      author: publicationLabel(authors.join('、')),
      translator: publicationLabel(translators.join('、')),
      isbn: isbns.firstOrNull ?? '',
      alternateIsbns: isbns.skip(1).toList(),
      license: license,
      language: publicationLabel(item['language']),
      edition: publicationLabel(item['edition_statement']),
      page: page,
      candidates: candidates.values.toList(),
      resources: resources.values.toList(),
    ),
    isbns,
  );
}

void _contributors(
  Object? items,
  List<String> authors,
  List<String> translators,
) {
  if (items is! List) return;
  for (final person in items.take(32).whereType<Map>()) {
    final contribution = person['contribution'];
    if (contribution != 'Author' && contribution != 'Translator') continue;
    final name = ['first_name', 'middle_name', 'last_name']
        .map((key) => publicationLabel(person[key], max: 80))
        .where((value) => value.isNotEmpty)
        .join(' ');
    if (name.isNotEmpty) {
      (contribution == 'Translator' ? translators : authors).add(name);
    }
  }
}

const _licenses = {
  'Attribution',
  'Attribution-ShareAlike',
  'Attribution-NoDerivs',
  'Attribution-NonCommercial',
  'Attribution-NonCommercial-ShareAlike',
  'Attribution-NonCommercial-NoDerivs',
  'No Rights Reserved',
  'Free Documentation License (GNU)',
};

AcquisitionCandidate _candidate(Uri link, Uri page, PublicationFormat format) =>
    AcquisitionCandidate(
      source: openTextbooksSource,
      link: link,
      page: page,
      format: format,
    );

bool _isBookPage(Uri page) =>
    page.scheme == 'https' &&
    page.port == 443 &&
    page.userInfo.isEmpty &&
    page.host == _host &&
    !page.hasQuery &&
    !page.hasFragment &&
    _bookPath.hasMatch(page.path);

Uri? _publicUrl(Object? raw) {
  if (raw is! String || raw.length > 2048) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'https' || uri.port != 443) return null;
  try {
    validatePublicationAddress(uri);
    return uri;
  } on Exception {
    return null;
  }
}
