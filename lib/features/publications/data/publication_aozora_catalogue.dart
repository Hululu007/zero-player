import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const aozoraPublicationSource = 'aozora-bunko';
const _host = 'www.aozora.gr.jp';
final aozoraCataloguePage = Uri.https(_host, '/index_pages/person_all.html');
final aozoraCatalogueEndpoint = Uri.https(
  _host,
  '/index_pages/list_person_all_extended_utf8.zip',
);
final _card = RegExp(r'^/cards/\d{6}/card\d{1,6}\.html$');
const _indexAsset = 'assets/catalogs/books/aozora-index.json.gz';

final class AozoraCatalogue implements PublicationCatalogue {
  const AozoraCatalogue(this.http);
  final PublicationHttp http;
  static Future<List<PublicationEdition>>? _index;

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(aozoraCatalogueEndpoint);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  @override
  Future<void> check(CancellationToken token) async {
    await _books(token);
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
    final books = await _books(token);
    return searchPublicationIndex(
      books,
      query,
      token,
      limit: 20 * maxPages.clamp(1, 5),
      allowed: allowed,
      filter: filter,
    );
  }
}

Future<List<PublicationEdition>> _load() async {
  final data = await rootBundle.load(_indexAsset);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return Isolate.run(() => _decode(bytes));
}

List<PublicationEdition> _decode(List<int> bytes) {
  final rows = jsonDecode(utf8.decode(gzip.decode(bytes)));
  if (rows is! List || rows.isEmpty || rows.length > 30000) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return [
    for (final row in rows)
      if (row case [
        String path,
        String title,
        String subtitle,
        String author,
        String translator,
      ] when _card.hasMatch(path) && title.isNotEmpty)
        PublicationEdition(
          id: publicationId('$aozoraPublicationSource\n$path'),
          title: publicationLabel(title),
          edition: publicationLabel(subtitle),
          author: publicationLabel(author),
          translator: publicationLabel(translator),
          language: 'ja',
          publisher: '青空文庫',
          page: Uri.https(_host, path),
        ),
  ];
}
