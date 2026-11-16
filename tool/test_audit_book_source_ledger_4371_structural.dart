// Pure Dart offline attribution, scope and tampering regressions.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_4371_structural.dart' as audit;

const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _evidence = 'docs/implementation/${audit.structural4371EvidenceFile}';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();
Map copy(Map value) => jsonDecode(jsonEncode(value)) as Map;

final class OfflineOnly extends IOOverrides {
  @override
  File createFile(String path) {
    if (p
        .split(p.normalize(path))
        .any((part) => part.toLowerCase() == 'build')) {
      throw StateError('build must not be an evidence input');
    }
    return super.createFile(path);
  }
}

final class Fixture {
  Fixture() {
    final archive = File(_archive).readAsBytesSync();
    final evidenceBytes = File(_evidence).readAsBytesSync();
    hashes = {
      _archive: hash(archive),
      _inventory: hash(File(_inventory).readAsBytesSync()),
      _evidence: hash(evidenceBytes),
    };
    evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
    records =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  late final Map evidence;
  late final List records;
  late final Map<String, String> hashes;

  audit.Structural4371Evidence load({
    Map? value,
    List? archive,
    Map<String, String>? digests,
  }) => audit.readStructural4371Evidence(
    value ?? evidence,
    digests ?? hashes,
    archive ?? records,
  );
}

Map row(Fixture f, audit.Structural4371Evidence evidence) => audit
    .selectStructural4371Evidence(
      evidence,
      parseBookSourceRecord(f.records[4371]),
      4371,
    )
    .single;

void checkFacts(Fixture f, audit.Structural4371Evidence evidence) {
  final result = row(f, evidence);
  final samples = (result['observations'] as List).cast<Map>();
  final method = result['method'] as Map;
  final interpretation = result['interpretation'] as Map;
  check(
    result['historical_selected_record_index'] == 4371 &&
        result['matches_current_selected_raw_record'] == true &&
        result['matches_current_full_endpoint'] == true &&
        result['matches_current_normalized_legado_rule'] == true &&
        result['matches_current_source_configuration'] == true &&
        result['site_security_verified'] == null &&
        result['site_malware_verified'] == null &&
        result['sitewide_adult_verified'] == null &&
        result['whole_source_unavailable_verified'] == null &&
        result['whole_source_readability_verified'] == null &&
        result['network_authenticity_verified_offline'] == false &&
        result['raw_pages_and_collector_replayable'] == false,
    'historical source identity or evidence boundary differs',
  );
  check(
    samples.length == 6 &&
        samples[0]['stage'] == 'old_search' &&
        samples[1]['stage'] == 'old_search' &&
        samples[0]['no_results_placeholder_count'] == 1 &&
        samples[1]['no_results_placeholder_count'] == 1 &&
        samples[0]['items_with_anchor_and_bold'] == 0 &&
        samples[1]['items_with_anchor_and_bold'] == 0 &&
        samples[2]['old_table_rows'] == 50 &&
        samples[3]['same_host_toc_candidate'] == true &&
        samples[4]['same_host_safe_chapter_candidates'] == 19 &&
        samples[5]['old_content_nodes'] == 1 &&
        samples[5]['visible_characters'] == 2056,
    'structural observations differ',
  );
  check(
    method['synthetic_keywords_distinct'] == true &&
        method['page_or_source_scripts_executed'] == false &&
        method['capture_requests_fetched_subresources'] == false &&
        method['overall_wall_deadline_enforced'] == false &&
        method['dns_validator'] ==
            'Python ipaddress.is_global; no independent multicast exclusion' &&
        interpretation['application_parser_executed'] == false &&
        interpretation['safe_candidates_are_collector_path_predicate_only'] ==
            true &&
        interpretation['one_chapter_does_not_prove_full_reading'] == true &&
        (result['limitations'] as List).any(
          (text) =>
              text is String &&
              text.contains('separate same-host script request'),
        ),
    'sample scope or outside-request limitation differs',
  );
}

void checkVariants(Fixture f, audit.Structural4371Evidence evidence) {
  final source = parseBookSourceRecord(f.records[4371]);
  final updated = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/other-search'},
  });
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://${source.endpoint.host}/different-entry',
  });
  final differentId = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'other-source',
  });
  final differentHost = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://other.example/',
  });
  check(
    updated.id == source.id && moved.id == source.id,
    'invalid variant fixture',
  );
  final changed = audit
      .selectStructural4371Evidence(evidence, updated, 4371)
      .single;
  final relocated = audit
      .selectStructural4371Evidence(evidence, moved, 4371)
      .single;
  check(
    changed['matches_current_normalized_legado_rule'] == false &&
        changed['matches_current_source_configuration'] == false &&
        relocated['matches_current_full_endpoint'] == false &&
        relocated['matches_current_source_configuration'] == false,
    'historical source observation mislabeled as current configuration',
  );
  check(
    audit.selectStructural4371Evidence(evidence, source, 4370).isEmpty &&
        audit
            .selectStructural4371Evidence(evidence, differentId, 4371)
            .isEmpty &&
        audit
            .selectStructural4371Evidence(evidence, differentHost, 4371)
            .isEmpty,
    'different ID, host or index inherited historical evidence',
  );
}

void checkTampering(Fixture f) {
  void rejected(void Function(Map) mutate, String message) {
    final candidate = copy(f.evidence);
    mutate(candidate);
    var caught = false;
    try {
      f.load(value: candidate);
    } on FormatException {
      caught = true;
    }
    check(caught, message);
  }

  rejected((x) => x['source']['source_id'] = '0' * 64, 'changed ID accepted');
  rejected(
    (x) => x['source']['endpoint_host'] = 'other.example',
    'changed host accepted',
  );
  rejected(
    (x) => x['source']['selected_record_index'] = 4370,
    'changed index accepted',
  );
  rejected(
    (x) => x['source']['normalized_legado_sha256'] = '0' * 64,
    'changed rule accepted',
  );
  rejected(
    (x) => x['observations'][0]['no_results_placeholder_count'] = 0,
    'changed search accepted',
  );
  rejected(
    (x) => x['observations'][5]['visible_characters'] = 0,
    'changed chapter accepted',
  );
  rejected(
    (x) => x['observations'][5]['body'] = 'private data',
    'body accepted',
  );
  rejected(
    (x) => x['interpretation']['site_security_verified'] = true,
    'safety verdict accepted',
  );
  rejected(
    (x) => x['method']['page_or_source_scripts_executed'] = true,
    'script execution accepted',
  );
  for (final path in [_archive, _inventory, _evidence]) {
    var caught = false;
    try {
      f.load(digests: {...f.hashes, path: '0' * 64});
    } on FormatException {
      caught = true;
    }
    check(caught, 'altered input hash accepted: $path');
  }
  final altered = [...f.records];
  altered[4371] = {...altered[4371] as Map, 'bookSourceName': 'changed'};
  var caught = false;
  try {
    f.load(archive: altered);
  } on FormatException {
    caught = true;
  }
  check(caught, 'altered original archive record accepted');
}

void checkSnapshotIsolation(Fixture f, audit.Structural4371Evidence evidence) {
  final before = row(f, evidence);
  (before['observations'] as List).clear();
  (before['method'] as Map)['page_or_source_scripts_executed'] = true;
  final after = row(f, evidence);
  check(
    (after['observations'] as List).length == 6 &&
        (after['method'] as Map)['page_or_source_scripts_executed'] == false,
    'caller mutated retained evidence',
  );
}

void main() => HttpOverrides.runZoned(
  () => IOOverrides.runWithIOOverrides(() {
    final fixture = Fixture();
    final evidence = fixture.load();
    checkFacts(fixture, evidence);
    checkVariants(fixture, evidence);
    checkTampering(fixture);
    checkSnapshotIsolation(fixture, evidence);
    stdout.writeln('#4371 selected structural evidence offline checks passed');
  }, OfflineOnly()),
  createHttpClient: (_) => throw StateError('network is forbidden'),
);
