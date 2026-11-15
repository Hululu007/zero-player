// Exact-source adapters for the three 2026-11-16 evidence inputs. These are
// bounded historical observations, not current-content or safety verdicts.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_recent_evidence.dart';

const uaaEvidenceFile = 'legado-uaa-adult-id-review-20261116.json';
const equivalentEvidenceFile = 'legado-equivalent-adult-ids-20261116.json';
const twoChainEvidenceFile = 'legado-two-chain-pilot-20261116.json';
const redirectedEvidenceFile = 'legado-redirected-sources-20261116.json';
const myxzmEvidenceFile = 'legado-myxzm-recheck-20261116.json';
const mixedHomeEvidenceFile = 'legado-adult-mixed-home-recheck-20261116.json';
const novel242EvidenceFile = 'legado-242xs-recheck-20261116.json';
const threeRedirectEvidenceFile = 'legado-three-redirect-recheck-20261116.json';
const _historicalLedgerPath =
    'docs/implementation/legado-source-ledger-20261115.json';
const _historicalLabelsPath =
    'docs/implementation/legado-adult-label-evidence-20261115.json';
const _catalogArchivePath = 'assets/catalogs/books/legado/catalog.json.bz2';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();
String _textSha(String text) => _sha(utf8.encode(text));

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

/// Reads only the specified immutable Git object and validates its byte digest.
Map verifiedHistoricalGitObject(Map reference, String expectedPath) {
  final commit = reference['git_commit'];
  final path = reference['path'];
  final digest = reference['sha256'];
  _require(
    commit is String &&
        RegExp(r'^[0-9a-f]{40}$').hasMatch(commit) &&
        path == expectedPath &&
        digest is String &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(digest),
    'invalid historical Git evidence reference',
  );
  final result = Process.runSync(
    'git',
    ['show', '$commit:$path'],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  _require(
    result.exitCode == 0 && _sha(result.stdout as List<int>) == digest,
    'historical Git evidence object missing or digest mismatch',
  );
  return jsonDecode(utf8.decode(result.stdout as List<int>)) as Map;
}

final class Nov16LedgerEvidence {
  final network = <String, List<Map<String, Object?>>>{};
  final adultReview = <String, List<Map<String, Object?>>>{};
  final reading = <String, List<Map<String, Object?>>>{};

  void add(
    Map<String, List<Map<String, Object?>>> destination,
    Object? id,
    Object? host,
    Object? index,
    Map<String, Object?> observation,
  ) {
    _require(
      id is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(id) &&
          host is String &&
          host.isNotEmpty &&
          index is int &&
          index >= 0,
      'invalid 2026-11-16 selected source identity',
    );
    destination.putIfAbsent('$id\x00$host\x00$index', () => []).add({
      ...observation,
      'historical_selected_record_index': index,
    });
  }
}

/// All three identity components must agree; stale historical versions are not
/// assigned to a different selected record. Rules can still change in place.
List<Map<String, Object?>> selectNov16Evidence(
  Map<String, List<Map<String, Object?>>> evidence,
  BookSource source,
  int selectedIndex,
) => [
  for (final item
      in evidence['${source.id}\x00${source.endpoint.host}\x00$selectedIndex'] ??
          const <Map<String, Object?>>[])
    {
      ...item,
      'matches_current_selected_raw_record': true,
      if (item.containsKey('historical_normalized_legado_sha256'))
        'matches_current_normalized_legado_rule':
            source.legado != null &&
            legadoSourceFingerprint(source.legado!) ==
                item['historical_normalized_legado_sha256'],
      if (item.containsKey('historical_rule_sha256'))
        'matches_current_normalized_pilot_rules': _matchesPilotRules(
          source,
          item,
        ),
    },
];

bool _matchesPilotRules(BookSource source, Map observation) {
  final legado = source.legado;
  if (legado == null ||
      _textSha(legado.search) != observation['historical_search_rule_sha256']) {
    return false;
  }
  final hashes = observation['historical_rule_sha256'] as Map;
  return hashes.length == legado.rules.length &&
      legado.rules.entries.every(
        (entry) => hashes[entry.key] == _textSha(entry.value),
      );
}

Nov16LedgerEvidence readNov16Evidence(
  Map<String, Map> data,
  List rows,
  String archiveSha,
  String manifestSha,
  NetworkNormalizer normalize,
) {
  final uaa = data[uaaEvidenceFile]!;
  final equivalent = data[equivalentEvidenceFile]!;
  final pilot = data[twoChainEvidenceFile]!;
  _require(
    uaa['catalog_archive_sha256'] == archiveSha &&
        equivalent['catalog_archive_sha256'] == archiveSha,
    'adult review archive mismatch',
  );
  _verifyPilotInputs(pilot, archiveSha, manifestSha);
  final uaaReference = uaa['historical_ledger'] as Map;
  final equivReference = equivalent['historical_ledger'] as Map;
  _require(
    uaaReference['git_commit'] == equivReference['git_commit'] &&
        uaaReference['path'] == equivReference['path'] &&
        uaaReference['sha256'] == equivReference['sha256'],
    'adult reviews refer to different historical ledgers',
  );
  final ledger = verifiedHistoricalGitObject(
    uaaReference,
    _historicalLedgerPath,
  );
  final labelReference = equivalent['historical_label_evidence'] as Map;
  _require(
    labelReference['git_commit'] == uaaReference['git_commit'],
    'historical label evidence commit mismatch',
  );
  final labels = verifiedHistoricalGitObject(
    labelReference,
    _historicalLabelsPath,
  );
  _require(
    (ledger['input_sha256']
                as Map)['assets/catalogs/books/legado/catalog.json.bz2'] ==
            archiveSha &&
        labels['archive_sha256'] == archiveSha,
    'historical Git evidence archive mismatch',
  );
  _verifyHistoricalCode(uaa, equivalent, ledger, uaaReference);
  final output = Nov16LedgerEvidence();
  _addUaa(output, uaa, ledger, rows);
  _addEquivalents(output, equivalent, ledger, labels, rows);
  _addPilot(output, pilot, rows, normalize);
  return output;
}

/// This is a bounded exact-host observation; no page excerpts are retained.
void addWooHomeReview(Nov16LedgerEvidence output, Map evidence, List rows) {
  final host = evidence['host'];
  _require(host == 'm.woo15.com', 'adult homepage host mismatch');
  final history = verifiedHistoricalGitObject({
    'git_commit': 'a6c7d9986a64a2c7328c5f74c06415a116ef27a9',
    'path': _historicalLedgerPath,
    'sha256': evidence['historical_ledger_sha256'],
  }, _historicalLedgerPath);
  _require(
    (history['input_sha256'] as Map)[_catalogArchivePath] ==
        evidence['catalog_archive_sha256'],
    'adult homepage historical archive mismatch',
  );
  final historical = {
    for (final row in (history['sources'] as List).cast<Map>())
      row['source_id']: row,
  };
  final observations = (evidence['observations'] as List).cast<Map>();
  _require(observations.length == 2, 'adult homepage observation count');
  for (final entry in (evidence['selected_sources'] as List).cast<Map>()) {
    final index = entry['record_index'];
    _require(
      index is int && index >= 0 && index < rows.length,
      'invalid index',
    );
    final source = parseBookSourceRecord(rows[index as int]);
    final old = historical[source.id];
    _require(
      source.id == entry['source_id'] &&
          source.endpoint.host == host &&
          old != null &&
          old['endpoint_host'] == host &&
          old['selected_record_index'] == index,
      'adult homepage selected identity mismatch',
    );
    output.add(output.adultReview, source.id, host, index, {
      'evidence': 'legado-woo15-home-review-20261116.json',
      'classification': 'exact_host_adult_audience_and_static_clues',
      'observation_count': observations.length,
      'observed_at_utc': [
        for (final row in observations) row['observed_at_utc'],
      ],
      'adult_description_clue_recorded': true,
      'adult_visible_clue_recorded': true,
      'site_security_verified': null,
    });
  }
}

void addNovel242Review(
  Nov16LedgerEvidence output,
  Map evidence,
  List rows,
  NetworkNormalizer normalize,
) {
  final refs = evidence['input_references'] as Map;
  final history = _targetedHistory(refs['source_ledger_historical_git'] as Map);
  _require(
    (history['input_sha256'] as Map)[_catalogArchivePath] ==
        (refs['catalog_archive'] as Map)['sha256'],
    '242 source historical archive mismatch',
  );
  final snapshot = evidence['source'] as Map;
  final index = snapshot['selected_record_index'];
  _require(
    index is int && index >= 0 && index < rows.length,
    'invalid 242 index',
  );
  final source = parseBookSourceRecord(rows[index as int]);
  final matches = (history['sources'] as List)
      .cast<Map>()
      .where((item) => item['source_id'] == snapshot['source_id'])
      .toList();
  final old = matches.length == 1 ? matches.single : null;
  _require(
    old != null &&
        source.id == snapshot['source_id'] &&
        source.endpoint.host == snapshot['endpoint_host'] &&
        old['selected_record_index'] == index &&
        old['endpoint_host'] == snapshot['endpoint_host'] &&
        old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
        old['selected_raw_record_canonical_sha256'] ==
            snapshot['selected_raw_record_canonical_sha256'] &&
        old['normalized_legado_canonical_sha256'] ==
            snapshot['normalized_legado_sha256'],
    '242 source historical identity mismatch',
  );
  final observations = (evidence['observations'] as List).cast<Map>();
  _require(observations.length == 6, '242 source observation count');
  final identities = {
    for (final sample in observations) '${sample['round']}:${sample['target']}',
  };
  _require(
    identities.length == 6 &&
        identities.containsAll({
          '1:root',
          '1:old_search',
          '1:old_category',
          '2:root',
          '2:old_search',
          '2:old_category',
        }),
    '242 source observation coverage mismatch',
  );
  for (final sample in observations) {
    final target = sample['target'];
    _require(
      (target == 'root' && sample['http_status'] == 200) ||
          ((target == 'old_search' || target == 'old_category') &&
              sample['http_status'] == 404),
      '242 source observation classification mismatch',
    );
    output.add(output.reading, source.id, source.endpoint.host, index, {
      'evidence': novel242EvidenceFile,
      'observation_kind': 'bounded_legacy_source_request',
      'round': sample['round'],
      'target': target,
      'observed_at_utc': sample['observed_at_utc'],
      'http_status': sample['http_status'],
      'sample_bytes': sample['sample_bytes'],
      'sample_sha256': sample['sample_sha256'],
      'truncated': sample['truncated'],
      'old_search_selector_nodes': sample['old_search_selector_nodes'],
      'old_category_selector_nodes': sample['old_category_selector_nodes'],
      'homepage_video_signals_recorded': target == 'root'
          ? (sample['video_term_counts'] as Map).values.any(
              (n) => n is int && n > 0,
            )
          : null,
      'historical_normalized_legado_sha256':
          snapshot['normalized_legado_sha256'],
      'maliciousness_verified': null,
      'permanent_failure_verified': null,
    });
    if (target == 'root') {
      output.add(output.network, source.id, source.endpoint.host, index, {
        ...normalize(
          evidence: novel242EvidenceFile,
          method: 'GET',
          path: '/',
          row: {
            'observed_at': sample['observed_at_utc'],
            'http_status': sample['http_status'],
            'sample_bytes': sample['sample_bytes'],
            'sample_sha256': sample['sample_sha256'],
            'truncated': sample['truncated'],
          },
        ),
        'historical_normalized_legado_sha256':
            snapshot['normalized_legado_sha256'],
        'site_security_verified': null,
      });
    }
  }
}

Map _targetedHistory(Map reference) => verifiedHistoricalGitObject({
  'git_commit': reference['commit'],
  'path': reference['path'],
  'sha256': reference['sha256'],
}, _historicalLedgerPath);

/// Preserve the observed method/UA and missing values for the three candidates.
void addThreeRedirectReview(
  Nov16LedgerEvidence output,
  Map evidence,
  Map priorHead,
  List rows,
  NetworkNormalizer normalize,
) {
  final refs = evidence['input_references'] as Map;
  final history = _targetedHistory(refs['source_ledger_historical_git'] as Map);
  _require(
    (history['input_sha256'] as Map)[_catalogArchivePath] ==
        (refs['catalog_archive'] as Map)['sha256'],
    'three-source historical archive mismatch',
  );
  final oldSources = {
    for (final row in (history['sources'] as List).cast<Map>())
      row['source_id']: row,
  };
  final priorRows = {
    for (final row in (priorHead['results'] as List).cast<Map>())
      row['host']: row,
  };
  final sources = (evidence['sources'] as List).cast<Map>();
  final previous = (evidence['previous_head_observations'] as List).cast<Map>();
  final samples = (evidence['get_observations'] as List).cast<Map>();
  _require(
    sources.length == 3 && previous.length == 3 && samples.length == 22,
    'three-source observation coverage mismatch',
  );
  for (final snapshot in sources) {
    final id = snapshot['source_id'];
    final host = snapshot['host'];
    final index = snapshot['selected_record_index'];
    _require(
      index is int && index >= 0 && index < rows.length,
      'invalid source index',
    );
    final source = parseBookSourceRecord(rows[index as int]);
    final old = oldSources[id];
    _require(
      old != null &&
          source.id == id &&
          source.endpoint.host == host &&
          source.kind.name == snapshot['kind'] &&
          source.format.name == snapshot['format'] &&
          old['selected_record_index'] == index &&
          old['endpoint_host'] == host &&
          old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
          old['selected_raw_record_canonical_sha256'] ==
              snapshot['selected_raw_record_canonical_sha256'] &&
          old['normalized_legado_canonical_sha256'] ==
              snapshot['normalized_legado_sha256'],
      'three-source historical identity mismatch',
    );
    final oldHead = previous.where((row) => row['host'] == host).toList();
    final prior = priorRows[host];
    _require(
      oldHead.length == 1 &&
          prior != null &&
          oldHead.single['method'] == 'HEAD' &&
          oldHead.single['user_agent'] == 'not_recorded' &&
          oldHead.single['observed_at_utc'] ==
              (prior['latest_head'] as Map)['observed_at'] &&
          oldHead.single['http_status'] ==
              (prior['latest_head'] as Map)['http_status'],
      'three-source prior HEAD mismatch',
    );
    final current = samples.where((sample) => sample['host'] == host).toList();
    final discovery = current
        .map((r) => r['target'])
        .whereType<String>()
        .where((target) => target.startsWith('discovery_'))
        .toSet();
    _require(
      discovery.length == 2,
      'three-source discovery sample scope mismatch',
    );
    final mode = snapshot['search_mode'];
    output.add(output.reading, id, host, index, {
      'evidence': threeRedirectEvidenceFile,
      'observation_kind': 'bounded_redirect_recheck_scope',
      'historical_normalized_legado_sha256':
          snapshot['normalized_legado_sha256'],
      'previous_head_observed_at_utc': oldHead.single['observed_at_utc'],
      'previous_head_status': oldHead.single['http_status'],
      'previous_head_user_agent': oldHead.single['user_agent'],
      'current_get_user_agent_profile': snapshot['ua_profile'],
      'search_mode': mode,
      'original_search_post_submitted': mode == 'POST_not_sent' ? false : null,
      'declared_login_used': mode == 'GET_declared_login_not_used'
          ? false
          : null,
      'webview_rendered': mode == 'GET_webview_option_not_rendered'
          ? false
          : null,
      'declared_discovery_entry_count': snapshot['declared_nonempty_entries'],
      'sampled_discovery_entry_count': discovery.length,
      'full_readability_verified': null,
      'site_security_verified': null,
      'permanent_failure_verified': null,
    });
    for (final sample in current) {
      final item = <String, Object?>{
        'evidence': threeRedirectEvidenceFile,
        'observation_kind': 'bounded_redirect_recheck_get',
        'historical_normalized_legado_sha256':
            snapshot['normalized_legado_sha256'],
        'round': sample['round'],
        'target': sample['target'],
        'method': 'GET',
        'user_agent_profile': snapshot['ua_profile'],
        'observed_at_utc': sample['observed_at_utc'],
        'http_status': sample['http_status'],
        'redirect_category': sample['redirect_category'],
        'body_read': sample['body_read'],
        'missing_fields': sample['missing_fields'],
        'redirect_followed': false,
        'full_readability_verified': null,
        'site_security_verified': null,
        'permanent_failure_verified': null,
      };
      output.add(output.reading, id, host, index, item);
      if (sample['target'] == 'root') {
        output.add(output.network, id, host, index, {
          ...normalize(
            evidence: threeRedirectEvidenceFile,
            method: 'GET',
            path: '/',
            row: {
              'observed_at': sample['observed_at_utc'],
              'http_status': sample['http_status'],
            },
          ),
          'historical_normalized_legado_sha256':
              snapshot['normalized_legado_sha256'],
          'user_agent_profile': snapshot['ua_profile'],
          'redirect_category': sample['redirect_category'],
          'body_read': sample['body_read'],
          'missing_fields': sample['missing_fields'],
          'redirect_followed': false,
          'site_security_verified': null,
        });
      }
    }
  }
}

void addTargetedSourceReviews(
  Nov16LedgerEvidence output,
  Map redirected,
  Map myxzm,
  List rows,
  NetworkNormalizer normalize,
) {
  _addRedirectedReview(output, redirected, rows, normalize);
  _addMyxzmReview(output, myxzm, rows);
}

void _addRedirectedReview(
  Nov16LedgerEvidence output,
  Map redirected,
  List rows,
  NetworkNormalizer normalize,
) {
  final history = _targetedHistory(redirected['historical_ledger'] as Map);
  _require(
    (history['input_sha256'] as Map)[_catalogArchivePath] ==
        redirected['archive_sha256'],
    'redirect review historical archive mismatch',
  );
  final historicalById = {
    for (final row in (history['sources'] as List).cast<Map>())
      row['source_id']: row,
  };
  final rounds = (redirected['rounds'] as List).cast<Map>();
  final sources = (redirected['sources'] as List).cast<Map>();
  _require(rounds.length == 2 && sources.length == 2, 'redirect review size');
  final redirectTargets = {
    for (final round in rounds)
      for (final item in (round['observations'] as List).cast<Map>())
        item['redirect_host'],
  };
  _require(
    redirectTargets.length == 1 && redirectTargets.single is String,
    'redirect targets are not a single recorded third party',
  );
  for (final target in sources) {
    final id = target['source_id'];
    final index = target['selected_record_index'];
    final host = target['host'];
    _require(
      index is int && index >= 0 && index < rows.length,
      'invalid source index',
    );
    final source = parseBookSourceRecord(rows[index as int]);
    final old = historicalById[id];
    _require(
      old != null &&
          source.id == id &&
          source.endpoint.host == host &&
          old['selected_record_index'] == index &&
          old['endpoint_host'] == host &&
          old['selected_raw_record_canonical_sha256'] ==
              target['selected_raw_record_canonical_sha256'] &&
          old['normalized_legado_canonical_sha256'] ==
              target['normalized_legado_canonical_sha256'],
      'redirect source historical identity mismatch',
    );
    for (final round in rounds) {
      final items = (round['observations'] as List)
          .cast<Map>()
          .where((r) => r['host'] == host)
          .toList();
      final expected = <String>{
        'root:HEAD',
        'search:HEAD',
        'search:GET',
        if (host == 'www.3ubook.com') ...{'category:HEAD', 'category:GET'},
      };
      final actual = {
        for (final item in items) '${item['purpose']}:${item['method']}',
      };
      _require(
        items.length == expected.length && actual.containsAll(expected),
        'redirect observation coverage mismatch',
      );
      for (final item in items) {
        _require(
          item['status'] == 302 && item['redirect'] == 'other_host',
          'redirect observation mismatch',
        );
        final observation = <String, Object?>{
          'evidence': redirectedEvidenceFile,
          'observation_kind': 'bounded_source_request_redirect',
          'round': round['round'],
          'purpose': item['purpose'],
          'method': item['method'],
          'observed_at': item['observed_at'],
          'request_sha256': item['request_sha256'],
          'http_status': item['status'],
          'redirect_category': item['redirect'],
          'redirect_followed': false,
          'same_third_party_for_both_sources': true,
          'historical_normalized_legado_sha256':
              target['normalized_legado_canonical_sha256'],
          'maliciousness_verified': null,
          'readability_verified': null,
        };
        output.add(output.reading, id, host, index, observation);
        if (item['purpose'] == 'root') {
          output.add(output.network, id, host, index, {
            ...normalize(
              evidence: redirectedEvidenceFile,
              method: item['method'] as String,
              path: '/',
              row: item,
            ),
            'redirect_category': item['redirect'],
            'redirect_followed': false,
            'historical_normalized_legado_sha256':
                target['normalized_legado_canonical_sha256'],
          });
        }
      }
    }
  }
}

void _addMyxzmReview(Nov16LedgerEvidence output, Map myxzm, List rows) {
  final myxzmHistory =
      (myxzm['input_references'] as Map)['source_ledger_historical_git'] as Map;
  final target = myxzm['selection_snapshot'] as Map;
  final index = target['selected_record_index'];
  _require(
    index is int && index >= 0 && index < rows.length,
    'invalid sample index',
  );
  final source = parseBookSourceRecord(rows[index as int]);
  final myxzmLedger = _targetedHistory(myxzmHistory);
  _require(
    (myxzmLedger['input_sha256'] as Map)[_catalogArchivePath] ==
        ((myxzm['input_references'] as Map)['catalog_archive']
            as Map)['sha256'],
    'sampled source historical archive mismatch',
  );
  final myxzmMatches = (myxzmLedger['sources'] as List)
      .cast<Map>()
      .where((row) => row['source_id'] == target['source_id'])
      .toList();
  final old = myxzmMatches.length == 1 ? myxzmMatches.single : null;
  _require(
    old != null &&
        source.id == target['source_id'] &&
        source.endpoint.host == target['endpoint_host'] &&
        old['selected_record_index'] == index &&
        old['endpoint_host'] == target['endpoint_host'] &&
        old['endpoint_sha256'] == target['endpoint_sha256'] &&
        old['selected_raw_record_canonical_sha256'] ==
            target['selected_raw_record_canonical_sha256'] &&
        old['normalized_legado_canonical_sha256'] ==
            target['normalized_legado_sha256'],
    'sample source historical identity mismatch',
  );
  final evidence = ((myxzm['recorded_observations'] as Map)['evidence']) as Map;
  final search = evidence['search'] as Map;
  final a = evidence['sample_a'] as Map;
  final b = evidence['sample_b'] as Map;
  final candidate = evidence['single_class_candidate'] as Map;
  final control = evidence['synthetic_advertisement_control'] as Map;
  output.add(output.reading, source.id, source.endpoint.host, index, {
    'evidence': myxzmEvidenceFile,
    'observation_kind': 'bounded_two_sample_source_rule_review',
    'historical_normalized_legado_sha256': target['normalized_legado_sha256'],
    'search': {
      'observed_at_utc': search['observed_at_utc'],
      'http_status': search['status'],
      'old_rule_result_count': search['old_novel_search_rule_engine_books'],
      'novel_search_endpoint_verified':
          search['novel_search_endpoint_verified'],
    },
    'sample_a': {
      'detail_observed_at_utc': a['detail_observed_at_utc'],
      'detail_status': a['detail_status'],
      'chapter_count': a['old_toc_engine_chapters'],
      'content_observed_at_utc': a['content_observed_at_utc'],
      'content_status': a['content_status'],
      'old_rule_characters': a['old_content_characters'],
      'candidate_nodes': a['candidate_nodes'],
      'candidate_characters': a['candidate_characters'],
    },
    'sample_b': {
      'detail_observed_at_utc': b['detail_observed_at_utc'],
      'detail_status': b['detail_status'],
      'chapter_count': b['old_toc_engine_chapters'],
      'content_observed_at_utc': b['content_observed_at_utc'],
      'content_status': b['content_status'],
      'old_rule_characters': b['old_content_characters'],
      'candidate_nodes': b['two_class_candidate_nodes'],
      'candidate_characters': b['two_class_candidate_characters'],
      'later_other_container_characters':
          b['substantial_container_text_characters'],
      'later_structure_observed_at_utc':
          b['subsequent_static_structure_observed_at_utc'],
    },
    'single_class_candidate_tested_on_both_samples':
        candidate['actual_engine_tested_on_fetched_samples'],
    'single_class_candidate_refetches': [
      for (final key in ['sample_a_refetch', 'sample_b_refetch'])
        {
          'sample': key,
          'observed_at_utc': (candidate[key] as Map)['observed_at_utc'],
          'http_status': (candidate[key] as Map)['status'],
          'failure': (candidate[key] as Map)['failure'],
        },
    ],
    'candidate_retained_synthetic_advertisement':
        control['candidate_kept_advertisement_text'],
    'synthetic_script_executed': control['synthetic_script_executed'],
    'readability_verified': null,
    'site_security_verified': null,
  });
}

void addMixedHomeReview(
  Nov16LedgerEvidence output,
  Map evidence,
  List rows,
  NetworkNormalizer normalize,
) {
  final refs = evidence['input_references'] as Map;
  final history = _targetedHistory(refs['source_ledger_historical_git'] as Map);
  _require(
    (history['input_sha256'] as Map)[_catalogArchivePath] ==
        (refs['catalog_archive'] as Map)['sha256'],
    'mixed source historical archive mismatch',
  );
  final previous = {
    for (final row in (history['sources'] as List).cast<Map>())
      row['source_id']: row,
  };
  final snapshots = (evidence['source_snapshot'] as List).cast<Map>();
  final observations = (evidence['observations'] as List).cast<Map>();
  final decisions = evidence['decisions'] as Map;
  _require(
    snapshots.length == 5 && observations.length == 4,
    'mixed evidence size',
  );
  for (final snapshot in snapshots) {
    final id = snapshot['source_id'];
    final host = snapshot['host'];
    final index = snapshot['selected_record_index'];
    _require(
      index is int && index >= 0 && index < rows.length,
      'invalid mixed source index',
    );
    final source = parseBookSourceRecord(rows[index as int]);
    final old = previous[id];
    final decision = decisions[host] as Map;
    _require(
      old != null &&
          source.id == id &&
          source.endpoint.host == host &&
          old['selected_record_index'] == index &&
          old['endpoint_host'] == host &&
          old['endpoint_sha256'] == snapshot['endpoint_sha256'] &&
          old['selected_raw_record_canonical_sha256'] ==
              snapshot['selected_raw_record_canonical_sha256'] &&
          old['normalized_legado_canonical_sha256'] ==
              snapshot['normalized_legado_sha256'] &&
          (old['static_policy'] as Map)['adult_source_classified'] ==
              snapshot['static_adult_policy_snapshot'] &&
          decision['site_adult_status_from_sample'] == 'undetermined' &&
          decision['new_source_classification'] == 'not_supported',
      'mixed source historical identity or classification mismatch',
    );
    final samples = observations.where((row) => row['host'] == host).toList();
    _require(samples.length == 2, 'mixed homepage sample count');
    output.add(output.adultReview, id, host, index, {
      'evidence': mixedHomeEvidenceFile,
      'classification': 'insufficient_site_wide_adult_evidence',
      'site_adult_status_from_sample': 'undetermined',
      'new_source_classification': 'not_supported',
      'historical_adult_policy_snapshot':
          snapshot['static_adult_policy_snapshot'],
      'historical_normalized_legado_sha256':
          snapshot['normalized_legado_sha256'],
      'historical_same_host_adult_source_recorded': host == 'i.12bz.net',
      'source_risk_cleared': false,
      'site_security_verified': null,
    });
    for (final sample in samples) {
      output.add(output.network, id, host, index, {
        ...normalize(
          evidence: mixedHomeEvidenceFile,
          method: 'GET',
          path: '/',
          row: {
            'observed_at': sample['observed_at'],
            'http_status': sample['http_status'],
            'sample_bytes': sample['sample_bytes'],
            'truncated': sample['truncated'],
          },
        ),
        'site_adult_status_from_sample': 'undetermined',
        'adult_text_clue_recorded': null,
        'site_security_verified': null,
      });
    }
  }
}

void _verifyHistoricalCode(Map uaa, Map equivalent, Map ledger, Map reference) {
  final left = uaa['historical_normalized_source_code_sha256'] as Map;
  final right = equivalent['historical_normalized_source_code_sha256'] as Map;
  _require(
    left.isNotEmpty && left.length == right.length,
    'historical code digest set mismatch',
  );
  for (final entry in left.entries) {
    final path = entry.key as String;
    _require(
      right[path] == entry.value &&
          (ledger['normalized_source_code_sha256'] as Map)[path] == entry.value,
      'historical code digest evidence mismatch: $path',
    );
    final result = Process.runSync(
      'git',
      ['show', '${reference['git_commit']}:$path'],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    _require(result.exitCode == 0, 'historical code Git object missing: $path');
    final normalized = utf8
        .decode(result.stdout as List<int>)
        .replaceAll('\r\n', '\n');
    _require(
      _textSha(normalized) == entry.value,
      'historical code Git digest mismatch: $path',
    );
  }
}

Map _historicalIdentity(Map item, Map ledger, List rows) {
  final index = item['selected_record_index'];
  _require(
    index is int && index >= 0 && index < rows.length,
    'invalid historical record index',
  );
  final matches = (ledger['sources'] as List)
      .cast<Map>()
      .where((source) => source['selected_record_index'] == index)
      .toList();
  _require(matches.length == 1, 'historical selected record is ambiguous');
  final old = matches.single;
  for (final field in [
    'source_id',
    'kind',
    'endpoint_host',
    'normalized_legado_canonical_sha256',
  ]) {
    _require(old[field] == item[field], 'historical identity mismatch: $field');
  }
  _require(
    (old['static_policy'] as Map)['adult_source_classified'] ==
        item['adult_source_classified_at_historical_snapshot'],
    'historical adult policy mismatch',
  );
  final raw = parseBookSourceRecord(rows[index as int]);
  _require(
    raw.id == old['source_id'] && raw.endpoint.host == old['endpoint_host'],
    'archived source identity mismatch',
  );
  return old;
}

void _addUaa(Nov16LedgerEvidence output, Map evidence, Map ledger, List rows) {
  for (final entry in const [
    ('candidate', 'candidate_source', true),
    ('already_classified_comparison', 'already_classified_comparison', true),
    ('separate_dynamic_candidate', 'dynamic_category_unresolved', null),
    ('same_host_comic_counterexample', 'same_host_comic_counterexample', null),
  ]) {
    final item = evidence[entry.$1] as Map;
    _historicalIdentity(item, ledger, rows);
    output.add(
      output.adultReview,
      item['source_id'],
      item['endpoint_host'],
      item['selected_record_index'],
      {
        'evidence': uaaEvidenceFile,
        'observation_kind': 'historical_static_adult_source_review',
        'review_role': entry.$2,
        'evidence_generated_at': evidence['generated_at'],
        'historical_normalized_legado_sha256':
            item['normalized_legado_canonical_sha256'],
        'historical_source_adult_business_evidence': entry.$3,
        'literal_discovery_title_url_pairs':
            item['literal_discovery_title_url_pairs'],
        'common_unique_title_url_pairs_with_989':
            item['common_unique_title_url_pairs_with_989'],
        'all_literal_discovery_pairs_use_search_endpoint':
            item['all_literal_discovery_pairs_use_search_endpoint'],
        'dynamic_category_response_observed':
            item['dynamic_category_response_observed'],
        'whole_source_adult_classification_proven':
            item['whole_source_adult_classification_proven'],
        'current_webpage_verified': null,
        'source_scripts_executed': false,
      },
    );
  }
}

void _addEquivalents(
  Nov16LedgerEvidence output,
  Map evidence,
  Map ledger,
  Map labels,
  List rows,
) {
  for (final pair in (evidence['pairs'] as List).cast<Map>()) {
    final labelled = pair['labelled_source'] as Map;
    final candidate = pair['candidate_source'] as Map;
    final counter = pair['same_host_different_rule_counterexample'] as Map;
    final oldLabelled = _historicalIdentity(labelled, ledger, rows);
    final oldCandidate = _historicalIdentity(candidate, ledger, rows);
    _historicalIdentity(counter, ledger, rows);
    _require(
      labelled['source_id'] != candidate['source_id'] &&
          labelled['endpoint_host'] == candidate['endpoint_host'] &&
          labelled['format'] == candidate['format'] &&
          labelled['format'] == oldLabelled['format'] &&
          candidate['format'] == oldCandidate['format'] &&
          labelled['endpoint_sha256'] == candidate['endpoint_sha256'] &&
          labelled['endpoint_sha256'] == oldLabelled['endpoint_sha256'] &&
          candidate['endpoint_sha256'] == oldCandidate['endpoint_sha256'] &&
          labelled['normalized_legado_canonical_sha256'] ==
              candidate['normalized_legado_canonical_sha256'] &&
          counter['endpoint_host'] == labelled['endpoint_host'] &&
          counter['source_id'] != candidate['source_id'] &&
          counter['normalized_legado_canonical_sha256'] !=
              candidate['normalized_legado_canonical_sha256'],
      'historical rule equivalence or same-host counterexample mismatch',
    );
    final explicit = pair['explicit_label'] as Map;
    final labelIndex = explicit['record_index'] as int;
    _require(
      labelIndex >= 0 &&
          labelIndex < rows.length &&
          (rows[labelIndex] as Map)['bookSourceName'] == explicit['name'] &&
          (explicit['name'] as String).contains('🔞'),
      'historical explicit label mismatch',
    );
    _require(
      (oldLabelled['related_same_id_and_endpoint_host_record_indices'] as List)
          .contains(labelIndex),
      'label record does not match source identity',
    );
    final labelRows = (labels['sources'] as List)
        .cast<Map>()
        .where((row) => row['id'] == labelled['source_id'])
        .toList();
    _require(
      labelRows.length == 1 &&
          (labelRows.single['raw_label_evidence'] as List).cast<Map>().any(
            (row) =>
                row['index'] == labelIndex &&
                row['host'] == labelled['endpoint_host'] &&
                row['name'] == explicit['name'],
          ),
      'historical Git label evidence mismatch',
    );
    for (final entry in [
      (labelled, 'labelled_source', true),
      (candidate, 'equivalent_independent_source_id', true),
      (counter, 'same_host_different_rule_counterexample', null),
    ]) {
      final item = entry.$1;
      output.add(
        output.adultReview,
        item['source_id'],
        item['endpoint_host'],
        item['selected_record_index'],
        {
          'evidence': equivalentEvidenceFile,
          'observation_kind': 'historical_static_rule_equivalence_review',
          'review_role': entry.$2,
          'evidence_generated_at': evidence['generated_at'],
          'historical_normalized_legado_sha256':
              item['normalized_legado_canonical_sha256'],
          'historical_source_adult_business_evidence': entry.$3,
          'historical_label_source_id': labelled['source_id'],
          'historical_label_record_index': labelIndex,
          'host_wide_classification_inferred': false,
          'current_webpage_verified': null,
          'source_scripts_executed': false,
        },
      );
    }
  }
}

void _verifyPilotInputs(Map pilot, String archiveSha, String manifestSha) {
  for (final key in [
    'source_file_sha256_at_initial',
    'source_file_sha256_at_followup',
  ]) {
    final inputs = pilot[key] as Map;
    _require(
      inputs['assets/catalogs/books/legado/catalog.json.bz2'] == archiveSha &&
          inputs['assets/catalogs/books/legado/manifest.json'] == manifestSha,
      'two-chain pilot archive/manifest mismatch',
    );
  }
}

void _addPilot(
  Nov16LedgerEvidence output,
  Map evidence,
  List rows,
  NetworkNormalizer normalize,
) {
  final sources = <String, Map>{};
  for (final item in (evidence['sources'] as List).cast<Map>()) {
    final index = item['raw_selected_index'] as int;
    _require(
      index >= 0 && index < rows.length,
      'two-chain source index out of bounds',
    );
    final raw = parseBookSourceRecord(rows[index]);
    _require(
      raw.id == item['id'] &&
          raw.endpoint.host == item['host'] &&
          !sources.containsKey(raw.id),
      'two-chain archived source identity mismatch',
    );
    _validatePilotRuleHashes(item);
    sources[raw.id] = item;
  }
  _require(sources.length == 2, 'two-chain source count mismatch');
  for (final event in (evidence['observations'] as List).cast<Map>()) {
    final item =
        sources[event['source_id']] ??
        (throw const FormatException('unknown two-chain observation source'));
    _addPilotEvent(output, event, item, normalize);
  }
  final seen = <String>{};
  for (final finding in (evidence['findings'] as List).cast<Map>()) {
    final id = finding['source_id'] as String;
    final item =
        sources[id] ??
        (throw const FormatException('unknown two-chain finding source'));
    _require(seen.add(id), 'duplicate two-chain finding');
    _addPilotFinding(output, evidence, finding, item);
  }
  _require(seen.length == sources.length, 'two-chain finding missing');
}

void _addPilotEvent(
  Nov16LedgerEvidence output,
  Map event,
  Map item,
  NetworkNormalizer normalize,
) {
  _require(
    event['host'] == item['host'],
    'two-chain observation host mismatch',
  );
  final uri = Uri.parse(event['uri'] as String);
  _require(
    event['method'] == 'GET' &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.host == item['host'] &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment,
    'two-chain observation URI or method mismatch',
  );
  final cap = event['byte_cap'];
  final bytes = event['sample_bytes'];
  final truncated = event['truncated'];
  _require(
    cap is int &&
        bytes is int &&
        bytes > 0 &&
        bytes <= cap &&
        truncated is bool,
    'invalid two-chain sample bounds',
  );
  if (truncated == true) {
    _require(
      bytes == cap &&
          event['sample_sha256'] == null &&
          event['failure'] == 'over_limit_no_parse',
      'invalid truncated sample',
    );
  } else {
    _require(
      event['sample_sha256'] is String &&
          RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(event['sample_sha256'] as String) &&
          event['failure'] == null,
      'invalid complete sample',
    );
  }
  output.add(
    output.network,
    item['id'],
    item['host'],
    item['raw_selected_index'],
    {
      ...normalize(
        evidence: twoChainEvidenceFile,
        method: event['method'] as String,
        path: uri.path,
        row: event,
      ),
      'sample_started_at': event['started_at'],
      'observation_id': event['observation_id'],
      'stage': event['stage'],
      'phase': event['phase'],
      'sample_byte_cap': cap,
      'truncated_sample_parsed': truncated ? false : null,
      'historical_response_body_retained': false,
      'historical_intermediate_snapshots_version_controlled': false,
      'source_scripts_executed': false,
      'historical_search_rule_sha256': item['search_rule_sha256'],
      'historical_rule_sha256': item['rule_sha256'],
    },
  );
}

void _addPilotFinding(
  Nov16LedgerEvidence output,
  Map evidence,
  Map finding,
  Map item,
) {
  final search = finding['search'] as Map;
  final detail = finding['detail'] as Map;
  final toc = finding['toc'] as Map;
  final content = finding['content'] as Map;
  final length = content['content_length_utf16_code_units'];
  final parsed = content['parsed'] == false
      ? false
      : length is int && length > 0
      ? true
      : null;
  final matching = (evidence['observations'] as List).cast<Map>().where(
    (event) => event['source_id'] == item['id'],
  );
  bool completed(String stage, {Object? uri}) => matching.any(
    (event) =>
        event['stage'] == stage &&
        (uri == null || event['uri'] == uri) &&
        event['http_status'] == 200 &&
        event['truncated'] == false &&
        event['failure'] == null,
  );
  final sampleChain =
      parsed == true &&
      search['parsed_books'] is int &&
      search['parsed_books'] > 0 &&
      detail['old_rule_toc_output'] is String &&
      toc['old_rule_chapters_first_page'] is int &&
      toc['old_rule_chapters_first_page'] > 0 &&
      toc['first_chapter_url'] is String &&
      completed('search') &&
      completed('detail') &&
      completed('toc', uri: detail['old_rule_toc_output']) &&
      completed('content', uri: toc['first_chapter_url']);
  final policyPath = 'lib/features/books/domain/book_source_risk.dart';
  output.add(
    output.reading,
    item['id'],
    item['host'],
    item['raw_selected_index'],
    {
      'evidence': twoChainEvidenceFile,
      'observation_kind': 'one_synthetic_search_and_one_book_sample',
      'observation_start_utc': evidence['observation_start_utc'],
      'observation_end_utc': evidence['observation_end_utc'],
      'search_books_reported':
          search['parsed_books'] ?? search['parsed_books_sample'],
      'search_result_reporting_cap': search['result_reporting_cap'],
      'search_keyword_matches_reported': search['matching_in_sample'],
      'toc_chapters_observed':
          toc['old_rule_chapters_first_page'] ??
          toc['old_rule_chapters_on_detail_page'],
      'toc_pagination_link_candidates': toc['pagination_link_candidates'],
      'toc_pagination_fetched': toc['pagination_fetched'],
      'content_sample_parsed': parsed,
      'content_sample_utf16_code_units': length,
      'content_sample_sha256_utf8': content['content_sha256_utf8'],
      'content_limit_rechecks_bytes': content['limit_rechecks_bytes'],
      'prior_one_sample_reading_chain_reported': sampleChain ? true : null,
      'full_book_reading_verified': null,
      'content_safety_verified': null,
      'historical_response_body_retained': false,
      'historical_intermediate_snapshots_version_controlled': false,
      'historical_workspace_policy_snapshots_retained': null,
      'historical_workspace_policy_sha256_initial':
          (evidence['source_file_sha256_at_initial'] as Map)[policyPath],
      'historical_workspace_policy_sha256_followup':
          (evidence['source_file_sha256_at_followup'] as Map)[policyPath],
      'historical_page_parsing_independently_recomputed': false,
      'parser_engine': 'Dart VM LegadoOperation',
      'source_scripts_executed': false,
      'historical_search_rule_sha256': item['search_rule_sha256'],
      'historical_rule_sha256': item['rule_sha256'],
    },
  );
}

void _validatePilotRuleHashes(Map item) {
  _require(
    _textSha(item['search'] as String) == item['search_rule_sha256'],
    'two-chain search rule digest mismatch',
  );
  final rules = item['rules'] as Map;
  final hashes = item['rule_sha256'] as Map;
  _require(
    rules.length == hashes.length &&
        rules.entries.every(
          (entry) =>
              entry.value is String &&
              hashes[entry.key] == _textSha(entry.value as String),
        ),
    'two-chain rule digest mismatch',
  );
}
