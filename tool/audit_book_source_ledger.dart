// Recompute an offline ledger from the bundled catalog and prior audit metadata.
// This program never executes a source rule, reads user data, or uses network I/O.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';
import 'package:zero_player/features/supervision/domain/adult_source_evidence.dart';
import 'package:zero_player/features/supervision/domain/content_classification.dart';

const _catalogFolder = 'assets/catalogs/books/legado';
const _evidenceFolder = 'docs/implementation';
const _head = 'legado-host-audit-20261115.json';
const _recheck = 'legado-host-recheck-20261115.json';
const _targeted = 'legado-targeted-rechecks-20261115.json';
const _fqxs = 'legado-fqxs-soft404-20261115.json';
const _iqiyi = 'legado-iqiyi-manhua-recheck-20261115.json';
const _adult = 'legado-adult-homepages-20261115.json';
const _otherSites = 'legado-jjmh-635k-recheck-20261115.json';
const _listRecheck = 'legado-blocklist-malware-recheck-20261115.json';
const _registry = 'legado-rdap-sample-20261115.json';
const _blocklist = 'legado-blocklistproject-evidence-20261115.json';
const _certpl = 'certpl-legado-evidence-20261115.json';
const _evalTriage = 'legado-eval-triage-20261115.json';
const _responseTriage = 'legado-response-eval-triage-20261115.json';
const _localTriage = 'legado-local-eval-review-20261115.json';
const _searchPilot = 'legado-static-search-pilot-20261115.json';
const _amsiClusters = 'legado-amsi-template-clusters-20261115.json';
const _amsi4qo = 'legado-amsi-recheck-4qo-20261115.json';
const _amsi4qoDecoded = 'legado-amsi-recheck-4qo-decoded-20261115.json';
const _amsiFiles = [
  'legado-amsi-pilot-20261115.json',
  'legado-amsi-prior-html-20261115.json',
  'legado-amsi-other-hosts-20261115.json',
];
const _evidenceFiles = [
  _head,
  _recheck,
  _targeted,
  _fqxs,
  _iqiyi,
  _adult,
  _otherSites,
  _listRecheck,
  _registry,
  _blocklist,
  _certpl,
  _evalTriage,
  _responseTriage,
  _localTriage,
  _searchPilot,
  _amsiClusters,
  _amsi4qo,
  _amsi4qoDecoded,
  ..._amsiFiles,
];
const _codePaths = [
  'lib/core/network/cancellation_token.dart',
  'lib/core/network/document_client.dart',
  'lib/core/network/document_encoding.dart',
  'lib/core/network/header_policy.dart',
  'lib/core/network/lan_access_policy.dart',
  'lib/core/network/media_http_client.dart',
  'lib/core/network/network_budget.dart',
  'lib/core/network/network_target_policy.dart',
  'lib/core/network/request_scheduler.dart',
  'lib/core/network/request_trace.dart',
  'lib/features/sources/data/jsonc_decoder.dart',
  'lib/features/sources/domain/source_diagnostics.dart',
  'lib/features/sources/domain/source_name.dart',
  'lib/features/sources/domain/video_source.dart',
  'lib/features/books/data/book_import.dart',
  'lib/features/books/data/book_source_links.dart',
  'lib/features/books/data/legado/legado_import.dart',
  'lib/features/books/data/legado/legado_discovery.dart',
  'lib/features/books/data/legado/legado_request.dart',
  'lib/features/books/data/legado/legado_rule_tokens.dart',
  'lib/features/books/domain/book.dart',
  'lib/features/books/domain/book_source_risk.dart',
  'lib/features/books/domain/iqiyi_legacy_quarantine.dart',
  'lib/features/books/domain/taotaoshu_legacy_quarantine.dart',
  'lib/features/books/domain/legado_source_fingerprint.dart',
  'lib/features/books/domain/known_untrusted_book_rules.dart',
  'lib/features/books/domain/legado_source.dart',
  'lib/features/books/domain/legado_source_fixes.dart',
  'lib/features/books/domain/kuwo_legacy_source_fix.dart',
  'lib/features/books/domain/qq_reading_legacy_source_fix.dart',
  'lib/features/books/domain/yuque_legacy_source_fix.dart',
  'lib/features/books/domain/zhongyi_legacy_source_fix.dart',
  'lib/features/books/domain/jingzhi_legacy_source_fix.dart',
  'lib/features/books/domain/shubang_legacy_source_fix.dart',
  'lib/features/books/domain/yingyu_legacy_source_fix.dart',
  'lib/features/supervision/domain/content_classification.dart',
  'lib/features/supervision/domain/adult_source_evidence.dart',
  'tool/audit_book_source_ledger.dart',
];

String _sha(List<int> bytes) => sha256.convert(bytes).toString();
String _sourceSha(String path) =>
    _sha(utf8.encode(File(path).readAsStringSync().replaceAll('\r\n', '\n')));

/// The lockfile is tracked as LF text but may be checked out with CRLF.
/// All other inputs retain their original bytes for evidence reproducibility.
String inputFingerprint(String path, List<int> bytes) => path == 'pubspec.lock'
    ? _sha(utf8.encode(utf8.decode(bytes).replaceAll('\r\n', '\n')))
    : _sha(bytes);

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

/// A prior observation is relevant only to the exact selected endpoint host
/// and an identity explicitly linked by the prior record indices or source ID.
final class HostObservation {
  HostObservation(this.host, this.ids, this.indices, this.observation);
  final String host;
  final Set<String> ids;
  final Set<int> indices;
  final Map<String, Object?> observation;

  bool matches(BookSource source, Set<int> sourceIndices) =>
      host == source.endpoint.host &&
      (ids.contains(source.id) || indices.any(sourceIndices.contains));
}

String _pathScope(Uri endpoint, String path) {
  if (!endpoint.hasQuery &&
      (endpoint.path == path || (endpoint.path.isEmpty && path == '/'))) {
    return 'endpoint_path';
  }
  if (path == '/') return 'endpoint_host_root';
  return 'endpoint_host_other_path';
}

String _failureCategory(Object? value) {
  if (value is! String || value.isEmpty) return 'unknown';
  final lower = value.toLowerCase();
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return 'timeout';
  }
  if (lower.contains('non_public') || lower.contains('non-public')) {
    return 'non_public_address_rejected';
  }
  if (lower.contains('dns') || lower.contains('getaddrinfo')) {
    return 'dns_error';
  }
  if (lower.contains('tls') ||
      lower.contains('ssl') ||
      lower.contains('cert')) {
    return 'tls_error';
  }
  if (lower.contains('redirect')) return 'redirect_not_followed';
  if (lower.contains('http_status')) return 'http_status';
  if (lower.contains('empty_html')) return 'empty_html';
  if (lower.contains('non_html') || lower.contains('encoded')) {
    return 'non_html_or_encoded';
  }
  if (lower.contains('connection') || lower.contains('transport')) {
    return 'connection_or_transport_error';
  }
  return 'other_or_unrecorded';
}

bool? _textClue(Map row, Map sample, String sampleKey, String visibleKey) {
  final visible = row['visible_text_clues'];
  final values = [
    if (sample[sampleKey] is List) sample[sampleKey] as List,
    if (visible is Map && visible[visibleKey] is List)
      visible[visibleKey] as List,
  ];
  return values.isEmpty ? null : values.any((items) => items.isNotEmpty);
}

/// This is a clue in the reviewed homepage description, not a site-wide or
/// per-book verdict. Missing descriptions remain unknown.
bool? homepageDescriptionAdult(Object? description) {
  if (description is! String || description.trim().isEmpty) return null;
  return adultBookLabels(description, '') ||
      adultContent(description) ||
      RegExp(r'成人(?:黄色|黃色|連載|连载)?(?:小说|小說)').hasMatch(description);
}

/// Only a fixed list of metadata fields is copied. Page text, title, redirect
/// targets, headers, and raw diagnostic messages are deliberately omitted.
Map<String, Object?> networkObservation({
  required String evidence,
  required String method,
  required String path,
  required Map row,
  Uri? endpoint,
}) {
  final status = row['http_status'] ?? row['status'];
  final sample = row['sample'] is Map ? row['sample'] as Map : const {};
  final classification = row['classification'];
  final failure =
      row['failure'] ??
      row['error'] ??
      (classification is String && !classification.startsWith('http_')
          ? classification
          : null);
  final outcome = status is int
      ? 'http_response_recorded'
      : failure != null
      ? 'no_http_response_recorded'
      : 'status_and_failure_not_recorded';
  return {
    'evidence': evidence,
    'method': method,
    'path': path,
    if (endpoint != null) 'path_relation': _pathScope(endpoint, path),
    'observed_at': row['observed_at'] ?? row['sample_observed_at'],
    'http_status': status is int ? status : null,
    'response_recorded': status is int,
    'outcome': outcome,
    'failure_category': failure == null ? null : _failureCategory(failure),
    'sample_bytes': row['sample_bytes'] ?? sample['sample_bytes'],
    'sample_sha256': row['sample_sha256'],
    'sample_truncated': row['truncated'],
    'adult_text_clue_recorded': _textClue(
      row,
      sample,
      'adult_signals',
      'adult_explicit',
    ),
    'gambling_text_clue_recorded': _textClue(
      row,
      sample,
      'betting_signals',
      'gambling',
    ),
    'photography_or_sexy_text_clue_recorded': _textClue(
      row,
      sample,
      'photography_or_sexy',
      'photography_or_sexy',
    ),
    if (row['clue_basis'] == 'reviewed_homepage_description')
      'adult_text_clue_basis': 'reviewed_homepage_description',
  };
}

Map<String, Object?> _amsiObservation(String evidence, Map row) {
  final root = row['amsi'];
  final inline = row['inline_scripts'];
  final samples = inline is Map
      ? inline['samples'] ?? inline['scanned_samples']
      : null;
  final sampleList = samples is List ? samples : const [];
  final inlineClassifications = [
    for (final sample in sampleList.whereType<Map>())
      if (sample['amsi'] is Map) (sample['amsi'] as Map)['classification'],
  ];
  final inlineDetected = inlineClassifications.contains('detected')
      ? true
      : inlineClassifications.contains('not_detected')
      ? false
      : null;
  final classification = root is Map ? root['classification'] : null;
  return {
    'evidence': evidence,
    'observed_at': row['sample_observed_at'],
    'root_scan_classification': classification ?? 'not_scanned_or_unknown',
    'root_sample_bytes': row['sample_bytes'],
    'root_sample_sha256': row['sample_sha256'],
    'root_sample_truncated': row['truncated'],
    'inline_samples': sampleList.length,
    'inline_samples_omitted': inline is Map
        ? inline['inline_scripts_omitted']
        : null,
    'inline_detection_recorded': inlineDetected,
  };
}

/// Split every listed-domain signal separately: group-level labels alone can
/// hide extra rule-field references attached to an endpoint match.
Map<String, List<Map<String, Object?>>> communityClues(
  Map evidence,
  BookSource source,
  int currentSelectedIndex,
) {
  final separated = <String, List<Map<String, Object?>>>{
    'exact_endpoint': [],
    'listed_parent_of_endpoint': [],
    'other_fields_only': [],
  };
  final categories = (evidence['comparison'] as Map)['categories'] as Map;
  for (final category in categories.entries) {
    final groups =
        (category.value as Map)['selected_sources_by_relation'] as Map;
    for (final rows in groups.values) {
      for (final row in (rows as List).whereType<Map>()) {
        if (row['source_id'] != source.id ||
            row['source_endpoint_host'] != source.endpoint.host) {
          continue;
        }
        final historicalIndex = row['selected_record_index'];
        if (historicalIndex is! int) {
          throw const FormatException(
            'community clue missing selected record index',
          );
        }
        for (final signal in (row['signals'] as List).whereType<Map>()) {
          final host = signal['catalog_host'];
          final listed = signal['listed_domain'];
          final fields = (signal['fields'] as List).cast<String>();
          final isEndpoint =
              fields.contains('selected_imported_host') &&
              host == source.endpoint.host;
          final relation = isEndpoint && signal['relation'] == 'exact'
              ? 'exact_endpoint'
              : isEndpoint && signal['relation'] == 'listed_parent'
              ? 'listed_parent_of_endpoint'
              : 'other_fields_only';
          separated[relation]!.add({
            'category': category.key,
            'observed_host': host,
            'listed_domain': listed,
            'list_relation': signal['relation'],
            'fields': fields,
            'historical_selected_record_index': historicalIndex,
            'matches_current_selected_record':
                historicalIndex == currentSelectedIndex,
          });
        }
      }
    }
  }
  return separated;
}

Map<String, bool> communityReviewFlags(
  Map<String, List<Map<String, Object?>>> clues,
) => {
  for (final entry in clues.entries) ...{
    'community_${entry.key}_current_selected_raw': entry.value.any(
      (clue) => clue['matches_current_selected_record'] == true,
    ),
    'community_${entry.key}_other_historical_raw': entry.value.any(
      (clue) => clue['matches_current_selected_record'] == false,
    ),
  },
};

List<Map<String, Object?>> ruleReviewEvidence(
  Map<String, Map> data,
  BookSource source,
  int selectedIndex,
) => [
  for (final file in [_evalTriage, _responseTriage, _localTriage])
    for (final profile in (data[file]!['source_profiles'] as List).cast<Map>())
      if (profile['source_id'] == source.id &&
          profile['host'] == source.endpoint.host)
        {
          'evidence': file,
          'historical_raw_selected_record_index':
              profile['selected_record_index'],
          'matches_current_selected_raw_record':
              profile['selected_record_index'] == selectedIndex,
          'classification': profile['classification'],
          'selected_record_has_evidence':
              profile['selected_record_has_evidence'],
          'raw_field_digests': [
            for (final entry
                in ((profile['evidence'] as List?) ?? const []).cast<Map>())
              if (entry['record_index'] == profile['selected_record_index'])
                {
                  'field': entry['field'],
                  'sha256': entry['field_sha256'],
                  'category': entry['category'],
                },
            for (final entry
                in ((profile['checked_fields'] as List?) ?? const [])
                    .cast<Map>())
              {'field': entry['field'], 'sha256': entry['field_sha256']},
          ],
        },
];

/// These are bounded synthetic-query search or discovery observations, not a
/// claim that detail, chapter, reading, current content, or security works.
List<Map<String, Object?>> searchPilotObservations(
  Map evidence,
  BookSource source,
  int selectedIndex,
) {
  final preflights = (evidence['initial_preflight'] as List).cast<Map>().where(
    (row) => row['id'] == source.id && row['host'] == source.endpoint.host,
  );
  if (preflights.length != 1) return [];
  final preflight = preflights.single;
  final results = (evidence['initial_parser_results'] as List).cast<Map>();
  final observed = (evidence['initial_observations'] as List).cast<Map>().where(
    (row) => row['id'] == source.id && row['host'] == source.endpoint.host,
  );
  if (observed.length != 1) {
    throw const FormatException('search pilot observation is ambiguous');
  }
  final parsed = results.where((row) => row['id'] == source.id).toList();
  if (parsed.length > 1) {
    throw const FormatException('search pilot parser result is ambiguous');
  }
  final sample = observed.single;
  final selectedMatches = preflight['selected_index'] == selectedIndex;
  final output = <Map<String, Object?>>[
    {
      'evidence': _searchPilot,
      'observation_kind': 'initial_synthetic_search',
      'historical_selected_record_index': preflight['selected_index'],
      'matches_current_selected_raw_record': selectedMatches,
      'observed_at': sample['observed_at'],
      'http_status': sample['http_status'],
      'failure_category': sample['failure'] == null
          ? null
          : _failureCategory(sample['failure']),
      'sample_bytes': sample['sample_bytes'],
      'sample_sha256': sample['sample_sha256'],
      'sample_truncated': sample['truncated'],
      'parser_result_recorded': parsed.isNotEmpty,
      'row_count': parsed.isEmpty ? null : parsed.single['row_count'],
      'books': parsed.isEmpty ? null : parsed.single['books'],
      'same_host_books': parsed.isEmpty
          ? null
          : parsed.single['same_host_books'],
      'keyword_matches': parsed.isEmpty
          ? null
          : parsed.single['keyword_matches'],
      'historical_search_rule_sha256': preflight['search_sha256'],
      'historical_search_list_rule_sha256': preflight['search_list_sha256'],
    },
  ];
  final followup = evidence['myxzm_followup'] as Map;
  if (followup['source_id'] != source.id) return output;
  if (followup['selected_record_index'] != preflight['selected_index']) {
    throw const FormatException(
      'search follow-up selected record does not match',
    );
  }
  output.addAll(_searchPilotFollowup(followup, selectedMatches));
  return output;
}

List<Map<String, Object?>> _searchPilotFollowup(
  Map followup,
  bool selectedMatches,
) {
  final output = <Map<String, Object?>>[];
  for (final entry in [
    (
      'repeated_search_observation',
      'repeated_synthetic_search',
      'old_search_counts',
    ),
    ('form_observation', 'synthetic_form_search', 'form_old_search_counts'),
    ('category_observation', 'discovery_novel_ranking', 'old_category_counts'),
  ]) {
    final sample = followup[entry.$1] as Map;
    final counts = followup[entry.$3] as Map;
    output.add({
      'evidence': _searchPilot,
      'observation_kind': entry.$2,
      'historical_selected_record_index': followup['selected_record_index'],
      'matches_current_selected_raw_record': selectedMatches,
      'observed_at': sample['observed_at'],
      'http_status': sample['http_status'],
      'sample_bytes': sample['sample_bytes'],
      'sample_sha256': sample['sample_sha256'],
      'sample_truncated': sample['truncated'],
      'old_rule_rows': counts['old_rows'] ?? counts['old_list_rows'],
      'old_rule_rows_with_name':
          counts['rows_with_name'] ?? counts['old_name_rows'],
      'old_rule_rows_with_link':
          counts['rows_with_link'] ?? counts['old_link_rows'],
      'old_rule_discovery_books': counts['actual_discovery_books'],
    });
  }
  final comic = followup['comic_search_experiment_original'] as Map;
  output.add({
    'evidence': _searchPilot,
    'observation_kind': 'experimental_comic_selector_not_novel_search',
    'historical_selected_record_index': followup['selected_record_index'],
    'matches_current_selected_raw_record': selectedMatches,
    'observed_at':
        (followup['repeated_search_observation'] as Map)['observed_at'],
    'comic_rows': comic['row_count'],
    'comic_books': comic['actual_engine_books'],
    'comic_same_host_books': comic['same_host_books'],
    'comic_keyword_matches': comic['keyword_matches'],
  });
  return output;
}

final class _Catalog {
  _Catalog(
    this.imported,
    this.rows,
    this.selectedIndex,
    this.indicesByIdentity,
  );
  final BookSourceImport imported;
  final List rows;
  final Map<String, int> selectedIndex;
  final Map<String, Set<int>> indicesByIdentity;
}

String _identity(String id, String host) => '$id\x00$host';

/// The importer may only add adult evidence after choosing a source version.
bool selectedVersionMatches(BookSource selected, BookSource imported) {
  if (selected.id != imported.id ||
      (selected.adultEvidence && !imported.adultEvidence)) {
    return false;
  }
  final expected = selected.toJson()..remove('adultEvidence');
  final actual = imported.toJson()..remove('adultEvidence');
  return _objectSha(expected) == _objectSha(actual);
}

_Catalog _readCatalog(Map manifest, List<int> compressed) {
  if (_sha(compressed) != manifest['archiveSha256']) {
    throw const FormatException('catalog archive SHA-256 mismatch');
  }
  final archive =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(compressed))) as Map;
  final rows = archive['records'] as List;
  if (rows.length != manifest['records']) {
    throw const FormatException('catalog record count mismatch');
  }
  final parsedRows = <int, BookSource>{};
  final indices = <String, Set<int>>{};
  for (var index = 0; index < rows.length; index++) {
    try {
      final source = parseBookSourceRecord(rows[index]);
      parsedRows[index] = source;
      indices
          .putIfAbsent(_identity(source.id, source.endpoint.host), () => {})
          .add(index);
    } on Object {
      // Rejections are reported separately by the production importer below.
    }
  }
  final memberships = archive['packs'] as Map;
  final references = <int>[];
  final selected = <String, int>{};
  final versions = <String, int>{};
  for (final pack in manifest['packs'] as List) {
    final refs = (memberships[pack['id']] as List).cast<int>();
    if (refs.length != pack['count'] ||
        refs.any((i) => i < 0 || i >= rows.length)) {
      throw const FormatException('invalid catalog pack references');
    }
    references.addAll(refs);
    for (final index in refs) {
      final source = parsedRows[index];
      if (source == null) continue;
      final previous = versions[source.id];
      if (previous == null || source.updatedAt > previous) {
        selected[source.id] = index;
        versions[source.id] = source.updatedAt;
      }
    }
  }
  final actual = parseBookSourceRecords(references.map((index) => rows[index]));
  if (actual.sources.length != selected.length ||
      actual.sources.any((source) => !selected.containsKey(source.id))) {
    throw const FormatException(
      'selected source indices do not match importer',
    );
  }
  for (final source in actual.sources) {
    final index = selected[source.id]!;
    if (!selectedVersionMatches(parsedRows[index]!, source)) {
      throw FormatException(
        'selected source version differs: ${source.id}, record $index',
      );
    }
  }
  return _Catalog(actual, rows, selected, indices);
}

Set<int> _indices(Object? value) =>
    value is List ? value.whereType<int>().toSet() : {};
Set<String> _ids(Object? value) =>
    value is List ? value.whereType<String>().toSet() : {};

final class _EvidenceIndex {
  final network = <String, List<HostObservation>>{};
  final amsi = <String, List<HostObservation>>{};
  final registry = <String, List<HostObservation>>{};

  void add(
    Map<String, List<HostObservation>> destination,
    String host,
    Set<String> ids,
    Set<int> indices,
    Map<String, Object?> value,
  ) {
    if (host.isEmpty || (ids.isEmpty && indices.isEmpty)) return;
    destination
        .putIfAbsent(host, () => [])
        .add(HostObservation(host, ids, indices, value));
  }
}

void _addHead(_EvidenceIndex index, String file, Map row, {Map? measurement}) {
  final host = row['host'] as String;
  final observed = measurement ?? row;
  final ids = _ids(row['selected_source_ids']);
  final indices = _indices(row['record_indices']);
  final path = (row['path'] as String?) ?? '/';
  final head = Map.of(observed)..remove('sample');
  index.add(
    index.network,
    host,
    ids,
    indices,
    networkObservation(evidence: file, method: 'HEAD', path: path, row: head),
  );
  final sample = observed['sample'];
  if (sample is Map) {
    index.add(
      index.network,
      host,
      ids,
      indices,
      networkObservation(
        evidence: file,
        method: 'GET',
        path: path,
        row: {...sample, 'sample': sample},
      ),
    );
  }
}

void _addGet(
  _EvidenceIndex index,
  String file,
  Map row,
  Set<String> ids,
  Set<int> indices, {
  String path = '/',
  bool includeAmsi = false,
}) {
  final host = row['host'] as String;
  index.add(
    index.network,
    host,
    ids,
    indices,
    networkObservation(evidence: file, method: 'GET', path: path, row: row),
  );
  if (includeAmsi) {
    index.add(index.amsi, host, ids, indices, _amsiObservation(file, row));
  }
}

_EvidenceIndex _readEvidence(Map<String, Map> data) {
  final index = _EvidenceIndex();
  _addRootChecks(index, data);
  _addAmsiRechecks(index, data);
  _addIqiyiChecks(index, data[_iqiyi]!);
  _addTargetedChecks(index, data);
  _addRegistryChecks(index, data[_registry]!);
  return index;
}

void _addAmsiRechecks(_EvidenceIndex index, Map<String, Map> data) {
  for (final row in (data[_amsiClusters]!['results'] as List).cast<Map>()) {
    _addGet(
      index,
      _amsiClusters,
      row,
      _ids(row['selected_source_ids']),
      _indices(row['record_indices']),
      includeAmsi: true,
    );
  }
  for (final file in [_amsi4qo, _amsi4qoDecoded]) {
    final row = data[file]!;
    _addGet(
      index,
      file,
      row,
      _ids(row['selected_source_ids']),
      _indices(row['record_indices']),
      includeAmsi: true,
    );
  }
}

void _addRootChecks(_EvidenceIndex index, Map<String, Map> data) {
  for (final row in (data[_head]!['results'] as List).cast<Map>()) {
    _addHead(index, _head, row);
  }
  for (final row in (data[_recheck]!['results'] as List).cast<Map>()) {
    _addHead(index, _recheck, row, measurement: row['recheck'] as Map);
  }
  for (final row in (data[_targeted]!['observations'] as List).cast<Map>()) {
    _addHead(index, _targeted, row);
  }
  for (final row in (data[_fqxs]!['results'] as List).cast<Map>()) {
    _addHead(index, _fqxs, row);
  }
  for (final file in _amsiFiles) {
    for (final row in (data[file]!['results'] as List).cast<Map>()) {
      _addGet(
        index,
        file,
        row,
        _ids(row['selected_source_ids']),
        _indices(row['record_indices']),
        includeAmsi: true,
      );
    }
  }
}

void _addIqiyiChecks(_EvidenceIndex index, Map iqiyi) {
  final iqiyiSources = (iqiyi['iqiyi_legacy_rules'] as Map)['sources'] as List;
  final iqiyiIds = {
    for (final row in iqiyiSources.cast<Map>()) row['source_id'] as String,
  };
  for (final row in (iqiyi['iqiyi_observations'] as List).cast<Map>()) {
    final host = row['host'] as String;
    index.add(
      index.network,
      host,
      iqiyiIds,
      {},
      networkObservation(
        evidence: _iqiyi,
        method: row['method'] as String,
        path: row['path'] as String,
        row: row,
      ),
    );
  }
  for (final group in (iqiyi['other_candidates'] as List).cast<Map>()) {
    final ids = {
      for (final row in (group['selected_sources'] as List).cast<Map>())
        row['source_id'] as String,
    };
    for (final row
        in ((group['observations'] as List?) ?? const []).cast<Map>()) {
      final host = row['host'] as String;
      index.add(
        index.network,
        host,
        ids,
        {},
        networkObservation(
          evidence: _iqiyi,
          method: row['method'] as String,
          path: row['path'] as String,
          row: row,
        ),
      );
    }
  }
}

void _addTargetedChecks(_EvidenceIndex index, Map<String, Map> data) {
  for (final row in (data[_adult]!['results'] as List).cast<Map>()) {
    final ids = {
      for (final item in (row['sources'] as List).cast<Map>())
        item['id'] as String,
    };
    final common = {'observed_at': row['observed_at_utc']};
    final host = row['host'] as String;
    final adultClue = homepageDescriptionAdult(row['description_excerpt']);
    for (final method in ['HEAD', 'GET']) {
      index.add(
        index.network,
        host,
        ids,
        {},
        networkObservation(
          evidence: _adult,
          method: method,
          path: '/',
          row: {
            ...common,
            'status': row[method == 'HEAD' ? 'head_status' : 'get_status'],
            if (method == 'GET') 'sample_bytes': row['sample_bytes'],
            if (method == 'GET') 'sample_sha256': row['sample_sha256'],
            if (method == 'GET' && adultClue != null)
              'visible_text_clues': {
                'adult_explicit': [if (adultClue) true],
              },
            if (method == 'GET' && adultClue != null)
              'clue_basis': 'reviewed_homepage_description',
          },
        ),
      );
    }
  }
  final siteData = data[_otherSites]!;
  for (final row in (siteData['results'] as List).cast<Map>()) {
    final host = row['host'] as String;
    final sourceRows = ((siteData['sources'] as Map)[host] as List).cast<Map>();
    _addGet(
      index,
      _otherSites,
      row,
      {for (final source in sourceRows) source['source_id'] as String},
      {for (final source in sourceRows) source['record_index'] as int},
    );
  }
  for (final row in (data[_listRecheck]!['observations'] as List).cast<Map>()) {
    final links =
        (row['list_linkage'] as Map)['selected_catalog_sources'] as List;
    _addGet(
      index,
      _listRecheck,
      row,
      {for (final item in links.cast<Map>()) item['source_id'] as String},
      _indices((row['list_linkage'] as Map)['catalog_record_indices']),
    );
  }
}

/// Only the queried endpoint hostname is eligible: registry-domain and
/// example.com control queries do not establish the state of a subdomain.
List<Map<String, Object?>> currentDohObservations(Map registry, String host) =>
    [
      for (final observation
          in (registry['current_public_doh_observations'] as List).cast<Map>())
        if (observation['host'] == host)
          {
            'evidence': _registry,
            'observation_kind': 'current_public_doh_exact_endpoint_host',
            'queried_host': host,
            'observed_at': observation['observed_at'],
            'provider': observation['provider'],
            'query_type': observation['query_type'],
            'dns_rcode': observation['dns_rcode'],
            'dnssec_authenticated': observation['dnssec_authenticated'],
            'classification': observation['classification'],
            'response_sha256': observation['response_sha256'],
          },
    ];

void _addRegistryChecks(_EvidenceIndex index, Map registry) {
  for (final candidate in (registry['candidates'] as List).cast<Map>()) {
    final host = candidate['old_endpoint_host'] as String;
    final sources = (candidate['selected_sources'] as List).cast<Map>();
    final ids = {for (final source in sources) source['id'] as String};
    final indices = _indices(candidate['raw_record_indices']);
    for (final observation
        in (candidate['rdap_observations'] as List).cast<Map>()) {
      index.add(index.registry, host, ids, indices, {
        'evidence': _registry,
        'observation_kind': 'rdap_registered_domain',
        'registry_domain': candidate['registry_domain'],
        'observed_at': observation['observed_at'],
        'http_status': observation['http_status'],
        'classification': observation['classification'],
      });
    }
    for (final observation
        in (candidate['previous_public_doh_observations'] as List)
            .cast<Map>()) {
      index.add(index.registry, host, ids, indices, {
        'evidence': _registry,
        'observation_kind': 'previous_public_doh_exact_endpoint_host',
        'queried_host': host,
        'observed_at': observation['observed_at'],
        'provider': observation['provider'],
        'query_type': observation['query_type'],
        'dns_rcode': observation['dns_rcode'],
        'dnssec_authenticated': observation['dnssec_authenticated'],
        'classification': observation['classification'],
      });
    }
    for (final observation in currentDohObservations(registry, host)) {
      index.add(index.registry, host, ids, indices, observation);
    }
  }
}

List<Map<String, Object?>> _matching(
  Map<String, List<HostObservation>> evidence,
  BookSource source,
  Set<int> indices, {
  bool addPathRelation = false,
}) => [
  for (final item
      in evidence[source.endpoint.host] ?? const <HostObservation>[])
    if (item.matches(source, indices))
      {
        ...item.observation,
        if (addPathRelation)
          'path_relation': _pathScope(
            source.endpoint,
            item.observation['path'] as String,
          ),
      },
];

String networkCoverage(List<Map<String, Object?>> observations) {
  if (observations.isEmpty) return 'no_observation';
  final responses = observations.any(
    (observation) => observation['response_recorded'] == true,
  );
  final noResponse = observations.any(
    (observation) => observation['outcome'] == 'no_http_response_recorded',
  );
  if (responses && noResponse) return 'response_and_no_response_recorded';
  if (responses) return 'response_recorded';
  if (noResponse) return 'no_response_recorded';
  return 'status_and_failure_not_recorded';
}

bool? amsiDetectionRecorded(List<Map<String, Object?>> observations) {
  if (observations.any(
    (row) =>
        row['root_scan_classification'] == 'detected' ||
        row['inline_detection_recorded'] == true,
  )) {
    return true;
  }
  if (observations.any(
    (row) =>
        row['root_scan_classification'] == 'not_detected' ||
        row['inline_detection_recorded'] == false,
  )) {
    return false;
  }
  return null;
}

bool? _recordedTextClue(List<Map<String, Object?>> observations, String key) {
  final checks = observations.map((row) => row[key]).whereType<bool>().toList();
  return checks.isEmpty ? null : checks.any((value) => value);
}

Map<String, Object?> _staticPolicy(BookSource source) {
  final hosts = [source.endpoint.host, ...source.mediaHosts];
  final fixedHost = quarantinedBookHost(source.endpoint.host);
  final fixedMediaHosts = source.mediaHosts.where(quarantinedBookHost).toList()
    ..sort();
  final unsafe = knownUnsafeBookRule(source);
  final unavailable = knownUnavailableBookRule(source);
  final fixedOther =
      quarantinedBookSource(source) && !fixedHost && !unsafe && !unavailable;
  final textAdult =
      adultContent('${source.name} ${source.endpoint.host}') ||
      adultContent(source.group, category: true);
  final knownAdultHosts =
      hosts
          .where((host) => adultBookHost(host) || knownAdultHost(host))
          .toSet()
          .toList()
        ..sort();
  return {
    'adult_source_classified': adultBookSource(source),
    'adult_by_label': adultBookLabels(source.name, source.group),
    'adult_by_bundled_id': adultBundledSourceId(source.id),
    'adult_evidence_merged': source.adultEvidence,
    'adult_by_text_policy': textAdult,
    'known_adult_hosts': knownAdultHosts,
    'fixed_endpoint_host_quarantine': fixedHost,
    'fixed_media_host_quarantines': fixedMediaHosts,
    'fixed_untrusted_rule': unsafe,
    'fixed_unavailable_rule': unavailable,
    'fixed_other_exact_source_quarantine': fixedOther,
    'fixed_orphan_history_id': quarantinedBookSourceId(source.id),
  };
}

Map<String, Object?> _row(
  BookSource source,
  _Catalog catalog,
  _EvidenceIndex evidence,
  Map<String, Map> data,
) {
  final index = catalog.selectedIndex[source.id]!;
  final indices =
      catalog.indicesByIdentity[_identity(source.id, source.endpoint.host)] ??
      <int>{};
  final network = _matching(
    evidence.network,
    source,
    indices,
    addPathRelation: true,
  );
  final amsi = _matching(evidence.amsi, source, indices);
  final registry = _matching(evidence.registry, source, indices);
  final community = communityClues(data[_blocklist]!, source, index);
  final ruleReview = ruleReviewEvidence(data, source, index);
  final searchPilot = searchPilotObservations(
    data[_searchPilot]!,
    source,
    index,
  );
  return {
    'source_id': source.id,
    'name': source.name,
    'kind': source.kind.name,
    'format': source.format.name,
    'endpoint_host': source.endpoint.host,
    'endpoint_sha256': _sha(utf8.encode(source.endpoint.toString())),
    'endpoint_has_query': source.endpoint.hasQuery,
    'selected_record_index': index,
    'related_same_id_and_endpoint_host_record_indices': indices.toList()
      ..sort(),
    'selected_raw_record_canonical_sha256': _objectSha(catalog.rows[index]),
    'normalized_source_canonical_sha256': _objectSha(source.toJson()),
    'normalized_legado_canonical_sha256': source.legado == null
        ? null
        : legadoSourceFingerprint(source.legado!),
    'static_policy': _staticPolicy(source),
    'network_coverage': networkCoverage(network),
    'network_observations': network,
    'amsi_observations': amsi,
    'registry_and_doh_observations': registry,
    'community_list_clues': community,
    'historical_raw_rule_review': ruleReview,
    'search_and_discovery_observations': searchPilot,
    'review_clues': {
      'amsi_detection_recorded': amsiDetectionRecorded(amsi),
      ...communityReviewFlags(community),
      'adult_text_clue_recorded': _recordedTextClue(
        network,
        'adult_text_clue_recorded',
      ),
      'gambling_text_clue_recorded': _recordedTextClue(
        network,
        'gambling_text_clue_recorded',
      ),
      'photography_or_sexy_text_clue_recorded': _recordedTextClue(
        network,
        'photography_or_sexy_text_clue_recorded',
      ),
      'historical_selected_raw_network_eval_evidence': ruleReview.any(
        (row) =>
            row['matches_current_selected_raw_record'] == true &&
            row['classification'] == 'network_data_to_eval' &&
            row['selected_record_has_evidence'] != false,
      ),
    },
  };
}

void _verifyArchiveAssociation(
  String file,
  Map evidence,
  String digest,
  Map<String, String> inputHashes,
) {
  if (file == _amsiClusters) {
    final scans = (evidence['source_scans'] as List).cast<Map>();
    if (scans.isEmpty ||
        scans.any(
          (row) =>
              row['archive_sha256'] != digest ||
              inputHashes['$_evidenceFolder/${row['file']}'] != row['sha256'],
        )) {
      throw const FormatException('AMSI cluster input association mismatch');
    }
    return;
  }
  if (file == _amsi4qo || file == _amsi4qoDecoded) {
    if (evidence['prior_result_file_sha256'] !=
        inputHashes['$_evidenceFolder/${_amsiFiles[1]}']) {
      throw const FormatException('4qo recheck input association mismatch');
    }
    return;
  }
  final associated = switch (file) {
    _iqiyi => (evidence['inputs'] as Map)['catalog_archive_sha256'],
    _listRecheck =>
      (evidence['list_evidence'] as Map)['catalog_archive_sha256'],
    _registry => (evidence['inputs'] as Map)['archive_sha256'],
    _blocklist => (evidence['catalog'] as Map)['archive_sha256'],
    _certpl => (evidence['catalog'] as Map)['archive_sha256'],
    _searchPilot => (evidence['inputs'] as Map)['catalog_archive_sha256'],
    _ => evidence['archive_sha256'],
  };
  if (associated != digest) {
    throw FormatException('evidence archive mismatch: $file');
  }
}

Map<String, int> _summary(List<Map<String, Object?>> sources) {
  int count(bool Function(Map<String, Object?>) predicate) =>
      sources.where(predicate).length;
  bool policy(Map<String, Object?> row, String key) =>
      (row['static_policy'] as Map)[key] == true;
  bool clue(Map<String, Object?> row, String key) =>
      (row['review_clues'] as Map)[key] == true;
  return {
    'selected_sources': sources.length,
    'adult_source_classified': count(
      (row) => policy(row, 'adult_source_classified'),
    ),
    'fixed_untrusted_rule': count((row) => policy(row, 'fixed_untrusted_rule')),
    'fixed_unavailable_rule': count(
      (row) => policy(row, 'fixed_unavailable_rule'),
    ),
    'fixed_endpoint_host_quarantine': count(
      (row) => policy(row, 'fixed_endpoint_host_quarantine'),
    ),
    'fixed_other_exact_source_quarantine': count(
      (row) => policy(row, 'fixed_other_exact_source_quarantine'),
    ),
    'amsi_detection_recorded': count(
      (row) => clue(row, 'amsi_detection_recorded'),
    ),
    'amsi_completed_without_detection_in_sample': count(
      (row) => (row['review_clues'] as Map)['amsi_detection_recorded'] == false,
    ),
    'amsi_unknown_or_unscanned': count(
      (row) => (row['review_clues'] as Map)['amsi_detection_recorded'] == null,
    ),
    for (final relation in [
      'exact_endpoint',
      'listed_parent_of_endpoint',
      'other_fields_only',
    ])
      for (final provenance in ['current_selected_raw', 'other_historical_raw'])
        'community_${relation}_$provenance': count(
          (row) => clue(row, 'community_${relation}_$provenance'),
        ),
    'photography_or_sexy_text_clue_recorded': count(
      (row) => clue(row, 'photography_or_sexy_text_clue_recorded'),
    ),
    'historical_selected_raw_network_eval_evidence': count(
      (row) => clue(row, 'historical_selected_raw_network_eval_evidence'),
    ),
    'sources_with_search_or_discovery_observation': count(
      (row) => (row['search_and_discovery_observations'] as List).isNotEmpty,
    ),
    for (final state in [
      'no_observation',
      'no_response_recorded',
      'status_and_failure_not_recorded',
      'response_recorded',
      'response_and_no_response_recorded',
    ])
      'network_$state': count((row) => row['network_coverage'] == state),
  };
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart tool/audit_book_source_ledger.dart OUTPUT');
    exitCode = 64;
    return;
  }
  final output = File(args.single);
  if (output.existsSync()) throw const FormatException('output already exists');
  final codeHashes = {for (final path in _codePaths) path: _sourceSha(path)};
  final inputBytes = <String, List<int>>{
    '$_catalogFolder/manifest.json': File(
      '$_catalogFolder/manifest.json',
    ).readAsBytesSync(),
    '$_catalogFolder/catalog.json.bz2': File(
      '$_catalogFolder/catalog.json.bz2',
    ).readAsBytesSync(),
    'pubspec.lock': File('pubspec.lock').readAsBytesSync(),
    for (final file in _evidenceFiles)
      '$_evidenceFolder/$file': File(
        '$_evidenceFolder/$file',
      ).readAsBytesSync(),
  };
  final hashes = {
    for (final entry in inputBytes.entries)
      entry.key: inputFingerprint(entry.key, entry.value),
  };
  final manifest =
      jsonDecode(utf8.decode(inputBytes['$_catalogFolder/manifest.json']!))
          as Map;
  final compressed = inputBytes['$_catalogFolder/catalog.json.bz2']!;
  final catalog = _readCatalog(manifest, compressed);
  final data = <String, Map>{};
  for (final file in _evidenceFiles) {
    final evidence =
        jsonDecode(utf8.decode(inputBytes['$_evidenceFolder/$file']!)) as Map;
    _verifyArchiveAssociation(file, evidence, _sha(compressed), hashes);
    data[file] = evidence;
  }
  if (((data[_certpl]!['comparison'] as Map)['matches'] as List).isNotEmpty) {
    throw const FormatException(
      'CERT Polska matches require a reviewed relation adapter',
    );
  }
  final evidence = _readEvidence(data);
  final rows = [
    for (final source in catalog.imported.sources)
      _row(source, catalog, evidence, data),
  ];
  rows.sort(
    (a, b) => (a['source_id'] as String).compareTo(b['source_id'] as String),
  );
  for (final entry in codeHashes.entries) {
    if (_sourceSha(entry.key) != entry.value) {
      throw FormatException('source changed during audit: ${entry.key}');
    }
  }
  for (final entry in hashes.entries) {
    if (inputFingerprint(entry.key, File(entry.key).readAsBytesSync()) !=
        entry.value) {
      throw FormatException('input changed during audit: ${entry.key}');
    }
  }
  final summary = _summary(rows);
  final result = _ledgerDocument(
    catalog,
    data,
    hashes,
    codeHashes,
    rows,
    summary,
  );
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
  );
  stdout.writeln(jsonEncode(summary));
  stdout.writeln('wrote ${output.path}');
}

Map<String, Object?> _ledgerDocument(
  _Catalog catalog,
  Map<String, Map> data,
  Map<String, String> hashes,
  Map<String, String> codeHashes,
  List<Map<String, Object?>> rows,
  Map<String, int> summary,
) => {
  'schema_version': 1,
  'scope':
      'Offline bundled catalog only; existing evidence is linked by source ID, exact endpoint host and record references. No rules, page scripts, network, or user database are accessed.',
  'source_digest_convention':
      'SHA-256 of UTF-8 source files with CRLF normalized to LF; JSON object digests use recursively sorted map keys and preserved list order.',
  'input_digest_convention':
      'SHA-256 of original input bytes, except pubspec.lock is decoded as UTF-8 and CRLF is normalized to LF both when recording and checking for changes.',
  'limitations': [
    'The evidence is time-limited and may describe root or other paths instead of the complete current source workflow.',
    'HTTP response, no response, AMSI non-detection, and a community list entry are observations or review clues, not safety, maliciousness, adult-content or permanent-closure verdicts.',
    'Community list field references are historical selected records and are not promoted to endpoint matches; a changed selected record is explicitly marked.',
    'Community list relation groups describe each signal, so a source with an endpoint hit may also have a separate other-field-only signal.',
    'Rule triage describes historical raw record fields; import-time repairs can change the normalized rules, so it is not a current execution verdict.',
    'Synthetic-query search and discovery results are separate observations and do not establish a working reading chain or security.',
    'Static flags do not include personal settings, enabled state, mutable assessments, user blacklists, supervision, or every private repository policy.',
    'Same-ID historical cache can lack the rule fingerprint needed to attribute old content to a specific source version.',
    'No search-detail-chapter-content chain is verified by this ledger.',
    'Only the listed formal evidence inputs are included; other local or untracked rechecks are not incorporated.',
  ],
  'input_sha256': hashes,
  'normalized_source_code_sha256': codeHashes,
  'community_inputs': {
    'block_list_project_revision':
        (data[_blocklist]!['source'] as Map)['revision'],
    'cert_polska_observed_at': (data[_certpl]!['source'] as Map)['observed_at'],
    'cert_polska_matching_host_indicator_pairs':
        (data[_certpl]!['comparison'] as Map)['matching_host_indicator_pairs'],
  },
  'formal_amsi_rechecks_without_selected_source_match': [
    for (final file in [_amsi4qo, _amsi4qoDecoded])
      if (!rows.any(
        (row) => (row['amsi_observations'] as List).whereType<Map>().any(
          (observation) => observation['evidence'] == file,
        ),
      ))
        {
          'evidence': file,
          'host': data[file]!['host'],
          'record_indices': data[file]!['record_indices'],
          'reason': 'no_selected_source_identity_matches_exact_host',
        },
  ],
  'import_summary': {
    'archive_raw_records': catalog.rows.length,
    'selected_unique_sources': catalog.imported.sources.length,
    'duplicate_pack_records': catalog.imported.duplicates,
    'rejected_pack_records': catalog.imported.rejected,
    'rejection_reasons': catalog.imported.issues,
  },
  'overlapping_summary': summary,
  'sources': rows,
};
