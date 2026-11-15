// A shared historical homepage follow-up, never a malware or safety verdict.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const lengmenEvidenceFile = 'legado-lengmen-amsi-recheck-20261116.json';
const lengmenEvidenceSha =
    '164231366b599573390b760af8d942da250ebe7aea5bf1e3616da8c22250578d';
const _canonicalSha =
    '188613f00ab2f91b097dd8d3038a36130dc972ce0bff9232485be9e2157d6819';
const _archivePath = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _commit = 'f7b5697d49fdc5113274e5add45a1108638957c5';
const _host = 'www.lengmen.org';
const _history = <String, (String, String)>{
  'ledger': (
    'docs/implementation/legado-source-ledger-20261115.json',
    'fb6b8ace9e42eed5ab9756cb3a35d115a83466479b1946e968afe13306aee8c6',
  ),
  'summary': (
    'docs/implementation/legado-amsi-summary-20261115.json',
    'b8a93e7b8fb78ca3bcf57f5748a7b50f67e32e14c8298776726f7779f81ecf67',
  ),
  'initial': (
    'docs/implementation/legado-amsi-other-hosts-20261115.json',
    '25180e804c1df15165af8bb20ae58c5b4dd6b2e24f6a0a092d50281ca5e25750',
  ),
  'clusters': (
    'docs/implementation/legado-amsi-template-clusters-20261115.json',
    '0aaff7d86529327f67ea09f741d62a00a0cf47a03a90175b982619beeed9de3e',
  ),
  'classification': (
    'docs/implementation/legado-amsi-source-classification-20261115.json',
    'd8a40945fa3875f65085d9fd210808aa8038f5d8a012495e8bf2bd68fe061180',
  ),
};
const _expected = <int, (String, String)>{
  450: (
    '5c5cc84bbd5019fd7fc40a5effcdf9adfddca60a2f4f6885b1eb034ad4da0a93',
    '98d3c34181b05187296b73cedf44c117088709673fc7d8bf4307fbfdcdcbd5dd',
  ),
  1921: (
    '47e709728d21b76a1156fd1a080dd45d8dc82c1a95f8e66359533ac4d336847e',
    '264c75aab9098fa2d643b6ef1db6174d91ca55a8d00c8b216fb5837decde112e',
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

void verifyLengmenInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['inputs'] as Map;
  final history = inputs['historical_files'] as Map;
  _require(
    hashes['docs/implementation/$lengmenEvidenceFile'] == lengmenEvidenceSha &&
        _objectSha(evidence) == _canonicalSha &&
        evidence['host'] == _host &&
        inputs['historical_git_commit'] == _commit &&
        inputs['archive_path'] == _archivePath &&
        archiveSha == _archiveSha &&
        inputs['archive_sha256'] == _archiveSha &&
        history.length == _history.length,
    'lengmen evidence or archive mismatch',
  );
  for (final entry in _history.entries) {
    final reference = history[entry.key] as Map;
    _require(
      reference['path'] == entry.value.$1 &&
          reference['sha256'] == entry.value.$2,
      'lengmen historical reference mismatch',
    );
  }
}

final class LengmenLedgerEvidence {
  final _observations = <String, List<Map<String, Object?>>>{};
}

LengmenLedgerEvidence readLengmenEvidence(
  Map evidence,
  Map<String, String> hashes,
  List rows,
) {
  verifyLengmenInput(evidence, hashes[_archivePath] ?? '', hashes);
  final objects = <String, Map>{};
  for (final entry in _history.entries) {
    objects[entry.key] = verifiedHistoricalGitObject({
      'git_commit': _commit,
      'path': entry.value.$1,
      'sha256': entry.value.$2,
    }, entry.value.$1);
  }
  final ledger = objects['ledger']!;
  _require(
    (ledger['input_sha256'] as Map)[_archivePath] == _archiveSha,
    'lengmen historical archive mismatch',
  );
  _verifyPrior(evidence, objects);
  final sources = (evidence['source_fingerprints'] as List).cast<Map>();
  _require(sources.length == 2, 'lengmen historical source count mismatch');
  final output = LengmenLedgerEvidence();
  final seen = <int>{};
  for (final snapshot in sources) {
    final index = snapshot['selected_record_index'];
    _require(
      index is int &&
          _expected.containsKey(index) &&
          seen.add(index) &&
          index >= 0 &&
          index < rows.length,
      'lengmen historical index mismatch',
    );
    final expected = _expected[index]!;
    final matches = (ledger['sources'] as List)
        .cast<Map>()
        .where((row) => row['source_id'] == expected.$1)
        .toList();
    final classified = (objects['classification']!['sources'] as List)
        .cast<Map>()
        .where(
          (row) => row['id'] == expected.$1 && row['endpoint_host'] == _host,
        )
        .toList();
    _require(
      matches.length == 1 && classified.length == 1,
      'lengmen historical source not unique',
    );
    final old = matches.single;
    final raw = rows[index] as Map;
    final current = parseBookSourceRecord(raw);
    _require(
      current.id == expected.$1 &&
          current.endpoint.host == _host &&
          current.kind.name == snapshot['kind'] &&
          current.format.name == snapshot['format'] &&
          snapshot['source_id'] == expected.$1 &&
          snapshot['normalized_legado_canonical_sha256'] == expected.$2 &&
          old['endpoint_host'] == _host &&
          old['kind'] == snapshot['kind'] &&
          old['format'] == snapshot['format'] &&
          old['selected_record_index'] == index &&
          old['normalized_legado_canonical_sha256'] == expected.$2 &&
          old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
          old['endpoint_sha256'] ==
              _sha(utf8.encode(current.endpoint.toString())) &&
          old['selected_raw_record_canonical_sha256'] ==
              snapshot['raw_record_canonical_sha256'] &&
          _objectSha(raw) == snapshot['raw_record_canonical_sha256'] &&
          _objectSha(old['related_same_id_and_endpoint_host_record_indices']) ==
              _objectSha(snapshot['historical_same_id_record_indices']) &&
          _objectSha(old['static_policy']) ==
              _objectSha(snapshot['historical_static_policy']) &&
          (classified.single['rule'] as Map)['normalized_legado_sha256'] ==
              snapshot['earlier_amsi_classification_legado_sha256_unsorted_json'],
      'lengmen historical source, raw record or rule mismatch',
    );
    for (final field in (snapshot['raw_field_sha256'] as Map).entries) {
      final value = raw[field.key];
      final digest = value is String
          ? _sha(utf8.encode(value))
          : _objectSha(value);
      _require(digest == field.value, 'lengmen raw field mismatch');
    }
    output._observations
        .putIfAbsent(_key(current.id, current.endpoint.host), () => [])
        .add({
          'evidence': lengmenEvidenceFile,
          'observation_kind': 'shared_host_bounded_engine_followup',
          'historical_selected_record_index': index,
          'historical_raw_record_sha256':
              snapshot['raw_record_canonical_sha256'],
          'historical_normalized_legado_sha256': expected.$2,
          'historical_endpoint_sha256': snapshot['endpoint_sha256'],
          'historical_kind': snapshot['kind'],
          'historical_format': snapshot['format'],
          'sampling_scope': 'one_host_root_one_network_environment',
          'same_host_observations_shared_by_two_sources': true,
          'independent_threat_count': null,
          'prior_observations_already_in_existing_amsi_records': true,
          'requests': _redact(evidence['observations']),
          'controls': _redact(evidence['controls']),
          'redirects_followed': false,
          'script_executed': false,
          'subresources_requested': false,
          'malware_verified': null,
          'false_positive_verified': null,
          'site_security_verified': null,
          'full_source_behavior_verified': null,
        });
  }
  return output;
}

void _verifyPrior(Map evidence, Map<String, Map> objects) {
  Map one(String name, String array) {
    final matches = (objects[name]![array] as List)
        .cast<Map>()
        .where((row) => row['host'] == _host)
        .toList();
    _require(matches.length == 1, 'lengmen prior host observation mismatch');
    return matches.single;
  }

  final initial = one('initial', 'results');
  final summary = one('summary', 'detection_observations');
  final cluster = one('clusters', 'results');
  final prior = evidence['prior'] as Map;
  final a = prior['initial'] as Map;
  final b = prior['cluster_recheck'] as Map;
  final ids = _expected.values.map((value) => value.$1).toSet();
  for (final item in [initial, summary, cluster]) {
    _require(
      (item['selected_source_ids'] as List).toSet().length == 2 &&
          (item['selected_source_ids'] as List).toSet().containsAll(ids),
      'lengmen prior selected source association mismatch',
    );
  }
  _require(
    _objectSha(initial['record_indices']) == _objectSha([450, 1921, 2318]) &&
        _objectSha(cluster['record_indices']) ==
            _objectSha([450, 1921, 2318]) &&
        a['observed_at_utc'] == initial['sample_observed_at'] &&
        a['sample_sha256'] == initial['sample_sha256'] &&
        a['sample_sha256'] == summary['sample_sha256'] &&
        _objectSha(a['html_amsi']) == _objectSha(initial['amsi']) &&
        b['observed_at_utc'] == cluster['sample_observed_at'] &&
        b['sample_sha256'] == cluster['sample_sha256'] &&
        b['shape_sha256'] == cluster['shape_sha256'] &&
        _objectSha(b['html_amsi']) == _objectSha(cluster['amsi']),
    'lengmen prior engine observation mismatch',
  );
  final requests = evidence['observations'] as List;
  _require(
    requests.length == 6 &&
        (requests.first as Map)['http_status'] == 302 &&
        (requests.first as Map)['redirect_target'] == 'unknown_not_captured',
    'lengmen unknown redirect or request count mismatch',
  );
}

/// Copy only redacted metrics, outcome codes, and study scope; no URL or text.
Object? _redact(Object? input) {
  const fields = {
    'kind',
    'observed_at_utc',
    'http_status',
    'redirect_target',
    'amsi',
    'hresult',
    'amsi_result',
    'classification',
    'sample_bytes',
    'sample_sha256',
    'truncated',
    'html_amsi',
    'inline_amsi',
    'inline_sample_bytes',
    'inline_sample_sha256',
    'shape_sha256',
    'script_shape_sha256',
    'literal_navigation_same_host_root',
    'literal_navigation_had_query',
    'target_followed',
    'direct_atob_literals',
    'segment_scans',
    'offset',
    'bytes',
    'sha256',
    'same_sample_transforms',
    'ordinary_synthetic_navigation_controls',
    'static_indicators',
    'complete_eicar_marker',
    'eicar_word',
    'script_location_reference',
    'script_eval_reference',
    'script_atob_reference',
    'script_document_write_reference',
    'external_script_src',
    'iframe_tag',
    'meta_refresh',
    'one_literal_url',
    'same_byte_length_for_all_variants',
    'comparisons',
    'clean',
    'eicar_raw',
    'eicar_in_html',
    'eicar_in_script',
    'passed_for_raw_and_clean_only',
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

List<Map<String, Object?>> selectLengmenEvidence(
  LengmenLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) => [
  for (final row
      in evidence._observations[_key(source.id, source.endpoint.host)] ??
          const <Map<String, Object?>>[])
    {
      ...row,
      'matches_current_selected_raw_record':
          row['historical_selected_record_index'] == selectedIndex,
      'matches_current_source_kind': row['historical_kind'] == source.kind.name,
      'matches_current_source_format':
          row['historical_format'] == source.format.name,
      'matches_current_full_endpoint':
          row['historical_endpoint_sha256'] ==
          _sha(utf8.encode(source.endpoint.toString())),
      'matches_current_normalized_legado_rule':
          source.legado != null &&
          row['historical_normalized_legado_sha256'] ==
              legadoSourceFingerprint(source.legado!),
    },
];
