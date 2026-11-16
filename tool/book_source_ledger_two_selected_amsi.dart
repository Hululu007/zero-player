// Historical, bounded observations only; no verdict about an entire host.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const twoSelectedAmsiFile = 'legado-two-selected-amsi-static-20261116.json';
const twoSelectedAmsiSha =
    '84eb42ddbcf6b4ba3e51234dd565811d1323529a0e87c25790bd344589bbaec9';
const _evidenceCanonical =
    'b6d5b776ccfc3ec60efe862fa4dfc0bca4871c2fbf2cceb1c9fc11a7f5501fed';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _inventorySha =
    'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c';
const _prior = 'docs/implementation/legado-amsi-other-hosts-20261115.json';
const _priorSha =
    '25180e804c1df15165af8bb20ae58c5b4dd6b2e24f6a0a092d50281ca5e25750';
const _priorCanonical =
    '08f7d2e95187f70c0f042b9a20b9c8ee9ec19aa9adbf7490700f6faa6d45bf93';
const _later =
    'docs/implementation/legado-amsi-template-clusters-20261115.json';
const _laterSha =
    '0aaff7d86529327f67ea09f741d62a00a0cf47a03a90175b982619beeed9de3e';
const _laterCanonical =
    'a7eba07de4a52012adc9d5649ac4e0a6ace56725f881a5f893185ecbfda5f8fd';
const _ledger = 'docs/implementation/legado-source-ledger-20261115.json';
const _commit = '1247df93222ac993e04c6db57ba0471fc713a63e';
const _ledgerSha =
    'b6afb51bcce7af5f7f152ffa3f1c3bce824a0419970253e2c110eed299e09448';
const _identities = <int, (String, String)>{
  4838: (
    '825bca65b0ffd75ab89a26aafc8b0f956f0075f28ee56305201766c2c86b70d0',
    'kuronavi.blog',
  ),
  3558: (
    'b0764c15a1a2830da1600ae84b8ac459a73a8dcbabe968630e10a66c9618137b',
    'm.69shu.la',
  ),
};

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
Map<String, Object?> _copy(Map value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

/// Validate byte and parsed-content digests independently.
void verifyTwoSelectedAmsiInput(Map evidence, Map<String, String> hashes) {
  _require(
    hashes['docs/implementation/$twoSelectedAmsiFile'] == twoSelectedAmsiSha &&
        _objectSha(evidence) == _evidenceCanonical &&
        hashes[_archive] == _archiveSha &&
        hashes[_inventory] == _inventorySha &&
        hashes[_prior] == _priorSha &&
        hashes[_later] == _laterSha &&
        evidence['ledger_git_commit'] == _commit &&
        evidence['ledger_sha256'] == _ledgerSha &&
        evidence['archive_sha256'] == _archiveSha,
    'two-source evidence or input digest mismatch',
  );
}

final class TwoSelectedAmsiEvidence {
  const TwoSelectedAmsiEvidence(this._rows);
  final Map<int, Map<String, Object?>> _rows;
}

Map _priorObservation(Map evidence, String host, String id, int index) {
  final hits = (evidence['results'] as List)
      .cast<Map>()
      .where((row) => row['host'] == host)
      .toList();
  _require(hits.length == 1, 'historical host observation is not unique');
  final row = hits.single;
  _require(
    (row['record_indices'] as List).contains(index) &&
        (row['selected_source_ids'] as List).contains(id) &&
        (row['amsi'] as Map)['classification'] == 'detected',
    'historical detection identity mismatch',
  );
  return row;
}

Map<String, Object?> _priorSample(Map sample) => {
  'observed_at': sample['sample_observed_at'],
  'sample_sha256': sample['sample_sha256'],
  'sample_bytes': sample['sample_bytes'],
  'truncated': sample['truncated'],
  'root_classification': (sample['amsi'] as Map)['classification'],
  'inline_classifications': [
    for (final row
        in ((sample['inline_scripts'] as Map)['samples'] as List).cast<Map>())
      (row['amsi'] as Map)['classification'],
  ],
};

/// Check the exact historical Git ledger, selected archive records and prior
/// engine observations before constructing source-level historical facts.
TwoSelectedAmsiEvidence readTwoSelectedAmsiEvidence(
  Map evidence,
  Map prior,
  Map later,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyTwoSelectedAmsiInput(evidence, hashes);
  _require(
    _objectSha(prior) == _priorCanonical &&
        _objectSha(later) == _laterCanonical,
    'historical parsed engine evidence mismatch',
  );
  final ledger = verifiedHistoricalGitObject({
    'git_commit': _commit,
    'path': _ledger,
    'sha256': _ledgerSha,
  }, _ledger);
  final oldInputs = ledger['input_sha256'] as Map;
  _require(
    oldInputs[_archive] == _archiveSha &&
        oldInputs[_inventory] == _inventorySha,
    'historical archive or inventory mismatch',
  );
  final oldRows = <String, Map>{};
  for (final row in (ledger['sources'] as List).cast<Map>()) {
    final id = row['source_id'];
    _require(
      id is String && !oldRows.containsKey(id),
      'duplicate historical ID',
    );
    oldRows[id as String] = row;
  }
  _require(oldRows.length == 2139, 'historical selected population mismatch');
  final snapshots = (evidence['sources'] as List).cast<Map>();
  final observations = (evidence['observations'] as List).cast<Map>();
  _require(
    snapshots.length == 2 && observations.length == 4,
    'sample count mismatch',
  );
  final rows = <int, Map<String, Object?>>{};
  for (final entry in _identities.entries) {
    final index = entry.key;
    final (id, host) = entry.value;
    _require(index < rawRecords.length, 'archived source is missing');
    final matches = snapshots
        .where((row) => row['selected_record_index'] == index)
        .toList();
    _require(
      matches.length == 1 && oldRows[id] != null,
      'selected source is not unique',
    );
    final snapshot = matches.single;
    final raw = rawRecords[index] as Map;
    final parsed = parseBookSourceRecord(raw);
    final old = oldRows[id]!;
    _require(
      snapshot['source_id'] == id &&
          snapshot['host'] == host &&
          snapshot['kind'] == 'text' &&
          snapshot['format'] == 'html' &&
          parsed.id == id &&
          parsed.endpoint.host == host &&
          parsed.kind == BookKind.text &&
          parsed.format == BookFormat.html &&
          _objectSha(raw) == snapshot['raw_record_sha256'] &&
          old['selected_record_index'] == index &&
          old['endpoint_host'] == host &&
          old['kind'] == 'text' &&
          old['format'] == 'html' &&
          old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
          old['selected_raw_record_canonical_sha256'] ==
              snapshot['raw_record_sha256'] &&
          old['normalized_legado_canonical_sha256'] ==
              snapshot['normalized_legado_sha256'],
      'historical selected identity, endpoint or rules mismatch',
    );
    final first = _priorObservation(prior, host, id, index);
    final second = _priorObservation(later, host, id, index);
    final relevant = observations.where((row) => row['host'] == host).toList();
    _require(relevant.length == 2, 'per-source observations mismatch');
    final control = evidence['control'] as Map;
    rows[index] = _copy({
      'evidence': twoSelectedAmsiFile,
      'observation_kind': 'bounded_homepage_engine_revisit',
      'historical_git_commit': _commit,
      'historical_selected_record_index': index,
      'historical_raw_record_sha256': snapshot['raw_record_sha256'],
      'historical_endpoint_sha256': snapshot['endpoint_sha256'],
      'historical_normalized_legado_sha256':
          snapshot['normalized_legado_sha256'],
      'historical_normalized_source_sha256':
          old['normalized_source_canonical_sha256'],
      'historical_engine_samples': [_priorSample(first), _priorSample(second)],
      'homepage_observations': relevant,
      'engine_control': {
        'negative': (control['negative'] as Map)['classification'],
        'test_marker': (control['eicar'] as Map)['classification'],
        'html_wrapped_test_marker':
            (control['html_wrapped_eicar'] as Map)['classification'],
        'inline_wrapped_test_marker':
            (control['inline_script_with_eicar'] as Map)['classification'],
        'basic_controls_passed': control['passed'],
        'provider_may_upload_sample': true,
      },
      'site_security_verified': null,
      'site_malware_verified': null,
      'sitewide_adult_verified': null,
      'whole_source_unavailable_verified': null,
      'whole_source_readability_verified': null,
      'redirects_followed': false,
      'redirect_target_collected': false,
      'source_or_page_scripts_executed': false,
      'raw_response_available_offline': false,
      'network_authenticity_verified_offline': false,
      'same_template_proves_independent_threats': false,
    });
  }
  return TwoSelectedAmsiEvidence(rows);
}

/// Never attach historical observations to another selected index, ID or host.
/// A same-ID revision remains explicitly labelled as a historical mismatch.
List<Map<String, Object?>> selectTwoSelectedAmsiEvidence(
  TwoSelectedAmsiEvidence evidence,
  BookSource source,
  int selectedIndex,
) {
  final identity = _identities[selectedIndex];
  if (identity == null ||
      source.id != identity.$1 ||
      source.endpoint.host != identity.$2) {
    return [];
  }
  final stored = evidence._rows[selectedIndex];
  if (stored == null) return [];
  final row = _copy(stored);
  final sameKind = source.kind == BookKind.text;
  final sameFormat = source.format == BookFormat.html;
  final sameEndpoint =
      _sha(utf8.encode(source.endpoint.toString())) ==
      row['historical_endpoint_sha256'];
  final sameRule =
      source.legado != null &&
      legadoSourceFingerprint(source.legado!) ==
          row['historical_normalized_legado_sha256'];
  final sameSource =
      _objectSha(source.toJson()) == row['historical_normalized_source_sha256'];
  return [
    {
      ...row,
      'matches_current_selected_raw_record': true,
      'matches_current_source_kind': sameKind,
      'matches_current_source_format': sameFormat,
      'matches_current_full_endpoint': sameEndpoint,
      'matches_current_normalized_legado_rule': sameRule,
      'matches_current_source_configuration':
          sameKind && sameFormat && sameEndpoint && sameRule && sameSource,
    },
  ];
}
