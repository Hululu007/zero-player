// Offline association of bounded historical registry and DNS observations.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const rdapOrgYqxzEvidenceFile = 'legado-rdap-org-yqxz-20261116.json';
const rdapOrgYqxzEvidenceSha =
    '7202ec6faabf7e612b15b8782608bcbb0b4ba6e95cdbdbde22c78ce6f0902f82';
const _canonicalSha =
    '435dd6e5e0024cef78e12f85e1b98c3055560e080532c5f39efc668b8ded8a81';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _commit = '56955b3d441678f4734d4c8cb4bf377a373212c4';
const _ledger = 'docs/implementation/legado-source-ledger-20261115.json';
const _ledgerSha =
    'cfd87a165b3fb175d603385eb7a64192f9ae11e5c0441ff35d94323594b7265e';
const _id = 'adf7fb3063ed743cadafd19afc8a980d610adf508bef68d4ed71068cb412068a';
const _host = 'www.yqxz.org', _domain = 'yqxz.org';
const _index = 1483;
const _endpointSha =
    '9ad83839efa13f583ab2c8c7268eb620ff8bfc85388c4bd6ff5b5cda721b3187';
const _ruleSha =
    '70d5b4969261b02fd5815790184a68abe79b9e6d3ee35310b64920319b5438e0';
const _rawSha =
    'c6308180cb8fa47e3cd0f0290ee507d3ea974e7c78ca4c4e171dfe002abdaf0d';
const _references = <String, (String, String)>{
  'archive': (_archive, _archiveSha),
  'manifest': (
    'assets/catalogs/books/legado/manifest.json',
    '59bb9e3551b5a01406c1d720d2b5d5d5f21518eccbb52cd93f8d752c19f7cf66',
  ),
  'native_recheck': (
    'docs/implementation/legado-host-recheck-20261115.json',
    'fcb543ff2a41e7e4960d2a0112af9c311d8e55148b8716d8854c09360b1080af',
  ),
  'public_doh': (
    'docs/implementation/legado-doh-reviewed-20261115.json',
    '4729489824e1f653d5e18872789a75e9f0ebe919286add025e738606f4243059',
  ),
  'later_head': (
    'docs/implementation/legado-unresolved-head-later-20261116.json',
    '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd',
  ),
  'later_943_head': (
    'docs/implementation/legado-unresolved-943-recheck-20261116.json',
    '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0',
  ),
};

void _require(bool value, String message) {
  if (!value) throw FormatException(message);
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();
Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}

String _objectSha(Object? value) =>
    _sha(utf8.encode(jsonEncode(_ordered(value))));
String _textSha(String value) => _sha(utf8.encode(value));

void verifyRdapOrgYqxzInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['inputs'] as Map;
  final historic = inputs['historical_ledger'] as Map;
  _require(
    hashes['docs/implementation/$rdapOrgYqxzEvidenceFile'] ==
            rdapOrgYqxzEvidenceSha &&
        _objectSha(evidence) == _canonicalSha &&
        archiveSha == _archiveSha &&
        historic['git_commit'] == _commit &&
        historic['path'] == _ledger &&
        historic['sha256'] == _ledgerSha,
    'org yqxz evidence or historical reference mismatch',
  );
  for (final entry in _references.entries) {
    final (path, expected) = entry.value;
    final ref = inputs[entry.key] as Map;
    _require(
      ref['path'] == path &&
          ref['sha256'] == expected &&
          hashes[path] == expected,
      'org yqxz input mismatch: ${entry.key}',
    );
  }
}

final class RdapOrgYqxzLedgerEvidence {
  const RdapOrgYqxzLedgerEvidence(this._observations);
  final List<Map<String, Object?>> _observations;
}

RdapOrgYqxzLedgerEvidence readRdapOrgYqxzEvidence(
  Map evidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyRdapOrgYqxzInput(evidence, hashes[_archive] ?? '', hashes);
  final history = verifiedHistoricalGitObject({
    'git_commit': _commit,
    'path': _ledger,
    'sha256': _ledgerSha,
  }, _ledger);
  for (final entry in _references.values) {
    _require(
      (history['input_sha256'] as Map)[entry.$1] == entry.$2,
      'org yqxz historical input digest mismatch',
    );
  }
  _require(rawRecords.length > _index, 'org yqxz archived index missing');
  final oldRows = (history['sources'] as List)
      .cast<Map>()
      .where((r) => r['source_id'] == _id)
      .toList();
  _require(oldRows.length == 1, 'org yqxz historical source not unique');
  final old = oldRows.single;
  final candidate = evidence['candidate'] as Map;
  final snapshot = candidate['selected_source'] as Map;
  final raw = rawRecords[_index] as Map;
  final parsed = parseBookSourceRecord(raw);
  _require(
    candidate['registry_domain'] == _domain &&
        candidate['old_source_host'] == _host &&
        snapshot['source_id'] == _id &&
        snapshot['selected_record_index'] == _index &&
        snapshot['name'] == old['name'] &&
        snapshot['kind'] == 'text' &&
        old['kind'] == 'text' &&
        old['format'] == 'html' &&
        old['selected_record_index'] == _index &&
        old['endpoint_host'] == _host &&
        snapshot['endpoint_sha256'] == old['endpoint_sha256'] &&
        old['endpoint_sha256'] == _endpointSha &&
        snapshot['normalized_legado_sha256'] ==
            old['normalized_legado_canonical_sha256'] &&
        old['normalized_legado_canonical_sha256'] == _ruleSha &&
        snapshot['selected_raw_record_canonical_sha256'] ==
            old['selected_raw_record_canonical_sha256'] &&
        old['selected_raw_record_canonical_sha256'] == _rawSha &&
        _objectSha(raw) == _rawSha &&
        parsed.id == _id &&
        parsed.endpoint.host == _host &&
        parsed.kind == BookKind.text &&
        parsed.format == BookFormat.html,
    'org yqxz archived or historical selected identity mismatch',
  );
  return RdapOrgYqxzLedgerEvidence(_observations(evidence));
}

List<Map<String, Object?>> _observations(Map evidence) {
  final rounds = (evidence['rounds'] as List).cast<Map>();
  final summary = evidence['summary'] as Map;
  _require(
    rounds.length == 2 &&
        summary['rdap_matching_domain_objects'] == 2 &&
        summary['old_subdomain_nxdomain'] == 7 &&
        summary['old_subdomain_timeout'] == 1 &&
        summary['apex_noerror_no_address'] == 8 &&
        summary['whole_source_permanently_unavailable_verified'] == null,
    'org yqxz observation summary mismatch',
  );
  final output = <Map<String, Object?>>[];
  var apexEmpty = 0, oldNx = 0, oldTimeout = 0, registered = 0;
  for (var i = 0; i < rounds.length; i++) {
    final round = rounds[i];
    final controls = round['control_status'] as Map;
    final rows = (round['observations'] as List).cast<Map>();
    _require(
      round['round'] == i + 1 &&
          controls['rdap'] == true &&
          controls['aliyun'] == true &&
          controls['tencent'] == true &&
          rows.length == 9 &&
          (round['skipped'] as List).isEmpty,
      'org yqxz round or control coverage mismatch',
    );
    final keys = <String>{};
    for (final row in rows) {
      final mode = row['mode'];
      final queried = mode == 'rdap' ? row['domain'] : row['host'];
      final key =
          '$mode\x00$queried\x00${row['provider']}\x00${row['query_type']}';
      _require(keys.add(key), 'org yqxz duplicate query');
      if (mode == 'rdap') {
        _require(
          queried == _domain &&
              row['classification'] == 'matching_domain_object' &&
              row['http_status'] == 200 &&
              row['rdap_object_matches'] == true &&
              row['rdap_conformance_present'] == true,
          'org yqxz registry observation mismatch',
        );
        registered++;
      } else {
        _require(
          mode == 'doh' &&
              {_domain, _host}.contains(queried) &&
              {'aliyun', 'tencent'}.contains(row['provider']) &&
              {'A', 'AAAA'}.contains(row['query_type']),
          'org yqxz DNS query scope mismatch',
        );
        final classification = row['classification'];
        if (queried == _domain) {
          _require(
            classification == 'noerror_no_address' &&
                row['http_status'] == 200 &&
                row['dns_rcode'] == 0,
            'org yqxz apex DNS mismatch',
          );
          apexEmpty++;
        } else if (classification == 'nxdomain') {
          _require(
            row['http_status'] == 200 && row['dns_rcode'] == 3,
            'org yqxz NXDOMAIN mismatch',
          );
          oldNx++;
        } else {
          _require(
            classification == 'provider_timeout' &&
                row['http_status'] == null &&
                row['dns_rcode'] == null,
            'org yqxz timeout must remain unknown',
          );
          oldTimeout++;
        }
      }
      output.add(_observation(row, round['round'] as int));
    }
    _require(keys.length == 9, 'org yqxz query coverage mismatch');
  }
  _require(
    apexEmpty == 8 && oldNx == 7 && oldTimeout == 1 && registered == 2,
    'org yqxz observed counts mismatch',
  );
  return output;
}

Map<String, Object?> _observation(Map row, int round) {
  final registry = row['mode'] == 'rdap';
  final host = registry ? _domain : row['host'];
  return {
    'evidence': rdapOrgYqxzEvidenceFile,
    'observation_kind': registry
        ? 'official_rdap_registered_domain_context'
        : 'public_doh',
    'round': round,
    'registry_domain': _domain,
    'queried_host': host,
    'host_relation': host == _host
        ? 'endpoint_host'
        : 'registered_domain_context',
    'historical_selected_record_index': _index,
    'historical_endpoint_sha256': _endpointSha,
    'historical_normalized_legado_sha256': _ruleSha,
    'historical_raw_record_sha256': _rawSha,
    'query_performed': true,
    'controls_passed': true,
    'observed_at': row['observed_at'],
    'classification': row['classification'],
    'http_status': row['http_status'],
    if (!registry) ...{
      'provider': row['provider'],
      'query_type': row['query_type'],
      'dns_rcode': row['dns_rcode'],
      'dns_truncated': row['dns_truncated'],
      'address_categories': row['address_categories'],
      'address_ttls_seconds': row['address_ttls_seconds'],
      'negative_ttls_seconds': row['negative_ttls_seconds'],
    },
    if (registry) 'rdap_object_matches': row['rdap_object_matches'],
    'site_security_verified': null,
    'source_readability_verified': null,
    'permanent_failure_verified': null,
  };
}

List<Map<String, Object?>> selectRdapOrgYqxzEvidence(
  RdapOrgYqxzLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) {
  if (source.id != _id ||
      source.endpoint.host != _host ||
      selectedIndex != _index) {
    return [];
  }
  return [
    for (final row in evidence._observations)
      {
        ...row,
        'matches_current_selected_raw_record': true,
        'matches_current_source_kind': source.kind == BookKind.text,
        'matches_current_source_format': source.format == BookFormat.html,
        'matches_current_full_endpoint':
            _textSha(source.endpoint.toString()) == _endpointSha,
        'matches_current_normalized_legado_rule':
            source.legado != null &&
            legadoSourceFingerprint(source.legado!) == _ruleSha,
      },
  ];
}
