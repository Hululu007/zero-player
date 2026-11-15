// Offline regression for nine-domain source associations and control gaps.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_com_rdap.dart' as audit;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map read(String path) => jsonDecode(File(path).readAsStringSync()) as Map;
String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture()
    : evidence = read('docs/implementation/${audit.rdapNineEvidenceFile}'),
      prior = read('docs/implementation/legado-doh-reviewed-20261115.json'),
      hostAudit = read('docs/implementation/legado-host-audit-20261115.json'),
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
    for (final entry in (evidence['input_references'] as Map).entries) {
      if (entry.key == 'source_ledger_historical_git') continue;
      final path = (entry.value as Map)['path'] as String;
      hashes[path] = hash(File(path).readAsBytesSync());
    }
  }
  final Map evidence, prior, hostAudit;
  final List rows;
  final hashes = <String, String>{};

  audit.ComRdapLedgerEvidence load([Map? altered]) =>
      audit.readRdapNineEvidence(
        altered ?? evidence,
        hashes,
        prior,
        rows,
        hostAudit,
      );
}

void checkAssociations(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final registered = <String>{};
  final unavailable = <String>{};
  final skipped = <String>{};
  final timeouts = <String>{};
  final oldTimeouts = <String>{};
  final oldServfails = <String>{};
  var sourceCount = 0;
  for (final candidate
      in (fixture.evidence['candidates'] as List).cast<Map>()) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    for (final selected
        in (candidate['selected_sources'] as List).cast<Map>()) {
      sourceCount++;
      final index = selected['selected_record_index'] as int;
      final source = parseBookSourceRecord(fixture.rows[index]);
      final rows = audit.selectComRdapEvidence(linked, source, index);
      final expectedLength = candidate['known_sibling_counterexample'] == true
          ? 23
          : 22;
      check(
        source.id == selected['source_id'] &&
            source.endpoint.host == host &&
            rows.length == expectedLength,
        'selected source identity or observation coverage changed',
      );
      check(
        rows.every(
          (row) =>
              row['matches_current_selected_raw_record'] == true &&
              row['matches_current_source_kind'] == true &&
              row['matches_current_full_endpoint'] == true &&
              row['matches_current_normalized_legado_rule'] == true &&
              row['site_security_verified'] == null,
        ),
        'historical source match or unknown safety state changed',
      );
      final rdap = rows
          .where(
            (row) =>
                row['observation_kind'] ==
                'official_rdap_registered_domain_context',
          )
          .toList();
      check(
        rdap.length == 2 &&
            rdap.every((row) => row['registry_domain'] == domain),
        'registered-domain RDAP observations missing',
      );
      if (rdap.every(
        (row) => row['classification'] == 'matching_domain_object',
      )) {
        registered.add(domain);
      } else if (rdap.every(
        (row) =>
            row['classification'] == 'http_404_empty_body' &&
            row['error_code'] == null,
      )) {
        unavailable.add(domain);
      } else {
        throw StateError('unexpected mixed RDAP observations for $domain');
      }
      final current = rows
          .where((row) => row['round'] is int && row['provider'] is String)
          .toList();
      check(current.length == 16, 'current DNS attempt/skip slot missing');
      for (final row in current) {
        final exact = row['host_relation'] == 'exact_endpoint_host';
        check(
          row['queried_host'] == (exact ? host : domain),
          'DNS host relationship changed',
        );
        final key =
            '$domain:${row['round']}:${row['queried_host']}:${row['provider']}:${row['query_type']}';
        if (row['classification'] == 'not_attempted_control_failed') {
          check(
            row['query_performed'] == false &&
                row['controls_passed'] == false &&
                row['http_status'] == null &&
                row['dns_rcode'] == null &&
                row['round'] == 1 &&
                row['provider'] == 'tencent' &&
                domain.endsWith('.com'),
            'skip misrepresented as DNS result',
          );
          skipped.add(key);
        } else if (row['classification'] == 'provider_timeout') {
          check(
            row['query_performed'] == true &&
                row['controls_passed'] == true &&
                row['http_status'] == null &&
                row['dns_rcode'] == null,
            'timeout not kept unknown',
          );
          timeouts.add(key);
        } else {
          check(
            row['query_performed'] == true && row['controls_passed'] == true,
            'completed DNS result lost control state',
          );
        }
      }
      final previous = rows
          .where(
            (row) =>
                row['observation_kind'] ==
                'previous_public_doh_exact_endpoint_host',
          )
          .toList();
      check(
        previous.length == 4 &&
            previous.every((row) => row['queried_host'] == host),
        'previous DNS result lost exact host',
      );
      for (final row in previous) {
        final key = '$host:${row['provider']}:${row['query_type']}';
        if (row['classification'] == 'servfail') {
          check(
            row['http_status'] == 200 && row['dns_rcode'] == 2,
            'SERVFAIL became another DNS state',
          );
          oldServfails.add(key);
        } else if (row['classification'] == 'provider_timeout') {
          check(
            row['http_status'] == null && row['dns_rcode'] == null,
            'old timeout became a DNS answer',
          );
          oldTimeouts.add(key);
        }
      }
    }
  }
  check(
    sourceCount == 12 &&
        registered.length == 6 &&
        unavailable.length == 3 &&
        skipped.length == 32 &&
        timeouts.length == 4 &&
        oldServfails.length == 4 &&
        oldTimeouts.length == 7,
    'registered/404/skip/timeout/SERVFAIL accounting changed',
  );
}

void checkBoundaries(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final old = parseBookSourceRecord(fixture.rows[969]);
  final historicalVariant = parseBookSourceRecord(fixture.rows[2924]);
  check(
    old.id == historicalVariant.id &&
        old.endpoint == historicalVariant.endpoint,
    'fixture must contain a same-ID historical rule variant',
  );
  final variantRows = audit.selectComRdapEvidence(
    linked,
    historicalVariant,
    2924,
  );
  check(
    variantRows.isNotEmpty &&
        variantRows.every(
          (row) =>
              row['matches_current_selected_raw_record'] == false &&
              row['matches_current_normalized_legado_rule'] == false,
        ),
    'old source evidence must not describe a different selected rule',
  );
  final changedEndpoint = BookSource.fromJson({
    ...old.toJson(),
    'url': 'https://www.xichubao.com/',
  });
  final changedRows = audit.selectComRdapEvidence(linked, changedEndpoint, 969);
  check(
    changedEndpoint.id == old.id &&
        changedRows.isNotEmpty &&
        changedRows.every(
          (row) => row['matches_current_full_endpoint'] == false,
        ),
    'endpoint trailing slash difference must remain visible',
  );
  final otherHost = BookSource.fromJson({
    ...old.toJson(),
    'url': 'https://xichubao.com',
  });
  check(
    otherHost.id == old.id &&
        audit.selectComRdapEvidence(linked, otherHost, 969).isEmpty,
    'same-ID old-host observation crossed hosts',
  );
  final otherId = BookSource.fromJson({
    ...old.toJson(),
    'sourceKey': 'independent-xichu',
  });
  check(
    otherId.id != old.id &&
        audit.selectComRdapEvidence(linked, otherId, 969).isEmpty,
    'same host observation crossed independent source IDs',
  );
  final net = parseBookSourceRecord(fixture.rows[1752]);
  final netRows = audit.selectComRdapEvidence(linked, net, 1752);
  check(
    netRows.isNotEmpty &&
        !netRows.any(
          (row) => row['classification'] == 'not_attempted_control_failed',
        ),
    '.net queries must not inherit the failed .com Tencent control',
  );
}

void checkSibling(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final source = parseBookSourceRecord(fixture.rows[1640]);
  final sibling = audit
      .selectComRdapEvidence(linked, source, 1640)
      .where((row) => row['host_relation'] == 'same_registered_domain_sibling')
      .toList();
  check(
    sibling.length == 1 &&
        sibling.single['queried_host'] == 'www.bulasw.com' &&
        sibling.single['http_status'] == 301 &&
        sibling.single['redirect_category'] == 'other_host' &&
        sibling.single['redirect_followed'] == false &&
        sibling.single['old_source_host_availability_inferred'] == null &&
        sibling.single['site_security_verified'] == null,
    'sibling 301 scope or non-follow state changed',
  );
}

void checkTampering(Fixture fixture) {
  Map copy() => jsonDecode(jsonEncode(fixture.evidence)) as Map;
  void rejects(void Function(Map) modify, String reason) {
    final changed = copy();
    modify(changed);
    var rejected = false;
    try {
      fixture.load(changed);
    } on FormatException {
      rejected = true;
    }
    check(rejected, reason);
  }

  rejects(
    (data) => data['input_references']['catalog_archive']['sha256'] = '0' * 64,
    'archive tampering accepted',
  );
  rejects(
    (data) =>
        data['input_references']['source_ledger_historical_git']['sha256'] =
            '0' * 64,
    'Git object tampering accepted',
  );
  rejects(
    (data) =>
        data['candidates'][0]['selected_sources'][0]['source_id'] = '0' * 64,
    'source ID tampering accepted',
  );
  rejects(
    (data) =>
        data['candidates'][0]['selected_sources'][0]['normalized_legado_sha256'] =
            '0' * 64,
    'rule digest tampering accepted',
  );
  rejects(
    (data) =>
        data['candidates'][0]['selected_sources'][0]['static_policy_snapshot']['fixed_unavailable_rule'] =
            true,
    'policy snapshot tampering accepted',
  );
  rejects(
    (data) => data['candidates'][0]['old_source_host'] = 'wrong.aoyekanshu.com',
    'old source host tampering accepted',
  );
  rejects(
    (data) => data['candidates'][0]['previous_public_doh'][0]['dns_rcode'] = 0,
    'previous DNS tampering accepted',
  );
  rejects(
    (data) => data['rounds'][0]['control_status']['com']['tencent'] = true,
    '.com control falsification accepted',
  );
  rejects(
    (data) => data['rounds'][0]['control_status']['net']['tencent'] = false,
    '.net control falsification accepted',
  );
  rejects(
    (data) => data['rounds'][0]['skipped'][0]['reason'] = 'provider_timeout',
    'skip mislabeled as timeout accepted',
  );
  rejects(
    (data) => data['known_sibling_counterexamples'][0]['http_status'] = 200,
    'sibling HTTP tampering accepted',
  );
  rejects(
    (data) => data['known_sibling_counterexamples'][0]['followed'] = true,
    'followed sibling redirect accepted',
  );
  rejects(
    (data) => data['known_sibling_counterexamples'][0]['redirect_host'] =
        'wrong.example.com',
    'sibling redirect target tampering accepted',
  );
  rejects(
    _omitSkipWithAdjustedSummaries,
    'missing skipped query was not detected',
  );
  rejects(
    _omitNetAttemptWithAdjustedSummaries,
    'missing .net attempted query was not detected',
  );
}

void _omitSkipWithAdjustedSummaries(Map data) {
  final round = data['rounds'][0] as Map;
  (round['skipped'] as List).removeWhere(
    (row) =>
        row['host'] == 'aoyekanshu.com' &&
        row['provider'] == 'tencent' &&
        row['query_type'] == 'A',
  );
  data['summary']['candidate_requests_skipped_due_to_control']--;
  final candidate = (data['candidates'] as List).cast<Map>().singleWhere(
    (row) => row['registry_domain'] == 'aoyekanshu.com',
  );
  candidate['current_summary']['skipped_due_to_control']--;
}

void _omitNetAttemptWithAdjustedSummaries(Map data) {
  final round = data['rounds'][0] as Map;
  (round['observations'] as List).removeWhere(
    (row) =>
        row['host'] == 'uu234.net' &&
        row['provider'] == 'aliyun' &&
        row['query_type'] == 'A',
  );
  round['scheduled']--;
  round['classification_counts']['noerror_no_address']--;
  data['summary']['candidate_requests_attempted']--;
  data['summary']['total_requests_attempted']--;
  data['summary']['doh_observations']--;
  final candidate = (data['candidates'] as List).cast<Map>().singleWhere(
    (row) => row['registry_domain'] == 'uu234.net',
  );
  candidate['current_summary']['dns_classification_counts']['uu234.net']['noerror_no_address']--;
}

void checkFullReplay() {
  final root = Directory.systemTemp.createTempSync('zero-player-ledger-nine-');
  final output = File('${root.path}/ledger.json');
  try {
    final process = Process.runSync(Platform.resolvedExecutable, [
      'tool/audit_book_source_ledger.dart',
      output.path,
    ], workingDirectory: Directory.current.path);
    check(
      process.exitCode == 0,
      'offline ledger generation failed: ${process.stderr}',
    );
    final document = jsonDecode(output.readAsStringSync()) as Map;
    final rows = (document['sources'] as List).cast<Map>();
    final associated = rows
        .where(
          (row) => (row['registry_and_doh_observations'] as List)
              .cast<Map>()
              .any((item) => item['evidence'] == audit.rdapNineEvidenceFile),
        )
        .toList();
    check(
      rows.length == 2139 &&
          associated.length == 12 &&
          (document['overlapping_summary']
                  as Map)['sources_with_rdap_nine_observations'] ==
              12,
      'nine-domain evidence must associate exactly 12 selected sources',
    );
    final reference = document['rdap_nine_historical_ledger_reference'] as Map;
    check(
      reference['commit'] == 'df798cc773dd09722214cdced6eded5a2d2431ea' &&
          reference['verified_from_git_object'] == true,
      'historical Git ledger reference not verified',
    );
    final code = document['normalized_source_code_sha256'] as Map;
    check(
      code.containsKey('tool/book_source_ledger_rdap_nine.dart'),
      'adapter digest missing',
    );
    final runtime =
        document['runtime_policy_reference_only_normalized_sha256'] as Map;
    for (final path in [
      'lib/features/books/data/book_store.dart',
      'lib/features/books/data/book_repository_request_policy.dart',
      'lib/features/books/data/book_request_guard.dart',
    ]) {
      check(
        runtime.containsKey(path),
        'runtime-only background digest missing: $path',
      );
    }
  } finally {
    if (output.existsSync()) output.deleteSync();
    root.deleteSync();
  }
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkAssociations(fixture, linked);
  checkBoundaries(fixture, linked);
  checkSibling(fixture, linked);
  checkTampering(fixture);
  checkFullReplay();
  stdout.writeln('nine-domain ledger offline checks passed');
}
