// Offline regression for five domains and skipped-control semantics.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_com_rdap.dart' as audit;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();
Map read(String path) => jsonDecode(File(path).readAsStringSync()) as Map;

final class Fixture {
  Fixture()
    : evidence = read('docs/implementation/${audit.rdapFiveEvidenceFile}'),
      prior = read('docs/implementation/legado-doh-reviewed-20261115.json'),
      rows =
          (jsonDecode(
                    utf8.decode(
                      BZip2Decoder().decodeBytes(
                        File(
                          'assets/catalogs/books/legado/catalog.json.bz2',
                        ).readAsBytesSync(),
                      ),
                    ),
                  )
                  as Map)['records']
              as List {
    hashes['docs/implementation/${audit.rdapFiveEvidenceFile}'] = hash(
      File(
        'docs/implementation/${audit.rdapFiveEvidenceFile}',
      ).readAsBytesSync(),
    );
    final refs = evidence['input_references'] as Map;
    for (final key in [
      'catalog_archive',
      'catalog_manifest',
      'later_host_recheck',
      'older_host_recheck',
      'prior_public_doh',
    ]) {
      final path = (refs[key] as Map)['path'] as String;
      hashes[path] = hash(File(path).readAsBytesSync());
    }
  }
  final Map evidence, prior;
  final List rows;
  final hashes = <String, String>{};

  audit.ComRdapLedgerEvidence load([Map? value, List? records]) => audit
      .readRdapFiveEvidence(value ?? evidence, hashes, prior, records ?? rows);
}

void checkObservations(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final rdap = <String>{}, skips = <String>{}, timeouts = <String>{};
  final crossPeriod = <String>{};
  var sources = 0;
  for (final candidate
      in (fixture.evidence['candidates'] as List).cast<Map>()) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    for (final selected
        in (candidate['selected_sources'] as List).cast<Map>()) {
      sources++;
      final index = selected['selected_record_index'] as int;
      final source = parseBookSourceRecord(fixture.rows[index]);
      final rows = audit.selectComRdapEvidence(linked, source, index);
      check(
        source.id == selected['source_id'] &&
            source.endpoint.host == host &&
            rows.length == (domain == 'zri.moe' ? 23 : 19),
        'missing exact-source observations for $index',
      );
      check(
        rows.every(
          (row) =>
              row['matches_current_selected_raw_record'] == true &&
              row['matches_current_full_endpoint'] == true &&
              row['site_security_verified'] == null,
        ),
        'source identity or security scope changed',
      );
      final scope = rows.singleWhere(
        (row) => row['observation_kind'] == 'historical_review_scope',
      );
      check(
        scope['strictly_eligible_in_this_study'] == false,
        'strict review incorrectly eligible',
      );
      if (scope['separate_cross_period_review_candidate'] == true) {
        check(domain == 'zri.moe', 'cross-period decision crossed domains');
        crossPeriod.add(source.id);
      }
      for (final row in rows) {
        if (row['observation_kind'] ==
            'official_rdap_registered_domain_context') {
          check(
            row['registry_domain'] == domain &&
                row['host_relation'] == 'registered_domain_context',
            'RDAP registry domain mistaken for exact host',
          );
          rdap.add('$domain:${row['round']}');
        }
        if (row['classification'] == 'not_attempted_control_failed') {
          check(
            row['controls_passed'] == false &&
                row['query_performed'] == false &&
                row['dns_rcode'] == null &&
                row['http_status'] == null,
            'failed-control skip became a DNS answer',
          );
          skips.add(
            '$domain:${row['round']}:${row['queried_host']}:${row['provider']}:${row['query_type']}',
          );
        }
        if (row['classification'] == 'provider_timeout') {
          check(
            row['controls_passed'] == true &&
                row['query_performed'] == true &&
                row['dns_rcode'] == null &&
                row['http_status'] == null,
            'candidate timeout became a DNS answer',
          );
          timeouts.add(
            '$domain:${row['round']}:${row['queried_host']}:${row['provider']}:${row['query_type']}',
          );
        }
      }
    }
  }
  final expectedCrossPeriod =
      (fixture.evidence['summary']['cross_period_zri_review_source_ids']
              as List)
          .cast<String>()
          .toSet();
  check(
    sources == 10 &&
        rdap.length == 10 &&
        skips.length == 20 &&
        timeouts.length == 1 &&
        crossPeriod.length == 4 &&
        crossPeriod.containsAll(expectedCrossPeriod),
    '5-domain/10-source/round/skip/timeout/cross-period counts changed',
  );
}

void checkVariants(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final source = parseBookSourceRecord(fixture.rows[4681]);
  check(
    audit
        .selectComRdapEvidence(linked, source, 4682)
        .every((row) => row['matches_current_selected_raw_record'] == false),
    'historical record index promoted to a different selection',
  );
  final collision = parseBookSourceRecord(fixture.rows[396]);
  final moved = BookSource.fromJson({
    ...collision.toJson(),
    'url': 'https://cwj18.org/',
  });
  check(
    moved.id == collision.id &&
        audit.selectComRdapEvidence(linked, moved, 396).isEmpty,
    'historical results crossed exact source hosts',
  );
  final otherId = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'fixture:other-id',
  });
  check(
    otherId.id != source.id &&
        audit.selectComRdapEvidence(linked, otherId, 4681).isEmpty,
    'same host incorrectly associated another source ID',
  );
  final changed = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/changed-search'},
  });
  check(
    changed.id == source.id &&
        audit
            .selectComRdapEvidence(linked, changed, 4681)
            .every(
              (row) => row['matches_current_normalized_legado_rule'] == false,
            ),
    'historical rule falsely marked current',
  );
}

void checkTampering(Fixture fixture) {
  void rejects(void Function(Map) alter, String label) {
    final changed = jsonDecode(jsonEncode(fixture.evidence)) as Map;
    alter(changed);
    var failed = false;
    try {
      fixture.load(changed);
    } on FormatException {
      failed = true;
    }
    check(failed, label);
  }

  rejects(
    (d) => d['candidates'][0]['old_source_host'] = 'other.example',
    'changed host accepted',
  );
  rejects(
    (d) => d['candidates'][0]['selected_sources'][0]['source_id'] = '0' * 64,
    'changed ID accepted',
  );
  rejects(
    (d) =>
        d['candidates'][0]['selected_sources'][0]['normalized_legado_sha256'] =
            '0' * 64,
    'changed rule accepted',
  );
  rejects(
    (d) => d['input_references']['source_ledger_historical_git']['sha256'] =
        '0' * 64,
    'changed ledger accepted',
  );
  rejects(
    (d) => d['rounds'][0]['skipped'].removeAt(0),
    'missing skip accepted',
  );
  rejects(
    (d) => d['rounds'][0]['skipped'][0]['reason'] = 'nxdomain',
    'skip changed to NXDOMAIN',
  );
  rejects(
    (d) => d['summary']['strictly_eligible_domains'].add('zri.moe'),
    'strict eligibility invented',
  );
  rejects(
    (d) => d['summary']['cross_period_zri_review_source_ids'].removeAt(0),
    'cross-period review scope changed',
  );
  final records = [...fixture.rows];
  records[4681] = {...records[4681] as Map, 'bookSourceName': 'changed'};
  var failed = false;
  try {
    fixture.load(null, records);
  } on FormatException {
    failed = true;
  }
  check(failed, 'changed archived source accepted');
}

void checkFullReplay() {
  final root = Directory.systemTemp.createTempSync('zero-player-ledger-five-');
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
          (source) => (source['registry_and_doh_observations'] as List)
              .cast<Map>()
              .any((row) => row['evidence'] == audit.rdapFiveEvidenceFile),
        )
        .toList();
    check(
      linked.length == 10,
      'five-domain evidence must attach to exactly ten IDs',
    );
    final skipped = <String>{}, timeouts = <String>{}, crossPeriod = <String>{};
    for (final source in linked) {
      for (final row
          in (source['registry_and_doh_observations'] as List).cast<Map>()) {
        if (row['evidence'] != audit.rdapFiveEvidenceFile) continue;
        if (row['separate_cross_period_review_candidate'] == true) {
          crossPeriod.add(source['source_id'] as String);
        }
        final key =
            '${source['endpoint_host']}:${row['round']}:${row['queried_host']}:${row['provider']}:${row['query_type']}';
        if (row['classification'] == 'not_attempted_control_failed') {
          skipped.add(key);
        }
        if (row['classification'] == 'provider_timeout') timeouts.add(key);
      }
    }
    check(
      skipped.length == 20 && timeouts.length == 1 && crossPeriod.length == 4,
      'full ledger changed skipped/timeout/cross-period observations',
    );
    check(
      (ledger['input_sha256']
                  as Map)['docs/implementation/${audit.rdapFiveEvidenceFile}'] ==
              audit.rdapFiveEvidenceSha &&
          (ledger['rdap_five_historical_ledger_reference']
                  as Map)['verified_from_git_object'] ==
              true &&
          (ledger['normalized_source_code_sha256'] as Map).containsKey(
            'lib/features/books/domain/moe_rdap_legacy_quarantine.dart',
          ) &&
          (ledger['normalized_source_code_sha256'] as Map).containsKey(
            'tool/book_source_ledger_rdap_five.dart',
          ),
      'five-domain evidence, historical Git object or policy code reference missing',
    );
  } finally {
    if (output.existsSync()) output.deleteSync();
    root.deleteSync();
  }
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkObservations(fixture, linked);
  checkVariants(fixture, linked);
  checkTampering(fixture);
  checkFullReplay();
  stdout.writeln(
    'five-domain ledger evidence association offline checks passed',
  );
}
