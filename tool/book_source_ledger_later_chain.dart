// Bounded historical reading/category observations; no network or rule runs.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const sfwx3984EvidenceFile = 'legado-sfwx-3984-recheck-20261116.json';
const sfwx3984EvidenceSha =
    '11cda92bb9e7f165d795b66786c16531c5367727deb4f68c47ce4b97762f6ba0';
const biquge7EvidenceFile = 'legado-biquge7-category-recheck-20261116.json';
const biquge7EvidenceSha =
    '46e24be60ca2667cd3d45d2d78d7289ce77976342e4b4a34a6e013e52a162a31';

const _canonicalDigests = {
  sfwx3984EvidenceFile:
      'cf3519094656c7485ba91cc7b04efafde6af46ad462e2544f83ce954358413ff',
  biquge7EvidenceFile:
      'f8c4cd6eac50fc47f8475545a0af23ecd99dff03d580e76dbe0d237e39915bfd',
};
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _commit = '42aa119be000a20f0220f8c35a17530c449e0ee7';
const _history = <String, (String, String)>{
  'ledger': (
    'docs/implementation/legado-source-ledger-20261115.json',
    '6877424859528319f67848af741f07ccff66bde782905fd2d1e0712c53e5f0dc',
  ),
  'head': (
    'docs/implementation/legado-unresolved-head-later-20261116.json',
    '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd',
  ),
  'prior_pilot': (
    'docs/implementation/legado-sfwx-repair-20261116.json',
    '2b9679fbb2f5b823af0cd10ff771862e04a618fb839c7931842ad921f211b6c0',
  ),
};
// Source ID, host, sourceKey, full endpoint, and historical Legado digest.
const _expected = <int, (String, String, String, String, String)>{
  3984: (
    '9f004a19d12200c68d88fd5bafd4d34615b347d27e26322dbfa26142983cd295',
    'www.sfwx.com',
    '',
    'https://www.sfwx.com/',
    '338b1507f045152f1795bbfb75b95f68bca074ea40f39ccb42cb08cbed5e238a',
  ),
  828: (
    '03ce53f0b6632695058a7553e513b103e5aae06c34979992769d32e06af05fa8',
    'www.biquge7.xyz',
    'biquge7.xyz#%23@%E9%81%87%E7%9F%A5',
    'https://www.biquge7.xyz/',
    '0a48023c241f6f1f78c6864403ae3fa68db2f8b877be0fa3981b3fd5cd1f8914',
  ),
  3002: (
    'ad35798f5b42bac39ba862133be63224081484921a86a8e8e6b5570e65ca63a3',
    'www.biquge7.xyz',
    '',
    'https://www.biquge7.xyz/',
    'e0768b6f273fc63bb1f09fc7bfb2514b749a3d15f0eb934bf797c1f6cdfac7cf',
  ),
  2578: (
    '926a302f72881a7c6488555dfd0779da9db89c7f1ae35fbb14fbaaa9846caa43',
    'www.b520.cc',
    '',
    'https://www.b520.cc/',
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

void verifyLaterChainInput(
  String file,
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final expectedBytes = switch (file) {
    sfwx3984EvidenceFile => sfwx3984EvidenceSha,
    biquge7EvidenceFile => biquge7EvidenceSha,
    _ => throw const FormatException('unknown later-chain evidence'),
  };
  final inputs = evidence['inputs'] as Map;
  final references = inputs['historical_files'] as Map;
  _require(
    hashes['docs/implementation/$file'] == expectedBytes &&
        _objectSha(evidence) == _canonicalDigests[file] &&
        archiveSha == _archiveSha &&
        inputs['archive_path'] == _archive &&
        inputs['archive_sha256'] == _archiveSha &&
        inputs['historical_commit'] == _commit &&
        references.length == _history.length,
    'later-chain evidence, archive or historical references mismatch',
  );
  for (final entry in _history.entries) {
    final reference = references[entry.key] as Map;
    _require(
      reference['path'] == entry.value.$1 &&
          reference['sha256'] == entry.value.$2,
      'later-chain historical reference mismatch',
    );
  }
}

final class LaterChainLedgerEvidence {
  final _reading = <String, List<Map<String, Object?>>>{};
}

LaterChainLedgerEvidence readLaterChainEvidence(
  Map sfwx,
  Map categories,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyLaterChainInput(
    sfwx3984EvidenceFile,
    sfwx,
    hashes[_archive] ?? '',
    hashes,
  );
  verifyLaterChainInput(
    biquge7EvidenceFile,
    categories,
    hashes[_archive] ?? '',
    hashes,
  );
  final historical = <String, Map>{};
  for (final entry in _history.entries) {
    historical[entry.key] = verifiedHistoricalGitObject({
      'git_commit': _commit,
      'path': entry.value.$1,
      'sha256': entry.value.$2,
    }, entry.value.$1);
  }
  final ledger = historical['ledger']!;
  _require(
    (ledger['input_sha256'] as Map)[_archive] == _archiveSha,
    'later-chain historical ledger archive mismatch',
  );
  final snapshots = <int, (Map, String)>{};
  final sfwxSource = sfwx['source'] as Map;
  _require(sfwxSource['index'] == 3984, 'later-chain sfwx index mismatch');
  snapshots[3984] = (sfwxSource, sfwx3984EvidenceFile);
  for (final source in (categories['sources'] as List).cast<Map>()) {
    final index = source['index'];
    _require(
      index is int &&
          {828, 3002, 2578}.contains(index) &&
          !snapshots.containsKey(index),
      'later-chain category source index mismatch',
    );
    snapshots[index] = (source, biquge7EvidenceFile);
  }
  _require(
    snapshots.length == _expected.length,
    'later-chain source count mismatch',
  );
  final oldSources = (ledger['sources'] as List).cast<Map>();
  final heads = (historical['head']!['results'] as List).cast<Map>();
  final output = LaterChainLedgerEvidence();
  for (final entry in snapshots.entries) {
    final index = entry.key;
    final (snapshot, file) = entry.value;
    _require(
      index >= 0 && index < rawRecords.length,
      'later-chain index out of range',
    );
    final raw = rawRecords[index] as Map;
    final source = parseBookSourceRecord(raw);
    final expected = _expected[index]!;
    final oldMatches = oldSources
        .where((row) => row['source_id'] == expected.$1)
        .toList();
    final headMatches = heads
        .where((row) => row['host'] == expected.$2)
        .toList();
    _require(
      oldMatches.length == 1 && headMatches.length == 1,
      'later-chain historical identity not unique',
    );
    final old = oldMatches.single;
    final head = headMatches.single['latest_head'] as Map;
    _verifySource(index, snapshot, raw, source, old, head, expected);
    final samples = _samplesFor(
      index,
      snapshot,
      sfwx,
      categories,
      historical['prior_pilot']!,
    );
    final method =
        (file == sfwx3984EvidenceFile ? sfwx : categories)['method'] as Map;
    output._reading
        .putIfAbsent(_key(source.id, source.endpoint.host), () => [])
        .add(_readingObservation(index, file, snapshot, old, method, samples));
  }
  return output;
}

Map<String, Object?> _readingObservation(
  int index,
  String file,
  Map snapshot,
  Map old,
  Map method,
  Map<String, Object?> samples,
) => {
  'evidence': file,
  'observation_kind': index == 2578
      ? 'bounded_historical_search_path_samples'
      : 'bounded_historical_reading_and_category_samples',
  'historical_selected_record_index': index,
  'historical_raw_record_sha256': snapshot['raw_record_canonical_sha256'],
  'historical_normalized_legado_sha256': _expected[index]!.$5,
  'historical_endpoint_sha256': snapshot['endpoint_sha256'],
  'historical_kind': old['kind'],
  'historical_format': old['format'],
  'historical_source_key': _expected[index]!.$3,
  'http_method': 'GET',
  'redirects_followed': method['redirects_followed'],
  'post_sent': method['posts_sent'],
  'scripts_executed':
      method['source_js_executed'] == true ||
      method['page_js_executed'] == true,
  'subresources_loaded': method['subresources_requested'],
  'prior_recovery_head_at_utc': snapshot['prior_head_observed_at_utc'],
  'prior_recovery_head_status': snapshot['prior_head_status'],
  if (index == 828 || index == 3002) ...{
    'shared_category_sample_collected_by_source_id': _expected[828]!.$1,
    'shared_category_sample_collected_by_record_index': 828,
  },
  'samples': _redact(samples),
  'site_security_verified': null,
  'full_readability_verified': null,
  'whole_source_unavailable_verified': null,
  'current_rule_validity_verified': null,
};

void _verifySource(
  int index,
  Map snapshot,
  Map raw,
  BookSource source,
  Map old,
  Map head,
  (String, String, String, String, String) expected,
) {
  _require(
    source.id == expected.$1 &&
        source.endpoint.host == expected.$2 &&
        source.sourceKey == expected.$3 &&
        source.endpoint.toString() == expected.$4 &&
        source.kind == BookKind.text &&
        source.format == BookFormat.html &&
        snapshot['id'] == expected.$1 &&
        snapshot['host'] == expected.$2 &&
        snapshot['source_key'] == expected.$3 &&
        snapshot['kind'] == 'text' &&
        snapshot['format'] == 'html' &&
        snapshot['old_legado_canonical_sha256'] == expected.$5 &&
        old['source_id'] == expected.$1 &&
        old['endpoint_host'] == expected.$2 &&
        old['selected_record_index'] == index &&
        old['kind'] == 'text' &&
        old['format'] == 'html' &&
        old['normalized_legado_canonical_sha256'] == expected.$5 &&
        old['selected_raw_record_canonical_sha256'] ==
            snapshot['raw_record_canonical_sha256'] &&
        _objectSha(raw) == snapshot['raw_record_canonical_sha256'] &&
        old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
        snapshot['endpoint_sha256'] == _sha(utf8.encode(expected.$4)) &&
        head['http_status'] == snapshot['prior_head_status'] &&
        head['observed_at'] == snapshot['prior_head_observed_at_utc'],
    'later-chain historical identity, endpoint, rule or HEAD mismatch',
  );
  const fields = {
    'searchUrl',
    'ruleSearch',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
  };
  final fieldsMap = snapshot['raw_field_sha256'] as Map;
  _require(
    fieldsMap.length == fields.length &&
        fieldsMap.keys.toSet().containsAll(fields),
    'later-chain raw field set mismatch',
  );
  for (final entry in fieldsMap.entries) {
    final value = raw[entry.key];
    final digest = value is String
        ? _sha(utf8.encode(value))
        : _objectSha(value);
    _require(
      digest == entry.value,
      'later-chain historical raw field mismatch',
    );
  }
}

Map<String, Object?> _samplesFor(
  int index,
  Map snapshot,
  Map sfwx,
  Map categories,
  Map prior,
) {
  final observations = categories['observations'] as Map;
  if (index == 3984) {
    return Map<String, Object?>.from(sfwx['observations'] as Map);
  }
  if (index == 2578) {
    final old =
        ((prior['observations'] as Map)['record_2578'] as Map)['search'];
    final matches = (prior['sources'] as List)
        .cast<Map>()
        .where(
          (x) =>
              x['record_index'] == index &&
              x['source_id'] == _expected[index]!.$1,
        )
        .toList();
    final latest = observations['record_2578_search'] as Map;
    final requests = (latest['requests'] as List).cast<Map>();
    _require(
      matches.length == 1 &&
          matches.single['endpoint_host'] == _expected[index]!.$2 &&
          matches.single['historical_legado_sha256'] == _expected[index]!.$5 &&
          matches.single['historical_raw_sha256'] ==
              snapshot['raw_record_canonical_sha256'] &&
          _objectSha(old) ==
              _objectSha(observations['record_2578_previous_search']) &&
          (old as Map)['status'] == 404 &&
          requests.length == 1 &&
          requests.single['id'] == _expected[index]!.$1 &&
          requests.single['host'] == _expected[index]!.$2 &&
          requests.single['stage'] == 'books' &&
          requests.single['status'] == 404,
      'later-chain earlier 404 identity or observation mismatch',
    );
    return {
      'previous_search': old,
      'latest_search': observations['record_2578_search'],
    };
  }
  final category = observations['shared_category_check'] as Map;
  final selectedId = _expected[index]!.$1;
  final requests = (category['requests'] as List).cast<Map>();
  _require(
    requests.length == 2 &&
        requests.every(
          (row) =>
              row['id'] == _expected[828]!.$1 &&
              row['host'] == _expected[828]!.$2 &&
              row['status'] == 200,
        ),
    'later-chain shared-page request identity mismatch',
  );
  final results = (category['engine_results'] as List)
      .cast<Map>()
      .where((row) => row['id'] == selectedId)
      .toList();
  _require(results.length == 8, 'later-chain category sample count mismatch');
  return {
    if (index == 828) ...{
      'work_a': observations['record_828_work_a'],
      'work_b': observations['record_828_work_b'],
    },
    'shared_category_check': {
      'requests': category['requests'],
      'engine_results': results,
      'synthetic_label_mapping': category['synthetic_label_mapping'],
    },
  };
}

/// Whitelist redacted measurements; never copy page data, URLs, or queries.
Object? _redact(Object? input) {
  const fields = {
    'work_a',
    'work_b',
    'additional_chapter_samples',
    'shared_category_check',
    'previous_search',
    'latest_search',
    'requests',
    'engine_results',
    'synthetic_label_mapping',
    'restricted_label_a',
    'restricted_label_b',
    'ordinary_label',
    'id',
    'host',
    'stage',
    'observed_at_utc',
    'timeout_seconds',
    'sample_limit_bytes',
    'has_query',
    'status',
    'content_type',
    'content_encoding',
    'sample_bytes',
    'sample_sha256',
    'truncated',
    'body_sampled',
    'candidate',
    'books',
    'book_count',
    'same_host',
    'matching_title_and_author_count',
    'book_request_empty',
    'actual_title_rule_matches',
    'author_matches',
    'category_present',
    'category_meta_count',
    'category_matches_meta',
    'error_type',
    'known_error',
    'chapter_count',
    'chapter_request_empty',
    'next_toc_count',
    'content_utf16_code_units',
    'content_sha256',
    'next_content_count',
    'next_matches_second_chapter',
    'sampled_ordinal',
    'content_continuation_marker',
    'next_page_anchor_count',
    'next_chapter_anchor_count',
    'next_matches_next_toc_chapter',
    'synthetic_label',
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

List<Map<String, Object?>> selectLaterChainEvidence(
  LaterChainLedgerEvidence evidence,
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
