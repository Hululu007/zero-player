// Offline association and historical-version regression for the later round.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

import 'book_source_ledger_com_rdap.dart' as audit;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();
Map read(String path) => jsonDecode(File(path).readAsStringSync()) as Map;

void main() {
  final evidencePath = 'docs/implementation/${audit.topLaterEvidenceFile}';
  final earlierPath = 'docs/implementation/${audit.topCcEvidenceFile}';
  final evidence = read(evidencePath);
  final earlier = read(earlierPath);
  final archivePath = 'assets/catalogs/books/legado/catalog.json.bz2';
  final archiveBytes = File(archivePath).readAsBytesSync();
  final records =
      (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archiveBytes)))
              as Map)['records']
          as List;
  final hashes = <String, String>{
    evidencePath: hash(File(evidencePath).readAsBytesSync()),
    earlierPath: hash(File(earlierPath).readAsBytesSync()),
    (evidence['latest_head_evidence'] as Map)['path'] as String: hash(
      File(
        (evidence['latest_head_evidence'] as Map)['path'] as String,
      ).readAsBytesSync(),
    ),
  };
  for (final ref in (earlier['input_references'] as Map).values) {
    if (ref is Map && ref['commit'] == null && ref['path'] is String) {
      final path = ref['path'] as String;
      hashes[path] = hash(File(path).readAsBytesSync());
    }
  }
  final linked = audit.readTopLaterEvidence(evidence, earlier, hashes, records);
  final expected = <int, (int, bool)>{
    950: (10, true),
    3062: (6, true),
    1646: (10, false),
    3551: (6, false),
  };
  for (final item in expected.entries) {
    final source = parseBookSourceRecord(records[item.key]);
    final rows = audit.selectComRdapEvidence(linked, source, item.key);
    check(rows.length == item.value.$1, 'missing observations for ${item.key}');
    check(
      rows.every(
        (row) =>
            row['matches_current_selected_raw_record'] == true &&
            row['matches_current_full_endpoint'] == true &&
            row['matches_current_normalized_legado_rule'] == true &&
            row['site_security_verified'] == null &&
            row['permanent_failure_verified'] == null,
      ),
      'historical identity or scope differs for ${item.key}',
    );
    final scope = rows.singleWhere(
      (row) => row['observation_kind'] == 'historical_review_scope',
    );
    check(
      scope['separate_cross_period_review_candidate'] == item.value.$2,
      'review eligibility differs for ${item.key}',
    );
    if (item.value.$2) {
      check(knownUnavailableBookRule(source), 'old source must be unavailable');
    }
    if (item.key == 1646) {
      final failures = rows.where(
        (row) => row['classification'] == 'provider_timeout',
      );
      check(
        failures.length == 3 &&
            failures.every(
              (row) => row['dns_rcode'] == null && row['http_status'] == null,
            ),
        'timeouts were not preserved as unknown',
      );
    }
    if (item.key == 3551) {
      check(
        rows.any((row) => row['classification'] == 'matching_domain_object'),
        'registered-object counterexample missing',
      );
    }
  }
  for (final index in [950, 3062]) {
    final source = parseBookSourceRecord(records[index]);
    final moved = BookSource.fromJson({
      ...source.toJson(),
      'url': source.endpoint
          .replace(
            host: source.endpoint.host.startsWith('www.')
                ? source.endpoint.host.substring(4)
                : 'www.${source.endpoint.host}',
          )
          .toString(),
    });
    check(moved.id == source.id, 'host variant must retain the ID');
    check(
      audit.selectComRdapEvidence(linked, moved, index).isEmpty,
      'evidence crossed to another exact host',
    );
    final changed = BookSource.fromJson({
      ...source.toJson(),
      'legado': {...source.legado!.toJson(), 'search': '/revised?q={{key}}'},
    });
    final oldRows = audit.selectComRdapEvidence(linked, changed, index);
    check(
      oldRows.isNotEmpty &&
          oldRows.every(
            (row) => row['matches_current_normalized_legado_rule'] == false,
          ),
      'old rule evidence became current after a revision',
    );
    check(!knownUnavailableBookRule(changed), 'a revised rule was blocked');
    final otherId = BookSource.fromJson({
      ...source.toJson(),
      'sourceKey': 'fixture:independent',
    });
    check(
      audit.selectComRdapEvidence(linked, otherId, index).isEmpty,
      'evidence crossed to another ID',
    );
    check(
      audit
          .selectComRdapEvidence(linked, source, index + 1)
          .every((row) => row['matches_current_selected_raw_record'] == false),
      'a different record index became the current sample',
    );
  }
  stdout.writeln('later .top ledger associations verified for four sources');
}
