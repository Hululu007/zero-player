// Offline regression for exact source associations and eighteenth-domain data.
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
String hash(List<int> data) => sha256.convert(data).toString();

final class Fixture {
  Fixture()
    : evidence = read(
        'docs/implementation/${audit.comRdapEighteenEvidenceFile}',
      ),
      prior = read('docs/implementation/legado-doh-reviewed-20261115.json'),
      siblingInputs = {
        'dns_address_recheck': read(
          'docs/implementation/legado-dns-address-recheck-20261115.json',
        ),
        'host_audit': read(
          'docs/implementation/legado-host-audit-20261115.json',
        ),
        'amsi_other': read(
          'docs/implementation/legado-amsi-other-hosts-20261115.json',
        ),
      },
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
  final Map evidence, prior;
  final Map<String, Map> siblingInputs;
  final List rows;
  final hashes = <String, String>{};

  audit.ComRdapLedgerEvidence load([Map? altered]) =>
      audit.readComRdapEighteenEvidence(
        altered ?? evidence,
        hashes,
        prior,
        rows,
        siblingInputs,
      );
}

void checkAssociations(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final registered = <String>{};
  final unavailable = <String>{};
  final timeouts = <String>{};
  final skipped = <String>{};
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
      final observations = audit.selectComRdapEvidence(linked, source, index);
      final expectedLength = candidate['known_sibling_counterexample'] == true
          ? 24
          : 22;
      check(
        source.id == selected['source_id'] &&
            source.endpoint.host == host &&
            observations.length == expectedLength,
        'source identity or observation coverage changed',
      );
      check(
        observations.every(
          (row) =>
              row['matches_current_selected_raw_record'] == true &&
              row['matches_current_source_kind'] == true &&
              row['matches_current_full_endpoint'] == true &&
              row['matches_current_normalized_legado_rule'] == true &&
              row['site_security_verified'] == null,
        ),
        'historical match or safety state incorrect',
      );
      final rdap = observations
          .where(
            (row) =>
                row['observation_kind'] ==
                'official_rdap_registered_domain_context',
          )
          .toList();
      check(
        rdap.length == 2 &&
            rdap.every((row) => row['registry_domain'] == domain),
        'both registered-domain RDAP results must remain visible',
      );
      if (rdap.every(
        (row) => row['classification'] == 'matching_domain_object',
      )) {
        registered.add(domain);
      } else if (rdap.every(
        (row) =>
            row['classification'] == 'http_404_empty_body' &&
            row['http_status'] == 404 &&
            row['error_code'] == null,
      )) {
        unavailable.add(domain);
      } else {
        throw StateError('unexpected mixed registered/404 result for $domain');
      }
      final currentDoh = observations
          .where((row) => row['round'] is int && row['provider'] is String)
          .toList();
      check(currentDoh.length == 16, 'each source needs 16 attempt/skip slots');
      for (final row in currentDoh) {
        final exact = row['host_relation'] == 'exact_endpoint_host';
        check(
          row['queried_host'] == (exact ? host : domain),
          'registered domain and exact endpoint host must stay separate',
        );
        final key =
            '$domain:${row['round']}:${row['queried_host']}:${row['provider']}:${row['query_type']}';
        if (row['classification'] == 'not_attempted_control_failed') {
          check(
            row['query_performed'] == false &&
                row['controls_passed'] == false &&
                row['dns_rcode'] == null &&
                row['http_status'] == null &&
                row['round'] == 1 &&
                row['provider'] == 'tencent',
            'skipped request must remain unobserved',
          );
          skipped.add(key);
        } else if (row['classification'] == 'provider_timeout') {
          check(
            row['query_performed'] == true &&
                row['controls_passed'] == true &&
                row['dns_rcode'] == null &&
                row['http_status'] == null,
            'attempted timeout must remain unknown',
          );
          timeouts.add(key);
        } else {
          check(
            row['query_performed'] == true && row['controls_passed'] == true,
            'completed DNS result must retain control status',
          );
        }
      }
      final previous = observations
          .where(
            (row) =>
                row['observation_kind'] ==
                'previous_public_doh_exact_endpoint_host',
          )
          .toList();
      check(
        previous.length == 4 &&
            previous.every((row) => row['queried_host'] == host),
        'previous DoH samples must stay on the exact endpoint host',
      );
    }
  }
  check(
    sourceCount == 22 &&
        registered.length == 11 &&
        unavailable.length == 7 &&
        skipped.length == 72 &&
        timeouts.length == 6,
    'registered/404/skip/timeout accounting changed',
  );
}

void checkSiblings(Fixture fixture, audit.ComRdapLedgerEvidence linked) {
  final candidates = (fixture.evidence['candidates'] as List).cast<Map>();
  final expected = {
    'bgwxc.com': ('www.bgwxc.com', null),
    'bqg70.com': ('www.bqg70.com', 503),
    'motie.com': ('app2.motie.com', 403),
  };
  for (final entry in expected.entries) {
    final candidate = candidates.singleWhere(
      (row) => row['registry_domain'] == entry.key,
    );
    for (final selected
        in (candidate['selected_sources'] as List).cast<Map>()) {
      final index = selected['selected_record_index'] as int;
      final source = parseBookSourceRecord(fixture.rows[index]);
      final sibling = audit
          .selectComRdapEvidence(linked, source, index)
          .where(
            (row) => row['host_relation'] == 'same_registered_domain_sibling',
          )
          .toList();
      check(
        sibling.length == 2 &&
            sibling.every(
              (row) =>
                  row['queried_host'] == entry.value.$1 &&
                  row['site_security_verified'] == null &&
                  row['old_source_host_availability_inferred'] == null,
            ),
        'sibling scope lost',
      );
      if (entry.value.$2 == null) {
        check(
          sibling.every(
            (row) =>
                row['classification'] == 'public_address_observed' &&
                (row['dns_a_address_kinds'] as Map)['public'] == 1,
          ),
          'sibling DNS response missing',
        );
      } else {
        check(
          sibling.every((row) => row['http_status'] == entry.value.$2),
          'sibling HTTP 403/503 response missing',
        );
      }
    }
  }
}

void checkVersionBoundaries(
  Fixture fixture,
  audit.ComRdapLedgerEvidence linked,
) {
  final original = parseBookSourceRecord(fixture.rows[456]);
  final sibling = BookSource.fromJson({
    ...original.toJson(),
    'url': 'https://iswsk.com',
  });
  check(
    sibling.id == original.id &&
        audit.selectComRdapEvidence(linked, sibling, 456).isEmpty,
    'same source ID must not transfer old-host evidence to another host',
  );
  final otherId = BookSource.fromJson({
    ...original.toJson(),
    'sourceKey': 'independent-example',
  });
  check(
    otherId.id != original.id &&
        audit.selectComRdapEvidence(linked, otherId, 456).isEmpty,
    'same host must not transfer evidence to another source ID',
  );
  final revised = BookSource.fromJson({
    ...original.toJson(),
    'legado': {...original.legado!.toJson(), 'search': '/new?q={{key}}'},
  });
  final changed = audit.selectComRdapEvidence(linked, revised, 456);
  check(
    revised.id == original.id &&
        changed.isNotEmpty &&
        changed.every(
          (row) => row['matches_current_normalized_legado_rule'] == false,
        ),
    'same-ID updated rule must remain historical',
  );
  final moved = BookSource.fromJson({
    ...original.toJson(),
    'url': 'https://www.iswsk.com/other',
  });
  final movedRows = audit.selectComRdapEvidence(linked, moved, 456);
  check(
    moved.id == original.id &&
        movedRows.isNotEmpty &&
        movedRows.every((row) => row['matches_current_full_endpoint'] == false),
    'same-ID changed endpoint must remain historical',
  );
  check(
    audit
        .selectComRdapEvidence(linked, original, 457)
        .every((row) => row['matches_current_selected_raw_record'] == false),
    'changed selected index must remain historical',
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
    'historical ledger tampering accepted',
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
    (data) => data['candidates'][0]['old_source_host'] = 'wrong.778buy.com',
    'old host tampering accepted',
  );
  rejects(
    (data) => data['candidates'][0]['previous_doh'][0]['dns_rcode'] = 0,
    'previous DNS tampering accepted',
  );
  rejects(
    (data) => data['rounds'][0]['control_status']['com']['tencent'] = true,
    'failed control falsification accepted',
  );
  rejects(
    (data) => data['rounds'][0]['skipped'][0]['reason'] = 'provider_timeout',
    'skip mislabeled as timeout accepted',
  );
  rejects(
    (data) => data['rounds'][0]['skipped'][0]['mode'] = 'rdap',
    'skip with unrelated request mode accepted',
  );
  rejects(
    (data) =>
        data['known_sibling_counterexamples'][0]['observations'][0]['a'] = 9003,
    'sibling DNS tampering accepted',
  );
  rejects(
    (data) =>
        data['known_sibling_counterexamples'][1]['observations'][0]['http_status'] =
            200,
    'sibling HTTP tampering accepted',
  );
  rejects((data) {
    final samples =
        data['known_sibling_counterexamples'][1]['observations'] as List;
    samples[1] = jsonDecode(jsonEncode(samples[0]));
  }, 'missing distinct sibling GET observation was not detected');
  rejects(_omitSkipWithAdjustedSummaries, 'missing skip slot was not detected');
  rejects(
    _omitAttemptWithAdjustedSummaries,
    'missing attempted query slot was not detected',
  );
}

void _omitSkipWithAdjustedSummaries(Map data) {
  final round = data['rounds'][0] as Map;
  final skipped = round['skipped'] as List;
  skipped.removeWhere(
    (row) =>
        row['host'] == '778buy.com' &&
        row['provider'] == 'tencent' &&
        row['query_type'] == 'A',
  );
  data['summary']['candidate_requests_skipped_due_to_control']--;
  data['candidates'][0]['current_summary']['skipped_due_to_control']--;
}

void _omitAttemptWithAdjustedSummaries(Map data) {
  final round = data['rounds'][1] as Map;
  final observations = round['observations'] as List;
  observations.removeWhere(
    (row) =>
        row['host'] == 'xs.778buy.com' &&
        row['provider'] == 'aliyun' &&
        row['query_type'] == 'A',
  );
  round['scheduled']--;
  round['classification_counts']['nxdomain']--;
  data['summary']['candidate_requests_attempted']--;
  data['summary']['total_requests_attempted']--;
  data['summary']['doh_observations']--;
  data['candidates'][0]['current_summary']['dns_classification_counts']['xs.778buy.com']['nxdomain']--;
}

void checkFullReplay(Fixture fixture) {
  final root = Directory.systemTemp.createTempSync(
    'zero-player-ledger-eighteen-',
  );
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
    final attached = rows
        .where(
          (row) =>
              (row['registry_and_doh_observations'] as List).cast<Map>().any(
                (item) => item['evidence'] == audit.comRdapEighteenEvidenceFile,
              ),
        )
        .toList();
    check(
      rows.length == 2139 &&
          attached.length == 22 &&
          (document['overlapping_summary']
                  as Map)['sources_with_com_rdap_eighteen_observations'] ==
              22,
      'eighteen-domain evidence was not linked to exactly 22 selected IDs',
    );
    final refs =
        document['com_rdap_eighteen_historical_ledger_reference'] as Map;
    check(
      refs['commit'] == 'df798cc773dd09722214cdced6eded5a2d2431ea' &&
          refs['verified_from_git_object'] == true,
      'historical ledger was not verified',
    );
    check(
      (document['normalized_source_code_sha256'] as Map).containsKey(
        'tool/book_source_ledger_com_eighteen.dart',
      ),
      'adapter digest missing',
    );
    final evidencePath =
        'docs/implementation/${audit.comRdapEighteenEvidenceFile}';
    check(
      (document['input_sha256'] as Map)[evidencePath] ==
          hash(File(evidencePath).readAsBytesSync()),
      'formal evidence input digest missing',
    );
  } finally {
    if (output.existsSync()) output.deleteSync();
    root.deleteSync();
  }
}

void main() {
  final fixture = Fixture();
  final linked = fixture.load();
  checkAssociations(fixture, linked);
  checkSiblings(fixture, linked);
  checkVersionBoundaries(fixture, linked);
  checkTampering(fixture);
  checkFullReplay(fixture);
  stdout.writeln('eighteen-domain ledger offline checks passed');
}
