// Offline source/version association regression; never executes source rules.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_sfwx.dart' as audit;

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture()
    : archive = File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytesSync(),
      evidenceBytes = File(
        'docs/implementation/${audit.sfwxEvidenceFile}',
      ).readAsBytesSync() {
    evidence = jsonDecode(utf8.decode(evidenceBytes)) as Map;
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  final List<int> archive, evidenceBytes;
  late final Map evidence;
  late final List rows;

  audit.SfwxLedgerEvidence load([
    Map? value,
    List? records,
    Map<String, String>? inputHashes,
  ]) => audit.readSfwxEvidence(
    value ?? evidence,
    inputHashes ??
        {
          'assets/catalogs/books/legado/catalog.json.bz2': hash(archive),
          'docs/implementation/${audit.sfwxEvidenceFile}': hash(evidenceBytes),
        },
    records ?? rows,
  );
}

void checkSourceSamples(Fixture fixture, audit.SfwxLedgerEvidence linked) {
  for (final index in [4760, 3002, 2578]) {
    final source = parseBookSourceRecord(fixture.rows[index]);
    final observations = audit.selectSfwxEvidence(linked, source, index);
    check(
      observations.length == 1,
      'selected source $index lacks its single observation',
    );
    final row = observations.single;
    check(
      row['historical_selected_record_index'] == index &&
          row['matches_current_selected_raw_record'] == true &&
          row['matches_current_full_endpoint'] == true &&
          row['site_security_verified'] == null &&
          row['full_readability_verified'] == null &&
          row['whole_source_unavailable_verified'] == null &&
          row['scripts_executed'] == false &&
          row['redirects_followed'] == false,
      'source $index identity or sampling boundaries changed',
    );
    final samples = row['samples'] as Map;
    if (index == 4760) {
      check(
        row['matches_current_normalized_legado_rule'] == false,
        'the repaired sfwx rule must differ from its historical sample',
      );
      final a = samples['work_a'] as Map;
      final b = samples['work_b'] as Map;
      check(
        (a['chapters'] as List).length == 2 &&
            (b['chapters'] as List).length == 1 &&
            (a['detail_and_toc'] as Map)['old_details'].toString().startsWith(
              'FormatException:',
            ) &&
            (a['detail_and_toc'] as Map)['candidate_title_and_author_match'] ==
                true &&
            ((samples['category_recheck']
                    as Map)['production_selector_evaluated_separately_on_saved_live_sample']) ==
                false,
        'two-work and three-chapter limits or old/candidate comparison lost',
      );
    } else if (index == 3002) {
      check(
        (samples['search'] as Map)['books'] == 30 &&
            (samples['toc'] as Map)['chapters'] == 120 &&
            (samples['chapter'] as Map)['status'] == 200,
        'bounded reading sample missing',
      );
    } else {
      check(
        (samples['search'] as Map)['status'] == 404 &&
            samples['detail_toc_content'] == 'not_requested',
        'single search 404 or unrequested stages misstated',
      );
    }
  }
}

void checkVariants(Fixture fixture, audit.SfwxLedgerEvidence linked) {
  final source = parseBookSourceRecord(fixture.rows[3002]);
  check(
    audit
            .selectSfwxEvidence(linked, source, 3003)
            .single['matches_current_selected_raw_record'] ==
        false,
    'same-ID historical selection must not be promoted to current index',
  );
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://${source.endpoint.host.replaceFirst('www.', '')}/',
  });
  check(
    moved.id == source.id &&
        audit.selectSfwxEvidence(linked, moved, 3002).isEmpty,
    'same ID must not carry observations to another host',
  );
  final otherId = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'fixture:other-id',
  });
  check(
    otherId.id != source.id &&
        audit.selectSfwxEvidence(linked, otherId, 3002).isEmpty,
    'same host must not attach another source ID',
  );
  final changedPath = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://${source.endpoint.host}/changed',
  });
  check(
    changedPath.id == source.id &&
        audit
                .selectSfwxEvidence(linked, changedPath, 3002)
                .single['matches_current_full_endpoint'] ==
            false,
    'changed endpoint must remain visibly distinct',
  );
  final updated = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/different-search'},
  });
  check(
    updated.id == source.id &&
        audit
                .selectSfwxEvidence(linked, updated, 3002)
                .single['matches_current_normalized_legado_rule'] ==
            false,
    'changed rule must remain historical',
  );
}

void checkTampering(Fixture fixture) {
  void rejects(void Function(Map) mutate, String reason) {
    final copy = jsonDecode(jsonEncode(fixture.evidence)) as Map;
    mutate(copy);
    var rejected = false;
    try {
      fixture.load(copy);
    } on FormatException {
      rejected = true;
    }
    check(rejected, reason);
  }

  rejects(
    (e) => e['sources'][0]['endpoint_host'] = 'other.example',
    'changed host accepted',
  );
  rejects(
    (e) => e['sources'][0]['source_id'] = '0' * 64,
    'changed ID accepted',
  );
  rejects(
    (e) => e['sources'][0]['record_index'] = 1,
    'changed selected index accepted',
  );
  rejects(
    (e) => e['sources'][0]['historical_legado_sha256'] = '0' * 64,
    'changed historical rule accepted',
  );
  rejects(
    (e) => e['inputs']['historical_ledger_sha256'] = '0' * 64,
    'changed Git digest accepted',
  );
  rejects(
    (e) => e['observations']['record_2578']['search']['status'] = 200,
    'altered sample accepted',
  );
  final rows = [...fixture.rows];
  rows[4760] = {...rows[4760] as Map, 'bookSourceName': 'changed'};
  var rejected = false;
  try {
    fixture.load(null, rows);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'changed historical raw record accepted');
}

void checkFullReplay() {
  final root = Directory.systemTemp.createTempSync('zero-player-ledger-sfwx-');
  final output = File('${root.path}/ledger.json');
  try {
    final run = Process.runSync(Platform.resolvedExecutable, [
      'tool/audit_book_source_ledger.dart',
      output.path,
    ]);
    check(run.exitCode == 0, 'offline ledger generation failed: ${run.stderr}');
    final ledger = jsonDecode(output.readAsStringSync()) as Map;
    final rows = (ledger['sources'] as List).cast<Map>();
    final linked = rows
        .where(
          (source) => (source['specialized_reading_observations'] as List)
              .cast<Map>()
              .any((row) => row['evidence'] == audit.sfwxEvidenceFile),
        )
        .toList();
    check(
      linked.length == 3,
      'historical sample must attach to exactly three sources',
    );
    final repaired = linked.singleWhere(
      (source) => source['selected_record_index'] == 4760,
    );
    final observation = (repaired['specialized_reading_observations'] as List)
        .cast<Map>()
        .singleWhere((row) => row['evidence'] == audit.sfwxEvidenceFile);
    check(
      observation['matches_current_normalized_legado_rule'] == false &&
          observation['site_security_verified'] == null &&
          observation['full_readability_verified'] == null,
      'repaired current rule or limited sample wrongly represented',
    );
    check(
      (ledger['input_sha256']
                  as Map)['docs/implementation/${audit.sfwxEvidenceFile}'] ==
              audit.sfwxEvidenceSha &&
          (ledger['sfwx_historical_ledger_reference']
                  as Map)['verified_from_git_object'] ==
              true,
      'ledger must retain the evidence and historical references',
    );
    final code = ledger['normalized_source_code_sha256'] as Map;
    final runtime =
        ledger['runtime_policy_reference_only_normalized_sha256'] as Map;
    check(
      code.containsKey('tool/book_source_ledger_sfwx.dart') &&
          code.containsKey('tool/verify_legado_sfwx_repair.py') &&
          code.containsKey(
            'lib/features/books/domain/sfwx_legacy_source_fix.dart',
          ) &&
          runtime.containsKey(
            'lib/features/books/application/book_category_policy.dart',
          ) &&
          runtime.containsKey(
            'lib/features/books/data/book_site_script_clues.dart',
          ),
      'ledger code or runtime background references missing',
    );
  } finally {
    if (output.existsSync()) output.deleteSync();
    root.deleteSync();
  }
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkSourceSamples(fixture, linked);
  checkVariants(fixture, linked);
  checkTampering(fixture);
  checkFullReplay();
  stdout.writeln('sfwx source evidence association offline checks passed');
}
