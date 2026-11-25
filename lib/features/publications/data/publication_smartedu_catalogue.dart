import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

const smartEduPublicationSource = 'panda-smartedu';
final smartEduHome = Uri.https('basic.smartedu.cn', '/');
final _id = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
final _coverPath = RegExp(
  r'^/edu_product/esp/(?:assets|thematic_course)/.+\.(?:jpe?g|png|webp)$',
);
final _coverVersion = RegExp(r'^v=[0-9]{1,16}$');
const _coverHosts = {
  'r1-ndr.ykt.cbern.com.cn',
  'r2-ndr.ykt.cbern.com.cn',
  'r3-ndr.ykt.cbern.com.cn',
};

final class SmartEduCatalogue implements PublicationCatalogue {
  SmartEduCatalogue(this.http);

  final PublicationHttp http;
  Future<List<PublicationEdition>>? _index;

  Future<List<PublicationEdition>> _books(CancellationToken token) async {
    token.check();
    http.authorize(smartEduHome);
    final books = await (_index ??= _load());
    token.check();
    return books;
  }

  Future<List<PublicationEdition>> _load() async {
    final data = await rootBundle.load(
      'assets/catalogs/books/panda-smartedu.json.gz',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return Isolate.run(
      () => parseSmartEduCatalogue(utf8.decode(gzip.decode(bytes))),
    );
  }

  @override
  Future<void> check(CancellationToken token) async {
    if ((await _books(token)).isEmpty) {
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
    if (filter?.field == PublicationSearchField.author ||
        filter?.field == PublicationSearchField.isbn) {
      return const [];
    }
    final books = await _books(token);
    return books
        .where(
          (book) => book.matches(query, filter: filter) && allowed(book.title),
        )
        .take((maxPages * 20).clamp(20, 60))
        .toList();
  }
}

List<PublicationEdition> parseSmartEduCatalogue(String body) {
  final data = jsonDecode(body);
  if (data is! List || data.length > 10000) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final books = <String, PublicationEdition>{};
  for (final row in data) {
    if (row
        case {
          'id': final String id,
          'type': final String type,
          'title': final String label,
        }
        when _id.hasMatch(id) &&
            const {'assets_document', 'thematic_course'}.contains(type)) {
      final title = publicationLabel(label);
      if (title.isEmpty) continue;
      final page = smartEduHome
          .resolve('tchMaterial/detail')
          .replace(
            queryParameters: {
              'contentType': type,
              'contentId': id,
              'catalogType': 'tchMaterial',
              'subCatalog': 'tchMaterial',
            },
          );
      final tags = row['tags'];
      books[id] = PublicationEdition(
        id: publicationId('$smartEduPublicationSource\n$id'),
        title: title,
        edition: publicationLabel(row['edition']),
        language: 'zh',
        tags: tags is List
            ? tags
                  .map(publicationLabel)
                  .where((item) => item.isNotEmpty)
                  .toList()
            : const [],
        page: page,
        cover: publicationCoverUrl(
          page,
          row['cover'],
          (uri) =>
              _coverHosts.contains(uri.host) &&
              _coverPath.hasMatch(uri.path) &&
              (!uri.hasQuery || _coverVersion.hasMatch(uri.query)),
        ),
      );
    }
  }
  return books.values.toList();
}
