// One selected historical source and six bounded static observations.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const structural4371EvidenceFile =
    'legado-4371-structural-review-20261116.json';
const structural4371EvidenceSha =
    'f5d78b86a28401b395081ec64aa16a93c29f312b01442c9f40681963153acd9c';
const _canonicalEvidenceSha =
    'c1cc0d3dcac27ea827bc16572fdfb694cebfb9694c2fac2b45cad5cbe761546a';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _inventorySha =
    'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c';
const _ledger = 'docs/implementation/legado-source-ledger-20261115.json';
const _commit = '1247df93222ac993e04c6db57ba0471fc713a63e';
const _ledgerSha =
    'b6afb51bcce7af5f7f152ffa3f1c3bce824a0419970253e2c110eed299e09448';
const _captureSha =
    'b5bbca7befd094f1924c39a764ba4f95611e7438b78c32c4b6f8f60aea0bc66d';
const _id = '22fd5687b4cd8b42ce1d69d0701148e989f39833d7d94b1e1dae73795084e242';
const _host = 'www.bsxiaoshuo.com';
const _recordSha =
    '5f5f1694a131bca90865399a6a3e9c1e57a44a7e37db649c3ad71da9080342b5';
const _endpointSha =
    '8e502f1b8e3c81cbd0ce27e302bdf745660e2fe347b5e4373e02ef30966d2f8a';
const _legadoSha =
    '5e0ce5b6c43db101d89212f26fab8528e17f91a7c1c2cd82085c62d84e45c43c';
const _sourceSha =
    'f225c4019a6dd2f134b691fcf4231de5009273abaaec692f94f655f7b35d3db7';

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
Map<String, Object?> _copy(Map value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

void verifyStructural4371Input(Map evidence, Map<String, String> hashes) {
  final provenance = evidence['provenance'] as Map;
  final ledger = provenance['historical_ledger'] as Map;
  _require(
    hashes['docs/implementation/$structural4371EvidenceFile'] ==
            structural4371EvidenceSha &&
        _objectSha(evidence) == _canonicalEvidenceSha &&
        hashes[_archive] == _archiveSha &&
        hashes[_inventory] == _inventorySha &&
        (provenance['archive'] as Map)['sha256'] == _archiveSha &&
        (provenance['import_inventory'] as Map)['sha256'] == _inventorySha &&
        ledger['path'] == _ledger &&
        ledger['git_commit'] == _commit &&
        ledger['sha256'] == _ledgerSha &&
        provenance['local_redacted_capture_sha256'] == _captureSha &&
        provenance['network_authenticity_verifiable_offline'] == false &&
        provenance['collector_or_dependencies_distributed'] == false,
    'structural #4371 evidence or provenance mismatch',
  );
}

final class Structural4371Evidence {
  const Structural4371Evidence(this._row);
  final Map<String, Object?> _row;
}

/// Bind the immutable sample to the historical Git ledger and raw archive.
Structural4371Evidence readStructural4371Evidence(
  Map evidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyStructural4371Input(evidence, hashes);
  final ledger = verifiedHistoricalGitObject({
    'git_commit': _commit,
    'path': _ledger,
    'sha256': _ledgerSha,
  }, _ledger);
  final inputs = ledger['input_sha256'] as Map;
  _require(
    inputs[_archive] == _archiveSha && inputs[_inventory] == _inventorySha,
    'historical archive or inventory mismatch',
  );
  final matches = (ledger['sources'] as List)
      .cast<Map>()
      .where((row) => row['source_id'] == _id)
      .toList();
  _require(
    matches.length == 1 && rawRecords.length > 4371,
    'historical source missing',
  );
  final old = matches.single;
  final raw = rawRecords[4371] as Map;
  final source = parseBookSourceRecord(raw);
  final snapshot = evidence['source'] as Map;
  _require(
    snapshot['source_id'] == _id &&
        snapshot['endpoint_host'] == _host &&
        snapshot['selected_record_index'] == 4371 &&
        snapshot['endpoint_sha256'] == _endpointSha &&
        snapshot['raw_record_canonical_sha256'] == _recordSha &&
        snapshot['normalized_legado_sha256'] == _legadoSha &&
        snapshot['normalized_source_sha256'] == _sourceSha &&
        old['selected_record_index'] == 4371 &&
        old['endpoint_host'] == _host &&
        old['kind'] == 'text' &&
        old['format'] == 'html' &&
        old['endpoint_sha256'] == _endpointSha &&
        old['selected_raw_record_canonical_sha256'] == _recordSha &&
        old['normalized_legado_canonical_sha256'] == _legadoSha &&
        old['normalized_source_canonical_sha256'] == _sourceSha &&
        _objectSha(raw) == _recordSha &&
        source.id == _id &&
        source.endpoint.host == _host &&
        source.kind == BookKind.text &&
        source.format == BookFormat.html,
    'historical selected ID, host, endpoint or full rule mismatch',
  );
  final observations = (evidence['observations'] as List).cast<Map>();
  _require(observations.length == 6, 'structural observation count mismatch');
  return Structural4371Evidence(
    _copy({
      'evidence': structural4371EvidenceFile,
      'observation_kind': 'bounded_static_reading_structure',
      'historical_git_commit': _commit,
      'historical_selected_record_index': 4371,
      'historical_raw_record_sha256': _recordSha,
      'historical_endpoint_sha256': _endpointSha,
      'historical_normalized_legado_sha256': _legadoSha,
      'historical_normalized_source_sha256': _sourceSha,
      'observations': observations,
      'method': evidence['method'],
      'interpretation': evidence['interpretation'],
      'limitations': evidence['limitations'],
      'network_authenticity_verified_offline': false,
      'raw_pages_and_collector_replayable': false,
      'site_security_verified': null,
      'site_malware_verified': null,
      'sitewide_adult_verified': null,
      'whole_source_unavailable_verified': null,
      'whole_source_readability_verified': null,
    }),
  );
}

/// Exact ID, host and selected index only; current-rule differences stay visible.
List<Map<String, Object?>> selectStructural4371Evidence(
  Structural4371Evidence evidence,
  BookSource source,
  int selectedIndex,
) {
  if (selectedIndex != 4371 ||
      source.id != _id ||
      source.endpoint.host != _host) {
    return [];
  }
  final sameKind = source.kind == BookKind.text;
  final sameFormat = source.format == BookFormat.html;
  final sameEndpoint =
      _sha(utf8.encode(source.endpoint.toString())) == _endpointSha;
  final sameRule =
      source.legado != null &&
      legadoSourceFingerprint(source.legado!) == _legadoSha;
  final sameSource = _objectSha(source.toJson()) == _sourceSha;
  return [
    {
      ..._copy(evidence._row),
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
