// Exact selected-source associations for four bounded static observations.
// They are historical clues, not current content, security or availability.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

const fourRiskEvidenceFile = 'legado-four-risk-revisit-20261116.json';
const fourRiskEvidenceSha =
    '1285cfaefd84eaf82eefaa67473ec690210698c07469cf059b5dc8d4c1f69dd4';
const _canonicalEvidenceSha =
    'feb2e4cb804b4d6e14a3085b208b05125fd74fd6464201294f06fcc0965730b8';
const _archive = 'assets/catalogs/books/legado/catalog.json.bz2';
const _archiveSha =
    '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d';
const _inventory = 'docs/implementation/legado-import-inventory-20261115.json';
const _inventorySha =
    'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c';
const _amsi = 'docs/implementation/legado-amsi-template-clusters-20261115.json';
const _amsiSha =
    '0aaff7d86529327f67ea09f741d62a00a0cf47a03a90175b982619beeed9de3e';
const _amsiCanonicalSha =
    'a7eba07de4a52012adc9d5649ac4e0a6ace56725f881a5f893185ecbfda5f8fd';
const _ledger = 'docs/implementation/legado-source-ledger-20261115.json';
const _sampleCommit = 'd02eb41033e22932273e0613fb133f9e395e11df';
const _sampleLedgerSha =
    '170da0a6054483e83ae0827b7d6f7af18b44f8c20a5a5231856a656fb148fae4';
const _summaryCommit = '56955b3d441678f4734d4c8cb4bf377a373212c4';
const _summaryLedgerSha =
    'cfd87a165b3fb175d603385eb7a64192f9ae11e5c0441ff35d94323594b7265e';
const _requestPath = 'lib/features/books/data/legado/legado_request.dart';
const _requestLfSha =
    'da65df24e85c72e12e9b6305407612084bd8ea2f6d9197ce66fc96e0bd717914';
const _identities = <int, (String, String)>{
  36: (
    '1f08fd713aac15e302299bffa11eaed3964cb16a0d6c6024cbaf0cb2e2539c9f',
    'get.xiashuzhan.com',
  ),
  1439: (
    '49288d9a4a46a7b884896dab3a61500fb815269d48f710dbd640dfed9848bf1b',
    's.fjwhcbsh.com',
  ),
  2098: (
    '5395fcb9dde14042bb1d7f37a878fe7400d5e87d0f96178b0e48561e386879e2',
    'wap.18biquge.com',
  ),
  4568: (
    'b580d46efc572f59d536293067e2671c03744bddfda42321e19ff36a058da206',
    'www.zongcaixiaoshuow.com',
  ),
};

void _require(bool condition, String reason) {
  if (!condition) throw FormatException(reason);
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();
String _textSha(String value) => _sha(utf8.encode(value));
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

/// Check the caller's byte digests and the parsed evidence independently.
void verifyFourRiskRevisitInput(Map evidence, Map<String, String> hashes) {
  final provenance = evidence['provenance'] as Map;
  final archive = provenance['archive'] as Map;
  final inventory = provenance['import_inventory'] as Map;
  final amsi = provenance['historical_amsi'] as Map;
  final sampling = provenance['sampling_ledger'] as Map;
  final summary = provenance['summary_ledger'] as Map;
  _require(
    hashes['docs/implementation/$fourRiskEvidenceFile'] ==
            fourRiskEvidenceSha &&
        _objectSha(evidence) == _canonicalEvidenceSha &&
        hashes[_archive] == _archiveSha &&
        hashes[_inventory] == _inventorySha &&
        hashes[_amsi] == _amsiSha &&
        archive['path'] == _archive &&
        archive['sha256'] == _archiveSha &&
        inventory['path'] == _inventory &&
        inventory['sha256'] == _inventorySha &&
        amsi['path'] == _amsi &&
        amsi['sha256'] == _amsiSha &&
        sampling['path'] == _ledger &&
        sampling['sha256'] == _sampleLedgerSha &&
        sampling['matching_git_commit'] == _sampleCommit &&
        sampling['matching_object_identified_after_initial_observations'] ==
            true &&
        sampling['commit_does_not_identify_entire_runtime'] == true &&
        summary['path'] == _ledger &&
        summary['sha256'] == _summaryLedgerSha &&
        summary['matching_git_commit'] == _summaryCommit &&
        provenance['local_capture_or_network_authenticity_offline_verifiable'] ==
            false &&
        provenance['collector_distributed'] == false,
    'four-source evidence, archive or historical references mismatch',
  );
}

final class FourRiskRevisitLedgerEvidence {
  const FourRiskRevisitLedgerEvidence(this._rows);
  final Map<int, Map<String, Object?>> _rows;
}

Map _history(String commit, String digest) => verifiedHistoricalGitObject({
  'git_commit': commit,
  'path': _ledger,
  'sha256': digest,
}, _ledger);

void _verifyHistoryInputs(Map history) {
  final hashes = history['input_sha256'] as Map;
  _require(
    hashes[_archive] == _archiveSha && hashes[_inventory] == _inventorySha,
    'four-source historical archive or inventory mismatch',
  );
}

void _verifyParserReference(Map provenance) {
  final reference = provenance['legado_request_static_source'] as Map;
  _require(
    reference['path'] == _requestPath &&
        reference['matching_git_commit'] == _sampleCommit &&
        reference['normalized_lf_sha256'] == _requestLfSha,
    'four-source parser reference mismatch',
  );
  final result = Process.runSync(
    'git',
    ['show', '$_sampleCommit:$_requestPath'],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  _require(result.exitCode == 0, 'historical parser Git object missing');
  final text = utf8.decode(result.stdout as List<int>).replaceAll('\r\n', '\n');
  _require(
    _textSha(text) == _requestLfSha &&
        text.contains('class LegadoRequest') &&
        text.contains("options['method']") &&
        !text.toLowerCase().contains('webview'),
    'historical parser inspection mismatch',
  );
}

DateTime _gitCommitTime(String commit) {
  final result = Process.runSync('git', ['show', '-s', '--format=%cI', commit]);
  _require(result.exitCode == 0, 'historical commit missing');
  return DateTime.parse((result.stdout as String).trim()).toUtc();
}

void _verifyChronology(Map evidence) {
  final provenance = evidence['provenance'] as Map;
  final sampling = provenance['sampling_ledger'] as Map;
  final summary = provenance['summary_ledger'] as Map;
  final observations = (evidence['observations'] as List).cast<Map>();
  _require(observations.length == 17, 'four-source observation count mismatch');
  final times = [
    for (final row in observations)
      DateTime.parse(row['started_at_utc'] as String).toUtc(),
  ];
  final firstCommit = _gitCommitTime(_sampleCommit);
  final secondCommit = _gitCommitTime(_summaryCommit);
  _require(
    firstCommit ==
            DateTime.parse(
              sampling['matching_commit_at_utc'] as String,
            ).toUtc() &&
        secondCommit ==
            DateTime.parse(
              summary['matching_commit_at_utc'] as String,
            ).toUtc() &&
        times.first.isBefore(firstCommit) &&
        firstCommit.isBefore(times.last) &&
        times.last.isBefore(secondCommit) &&
        !secondCommit.isAfter(
          DateTime.parse(
            provenance['local_summary_assembled_at_utc'] as String,
          ).toUtc(),
        ),
    'four-source commit and observation chronology mismatch',
  );
  for (var i = 1; i < times.length; i++) {
    _require(
      times[i - 1].isBefore(times[i]),
      'four-source request chronology mismatch',
    );
  }
}

Map<String, Map> _historicalRows(Map history) {
  final records = (history['sources'] as List).cast<Map>();
  final rows = <String, Map>{};
  for (final row in records) {
    final id = row['source_id'];
    _require(
      id is String && !rows.containsKey(id),
      'four-source historical ledger contains duplicate IDs',
    );
    rows[id as String] = row;
  }
  _require(
    records.length == 2139 && rows.length == records.length,
    'four-source historical ledger population mismatch',
  );
  return rows;
}

void _verifySelected(
  Map snapshot,
  Map raw,
  Map old,
  Map newer,
  int index,
  String id,
  String host,
) {
  final parsed = parseBookSourceRecord(raw);
  final rawSha = _objectSha(raw);
  _require(
    snapshot['record_index'] == index &&
        snapshot['source_id'] == id &&
        snapshot['endpoint_host'] == host &&
        parsed.id == id &&
        parsed.endpoint.host == host &&
        snapshot['kind'] == 'text' &&
        snapshot['format'] == 'html' &&
        parsed.kind == BookKind.text &&
        parsed.format == BookFormat.html &&
        rawSha == snapshot['raw_record_canonical_sha256'],
    'four-source archive or selected identity mismatch',
  );
  for (final row in [old, newer]) {
    _require(
      row['source_id'] == id &&
          row['selected_record_index'] == index &&
          row['endpoint_host'] == host &&
          row['name'] == snapshot['name'] &&
          row['kind'] == snapshot['kind'] &&
          row['format'] == snapshot['format'] &&
          row['endpoint_sha256'] == snapshot['sample_ledger_endpoint_sha256'] &&
          row['normalized_legado_canonical_sha256'] ==
              snapshot['sample_ledger_normalized_legado_sha256'] &&
          row['selected_raw_record_canonical_sha256'] == rawSha,
      'four-source historical ledger identity or rule mismatch',
    );
  }
}

void _verifyPriorAmsi(Map snapshot, Map priorByHost) {
  final prior = snapshot['prior_amsi'];
  if (snapshot['record_index'] == 4568) {
    _require(prior == null, 'unknown historical sample cannot become a scan');
    return;
  }
  final source = priorByHost[snapshot['endpoint_host']] as Map?;
  _require(source != null && prior is Map, 'historical AMSI sample missing');
  final actual = source!;
  final stored = prior as Map;
  final amsi = actual['amsi'] as Map;
  final inline =
      ((actual['inline_scripts'] as Map)['samples'] as List).single as Map;
  _require(
    (actual['selected_source_ids'] as List).contains(snapshot['source_id']) &&
        stored['evidence'] == _amsi &&
        stored['observed_at_utc'] == actual['sample_observed_at'] &&
        stored['root_classification'] == 'detected' &&
        amsi['classification'] == 'detected' &&
        stored['sample_bytes'] == actual['sample_bytes'] &&
        stored['sample_sha256'] == actual['sample_sha256'] &&
        stored['separate_inline_classification'] ==
            (inline['amsi'] as Map)['classification'] &&
        stored['separate_inline_classification'] == 'not_detected',
    'historical AMSI association mismatch',
  );
}

void _verifyScope(Map evidence, List<Map> observations) {
  final method = evidence['method'] as Map;
  final interpretation = evidence['interpretation'] as Map;
  final counts = <int, int>{};
  for (final row in observations) {
    final index = row['record_index'] as int;
    counts[index] = (counts[index] ?? 0) + 1;
  }
  _require(
    counts.length == 4 &&
        counts[36] == 3 &&
        counts[1439] == 3 &&
        counts[2098] == 4 &&
        counts[4568] == 7 &&
        method['http_requests'] == 17 &&
        method['get_requests'] == 16 &&
        method['synthetic_search_post_requests'] == 1 &&
        method['all_resolved_dns_answers_checked_public'] == true &&
        method['connection_pinned_to_checked_address'] == true &&
        method['tls_hostname_verified'] == true &&
        method['redirects_followed'] == false &&
        method['cookies_or_credentials_sent'] == false &&
        method['source_or_page_scripts_executed'] == false &&
        method['subresources_fetched'] == false &&
        method['max_sample_bytes'] == 65536 &&
        method['timeout_seconds_per_dns_connect_or_read'] == 7 &&
        method['overall_wall_deadline_enforced'] == false &&
        interpretation['actual_legado_engine_or_webview_executed'] == false &&
        interpretation['source4568_old_chapter_rule_declares_webview_true'] ==
            true &&
        interpretation['source4568_inspected_parser_implements_webview_option'] ==
            false &&
        interpretation['source4568_one_chapter_does_not_establish_full_reading'] ==
            true &&
        interpretation['source4568_mixed_keyword_clues_do_not_prove_sitewide_adult'] ==
            true &&
        interpretation['automatic_sitewide_classification_or_quarantine_proposed'] ==
            false,
    'four-source observation scope or limits mismatch',
  );
}

Map<String, Object?> _observation(Map row) {
  final sample = row['sample'] as Map?;
  return {
    'stage': row['stage'],
    'path_role': row['path_role'],
    'started_at_utc': row['started_at_utc'],
    'method': row['method'],
    'http_status': row['http_status'],
    'outcome': row['outcome'],
    'redirect': row['redirect'],
    'sample_bytes': sample?['bytes'],
    'sample_sha256': sample?['sha256'],
    'sample_truncated': sample?['truncated'],
    'visible_text_clues': sample?['visible_text_clues'],
    'title_clues': sample?['title_clues'],
    'description_clues': sample?['description_clues'],
    'script_tags': sample?['script_tags'],
    'external_script_tags': sample?['external_script_tags'],
    'visible_characters': sample?['visible_characters'],
  };
}

Map<String, Object?> _structuralObservation(Map row) => {
  'stage': row['stage'],
  'path_role': row['path_role'],
  'started_at_utc': row['started_at_utc'],
  'http_status': row['http_status'],
  'sample_truncated': (row['sample'] as Map?)?['truncated'],
  'static_selector_counts': row['structural_checks'],
  'application_engine_executed': false,
};

Map<String, Object?> _project(Map snapshot, List<Map> observations) {
  final index = snapshot['record_index'] as int;
  final relevant = observations
      .where((row) => row['record_index'] == index)
      .toList();
  return _copy({
    'evidence': fourRiskEvidenceFile,
    'observation_kind': 'bounded_static_four_source_revisit',
    'historical_selected_record_index': index,
    'historical_raw_record_sha256': snapshot['raw_record_canonical_sha256'],
    'historical_endpoint_sha256': snapshot['sample_ledger_endpoint_sha256'],
    'historical_normalized_legado_sha256':
        snapshot['sample_ledger_normalized_legado_sha256'],
    'sampling_ledger_matching_git_commit': _sampleCommit,
    'sampling_ledger_commit_after_first_observation': true,
    'summary_ledger_matching_git_commit': _summaryCommit,
    'historical_runtime_fully_reconstructed': false,
    'raw_pages_and_collectors_replayable': false,
    'network_authenticity_offline_verified': false,
    'historical_amsi_sample': snapshot['prior_amsi'],
    'current_amsi_assessment': null,
    'http_observations': [for (final row in relevant) _observation(row)],
    'static_page_structure_observations': [
      for (final row in relevant)
        if (row['structural_checks'] != null) _structuralObservation(row),
    ],
    'application_reading_chain': {
      'legado_engine_executed': false,
      'webview_executed': false,
      'application_search_verified': null,
      'application_chapter_readability_verified': null,
      'full_source_readability_verified': null,
      'old_rule_declares_webview_true': index == 4568 ? true : null,
      'inspected_historical_parser_implements_webview_option': index == 4568
          ? false
          : null,
      'inspected_parser_git_commit': index == 4568 ? _sampleCommit : null,
      'parser_runtime_fully_reconstructed': false,
      'chapter_sample_scope': index == 4568
          ? 'one_static_chapter_only'
          : 'not_sampled',
    },
    'site_security_verified': null,
    'sitewide_adult_content_verified': null,
    'whole_source_unavailable_verified': null,
    'current_rule_validity_verified': null,
    'redirects_followed': false,
    'source_or_page_scripts_executed': false,
    'subresources_fetched': false,
    'max_sample_bytes': 65536,
    'socket_operation_timeout_seconds': 7,
    'overall_wall_deadline_enforced': false,
  });
}

/// Validate archive rows and both fixed Git snapshots before retaining facts.
FourRiskRevisitLedgerEvidence readFourRiskRevisitEvidence(
  Map evidence,
  Map amsiEvidence,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyFourRiskRevisitInput(evidence, hashes);
  _require(
    _objectSha(amsiEvidence) == _amsiCanonicalSha,
    'four-source historical AMSI parsed evidence mismatch',
  );
  final old = _history(_sampleCommit, _sampleLedgerSha);
  final newer = _history(_summaryCommit, _summaryLedgerSha);
  _verifyHistoryInputs(old);
  _verifyHistoryInputs(newer);
  _verifyParserReference(evidence['provenance'] as Map);
  _verifyChronology(evidence);
  final oldRows = _historicalRows(old);
  final newerRows = _historicalRows(newer);
  final priorByHost = {
    for (final row in (amsiEvidence['results'] as List).cast<Map>())
      row['host']: row,
  };
  final snapshots = (evidence['sources'] as List).cast<Map>();
  final observations = (evidence['observations'] as List).cast<Map>();
  _require(
    snapshots.length == 4 && observations.length == 17,
    'four-source sample or request count mismatch',
  );
  _verifyScope(evidence, observations);
  final rows = <int, Map<String, Object?>>{};
  for (final entry in _identities.entries) {
    final index = entry.key;
    final (id, host) = entry.value;
    _require(index < rawRecords.length, 'four-source archive index missing');
    final selected = snapshots
        .where((row) => row['record_index'] == index)
        .toList();
    _require(
      selected.length == 1 && oldRows[id] != null && newerRows[id] != null,
      'four-source historical identity is not unique',
    );
    final snapshot = selected.single;
    _verifySelected(
      snapshot,
      rawRecords[index] as Map,
      oldRows[id]!,
      newerRows[id]!,
      index,
      id,
      host,
    );
    _verifyPriorAmsi(snapshot, priorByHost);
    rows[index] = _project(snapshot, observations);
  }
  return FourRiskRevisitLedgerEvidence(rows);
}

/// Only an exact source ID, endpoint host and selected raw-record index match.
/// Full endpoint and normalized rule comparisons stay separately visible.
List<Map<String, Object?>> selectFourRiskRevisitEvidence(
  FourRiskRevisitLedgerEvidence evidence,
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
      _textSha(source.endpoint.toString()) == row['historical_endpoint_sha256'];
  final sameRule =
      source.legado != null &&
      legadoSourceFingerprint(source.legado!) ==
          row['historical_normalized_legado_sha256'];
  return [
    {
      ...row,
      'matches_current_selected_raw_record': true,
      'matches_current_source_kind': sameKind,
      'matches_current_source_format': sameFormat,
      'matches_current_full_endpoint': sameEndpoint,
      'matches_current_normalized_legado_rule': sameRule,
      'matches_current_source_configuration':
          sameKind && sameFormat && sameEndpoint && sameRule,
    },
  ];
}
