import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'audit_book_source_ledger.dart' as ledger;
import 'book_source_ledger_recovered_four.dart' as audit;

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

String hash(List<int> value) => sha256.convert(value).toString();

void main() {
  final archive = File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytesSync();
  final headBytes = File(
    'docs/implementation/${audit.later943EvidenceFile}',
  ).readAsBytesSync();
  final fourBytes = File(
    'docs/implementation/${audit.recoveredFourEvidenceFile}',
  ).readAsBytesSync();
  final priorBytes = File(
    'docs/implementation/legado-unresolved-head-later-20261116.json',
  ).readAsBytesSync();
  final priorAmsi = File(
    'docs/implementation/legado-recovered-amsi-20261116.json',
  ).readAsBytesSync();
  final rows =
      (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
              as Map)['records']
          as List;
  final head = jsonDecode(utf8.decode(headBytes)) as Map;
  final four = jsonDecode(utf8.decode(fourBytes)) as Map;
  final prior = jsonDecode(utf8.decode(priorBytes)) as Map;
  final hashes = <String, String>{
    'assets/catalogs/books/legado/catalog.json.bz2': hash(archive),
    'docs/implementation/${audit.later943EvidenceFile}': hash(headBytes),
    'docs/implementation/${audit.recoveredFourEvidenceFile}': hash(fourBytes),
    'docs/implementation/legado-unresolved-head-later-20261116.json': hash(
      priorBytes,
    ),
    'docs/implementation/legado-recovered-amsi-20261116.json': hash(priorAmsi),
  };
  audit.RecoveredFourLedgerEvidence load({
    Map? headValue,
    Map? fourValue,
    List? rawRows,
  }) => audit.readRecoveredFourEvidence(
    headValue ?? head,
    fourValue ?? four,
    prior,
    hashes,
    rawRows ?? rows,
    ledger.networkObservation,
    amsiObservation,
  );
  final linked = load();
  check(
    linked.network.length == 908 &&
        linked.registry.length == 908 &&
        linked.amsi.length == 4,
    'wrong selected-source evidence coverage',
  );
  for (final index in [1347, 4837, 3466, 4560]) {
    final source = parseBookSourceRecord(rows[index]);
    final network = audit.selectRecoveredFourEvidence(
      linked.network,
      source,
      index,
    );
    final amsi = audit
        .selectRecoveredFourEvidence(linked.amsi, source, index)
        .single;
    check(
      network.any((r) => r['method'] == 'HEAD' && r['http_status'] == 200) &&
          amsi['historical_selected_record_index'] == index &&
          amsi['site_security_verified'] == null,
      'recovered source missing its own observations',
    );
    check(
      amsi['root_scan_classification'] ==
          (index == 4837 ? 'not_scanned_or_unknown' : 'not_detected'),
      'failure or non-detection was misclassified',
    );
    check(
      audit.selectRecoveredFourEvidence(linked.amsi, source, index + 1).isEmpty,
      'other selected index inherited observations',
    );
    final other = BookSource.fromJson({
      ...source.toJson(),
      'sourceKey': 'fixture-other',
    });
    check(
      audit.selectRecoveredFourEvidence(linked.network, other, index).isEmpty,
      'other source ID inherited observations',
    );
  }
  final changed = jsonDecode(jsonEncode(four)) as Map;
  ((changed['amsi'] as Map)['results'] as List)[0]['selected_source_ids'] = [
    '0' * 64,
  ];
  var rejected = false;
  try {
    load(fourValue: changed);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'tampered observation accepted');
  final modifiedRows = [...rows];
  modifiedRows[3466] = {
    ...modifiedRows[3466] as Map,
    'bookSourceName': 'changed',
  };
  rejected = false;
  try {
    load(rawRows: modifiedRows);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'tampered archived record accepted');
  stdout.writeln(
    'later 943-host and recovered-four source association checks passed',
  );
}

Map<String, Object?> amsiObservation(String file, Map row) {
  final scan = row['amsi'];
  return {
    'evidence': file,
    'observed_at': row['sample_observed_at'],
    'root_scan_classification': scan is Map
        ? scan['classification']
        : 'not_scanned_or_unknown',
  };
}
