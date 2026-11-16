// Offline association of one bounded historical category sample.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const jhsssdEvidenceFile = 'legado-jhsssd-category-recheck-20261116.json';
const jhsssdEvidenceSha =
    '1c6c3974a4c321af8dc9d1321b227c823980d047785fa0af035110b4c7c80431';
const _canonicalEvidenceSha =
    'b8cc24dd538e3286d32e07054aa542c2be24c55073aa15454c5e2e1a9a41bb48';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _historyCommit = '3454dc75b61d5f1156fc7d577d061b01f0dd6a91';
const _historyPath = 'docs/implementation/legado-source-ledger-20261115.json';
const _historySha =
    '2ad2348ab2d2435297d8d6cc04625b62ee07d1c198d8fd70fc7b73b9b79b5e87';
const _id = '3ea17136a0ff8e7ece79d304346edb613c2230e4c0ce806a0003e4a9b102dcc5';
const _host = 'm.jhsssd.com';
const _endpoint = 'https://m.jhsssd.com';
const _oldRule =
    '022794ec9f9953e5468daf7c04e4cec7797bc49d50c28e7fe17f473272a193a3';
const _candidateRule =
    '14abaed50f2c2546b6404056b9980533b5d0709064a641415ed9dc3d4573c598';

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

void verifyJhsssdInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['inputs'] as Map;
  _require(
    hashes['docs/implementation/$jhsssdEvidenceFile'] == jhsssdEvidenceSha &&
        _objectSha(evidence) == _canonicalEvidenceSha &&
        archiveSha == _archiveSha &&
        inputs['archive_path'] == _archive &&
        inputs['archive_sha256'] == _archiveSha &&
        inputs['historical_commit'] == _historyCommit &&
        inputs['historical_ledger_path'] == _historyPath &&
        inputs['historical_ledger_sha256'] == _historySha,
    'jhsssd evidence, archive or historical reference mismatch',
  );
}

final class JhsssdLedgerEvidence {
  const JhsssdLedgerEvidence(this._reading);
  final Map<String, Object?> _reading;
}

JhsssdLedgerEvidence readJhsssdEvidence(
  Map evidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyJhsssdInput(evidence, hashes[_archive] ?? '', hashes);
  final history = verifiedHistoricalGitObject({
    'git_commit': _historyCommit,
    'path': _historyPath,
    'sha256': _historySha,
  }, _historyPath);
  _require(
    (history['input_sha256'] as Map)[_archive] == _archiveSha &&
        rawRecords.length > 4651,
    'jhsssd historical ledger or archive mismatch',
  );
  final matching = (history['sources'] as List)
      .cast<Map>()
      .where((row) => row['source_id'] == _id)
      .toList();
  _require(matching.length == 1, 'jhsssd historical source not unique');
  final old = matching.single;
  final raw = rawRecords[4651] as Map;
  final source = parseBookSourceRecord(raw);
  final snapshot = evidence['source'] as Map;
  _require(
    source.id == _id &&
        source.endpoint.toString() == _endpoint &&
        source.sourceKey.isEmpty &&
        source.kind == BookKind.text &&
        source.format == BookFormat.html &&
        snapshot['id'] == _id &&
        snapshot['host'] == _host &&
        snapshot['index'] == 4651 &&
        snapshot['source_key'] == '' &&
        snapshot['kind'] == 'text' &&
        snapshot['format'] == 'html' &&
        snapshot['old_legado_canonical_sha256'] == _oldRule &&
        snapshot['candidate_legado_canonical_sha256'] == _candidateRule &&
        old['selected_record_index'] == 4651 &&
        old['endpoint_host'] == _host &&
        old['kind'] == 'text' &&
        old['format'] == 'html' &&
        old['normalized_legado_canonical_sha256'] == _oldRule &&
        old['selected_raw_record_canonical_sha256'] ==
            snapshot['raw_record_canonical_sha256'] &&
        _objectSha(raw) == snapshot['raw_record_canonical_sha256'] &&
        old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
        snapshot['endpoint_sha256'] == _sha(utf8.encode(_endpoint)),
    'jhsssd identity, endpoint, raw record or historical rule mismatch',
  );
  _verifyFields(raw, snapshot);
  final before =
      (evidence['observations'] as Map)['pre_repair_two_works'] as Map;
  final after = (evidence['observations'] as Map)['candidate_two_works'] as Map;
  final oldWorks = (before['works'] as List).cast<Map>();
  final newWorks = (after['works'] as List).cast<Map>();
  _require(oldWorks.length == 2 && newWorks.length == 2, 'jhsssd sample count');
  final works = <Map<String, Object?>>[];
  for (var i = 0; i < 2; i++) {
    works.add(_work(oldWorks[i], newWorks[i]));
  }
  return JhsssdLedgerEvidence({
    'evidence': jhsssdEvidenceFile,
    'observation_kind': 'bounded_historical_reading_and_category_samples',
    'historical_selected_record_index': 4651,
    'historical_raw_record_sha256': snapshot['raw_record_canonical_sha256'],
    'historical_normalized_legado_sha256': _oldRule,
    'candidate_normalized_legado_sha256': _candidateRule,
    'historical_endpoint_sha256': snapshot['endpoint_sha256'],
    'historical_source_key': '',
    'historical_kind': 'text',
    'historical_format': 'html',
    'http_method': 'GET',
    'redirects_followed': false,
    'post_sent': false,
    'scripts_executed': false,
    'subresources_loaded': false,
    'samples': {
      'search_before': _step(before['search'] as Map),
      'search_candidate': _step(after['search'] as Map),
      'works': works,
      'synthetic_policy_tests_are_not_site_observations': true,
    },
    'site_security_verified': null,
    'full_readability_verified': null,
    'whole_source_unavailable_verified': null,
    'current_rule_validity_verified': null,
  });
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
    'jhsssd raw field set mismatch',
  );
  for (final field in fields) {
    final value = raw[field];
    final actual = value is String
        ? _sha(utf8.encode(value))
        : _objectSha(value);
    _require(hashes[field] == actual, 'jhsssd raw field mismatch');
  }
}

Map<String, Object?> _work(Map old, Map candidate) {
  final oldDetail = old['detail'] as Map;
  final newDetail = candidate['detail'] as Map;
  final oldContent = old['content'] as Map;
  final newContent = candidate['content'] as Map;
  final before = oldDetail['analysis'] as Map;
  final after = newDetail['analysis'] as Map;
  _require(
    old['outcome'] == 'content_sample' &&
        candidate['outcome'] == 'content_sample' &&
        before['detail_category_length'] == 0 &&
        (after['detail_category_length'] as int) > 0 &&
        (after['category_diag'] as Map)['engine_matches_og'] == true &&
        (oldDetail['observation'] as Map)['sample_sha256'] ==
            (newDetail['observation'] as Map)['sample_sha256'] &&
        (oldContent['observation'] as Map)['sample_sha256'] ==
            (newContent['observation'] as Map)['sample_sha256'],
    'jhsssd paired sample mismatch',
  );
  return {
    'detail_before': _step(oldDetail),
    'detail_candidate': _step(newDetail),
    'content_before': _step(oldContent),
    'content_candidate': _step(newContent),
  };
}

Map<String, Object?> _step(Map step) {
  final observation = step['observation'] as Map;
  final analysis = step['analysis'] as Map? ?? const {};
  const fields = {
    'book_count',
    'query_matches',
    'books_with_category',
    'toc_chapter_count',
    'detail_category_length',
    'content_characters',
    'content_sha256_utf8',
    'same_host_next_content_links',
    'next_links_equal_sampled_toc_chapter',
    'next_links_match_split_path_pattern',
  };
  return {
    'stage': observation['phase'],
    'observed_at_utc': observation['observed_at'],
    'status': observation['http_status'],
    'sample_bytes': observation['sample_bytes'],
    'sample_sha256': observation['sample_sha256'],
    'sample_truncated': observation['truncated'],
    for (final field in fields)
      if (analysis.containsKey(field)) field: analysis[field],
    if (analysis['category_diag'] is Map)
      'category_matches_og':
          (analysis['category_diag'] as Map)['engine_matches_og'],
  };
}

List<Map<String, Object?>> selectJhsssdEvidence(
  JhsssdLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) {
  if (source.id != _id || source.endpoint.host != _host) return [];
  return [
    {
      ...evidence._reading,
      'matches_current_selected_raw_record': selectedIndex == 4651,
      'matches_current_source_kind': source.kind == BookKind.text,
      'matches_current_source_format': source.format == BookFormat.html,
      'matches_current_full_endpoint': source.endpoint.toString() == _endpoint,
      'matches_current_normalized_legado_rule':
          source.legado != null &&
          legadoSourceFingerprint(source.legado!) == _oldRule,
    },
  ];
}
