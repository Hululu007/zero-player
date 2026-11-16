// Offline regression for the registered-domain counterexample and source binding.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_rdap_org_yqxz.dart' as audit;

const archivePath = 'assets/catalogs/books/legado/catalog.json.bz2';
const index = 1483;

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

String hash(List<int> bytes) => sha256.convert(bytes).toString();

final class Fixture {
  Fixture() {
    final archive = File(archivePath).readAsBytesSync();
    final bytes = File(
      'docs/implementation/${audit.rdapOrgYqxzEvidenceFile}',
    ).readAsBytesSync();
    evidence = jsonDecode(utf8.decode(bytes)) as Map;
    hashes = {
      'docs/implementation/${audit.rdapOrgYqxzEvidenceFile}': hash(bytes),
    };
    for (final entry in (evidence['inputs'] as Map).entries) {
      if (entry.key == 'historical_ledger') continue;
      final path = (entry.value as Map)['path'] as String;
      hashes[path] = hash(File(path).readAsBytesSync());
    }
    rows =
        (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                as Map)['records']
            as List;
  }
  late final Map evidence;
  late final Map<String, String> hashes;
  late final List rows;

  audit.RdapOrgYqxzLedgerEvidence load({
    Map? value,
    List? records,
    Map<String, String>? digests,
  }) => audit.readRdapOrgYqxzEvidence(
    value ?? evidence,
    digests ?? hashes,
    records ?? rows,
  );
}

void checkResults(Fixture f, audit.RdapOrgYqxzLedgerEvidence evidence) {
  final source = parseBookSourceRecord(f.rows[index]);
  final rows = audit.selectRdapOrgYqxzEvidence(evidence, source, index);
  check(rows.length == 18, 'two complete observation rounds expected');
  check(
    rows.every(
      (row) =>
          row['matches_current_selected_raw_record'] == true &&
          row['matches_current_source_kind'] == true &&
          row['matches_current_source_format'] == true &&
          row['matches_current_full_endpoint'] == true &&
          row['site_security_verified'] == null &&
          row['source_readability_verified'] == null &&
          row['permanent_failure_verified'] == null,
    ),
    'historical-only source association changed',
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
        rdap.every(
          (row) =>
              row['http_status'] == 200 &&
              row['classification'] == 'matching_domain_object' &&
              row['rdap_object_matches'] == true &&
              row['host_relation'] == 'registered_domain_context',
        ),
    'registered-domain counterexample lost',
  );
  final apex = rows.where(
    (row) =>
        row['queried_host'] == 'yqxz.org' &&
        row['observation_kind'] == 'public_doh',
  );
  check(
    apex.length == 8 &&
        apex.every(
          (row) =>
              row['classification'] == 'noerror_no_address' &&
              row['dns_rcode'] == 0 &&
              row['host_relation'] == 'registered_domain_context',
        ),
    'apex DNS scope changed',
  );
  final old = rows
      .where((row) => row['queried_host'] == 'www.yqxz.org')
      .toList();
  check(
    old.length == 8 &&
        old.where((row) => row['classification'] == 'nxdomain').length == 7,
    'old host NXDOMAIN count changed',
  );
  final timeout = old.singleWhere(
    (row) => row['classification'] == 'provider_timeout',
  );
  check(
    timeout['round'] == 2 &&
        timeout['provider'] == 'tencent' &&
        timeout['query_type'] == 'A' &&
        timeout['http_status'] == null &&
        timeout['dns_rcode'] == null &&
        timeout['query_performed'] == true,
    'timeout became a DNS answer',
  );
}

void checkVariants(Fixture f, audit.RdapOrgYqxzLedgerEvidence evidence) {
  final source = parseBookSourceRecord(f.rows[index]);
  check(
    audit
            .selectRdapOrgYqxzEvidence(evidence, source, index)
            .first['matches_current_normalized_legado_rule'] ==
        true,
    'original rule did not match',
  );
  check(
    audit.selectRdapOrgYqxzEvidence(evidence, source, index - 1).isEmpty,
    'different selected record inherited evidence',
  );
  final custom = BookSource.fromJson({
    ...source.toJson(),
    'legado': {...source.legado!.toJson(), 'search': '/different-search'},
  });
  check(
    custom.id == source.id &&
        audit
            .selectRdapOrgYqxzEvidence(evidence, custom, index)
            .every(
              (row) => row['matches_current_normalized_legado_rule'] == false,
            ),
    'same-ID changed rule was treated as historical',
  );
  final moved = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://www.yqxz.org/changed',
  });
  check(
    moved.id == source.id &&
        audit
            .selectRdapOrgYqxzEvidence(evidence, moved, index)
            .every((row) => row['matches_current_full_endpoint'] == false),
    'same-ID changed endpoint was treated as historical',
  );
  final other = BookSource.fromJson({
    ...source.toJson(),
    'sourceKey': 'other-id',
  });
  final host = BookSource.fromJson({
    ...source.toJson(),
    'url': 'https://other.example/',
  });
  check(
    audit.selectRdapOrgYqxzEvidence(evidence, other, index).isEmpty &&
        audit.selectRdapOrgYqxzEvidence(evidence, host, index).isEmpty,
    'another source ID or host inherited evidence',
  );
}

void checkTampering(Fixture f) {
  void rejected(void Function(Map) change, String reason) {
    final copy = jsonDecode(jsonEncode(f.evidence)) as Map;
    change(copy);
    var caught = false;
    try {
      f.load(value: copy);
    } on FormatException {
      caught = true;
    }
    check(caught, reason);
  }

  rejected(
    (e) => e['candidate']['selected_source']['source_id'] = '0' * 64,
    'source ID changed',
  );
  rejected(
    (e) => e['candidate']['selected_source']['selected_record_index'] = 0,
    'source index changed',
  );
  rejected(
    (e) => e['candidate']['selected_source']['normalized_legado_sha256'] =
        '0' * 64,
    'old rule changed',
  );
  rejected(
    (e) => e['rounds'][0]['observations'][0]['http_status'] = 404,
    'registry response changed',
  );
  rejected(
    (e) => e['rounds'][1]['observations'].removeLast(),
    'DNS observation disappeared',
  );
  final records = [...f.rows];
  records[index] = {...records[index] as Map, 'bookSourceName': 'changed'};
  var rejectedRecord = false;
  try {
    f.load(records: records);
  } on FormatException {
    rejectedRecord = true;
  }
  check(rejectedRecord, 'changed archive record accepted');
  final bad = {
    ...f.hashes,
    'docs/implementation/${audit.rdapOrgYqxzEvidenceFile}': '0' * 64,
  };
  var rejectedHash = false;
  try {
    f.load(digests: bad);
  } on FormatException {
    rejectedHash = true;
  }
  check(rejectedHash, 'changed evidence digest accepted');
}

void main() {
  final f = Fixture();
  final evidence = f.load();
  checkResults(f, evidence);
  checkVariants(f, evidence);
  checkTampering(f);
  stdout.writeln('org yqxz source evidence association offline checks passed');
}
