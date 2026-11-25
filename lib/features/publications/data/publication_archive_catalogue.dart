import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_archive_hosts.dart';

const archiveGutenbergSource = 'internet-archive-gutenberg';
final archiveCatalogueEndpoint = Uri.https(
  'archive.org',
  '/advancedsearch.php',
);
final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$');
final _fileName = RegExp(r'^pg[0-9]+\.epub$');
final _shard = RegExp(r'^[0-9]{1,3}$');
typedef _ArchiveListing = ({
  String id,
  String title,
  String author,
  List<String> isbns,
  bool gutenberg,
});

final class ArchiveGutenbergCatalogue
    implements DownloadablePublicationCatalogue {
  const ArchiveGutenbergCatalogue(this.http);
  final PublicationHttp http;

  @override
  Future<void> check(CancellationToken token) async {
    await _list('', 1, token, count: 1);
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  }) async {
    final editions = <PublicationEdition>[];
    final seen = <String>{};
    for (var page = 1; page <= maxPages; page++) {
      try {
        final listings = await _list(query, page, token, filter: filter);
        if (listings.isEmpty) break;
        for (final row in listings) {
          token.check();
          if (!seen.add(row.id)) continue;
          final verified = query.isEmpty || row.gutenberg || row.title.isEmpty
              ? await _edition(row.id, token)
              : null;
          final edition =
              verified ??
              (query.isEmpty || row.title.isEmpty
                  ? null
                  : PublicationEdition(
                      id: publicationId('archive-gutenberg:${row.id}'),
                      title: row.title,
                      author: row.author,
                      isbn: row.isbns.firstOrNull ?? '',
                      alternateIsbns: row.isbns.skip(1).toList(),
                      page: Uri.https('archive.org', '/details/${row.id}'),
                    ));
          if (edition != null &&
              (filter?.matches(edition) ?? true) &&
              allowed('${edition.title} ${edition.author}')) {
            editions.add(edition);
          }
        }
      } on Exception catch (error) {
        token.check();
        if (editions.isEmpty || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      if (editions.length >= 16) break;
    }
    return editions;
  }

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final path = candidate.link.pathSegments;
    if (path.length != 3 ||
        path.first != 'download' ||
        candidate.link.host != 'archive.org' ||
        !_identifier.hasMatch(path[1]) ||
        !_fileName.hasMatch(path[2])) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final edition = await _edition(path[1], token);
    final current = edition?.candidates
        .where(
          (item) =>
              item.link == candidate.link &&
              item.bytes == candidate.bytes &&
              item.format == candidate.format,
        )
        .firstOrNull;
    if (current == null) {
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return PublicationDownload(
      current.link,
      scope: (uri) => restrictArchivePublicationFile(uri, path[1], path[2]),
    );
  }

  Future<List<_ArchiveListing>> _list(
    String raw,
    int page,
    CancellationToken token, {
    int count = 8,
    PublicationFieldSearch? filter,
  }) async {
    final q = archiveGutenbergSearch(
      raw,
      wholeCatalogue: raw.isNotEmpty,
      field: filter?.field ?? PublicationSearchField.all,
    );
    final uri = archiveCatalogueEndpoint.replace(
      queryParameters: {
        'q': q,
        'fl[]': ['identifier', 'title', 'creator', 'contributor', 'isbn'],
        'rows': '$count',
        'page': '$page',
        'output': 'json',
      },
    );
    final data = jsonDecode(
      await http.text(
        uri,
        token,
        maxBytes: 128 << 10,
        deadline: publicationCatalogueDeadline,
        scope: (uri) => _restrictCatalogue(uri, '/advancedsearch.php'),
      ),
    );
    if (data case {
      'response': {'docs': final List docs},
    } when docs.length <= count) {
      return [
        for (final row in docs)
          if (row case {
            'identifier': final String id,
          } when _identifier.hasMatch(id))
            (
              id: id,
              title: publicationLabel(row['title']),
              author: publicationLabel(
                _strings(row['creator']).take(4).join('、'),
              ),
              isbns: _archiveIsbns(row['isbn']),
              gutenberg: _strings(
                row['contributor'],
              ).contains('Project Gutenberg'),
            ),
      ];
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  Future<PublicationEdition?> _edition(
    String id,
    CancellationToken token,
  ) async {
    final uri = Uri.https('archive.org', '/metadata/$id');
    try {
      final data = await http.text(
        uri,
        token,
        maxBytes: 1 << 20,
        deadline: publicationCatalogueDeadline,
        scope: (target) => _restrictCatalogue(target, uri.path),
      );
      return archiveGutenbergEdition(id, jsonDecode(data));
    } on PublicationFailure catch (error) {
      if (error.problem == PublicationProblem.missing) return null;
      rethrow;
    }
  }

  static void _restrictCatalogue(Uri url, String path) {
    if (url.scheme != 'https' ||
        url.port != 443 ||
        url.host != 'archive.org' ||
        url.path != path) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }
}

String archiveGutenbergSearch(
  String raw, {
  bool wholeCatalogue = false,
  PublicationSearchField field = PublicationSearchField.all,
}) {
  final isbn =
      field == PublicationSearchField.all ||
          field == PublicationSearchField.isbn
      ? normalizedIsbn(raw)
      : '';
  final words = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*", unicode: true)
      .allMatches(raw)
      .take(12)
      .map((word) => word[0]!.replaceAll('’', "'"))
      .toList();
  final phrase = words.join(' ');
  String matches(String term) => switch (field) {
    PublicationSearchField.title => 'title:"$term"',
    PublicationSearchField.author => 'creator:"$term"',
    _ => '(title:"$term" OR creator:"$term")',
  };
  final search = switch (words.length) {
    0 => '',
    1 => matches(phrase),
    _ => '(${matches(phrase)} OR (${words.map(matches).join(' AND ')}))',
  };
  return [
    'mediatype:texts',
    if (!wholeCatalogue) ...[
      'collection:gutenberg',
      'contributor:"Project Gutenberg"',
    ],
    if (isbn.isNotEmpty) 'isbn:"$isbn"' else if (search.isNotEmpty) search,
  ].join(' AND ');
}

PublicationEdition? archiveGutenbergEdition(String id, Object? data) {
  if (!_identifier.hasMatch(id) ||
      data is! Map ||
      data['metadata'] is! Map ||
      data['files'] is! List) {
    return null;
  }
  final metadata = data['metadata'] as Map;
  // The archive's Gutenberg ingestion account and independently recorded
  // rights are both required. Collection membership alone can be misleading.
  if (metadata['identifier'] != id ||
      metadata['mediatype'] != 'texts' ||
      metadata['contributor'] != 'Project Gutenberg' ||
      metadata['uploader'] != 'ximm@archive.org' ||
      !_strings(metadata['collection']).contains('gutenberg') ||
      metadata['rights'] != 'Public domain in the USA.' ||
      _restricted(metadata['access-restricted-item']) ||
      _restricted(metadata['is_dark']) ||
      _restricted(data['is_dark']) ||
      _strings(metadata['collection']).any(
        const {'inlibrary', 'printdisabled', 'loggedin', 'no-preview'}.contains,
      )) {
    return null;
  }
  final title = publicationLabel(metadata['title']);
  if (title.isEmpty) return null;
  final page = Uri.https('archive.org', '/details/$id');
  final candidates = <AcquisitionCandidate>[];
  for (final row in data['files'] as List) {
    if (row is! Map ||
        row['source'] != 'original' ||
        row['format'] != 'EPUB' ||
        _restricted(row['private'])) {
      continue;
    }
    final name = row['name'];
    final bytes = int.tryParse(row['size'].toString());
    if (name is! String ||
        !_fileName.hasMatch(name) ||
        bytes == null ||
        bytes <= 0 ||
        bytes > PublicationFormat.epub.maxBytes) {
      continue;
    }
    candidates.add(
      AcquisitionCandidate(
        source: archiveGutenbergSource,
        link: Uri(
          scheme: 'https',
          host: 'archive.org',
          pathSegments: ['download', id, name],
        ),
        page: page,
        format: PublicationFormat.epub,
        bytes: bytes,
      ),
    );
  }
  if (candidates.isEmpty) return null;
  final isbns = _archiveIsbns(metadata['isbn']);
  return PublicationEdition(
    id: publicationId('archive-gutenberg:$id'),
    title: title,
    author: _strings(
      metadata['creator'],
    ).map(publicationLabel).where((s) => s.isNotEmpty).take(4).join('、'),
    isbn: isbns.firstOrNull ?? '',
    alternateIsbns: isbns.skip(1).toList(),
    language: _strings(metadata['language']).firstOrNull ?? '',
    publisher: publicationLabel(_strings(metadata['publisher']).firstOrNull),
    tags: _strings(
      metadata['subject'],
    ).map(publicationLabel).where((value) => value.isNotEmpty).take(5).toList(),
    license: 'Project Gutenberg · 美国公版',
    page: page,
    candidates: candidates,
  );
}

List<String> _archiveIsbns(Object? value) => _strings(value)
    .take(12)
    .map(normalizedIsbn)
    .where((isbn) => isbn.isNotEmpty)
    .toSet()
    .toList();

List<String> _strings(Object? value) => value is String
    ? [value]
    : value is List
    ? value.whereType<String>().toList()
    : const [];

bool _restricted(Object? value) =>
    value != null &&
    value != false &&
    value != 0 &&
    value != '0' &&
    value != 'false';

void restrictArchivePublicationFile(Uri url, String id, String file) {
  final parts = url.pathSegments;
  if (url.scheme == 'https' &&
      url.port == 443 &&
      !url.hasQuery &&
      url.userInfo.isEmpty &&
      !url.hasFragment) {
    if (url.host == 'archive.org' &&
        parts.length == 3 &&
        parts[0] == 'download' &&
        parts[1] == id &&
        parts[2] == file) {
      return;
    }
    if (archivePublicationStorageHost(url.host) &&
        parts.length == 4 &&
        _shard.hasMatch(parts[0]) &&
        parts[1] == 'items' &&
        parts[2] == id &&
        parts[3] == file) {
      return;
    }
  }
  throw const PublicationFailure(PublicationProblem.unsupported);
}
