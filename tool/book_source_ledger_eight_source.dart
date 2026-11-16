// Bounded observations for eight historical selected sources; no network access.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const eightSourceEvidenceFile = 'legado-eight-source-pilot-20261116.json';
const eightSourceEvidenceSha =
    'ab615d995deb1998f1e2cf048168610ae22fe8fb516c6d6af46f714b6c24222f';
const _canonicalEvidenceSha =
    'f6cf238328f3e74352d4b946e2c0752bda111a74550dea7ae6cbafaa65b531b6';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _inventorySha =
    'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c';
const _historyCommit = 'dfb4c9cb71fd6de1607bcbf8ca427ef4361ca307';
const _historyPath = 'docs/implementation/legado-source-ledger-20261115.json';
const _historySha =
    'cca374595f6d9fb79477032d5268737051fd813bed996131b205dbccaaeb4f17';
const _laterRiskSha =
    '96d56f4a01b80073ea52269320b7a3a22461aff7fa9a60ca25495c6744c35efc';

// The index is part of the identity: an older same-ID record is not selected.
const _identities = <int, (String, String)>{
  407: (
    'fa42526b9412d5c4431acbd60ab169b7e68e7b2fe008da412e8b8da8310bc877',
    'm.dmxso.com',
  ),
  1399: (
    'c7f3f35a20b48cf4fb02cb92f6714b08c96d97adb6bfd50a24adc0d3d21d7b20',
    'www.wucuoxs.com',
  ),
  3134: (
    'bc379d9cf7ee312a6d9813e14830fdc689be5b2371fa025529586fc3a67aec1d',
    'www.3uxiaoshuo.com',
  ),
  4371: (
    '22fd5687b4cd8b42ce1d69d0701148e989f39833d7d94b1e1dae73795084e242',
    'www.bsxiaoshuo.com',
  ),
  3954: (
    '0e51322b309496dd36b4388cc7dcbc156c06e32bff52d1d6a9878794877003d0',
    'm.gulongbbs.com',
  ),
  1056: (
    '981adf7639a1c61e23ad4104e4e11b3553439b9ea22599c1b429881ace889402',
    'www.shubang.net',
  ),
  3817: (
    '52a7d590143c8fd5168b42ff3681a8bd473d0cbd3b53810d527047294a9e8ba8',
    'wenxue.bkneng.com',
  ),
  4491: (
    '5ff498ddb51371e132e6b35fa505eaa7ddb0b989213814eda0a79cf3cd119747',
    'www.zzrx.net',
  ),
};

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
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
String _textSha(String value) => _sha(utf8.encode(value));

/// Verify both the caller's byte digest and the parsed evidence, not either alone.
void verifyEightSourceInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['inputs'] as Map;
  final later = (evidence['sampled_source_snapshots'] as Map)['later'] as Map;
  _require(
    hashes['docs/implementation/$eightSourceEvidenceFile'] ==
            eightSourceEvidenceSha &&
        _objectSha(evidence) == _canonicalEvidenceSha &&
        archiveSha == _archiveSha &&
        hashes[_inventory] == _inventorySha &&
        inputs['archive_path'] == _archive &&
        inputs['archive_sha256'] == _archiveSha &&
        inputs['inventory_path'] == _inventory &&
        inputs['inventory_sha256'] == _inventorySha &&
        inputs['historical_git_commit'] == _historyCommit &&
        inputs['historical_ledger_path'] == _historyPath &&
        inputs['historical_ledger_sha256'] == _historySha &&
        later['git_commit'] == null &&
        later['full_runtime_snapshot_reconstructable'] == false &&
        (later['uncaptured_risk_direct_dependencies'] as List).length == 8 &&
        (later['recorded_tracked_files_sha256']
                as Map)['lib/features/books/domain/book_source_risk.dart'] ==
            _laterRiskSha,
    'eight-source evidence, archive, historical reference or limits mismatch',
  );
}

final class EightSourceLedgerEvidence {
  const EightSourceLedgerEvidence(this._rows);
  final Map<int, Map<String, Object?>> _rows;
}

/// Validate against the fixed Git ledger and the supplied, independently hashed archive.
EightSourceLedgerEvidence readEightSourceEvidence(
  Map evidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyEightSourceInput(evidence, hashes[_archive] ?? '', hashes);
  final history = verifiedHistoricalGitObject({
    'git_commit': _historyCommit,
    'path': _historyPath,
    'sha256': _historySha,
  }, _historyPath);
  _require(
    (history['input_sha256'] as Map)[_archive] == _archiveSha &&
        (history['input_sha256'] as Map)[_inventory] == _inventorySha,
    'eight-source historical inputs mismatch',
  );
  final sourceSnapshots = (evidence['sources'] as List).cast<Map>();
  final initial = ((evidence['initial'] as Map)['observations'] as List)
      .cast<Map>();
  final followups = (evidence['followups'] as List).cast<Map>();
  _require(
    sourceSnapshots.length == 8 && initial.length == 8 && followups.length == 4,
    'eight-source observation count mismatch',
  );
  final historyRows = (history['sources'] as List).cast<Map>();
  final rows = <int, Map<String, Object?>>{};
  for (final entry in _identities.entries) {
    final index = entry.key;
    final (id, host) = entry.value;
    _require(index < rawRecords.length, 'eight-source archive index missing');
    final snapshots = sourceSnapshots
        .where((row) => row['index'] == index)
        .toList();
    final selected = historyRows
        .where((row) => row['source_id'] == id)
        .toList();
    final first = initial.where((row) => row['index'] == index).toList();
    final later = followups.where((row) => row['index'] == index).toList();
    _require(
      snapshots.length == 1 &&
          selected.length == 1 &&
          first.length == 1 &&
          later.length <= 1,
      'eight-source selected identity is not unique',
    );
    final snapshot = snapshots.single;
    final old = selected.single;
    final raw = rawRecords[index] as Map;
    final parsed = parseBookSourceRecord(raw);
    _require(
      snapshot['id'] == id &&
          snapshot['host'] == host &&
          snapshot['kind'] == 'text' &&
          snapshot['format'] == 'html' &&
          parsed.id == id &&
          parsed.endpoint.host == host &&
          old['selected_record_index'] == index &&
          old['source_id'] == id &&
          old['endpoint_host'] == host &&
          old['kind'] == 'text' &&
          old['format'] == 'html' &&
          old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
          old['normalized_legado_canonical_sha256'] ==
              snapshot['historical_legado_canonical_sha256'] &&
          old['selected_raw_record_canonical_sha256'] ==
              snapshot['raw_record_canonical_sha256'] &&
          _objectSha(raw) == snapshot['raw_record_canonical_sha256'] &&
          first.single['id'] == id &&
          first.single['host'] == host &&
          later.every((row) => row['id'] == id && row['host'] == host),
      'eight-source identity, historical endpoint, archive or rule mismatch',
    );
    _verifyFields(raw, snapshot);
    rows[index] = {
      'evidence': eightSourceEvidenceFile,
      'observation_kind': 'bounded_historical_search_and_reading_samples',
      'historical_selected_record_index': index,
      'historical_raw_record_sha256': snapshot['raw_record_canonical_sha256'],
      'historical_normalized_legado_sha256':
          snapshot['historical_legado_canonical_sha256'],
      'historical_endpoint_sha256': snapshot['endpoint_sha256'],
      'initial_recorded_files_git_commit': _historyCommit,
      if (later.isNotEmpty) ...{
        'followup_risk_policy_sha256': _laterRiskSha,
        'followup_risk_policy_git_commit': null,
        'followup_direct_dependency_hashes_complete': false,
      },
      'historical_runtime_fully_reconstructed': false,
      'raw_pages_and_collectors_replayable': false,
      'url_text_prefilter_confirms_site_safety': false,
      'http_method': 'GET',
      'redirects_followed': false,
      'post_sent': false,
      'scripts_executed': false,
      'subresources_loaded': false,
      'samples': {
        'initial': _sample(first.single),
        if (later.isNotEmpty) 'followup': _sample(later.single),
      },
      'site_security_verified': null,
      'full_readability_verified': null,
      'whole_source_unavailable_verified': null,
      'current_rule_validity_verified': null,
    };
  }
  return EightSourceLedgerEvidence(rows);
}

void _verifyFields(Map raw, Map snapshot) {
  const fields = {
    'searchUrl',
    'ruleSearch',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
  };
  final hashes = snapshot['raw_field_sha256'] as Map;
  _require(
    hashes.length == fields.length && hashes.keys.toSet().containsAll(fields),
    'eight-source raw field set mismatch',
  );
  for (final field in fields) {
    final value = raw[field];
    final actual = value is String ? _textSha(value) : _objectSha(value);
    _require(hashes[field] == actual, 'eight-source raw field mismatch');
  }
}

Map<String, Object?> _sample(Map sample) => {
  'outcome': sample['outcome'],
  if (sample.containsKey('started_at_utc'))
    'started_at_utc': sample['started_at_utc'],
  if (sample.containsKey('completed_at_utc'))
    'completed_at_utc': sample['completed_at_utc'],
  'steps': (sample['steps'] as List).cast<Map>().map(_step).toList(),
};

Map<String, Object?> _step(Map step) {
  final observation = step['observation'] as Map;
  final analysis = step['analysis'] as Map? ?? const {};
  const fields = {
    'book_count',
    'query_matches',
    'books_with_category',
    'toc_chapter_count',
    'detail_present',
    'detail_category_length',
    'content_characters',
    'content_sha256_utf8',
    'same_host_next_content_links',
    'same_host_toc_links',
  };
  return {
    'stage': observation['phase'],
    'started_at_utc': observation['started_at'],
    'observed_at_utc': observation['observed_at'],
    'status': observation['http_status'],
    'failure': observation['failure'],
    'content_type_family': observation['content_type_family'],
    'sample_bytes': observation['sample_bytes'],
    'sample_sha256': observation['sample_sha256'],
    'sample_truncated': observation['truncated'],
    'url_path_sha256': observation['url_path_sha256'],
    for (final field in fields)
      if (analysis.containsKey(field)) field: analysis[field],
    if (analysis.containsKey('safe_matching_books'))
      'matching_results_after_limited_url_text_prefilter':
          analysis['safe_matching_books'],
    if (analysis['category_diag'] is Map) ...{
      'og_category_nonempty':
          (analysis['category_diag'] as Map)['og_category_nonempty'],
      'category_matches_og':
          (analysis['category_diag'] as Map)['engine_matches_og'],
    },
  };
}

/// Index and source identity must both match; comparisons remain observational.
List<Map<String, Object?>> selectEightSourceEvidence(
  EightSourceLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) {
  final identity = _identities[selectedIndex];
  if (identity == null ||
      source.id != identity.$1 ||
      source.endpoint.host != identity.$2) {
    return [];
  }
  final row = evidence._rows[selectedIndex];
  if (row == null) return [];
  return [
    {
      ...row,
      'matches_current_selected_raw_record': true,
      'matches_current_source_kind': source.kind == BookKind.text,
      'matches_current_source_format': source.format == BookFormat.html,
      'matches_current_full_endpoint':
          _textSha(source.endpoint.toString()) ==
          row['historical_endpoint_sha256'],
      'matches_current_normalized_legado_rule':
          source.legado != null &&
          legadoSourceFingerprint(source.legado!) ==
              row['historical_normalized_legado_sha256'],
    },
  ];
}
