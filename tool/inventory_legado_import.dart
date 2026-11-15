// Local-only audit of the bundled catalog using the application's import code.
// This does not run source rules or issue network requests.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/inventory_legado_import.dart OUTPUT');
    exitCode = 64;
    return;
  }
  const folder = 'assets/catalogs/books/legado';
  final manifest =
      jsonDecode(File('$folder/manifest.json').readAsStringSync()) as Map;
  final archive = File('$folder/catalog.json.bz2').readAsBytesSync();
  final digest = sha256.convert(archive).toString();
  if (digest != manifest['archiveSha256']) {
    throw const FormatException('catalog archive SHA-256 mismatch');
  }
  final data =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
  final rows = data['records'] as List;
  if (rows.length != manifest['records']) {
    throw const FormatException('catalog record count mismatch');
  }
  final rawResults = <Map<String, Object>>[];
  final rawIssues = <String, int>{};
  for (var index = 0; index < rows.length; index++) {
    try {
      final source = parseBookSourceRecord(rows[index]);
      rawResults.add({
        'index': index,
        'id': source.id,
        'name': source.name,
        'group': source.group,
        'kind': source.kind.name,
        'host': source.endpoint.host,
      });
    } on FormatException catch (error) {
      rawIssues.update(error.message, (count) => count + 1, ifAbsent: () => 1);
    } on Object {
      rawIssues.update('记录格式无效', (count) => count + 1, ifAbsent: () => 1);
    }
  }
  final combined = <Object?>[];
  final memberships = data['packs'] as Map;
  final packReferences = <String, List<int>>{};
  for (final pack in manifest['packs'] as List) {
    final references = memberships[pack['id']] as List;
    if (references.length != pack['count']) {
      throw const FormatException('catalog pack count mismatch');
    }
    for (final index in references.cast<int>()) {
      combined.add(rows[index]);
    }
    packReferences[pack['id'] as String] = references.cast<int>();
  }
  final actual = parseBookSourceRecords(combined);
  final result = {
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'archive_sha256': digest,
    'import_code_sha256': {
      for (final path in [
        'lib/features/books/data/book_import.dart',
        'lib/features/books/data/legado/legado_import.dart',
        'lib/features/books/domain/book.dart',
        'lib/features/books/domain/legado_source.dart',
      ])
        path: sha256.convert(File(path).readAsBytesSync()).toString(),
    },
    'raw_records': rows.length,
    'raw_parseable_records': rawResults.length,
    'raw_rejections': rawIssues,
    'pack_rows': combined.length,
    'pack_accepted_before_deduplication':
        actual.sources.length + actual.duplicates,
    'pack_unique_sources': actual.sources.length,
    'pack_duplicates': actual.duplicates,
    'pack_rejections': actual.issues,
    // Each element's array position is the index within that source pack.
    'pack_references': packReferences,
    'raw_parseable': rawResults,
    'selected_sources': [
      for (final source in actual.sources)
        {
          'id': source.id,
          'name': source.name,
          'group': source.group,
          'kind': source.kind.name,
          'host': source.endpoint.host,
        },
    ],
  };
  final file = File(args.single);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${jsonEncode(result)}\n');
  stdout.writeln(
    'raw ${rows.length}; individually parseable ${rawResults.length}; '
    'pack rows ${combined.length}; unique sources ${actual.sources.length}; '
    'duplicates ${actual.duplicates}; rejected ${actual.rejected}',
  );
  stdout.writeln('wrote ${file.path}');
}
