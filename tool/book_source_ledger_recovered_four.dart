// Read-only, exact-source association for the later host and AMSI samples.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'book_source_ledger_nov16_evidence.dart';

const later943EvidenceFile = 'legado-unresolved-943-recheck-20261116.json';
const recoveredFourEvidenceFile = 'legado-recovered-four-amsi-20261116.json';
const _headSha =
    '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0';
const _headCanonical =
    '161905ec2edfc5739cd8639c61e7934dec54bfb1428b2c58ebbf099deccc9e99';
const _fourSha =
    '9e135e064dc6aa31f379defe31bfb03add9674cbce78d99f66f34da449ceb1a8';
const _fourCanonical =
    'cafaa10e42cf468d5967edcf29e97f0cac7ffcb6018f5d7ec6f9cfbe1ab317d3';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _prior = 'docs/implementation/legado-unresolved-head-later-20261116.json';
const _priorSha =
    '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd';
const _priorAmsi = 'docs/implementation/legado-recovered-amsi-20261116.json';
const _priorAmsiSha =
    '050c6913ab5dacd607c68a369206e46ac30bdd226f6729ef6a5c1cb5c3bc6dcc';
const _history = 'docs/implementation/legado-source-ledger-20261115.json';
const _historySha =
    'ec0f211055eb8a18c1b9c0db0496a3b0653519c9abeccb387bec1f1d3c90624d';
const _commit = '7c9e02eb84738b07cfeb47a6d08ade74ccfa4d00';

typedef NetworkRecord =
    Map<String, Object?> Function({
      required String evidence,
      required String method,
      required String path,
      required Map row,
    });
typedef AmsiRecord = Map<String, Object?> Function(String file, Map row);

void _require(bool value, String reason) {
  if (!value) throw FormatException(reason);
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _objectSha(Object? value) =>
    _sha(utf8.encode(jsonEncode(_canonical(value))));
String _key(String id, String host, int index) => '$id\x00$host\x00$index';

void verifyRecoveredFourInput(
  String file,
  Map evidence,
  Map<String, String> hashes,
) {
  final (expected, canonical) = switch (file) {
    later943EvidenceFile => (_headSha, _headCanonical),
    recoveredFourEvidenceFile => (_fourSha, _fourCanonical),
    _ => throw const FormatException('unknown recovered-four evidence'),
  };
  _require(
    hashes['docs/implementation/$file'] == expected &&
        _objectSha(evidence) == canonical &&
        hashes[_archive] == _archiveSha &&
        hashes[_prior] == _priorSha &&
        hashes[_priorAmsi] == _priorAmsiSha,
    'recovered-four evidence bytes or inputs changed',
  );
}

final class RecoveredFourLedgerEvidence {
  final network = <String, List<Map<String, Object?>>>{};
  final registry = <String, List<Map<String, Object?>>>{};
  final amsi = <String, List<Map<String, Object?>>>{};

  void add(
    Map<String, List<Map<String, Object?>>> map,
    String id,
    String host,
    int index,
    Map<String, Object?> value,
  ) {
    map.putIfAbsent(_key(id, host, index), () => []).add({
      ...value,
      'historical_selected_record_index': index,
      'matches_current_selected_raw_record': true,
    });
  }
}

RecoveredFourLedgerEvidence readRecoveredFourEvidence(
  Map head,
  Map four,
  Map prior,
  Map<String, String> hashes,
  List rawRecords,
  NetworkRecord networkObservation,
  AmsiRecord amsiObservation,
) {
  verifyRecoveredFourInput(later943EvidenceFile, head, hashes);
  verifyRecoveredFourInput(recoveredFourEvidenceFile, four, hashes);
  final references = head['input_references'] as Map;
  final historical = references['historical_ledger'] as Map;
  _require(
    historical['git_commit'] == _commit &&
        historical['path'] == _history &&
        historical['sha256'] == _historySha &&
        (references['previous_head'] as Map)['sha256'] == _priorSha &&
        ((four['input_references'] as Map)['head'] as Map)['sha256'] ==
            _headSha,
    'recovered-four reference mismatch',
  );
  final history = verifiedHistoricalGitObject(historical, _history);
  _require(
    (history['input_sha256'] as Map)[_archive] == _archiveSha &&
        (history['input_sha256'] as Map)[_prior] == _priorSha,
    'recovered-four historical ledger mismatch',
  );
  final sources = {
    for (final row in (history['sources'] as List).cast<Map>())
      row['source_id']: row,
  };
  final priorRows = {
    for (final row in (prior['results'] as List).cast<Map>()) row['host']: row,
  };
  final rows = (head['results'] as List).cast<Map>();
  _require(
    rows.length == 943 && rows.map((r) => r['host']).toSet().length == 943,
    'recovered-four HEAD population mismatch',
  );
  final output = RecoveredFourLedgerEvidence();
  final currentHeads = <String, Map>{};
  var sourceCount = 0;
  for (final row in rows) {
    final host = row['host'] as String;
    final old = priorRows[host];
    _require(
      old != null &&
          (old['latest_head'] as Map)['http_status'] == null &&
          jsonEncode(row['record_indices']) ==
              jsonEncode(old['record_indices']) &&
          jsonEncode(row['selected_sources']) ==
              jsonEncode(old['selected_sources']),
      'recovered-four prior host mismatch',
    );
    currentHeads[host] = row;
    for (final item in (row['selected_sources'] as List).cast<Map>()) {
      final id = item['source_id'] as String;
      final index = item['record_index'] as int;
      final saved = sources[id];
      _require(
        saved != null &&
            index >= 0 &&
            index < rawRecords.length &&
            saved['selected_record_index'] == index &&
            saved['endpoint_host'] == host &&
            _objectSha(rawRecords[index]) ==
                saved['selected_raw_record_canonical_sha256'],
        'recovered-four selected source mismatch',
      );
      sourceCount++;
      final latest = row['latest_head'] as Map;
      final dns = row['dns'] as Map;
      output.add(output.network, id, host, index, {
        ...networkObservation(
          evidence: later943EvidenceFile,
          method: 'HEAD',
          path: '/',
          row: latest,
        ),
        'recorded_classification': latest['classification'],
        'redirect_followed': false,
        'readability_verified': null,
        'site_security_verified': null,
      });
      output.add(output.registry, id, host, index, {
        'evidence': later943EvidenceFile,
        'observation_kind': 'later_native_dns_exact_endpoint_host',
        'queried_host': host,
        'verdict': dns['verdict'],
        'observations': dns['observations'],
        'permanent_failure_inferred': null,
      });
    }
  }
  _require(sourceCount == 908, 'recovered-four selected count mismatch');
  _addFour(output, four, currentHeads, networkObservation, amsiObservation);
  return output;
}

void _addFour(
  RecoveredFourLedgerEvidence output,
  Map four,
  Map<String, Map> heads,
  NetworkRecord networkObservation,
  AmsiRecord amsiObservation,
) {
  final samples = ((four['amsi'] as Map)['results'] as List).cast<Map>();
  _require(
    samples.length == 4 && samples.map((r) => r['host']).toSet().length == 4,
    'recovered-four AMSI population mismatch',
  );
  for (final sample in samples) {
    final host = sample['host'] as String;
    final head = heads[host];
    _require(
      head != null && (head['latest_head'] as Map)['http_status'] == 200,
      'recovered-four missing 200 HEAD',
    );
    final exactHead = head!;
    final selected = (exactHead['selected_sources'] as List).cast<Map>();
    _require(
      selected.length == 1 &&
          jsonEncode(sample['selected_source_ids']) ==
              jsonEncode([selected.single['source_id']]) &&
          jsonEncode(sample['record_indices']) ==
              jsonEncode(exactHead['record_indices']),
      'recovered-four AMSI source mismatch',
    );
    final id = selected.single['source_id'] as String;
    final index = selected.single['record_index'] as int;
    output.add(output.network, id, host, index, {
      ...networkObservation(
        evidence: recoveredFourEvidenceFile,
        method: 'GET',
        path: '/',
        row: sample,
      ),
      'readability_verified': null,
      'site_security_verified': null,
    });
    output.add(output.amsi, id, host, index, {
      ...amsiObservation(recoveredFourEvidenceFile, sample),
      'site_security_verified': null,
    });
  }
  _addFollowup(output, four, heads, networkObservation);
}

void _addFollowup(
  RecoveredFourLedgerEvidence output,
  Map four,
  Map<String, Map> heads,
  NetworkRecord networkObservation,
) {
  final template = four['shared_template'] as Map;
  for (final row in (template['fresh_root_gets'] as List).cast<Map>()) {
    final host = row['host'] as String;
    _require(
      const {'www.mumumh.com', 'www.nidedizhi1.com'}.contains(host) &&
          row['http_status'] == 200 &&
          row['sample_sha256'] == template['sample_sha256'],
      'recovered-four template source mismatch',
    );
    final selected = (heads[host]!['selected_sources'] as List).single as Map;
    output.add(
      output.network,
      selected['source_id'] as String,
      host,
      selected['record_index'] as int,
      {
        ...networkObservation(
          evidence: recoveredFourEvidenceFile,
          method: 'GET',
          path: '/',
          row: {
            ...row,
            'sample_bytes': template['sample_bytes'],
            'truncated': false,
          },
        ),
        'page_displays_domain_expiry_claim': true,
        'page_attribution_verified': null,
        'site_security_verified': null,
      },
    );
  }
  final followup = four['registry_and_old_path_followup'] as Map;
  final samples = (followup['old_paths'] as List).cast<Map>();
  _require(samples.length == 4, 'recovered-four old-path count mismatch');
  for (final row in samples) {
    final host = row['host'] as String;
    final selected = (heads[host]!['selected_sources'] as List).single as Map;
    final id = selected['source_id'] as String;
    final index = selected['record_index'] as int;
    _require(
      row['source_id'] == id &&
          row['http_status'] == 404 &&
          const {'www.mumumh.com', 'www.nidedizhi1.com'}.contains(host),
      'recovered-four old-path source mismatch',
    );
    output.add(output.network, id, host, index, {
      ...networkObservation(
        evidence: recoveredFourEvidenceFile,
        method: 'GET',
        path: row['path'] as String,
        row: row,
      ),
      'redirect_followed': false,
      'whole_source_unavailable_verified': null,
    });
  }
  final domains = {
    'mumumh.com': 'www.mumumh.com',
    'nidedizhi1.com': 'www.nidedizhi1.com',
  };
  for (final round in (followup['registry_rounds'] as List).cast<Map>()) {
    _require(
      round['controls_passed'] == true,
      'recovered-four registry controls failed',
    );
    for (final row in (round['candidates'] as List).cast<Map>()) {
      final domain = row['domain'] as String;
      final host = domains[domain];
      _require(
        host != null && row['classification'] == 'matching_domain_object',
        'recovered-four registry domain mismatch',
      );
      final selected = (heads[host]!['selected_sources'] as List).single as Map;
      output.add(
        output.registry,
        selected['source_id'] as String,
        host!,
        selected['record_index'] as int,
        {
          'evidence': recoveredFourEvidenceFile,
          'observation_kind': 'rdap_registered_domain',
          'registry_domain': domain,
          'observed_at': row['observed_at'],
          'http_status': row['http_status'],
          'classification': row['classification'],
          'status_indicators': row['status_indicators'],
          'expiration_dates_utc': row['expiration_dates_utc'],
          'whole_source_unavailable_verified': null,
        },
      );
    }
  }
}

List<Map<String, Object?>> selectRecoveredFourEvidence(
  Map<String, List<Map<String, Object?>>> evidence,
  BookSource source,
  int index,
) => [
  for (final item
      in evidence[_key(source.id, source.endpoint.host, index)] ??
          const <Map<String, Object?>>[])
    {...item},
];
