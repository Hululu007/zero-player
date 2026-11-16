// Offline association of two individually sampled legacy-source versions.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const sanyouEvidenceFile = 'legado-sanyou-sale-recheck-20261116.json';
const sanyouEvidenceSha =
    '305398e39c6c83d2a99b70a6ad08e7a36ec94e7eafe4221a7b2a8c9a59708f5f';
const _canonicalSha =
    '1174642fc27c806c72e45e7cf1912e5984a2395903ad99145e8cab81a89f9ac1';
const _commit = '1247df93222ac993e04c6db57ba0471fc713a63e';
const _ledger = 'docs/implementation/legado-source-ledger-20261115.json';
const _ledgerSha =
    'b6afb51bcce7af5f7f152ffa3f1c3bce824a0419970253e2c110eed299e09448';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _manifest = 'assets/catalogs/books/legado/manifest.json';
const _manifestSha =
    '59bb9e3551b5a01406c1d720d2b5d5d5f21518eccbb52cd93f8d752c19f7cf66';
const _pilot = 'docs/implementation/legado-eight-source-pilot-20261116.json';
const _pilotSha =
    'ab615d995deb1998f1e2cf048168610ae22fe8fb516c6d6af46f714b6c24222f';
const _endpoint = 'https://www.3uxiaoshuo.com/';
const _endpointSha =
    '461bb4c162e0a7f0abd078b194ff10a4258333273760510ceda34710edeb8c4a';
const _sources =
    <int, ({String id, String sourceKey, String rule, String raw})>{
      3134: (
        id: 'bc379d9cf7ee312a6d9813e14830fdc689be5b2371fa025529586fc3a67aec1d',
        sourceKey: '',
        rule:
            '719bcc073e57846c8fa64d94d46537f5fc764f7588af24e29c6fffdf8b210834',
        raw: 'e21aeed9e48a5137e0a84fe97914f09a29303750a77ad2dcdb9446c51d1e1009',
      ),
      918: (
        id: '6a45e0819c4f731d5a6edffd650e0b22eb49c8e2eccd5de320e0ae2c701c67e9',
        sourceKey: '3uxiaoshuo.com#%23@%E9%81%87%E7%9F%A5',
        rule:
            'c7ccae8b1f6031b071e57473cb987969c6a075bdd65b6767d6d1375d4d7c9e58',
        raw: '980b4eff23171322c2f21d72a1a83060bedbafab49fe5fd31ec4d447ff7d51f0',
      ),
    };

void _require(bool value, String message) {
  if (!value) throw FormatException(message);
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

void verifySanyouInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['inputs'] as Map;
  _require(
    hashes['docs/implementation/$sanyouEvidenceFile'] == sanyouEvidenceSha &&
        _objectSha(evidence) == _canonicalSha &&
        archiveSha == _archiveSha &&
        hashes[_manifest] == _manifestSha &&
        hashes[_pilot] == _pilotSha &&
        inputs['historical_git_commit'] == _commit &&
        inputs['historical_ledger_path'] == _ledger &&
        inputs['historical_ledger_sha256'] == _ledgerSha &&
        inputs['archive_path'] == _archive &&
        inputs['archive_sha256'] == _archiveSha &&
        inputs['manifest_path'] == _manifest &&
        inputs['manifest_sha256'] == _manifestSha &&
        inputs['prior_pilot_path'] == _pilot &&
        inputs['prior_pilot_sha256'] == _pilotSha,
    'sanyou evidence or input mismatch',
  );
}

final class SanyouLedgerEvidence {
  const SanyouLedgerEvidence(this._rows);
  final Map<int, List<Map<String, Object?>>> _rows;
}

SanyouLedgerEvidence readSanyouEvidence(
  Map evidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifySanyouInput(evidence, hashes[_archive] ?? '', hashes);
  final history = verifiedHistoricalGitObject({
    'git_commit': _commit,
    'path': _ledger,
    'sha256': _ledgerSha,
  }, _ledger);
  final historicalInputs = history['input_sha256'] as Map;
  _require(
    historicalInputs[_archive] == _archiveSha &&
        historicalInputs[_manifest] == _manifestSha &&
        historicalInputs[_pilot] == _pilotSha &&
        rawRecords.length > 3134,
    'sanyou historical input mismatch',
  );
  final result = <int, List<Map<String, Object?>>>{};
  for (final entry in _sources.entries) {
    final index = entry.key, expected = entry.value;
    final oldRows = (history['sources'] as List)
        .cast<Map>()
        .where((r) => r['source_id'] == expected.id)
        .toList();
    _require(oldRows.length == 1, 'sanyou selected source not unique');
    final old = oldRows.single;
    final snapshot =
        evidence[index == 3134 ? 'source' : 'second_source'] as Map;
    final raw = rawRecords[index] as Map;
    final parsed = parseBookSourceRecord(raw);
    _require(
      snapshot['source_id'] == expected.id &&
          snapshot['selected_record_index'] == index &&
          snapshot['source_key'] == expected.sourceKey &&
          snapshot['kind'] == 'text' &&
          snapshot['format'] == 'html' &&
          snapshot['normalized_endpoint'] == _endpoint &&
          snapshot['endpoint_sha256'] == _endpointSha &&
          snapshot['raw_record_canonical_sha256'] == expected.raw &&
          snapshot['normalized_legado_sha256'] == expected.rule &&
          old['selected_record_index'] == index &&
          old['kind'] == 'text' &&
          old['format'] == 'html' &&
          old['endpoint_host'] == 'www.3uxiaoshuo.com' &&
          old['endpoint_sha256'] == _endpointSha &&
          old['selected_raw_record_canonical_sha256'] == expected.raw &&
          old['normalized_legado_canonical_sha256'] == expected.rule &&
          _objectSha(raw) == expected.raw &&
          parsed.id == expected.id &&
          parsed.sourceKey == expected.sourceKey &&
          parsed.endpoint.toString() == _endpoint &&
          parsed.kind == BookKind.text &&
          parsed.format == BookFormat.html,
      'sanyou exact historical source mismatch',
    );
    final rows =
        (evidence[index == 3134 ? 'observations' : 'second_observations']
                as List)
            .cast<Map>();
    _require(rows.length == 8, 'sanyou observation count mismatch');
    result[index] = [
      for (final row in rows)
        _observed(row, index, expected.rule, expected.raw),
    ];
    if (index == 3134) {
      final prior = (evidence['prior_pilot_search_observations'] as List)
          .cast<Map>();
      _require(
        prior.length == 2 &&
            prior.every(
              (row) => row['status'] == 200 && row['engine_book_count'] == 0,
            ),
        'sanyou prior parser observations mismatch',
      );
      result[index]!.addAll([
        for (final row in prior)
          _prior(row, index, expected.rule, expected.raw),
      ]);
    }
  }
  return SanyouLedgerEvidence(result);
}

Map<String, Object?> _common(int index, String rule, String raw) => {
  'evidence': sanyouEvidenceFile,
  'historical_selected_record_index': index,
  'historical_endpoint_sha256': _endpointSha,
  'historical_normalized_legado_sha256': rule,
  'historical_raw_record_sha256': raw,
  'site_security_verified': null,
  'whole_source_permanent_failure_verified': null,
  'direct_book_or_cached_work_verified': null,
  'host_wide_verdict': false,
};

Map<String, Object?> _observed(Map row, int index, String rule, String raw) {
  _require(
    row['status'] == 200 &&
        row['truncated'] == false &&
        row['domain_sale_h1_count'] == 2 &&
        row['old_list_selector_nodes'] == 0,
    'sanyou retained observation mismatch',
  );
  return {
    ..._common(index, rule, raw),
    'observation_kind': 'bounded_old_entry_html_sample',
    'round': row['round'],
    'target_role': row['role'],
    'started_at_utc': row['started_at_utc'],
    'http_method': row['method'],
    'http_status': row['status'],
    'media_type': row['media_type'],
    'sample_bytes': row['sample_bytes'],
    'sample_sha256': row['sample_sha256'],
    'sample_truncated': row['truncated'],
    'domain_sale_h1_count': row['domain_sale_h1_count'],
    'contact_owner_h3': row['contact_owner_h3'],
    'old_list_selector_nodes': row['old_list_selector_nodes'],
    'css_or_rendering_evaluated': false,
    'source_scripts_executed': false,
  };
}

Map<String, Object?> _prior(Map row, int index, String rule, String raw) => {
  ..._common(index, rule, raw),
  'observation_kind': 'earlier_historical_search_parse',
  'started_at_utc': row['started_at_utc'],
  'observed_at_utc': row['observed_at_utc'],
  'http_status': row['status'],
  'sample_bytes': row['sample_bytes'],
  'sample_sha256': row['sample_sha256'],
  'sample_truncated': row['truncated'],
  'engine_book_count': row['engine_book_count'],
  'sale_heading_recorded': null,
};

List<Map<String, Object?>> selectSanyouEvidence(
  SanyouLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) {
  final expected = _sources[selectedIndex];
  if (expected == null ||
      source.id != expected.id ||
      source.endpoint.host != 'www.3uxiaoshuo.com') {
    return [];
  }
  return [
    for (final row in evidence._rows[selectedIndex] ?? <Map<String, Object?>>[])
      {
        ...row,
        'matches_current_selected_raw_record': true,
        'matches_current_source_kind': source.kind == BookKind.text,
        'matches_current_source_format': source.format == BookFormat.html,
        'matches_current_source_key': source.sourceKey == expected.sourceKey,
        'matches_current_full_endpoint':
            source.endpoint.toString() == _endpoint,
        'matches_current_normalized_legado_rule':
            source.legado != null &&
            legadoSourceFingerprint(source.legado!) == expected.rule,
      },
  ];
}
