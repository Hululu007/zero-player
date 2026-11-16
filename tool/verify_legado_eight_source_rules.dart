// Offline comparison of current imported rules to the redacted historical evidence.
// Does not access websites, execute Legado jobs, or read user data.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

const _evidence = 'docs/implementation/legado-eight-source-pilot-20261116.json';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';

void require(bool value, String reason) {
  if (!value) throw FormatException(reason);
}

String hash(List<int> value) => sha256.convert(value).toString();
String textHash(String value) => hash(utf8.encode(value));

({List rows, Map<String, BookSource> selected}) loadCatalog() {
  final manifest =
      jsonDecode(
            File(
              'assets/catalogs/books/legado/manifest.json',
            ).readAsStringSync(),
          )
          as Map;
  final archive = File(_archive).readAsBytesSync();
  require(
    hash(archive) == _archiveSha && manifest['archiveSha256'] == _archiveSha,
    'archive digest mismatch',
  );
  final catalog =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
  final rows = catalog['records'] as List;
  final packs = catalog['packs'] as Map;
  final referenced = <Object?>[];
  for (final pack in (manifest['packs'] as List).cast<Map>()) {
    final indices = (packs[pack['id']] as List).cast<int>();
    require(indices.length == pack['count'], 'archive pack count mismatch');
    referenced.addAll(indices.map((index) => rows[index]));
  }
  final parsed = parseBookSourceRecords(referenced);
  require(parsed.sources.length == 2139, 'imported source count changed');
  return (
    rows: rows,
    selected: {for (final source in parsed.sources) source.id: source},
  );
}

void verify(Map draft, List rows, Map<String, BookSource> sources) {
  final records = (draft['sources'] as List).cast<Map>();
  require(
    records.length == 8 && records.map((x) => x['id']).toSet().length == 8,
    'draft source count changed',
  );
  for (final record in records) {
    final id = record['id'] as String;
    final index = record['index'] as int;
    require(index >= 0 && index < rows.length, 'record index out of range');
    final selected = sources[id];
    require(selected != null, 'selected source missing');
    final expected = parseBookSourceRecord(rows[index]);
    final source = selected!;
    require(
      expected.id == id &&
          source.endpoint.host == record['host'] &&
          source.kind.name == record['kind'] &&
          source.format.name == record['format'] &&
          textHash(source.endpoint.toString()) == record['endpoint_sha256'] &&
          source.legado != null &&
          expected.legado != null &&
          legadoSourceFingerprint(source.legado!) ==
              record['historical_legado_canonical_sha256'] &&
          legadoSourceFingerprint(expected.legado!) ==
              legadoSourceFingerprint(source.legado!),
      'selected source identity or normalized rule changed',
    );
    final sampled = record['sampled_rules'] as Map;
    final rules = sampled['rules_sha256'] as Map;
    require(
      textHash(source.legado!.search) == sampled['search_sha256'] &&
          rules.length == source.legado!.rules.length &&
          source.legado!.rules.entries.every(
            (entry) => rules[entry.key] == textHash(entry.value),
          ),
      'sampled rule field digest changed',
    );
  }
}

void testTampering(Map draft, List rows, Map<String, BookSource> sources) {
  void rejected(void Function(Map) mutate) {
    final copy = jsonDecode(jsonEncode(draft)) as Map;
    mutate(copy);
    var failed = false;
    try {
      verify(copy, rows, sources);
    } on FormatException {
      failed = true;
    }
    require(failed, 'rule verifier accepted tampered draft');
  }

  rejected((d) => d['sources'][0]['id'] = '0' * 64);
  rejected((d) => d['sources'][0]['index'] = 0);
  rejected((d) => d['sources'][0]['host'] = 'example.invalid');
  rejected(
    (d) => d['sources'][0]['historical_legado_canonical_sha256'] = '0' * 64,
  );
  rejected((d) => d['sources'][0]['sampled_rules']['search_sha256'] = '0' * 64);
  rejected(
    (d) => d['sources'][0]['sampled_rules']['rules_sha256']['searchList'] =
        '0' * 64,
  );
}

void main(List<String> args) {
  final draft = jsonDecode(File(_evidence).readAsStringSync()) as Map;
  final catalog = loadCatalog();
  verify(draft, catalog.rows, catalog.selected);
  if (args.contains('--self-test')) {
    testTampering(draft, catalog.rows, catalog.selected);
  }
  stdout.writeln(
    jsonEncode({
      'source_count': 8,
      'current_imported_rules_match_recorded': true,
      'network_requested': false,
      'historical_webpages_replayed': false,
      'historical_runtime_completely_reconstructed': false,
      'self_test': args.contains('--self-test'),
    }),
  );
}
