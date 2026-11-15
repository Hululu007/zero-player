// Exact-source, time-bounded reading observations. No network or rule runs.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const sfwxEvidenceFile = 'legado-sfwx-repair-20261116.json';
const sfwxEvidenceSha =
    '2b9679fbb2f5b823af0cd10ff771862e04a618fb839c7931842ad921f211b6c0';
const _canonicalEvidenceSha =
    '5f3eb2de91596930a8c39ef1a51ee8e3f80778c0116731a0e03d97deb78219da';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _ledger = 'docs/implementation/legado-source-ledger-20261115.json';
const _ledgerSha =
    'fb6b8ace9e42eed5ab9756cb3a35d115a83466479b1946e968afe13306aee8c6';
const _head = 'docs/implementation/legado-unresolved-head-later-20261116.json';
const _headSha =
    '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd';
const _commit = 'f7b5697d49fdc5113274e5add45a1108638957c5';

const _expected = {
  4760: (
    '0723af128aa8adacd3e3a9efe03b622fa660d2f78a21b72cbe2bfe7d32ce8b75',
    'www.sfwx.com',
    'b91ea60260f819a4d31198672593d844caaaee381918419a46888814190ad411',
  ),
  3002: (
    'ad35798f5b42bac39ba862133be63224081484921a86a8e8e6b5570e65ca63a3',
    'www.biquge7.xyz',
    'e0768b6f273fc63bb1f09fc7bfb2514b749a3d15f0eb934bf797c1f6cdfac7cf',
  ),
  2578: (
    '926a302f72881a7c6488555dfd0779da9db89c7f1ae35fbb14fbaaa9846caa43',
    'www.b520.cc',
    'fc3ddc6cb8e9c568200327d1d360ba7fad42e88a698abb18b57147f8c536b2f8',
  ),
};

void _require(bool condition, String reason) {
  if (!condition) throw FormatException(reason);
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
String _key(String id, String host) => '$id\x00$host';

void verifySfwxInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['inputs'] as Map;
  _require(
    hashes['docs/implementation/$sfwxEvidenceFile'] == sfwxEvidenceSha &&
        _objectSha(evidence) == _canonicalEvidenceSha &&
        archiveSha == _archiveSha &&
        inputs['archive_path'] == _archive &&
        inputs['archive_sha256'] == _archiveSha &&
        inputs['historical_git_commit'] == _commit &&
        inputs['historical_ledger_path'] == _ledger &&
        inputs['historical_ledger_sha256'] == _ledgerSha &&
        inputs['historical_head_path'] == _head &&
        inputs['historical_head_sha256'] == _headSha,
    'sfwx evidence, archive or historical references mismatch',
  );
}

final class SfwxLedgerEvidence {
  final _reading = <String, List<Map<String, Object?>>>{};
}

SfwxLedgerEvidence readSfwxEvidence(
  Map evidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifySfwxInput(evidence, hashes[_archive] ?? '', hashes);
  final history = verifiedHistoricalGitObject({
    'git_commit': _commit,
    'path': _ledger,
    'sha256': _ledgerSha,
  }, _ledger);
  final previousHead = verifiedHistoricalGitObject({
    'git_commit': _commit,
    'path': _head,
    'sha256': _headSha,
  }, _head);
  _require(
    (history['input_sha256'] as Map)[_archive] == _archiveSha,
    'sfwx historical ledger archive mismatch',
  );
  final oldSources = (history['sources'] as List).cast<Map>();
  final heads = (previousHead['results'] as List).cast<Map>();
  final sources = (evidence['sources'] as List).cast<Map>();
  _require(sources.length == _expected.length, 'sfwx source count mismatch');
  final output = SfwxLedgerEvidence();
  final seen = <int>{};
  for (final snapshot in sources) {
    final index = snapshot['record_index'];
    _require(
      index is int && _expected.containsKey(index) && seen.add(index),
      'sfwx selected index mismatch',
    );
    _require(
      index >= 0 && index < rawRecords.length,
      'sfwx index out of range',
    );
    final source = parseBookSourceRecord(rawRecords[index]);
    final expected = _expected[index]!;
    final matches = oldSources
        .where((row) => row['source_id'] == expected.$1)
        .toList();
    final headMatches = heads
        .where((row) => row['host'] == expected.$2)
        .toList();
    _require(
      matches.length == 1 && headMatches.length == 1,
      'sfwx historical selection not unique',
    );
    final old = matches.single;
    final head = headMatches.single['latest_head'] as Map;
    final raw = rawRecords[index] as Map;
    _require(
      source.id == expected.$1 &&
          source.endpoint.host == expected.$2 &&
          snapshot['source_id'] == expected.$1 &&
          snapshot['endpoint_host'] == expected.$2 &&
          snapshot['historical_legado_sha256'] == expected.$3 &&
          old['source_id'] == expected.$1 &&
          old['endpoint_host'] == expected.$2 &&
          old['selected_record_index'] == index &&
          old['selected_raw_record_canonical_sha256'] ==
              snapshot['historical_raw_sha256'] &&
          _objectSha(raw) == snapshot['historical_raw_sha256'] &&
          old['normalized_legado_canonical_sha256'] == expected.$3 &&
          old['endpoint_sha256'] ==
              _sha(utf8.encode(source.endpoint.toString())) &&
          old['kind'] == source.kind.name &&
          old['format'] == source.format.name &&
          head['http_status'] == snapshot['prior_recovery_head_status'] &&
          head['observed_at'] == snapshot['prior_recovery_head_at_utc'],
      'sfwx historical identity, version or HEAD mismatch',
    );
    for (final entry in (snapshot['raw_field_sha256'] as Map).entries) {
      final value = raw[entry.key];
      final digest = value is String
          ? _sha(utf8.encode(value))
          : _objectSha(value);
      _require(digest == entry.value, 'sfwx historical raw field mismatch');
    }
    final samples = (evidence['observations'] as Map)['record_$index'] as Map;
    final method = evidence['method'] as Map;
    output._reading
        .putIfAbsent(_key(source.id, source.endpoint.host), () => [])
        .add({
          'evidence': sfwxEvidenceFile,
          'observation_kind': 'bounded_historical_reading_sample',
          'historical_selected_record_index': index,
          'historical_raw_record_sha256': snapshot['historical_raw_sha256'],
          'historical_normalized_legado_sha256': expected.$3,
          'historical_endpoint_sha256': old['endpoint_sha256'],
          'historical_kind': old['kind'],
          'historical_format': old['format'],
          'http_method': method['http_method'],
          'redirects_followed': method['redirects_followed'],
          'post_sent': method['post_sent'],
          'scripts_executed': method['scripts_executed'],
          'subresources_loaded': method['subresources_loaded'],
          'prior_recovery_head_at_utc': snapshot['prior_recovery_head_at_utc'],
          'prior_recovery_head_status': snapshot['prior_recovery_head_status'],
          'samples': _redact(samples),
          'site_security_verified': null,
          'full_readability_verified': null,
          'whole_source_unavailable_verified': null,
          'current_rule_validity_verified': null,
        });
  }
  return output;
}

/// Whitelist only the already redacted measurements, never page data or URLs.
Object? _redact(Object? input) {
  const fields = {
    'work_a',
    'work_b',
    'search',
    'detail',
    'toc',
    'chapter',
    'chapters',
    'detail_and_toc',
    'category_recheck',
    'detail_toc_content',
    'observed_at_utc',
    'observed_at_utc_role',
    'status',
    'sample_bytes',
    'sample_sha256',
    'truncated',
    'body_sampled',
    'books',
    'same_host_books',
    'title_and_author_match',
    'title_and_author_match_count',
    'old_details',
    'candidate_title_and_author_match',
    'candidate_toc_chapters',
    'candidate_toc_links',
    'old_and_candidate_detail_evaluated_at_utc',
    'content_sha256',
    'old_next_count',
    'old_next_unique_count',
    'old_next_matches_second_toc_chapter',
    'visible_next_page_anchors',
    'content_continuation_marker',
    'without_next_same_content_sha256',
    'without_next_links',
    'content_utf16_code_units',
    'story_character_clue',
    'nonempty_category_meta_count',
    'pipe_expression_output_length',
    'explicit_selector_output_length',
    'explicit_selector_contains_category_meta',
    'production_selector_evaluated_separately_on_saved_live_sample',
    'first_component_of_observed_three_selector_expression',
    'synthetic_exact_adult_label_preserved',
    'synthetic_ordinary_label_preserved',
  };
  if (input is Map) {
    return {
      for (final entry in input.entries)
        if (fields.contains(entry.key))
          entry.key as String: _redact(entry.value),
    };
  }
  if (input is List) return input.map(_redact).toList();
  return input;
}

List<Map<String, Object?>> selectSfwxEvidence(
  SfwxLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) => [
  for (final item
      in evidence._reading[_key(source.id, source.endpoint.host)] ??
          const <Map<String, Object?>>[])
    {
      ...item,
      'matches_current_selected_raw_record':
          item['historical_selected_record_index'] == selectedIndex,
      'matches_current_source_kind':
          item['historical_kind'] == source.kind.name,
      'matches_current_source_format':
          item['historical_format'] == source.format.name,
      'matches_current_full_endpoint':
          item['historical_endpoint_sha256'] ==
          _sha(utf8.encode(source.endpoint.toString())),
      'matches_current_normalized_legado_rule':
          source.legado != null &&
          item['historical_normalized_legado_sha256'] ==
              legadoSourceFingerprint(source.legado!),
    },
];
