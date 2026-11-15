import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/supervision/domain/adult_source_evidence.dart';

const evidencePath = 'docs/implementation/legado-two-chain-pilot-20261116.json';
const archivePath = 'assets/catalogs/books/legado/catalog.json.bz2';
const manifestPath = 'assets/catalogs/books/legado/manifest.json';

void require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

String hash(List<int> input) => sha256.convert(input).toString();
String textHash(String input) => hash(utf8.encode(input));

Map<String, BookSource> selectedSources(Map data) {
  final archive = File(archivePath).readAsBytesSync();
  final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map;
  final expectedFiles = data['source_file_sha256_at_initial'] as Map;
  require(
    hash(archive) == manifest['archiveSha256'],
    'archive/manifest mismatch',
  );
  require(
    hash(archive) == expectedFiles[archivePath],
    'archive/evidence mismatch',
  );
  require(
    hash(File(manifestPath).readAsBytesSync()) == expectedFiles[manifestPath],
    'manifest/evidence mismatch',
  );
  final catalog =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
  final rows = catalog['records'] as List;
  final packs = catalog['packs'] as Map;
  final inputs = <Object?>[];
  for (final pack in manifest['packs'] as List) {
    final indices = (packs[pack['id']] as List).cast<int>();
    require(indices.length == pack['count'], 'pack length mismatch');
    inputs.addAll(indices.map((index) => rows[index]));
  }
  final wanted = (data['sources'] as List).map((row) => row['id']).toSet();
  final imported = parseBookSourceRecords(inputs).sources;
  final selected = {
    for (final source in imported)
      if (wanted.contains(source.id)) source.id: source,
  };
  require(selected.length == wanted.length, 'source no longer selected');
  for (final record in data['sources'] as List) {
    final source = selected[record['id']]!;
    final raw = parseBookSourceRecord(
      rows[record['raw_selected_index'] as int],
    );
    require(raw.id == source.id, 'selected source index changed');
    require(
      jsonEncode(raw.legado?.toJson()) == jsonEncode(source.legado?.toJson()),
      'selected source version changed',
    );
  }
  return selected;
}

void verifyRules(Map evidence, BookSource actual) {
  final legado = actual.legado!;
  final rules = evidence['rules'] as Map;
  final hashes = evidence['rule_sha256'] as Map;
  require(evidence['name'] == actual.name, 'source name mismatch');
  require(evidence['host'] == actual.endpoint.host, 'source host mismatch');
  require(evidence['search'] == legado.search, 'search rule mismatch');
  require(
    textHash(legado.search) == evidence['search_rule_sha256'],
    'search hash mismatch',
  );
  require(
    rules.length == legado.rules.length && hashes.length == rules.length,
    'rule count mismatch',
  );
  for (final entry in legado.rules.entries) {
    require(rules[entry.key] == entry.value, 'rule mismatch: ${entry.key}');
    require(
      hashes[entry.key] == textHash(entry.value),
      'rule hash mismatch: ${entry.key}',
    );
  }
}

void verifyObservations(Map data, Map<String, BookSource> sources) {
  final events = data['observations'] as List;
  require(events.length == 12, 'observation count mismatch');
  for (var index = 0; index < events.length; index++) {
    final event = events[index] as Map;
    require(event['observation_id'] == index + 1, 'observation id mismatch');
    final source = sources[event['source_id']];
    require(
      source != null && event['host'] == source.endpoint.host,
      'unknown event source',
    );
    final uri = Uri.parse(event['uri'] as String);
    require(
      uri.scheme == 'https' &&
          uri.port == 443 &&
          uri.host == source!.endpoint.host &&
          uri.userInfo.isEmpty &&
          !uri.hasFragment,
      'unsafe event URI',
    );
    require(
      event['method'] == 'GET' && event['http_status'] == 200,
      'event method/status mismatch',
    );
    final cap = event['byte_cap'] as int;
    final length = event['sample_bytes'] as int;
    require(
      (cap == 524288 || cap == 2097152) && length > 0 && length <= cap,
      'invalid length',
    );
    if (event['truncated'] == true) {
      require(
        length == cap &&
            event['sample_sha256'] == null &&
            event['failure'] == 'over_limit_no_parse',
        'invalid truncated observation',
      );
    } else {
      final digest = event['sample_sha256'] as String;
      require(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) && event['failure'] == null,
        'invalid complete observation',
      );
    }
  }
  final exact = events
      .where((event) => event['phase'] == 'exact_empty_query')
      .toList();
  require(
    exact.length == 2 &&
        exact.every(
          (event) =>
              Uri.parse(event['uri'] as String).hasQuery &&
              Uri.parse(event['uri'] as String).query.isEmpty,
        ),
    'empty-query samples missing',
  );
  final truncated = events
      .where((event) => event['truncated'] == true)
      .toList();
  require(
    truncated.length == 2 &&
        truncated.map((event) => event['byte_cap']).toSet().containsAll([
          524288,
          2097152,
        ]),
    'oversized samples missing',
  );
}

void main(List<String> args) {
  stdout.encoding = utf8;
  require(args.length <= 1, 'expected at most one evidence path');
  final bytes = File(
    args.isEmpty ? evidencePath : args.single,
  ).readAsBytesSync();
  final evidence = jsonDecode(utf8.decode(bytes)) as Map;
  require(evidence['schema_version'] == 1, 'unsupported evidence schema');
  final selected = selectedSources(evidence);
  final currentPolicy = <Map<String, Object?>>[];
  for (final record in evidence['sources'] as List) {
    final source = selected[record['id']]!;
    verifyRules(record as Map, source);
    final adult =
        adultBookSource(source) ||
        knownAdultHost(source.endpoint.host) ||
        source.mediaHosts.any(
          (host) => adultBookHost(host) || knownAdultHost(host),
        );
    final quarantine = quarantinedBookSource(source);
    final observed = record['static_policy'] as Map;
    currentPolicy.add({
      'id': source.id,
      'adult': adult,
      'quarantined': quarantine,
      'matches_observation':
          adult == observed['adult'] && quarantine == observed['quarantined'],
    });
  }
  verifyObservations(evidence, selected);
  stdout.writeln(
    jsonEncode({
      'evidence_sha256': hash(bytes),
      'selected_source_count': selected.length,
      'observation_count': (evidence['observations'] as List).length,
      'normalized_rule_hashes_verified': true,
      'current_static_policy': currentPolicy,
      'historical_response_bodies_recomputed': false,
    }),
  );
}
