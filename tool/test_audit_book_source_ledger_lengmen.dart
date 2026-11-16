// Offline association regression for one shared, bounded homepage study.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_lengmen.dart' as audit;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> value) => sha256.convert(value).toString();

final class Fixture {
  Fixture()
    : archive = File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytesSync(),
      bytes = File(
        'docs/implementation/${audit.lengmenEvidenceFile}',
      ).readAsBytesSync() {
    evidence = jsonDecode(utf8.decode(bytes)) as Map;
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  final List<int> archive, bytes;
  late final Map evidence;
  late final List rows;
  audit.LengmenLedgerEvidence load([Map? value, List? records]) =>
      audit.readLengmenEvidence(value ?? evidence, {
        'assets/catalogs/books/legado/catalog.json.bz2': hash(archive),
        'docs/implementation/${audit.lengmenEvidenceFile}': hash(bytes),
      }, records ?? rows);
}

void checkSourceAssociations(
  Fixture fixture,
  audit.LengmenLedgerEvidence linked,
) {
  for (final index in [450, 1921]) {
    final source = parseBookSourceRecord(fixture.rows[index]);
    final observations = audit.selectLengmenEvidence(linked, source, index);
    check(
      source.endpoint.host == 'www.lengmen.org' && observations.length == 1,
      'historical sample does not match exact selected source $index',
    );
    final row = observations.single;
    check(
      row['matches_current_selected_raw_record'] == true &&
          row['matches_current_full_endpoint'] == true &&
          row['matches_current_normalized_legado_rule'] == true &&
          row['same_host_observations_shared_by_two_sources'] == true &&
          row['independent_threat_count'] == null &&
          row['malware_verified'] == null &&
          row['false_positive_verified'] == null &&
          row['site_security_verified'] == null,
      'historical match or non-verdict boundaries changed',
    );
    final requests = row['requests'] as List;
    final controls = (row['controls'] as List).cast<Map>();
    check(
      requests.length == 6 &&
          (requests.first as Map)['http_status'] == 302 &&
          (requests.first as Map)['redirect_target'] ==
              'unknown_not_captured' &&
          controls.length == 3 &&
          controls.every(
            (c) =>
                (c['eicar_raw'] as Map)['classification'] == 'detected' &&
                (c['eicar_in_html'] as Map)['classification'] ==
                    'not_detected' &&
                (c['eicar_in_script'] as Map)['classification'] ==
                    'not_detected',
          ),
      'unknown 302 target or limited engine controls changed',
    );
    final compare = requests.last as Map;
    final comparisons = (compare['comparisons'] as List).cast<Map>();
    check(
      compare['same_byte_length_for_all_variants'] == true &&
          comparisons.length == 4 &&
          (comparisons[0]['amsi'] as Map)['classification'] == 'detected' &&
          (comparisons[1]['amsi'] as Map)['classification'] == 'detected' &&
          (comparisons[2]['amsi'] as Map)['classification'] == 'not_detected' &&
          (comparisons[3]['amsi'] as Map)['classification'] == 'not_detected',
      'bounded byte substitution results changed',
    );
    final serialized = jsonEncode(row);
    check(
      !serialized.contains('https://') && !serialized.contains('<script'),
      'observation leaked an URL or script',
    );
  }
}

void checkVariants(Fixture fixture, audit.LengmenLedgerEvidence linked) {
  final source = parseBookSourceRecord(fixture.rows[450]);
  check(
    audit
            .selectLengmenEvidence(linked, source, 2318)
            .single['matches_current_selected_raw_record'] ==
        false,
    'other selected index treated as historical index',
  );
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://lengmen.org/',
  });
  check(
    moved.id == source.id &&
        audit.selectLengmenEvidence(linked, moved, 450).isEmpty,
    'same source ID must not move host observations',
  );
  final otherId = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'fixture:other',
  });
  check(
    otherId.id != source.id &&
        audit.selectLengmenEvidence(linked, otherId, 450).isEmpty,
    'same host must not associate another source ID',
  );
  final changed = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/changed-search'},
  });
  check(
    changed.id == source.id &&
        audit
                .selectLengmenEvidence(linked, changed, 450)
                .single['matches_current_normalized_legado_rule'] ==
            false,
    'different rule incorrectly reported as historical rule',
  );
}

void checkTampering(Fixture fixture) {
  void rejects(void Function(Map) alter, String reason) {
    final copy = jsonDecode(jsonEncode(fixture.evidence)) as Map;
    alter(copy);
    var failed = false;
    try {
      fixture.load(copy);
    } on FormatException {
      failed = true;
    }
    check(failed, reason);
  }

  rejects((e) => e['host'] = 'other.example', 'changed host accepted');
  rejects(
    (e) => e['source_fingerprints'][0]['source_id'] = '0' * 64,
    'changed ID accepted',
  );
  rejects(
    (e) => e['source_fingerprints'][0]['selected_record_index'] = 2318,
    'changed index accepted',
  );
  rejects(
    (e) => e['source_fingerprints'][0]['normalized_legado_canonical_sha256'] =
        '0' * 64,
    'changed rule accepted',
  );
  rejects(
    (e) => e['inputs']['historical_files']['ledger']['sha256'] = '0' * 64,
    'changed Git reference accepted',
  );
  rejects(
    (e) => e['observations'][0]['redirect_target'] = 'same_host',
    'invented 302 target accepted',
  );
  rejects(
    (e) => e['controls'][0]['eicar_in_html']['classification'] = 'detected',
    'altered control accepted',
  );
  final rows = [...fixture.rows];
  rows[450] = {...rows[450] as Map, 'bookSourceName': 'changed'};
  var failed = false;
  try {
    fixture.load(null, rows);
  } on FormatException {
    failed = true;
  }
  check(failed, 'changed raw archive record accepted');
}

void checkFullReplay() {
  final root = Directory.systemTemp.createTempSync(
    'zero-player-ledger-lengmen-',
  );
  final output = File('${root.path}/ledger.json');
  try {
    final result = Process.runSync(Platform.resolvedExecutable, [
      'tool/audit_book_source_ledger.dart',
      output.path,
    ]);
    check(
      result.exitCode == 0,
      'offline ledger replay failed: ${result.stderr}',
    );
    final ledger = jsonDecode(output.readAsStringSync()) as Map;
    final sources = (ledger['sources'] as List).cast<Map>();
    final linked = sources
        .where(
          (row) => (row['historical_engine_followup_observations'] as List)
              .cast<Map>()
              .any(
                (observation) =>
                    observation['evidence'] == audit.lengmenEvidenceFile,
              ),
        )
        .toList();
    check(
      linked.length == 2 &&
          linked.every((row) => row['endpoint_host'] == 'www.lengmen.org'),
      'shared host study was not attached to exactly two sources',
    );
    check(
      (ledger['input_sha256']
                  as Map)['docs/implementation/${audit.lengmenEvidenceFile}'] ==
              audit.lengmenEvidenceSha &&
          (ledger['lengmen_historical_ledger_reference']
                  as Map)['verified_from_git_object'] ==
              true &&
          (ledger['normalized_source_code_sha256'] as Map).containsKey(
            'tool/book_source_ledger_lengmen.dart',
          ) &&
          (ledger['normalized_source_code_sha256'] as Map).containsKey(
            'tool/verify_legado_lengmen_recheck.py',
          ),
      'evidence, historical reference or code digest missing',
    );
  } finally {
    if (output.existsSync()) output.deleteSync();
    root.deleteSync();
  }
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkSourceAssociations(fixture, linked);
  checkVariants(fixture, linked);
  checkTampering(fixture);
  checkFullReplay();
  stdout.writeln('lengmen shared homepage evidence offline checks passed');
}
