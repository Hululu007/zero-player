// Run with `dart tool/test_audit_book_source_ledger.dart`; no Flutter or network.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/domain/book.dart';

import 'audit_book_source_ledger.dart' as ledger;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

BookSource source(String endpoint) => BookSource.fromJson({
  'name': 'fixture',
  'kind': 'text',
  'format': 'html',
  'url': endpoint,
  'legado': {'search': '/search?q={{key}}', 'rules': <String, String>{}},
});

void checkCommunityRelations() {
  final current = source('https://www.example.com/');
  final collision = source('https://example.com/');
  check(collision.id == current.id, 'fixture needs the legacy ID collision');
  final observation = ledger.HostObservation(
    'www.example.com',
    {current.id},
    {17},
    {},
  );
  check(observation.matches(current, {17}), 'exact identity must match');
  check(
    !observation.matches(collision, {17}),
    'ID collision must not cross hosts',
  );
  final indexOnly = ledger.HostObservation('www.example.com', {}, {17}, {});
  check(
    !indexOnly.matches(current, {18}),
    'unrelated record index must not match',
  );
  final evidence = {
    'comparison': {
      'categories': {
        'malware': {
          'selected_sources_by_relation': {
            'exact_endpoint': [
              {
                'source_id': current.id,
                'source_endpoint_host': current.endpoint.host,
                'selected_record_index': 17,
                'signals': [
                  {
                    'catalog_host': 'www.example.com',
                    'listed_domain': 'www.example.com',
                    'relation': 'exact',
                    'fields': ['selected_imported_host'],
                  },
                  {
                    'catalog_host': 'www.example.com',
                    'listed_domain': 'example.com',
                    'relation': 'listed_parent',
                    'fields': ['selected_imported_host'],
                  },
                  {
                    'catalog_host': 'static.example.com',
                    'listed_domain': 'example.com',
                    'relation': 'listed_parent',
                    'fields': ['ruleContent.content'],
                  },
                ],
              },
            ],
            'listed_parent_endpoint': <Object>[],
            'other_fields_only': <Object>[],
          },
        },
      },
    },
  };
  final clues = ledger.communityClues(evidence, current, 18);
  check(clues['exact_endpoint']!.length == 1, 'exact endpoint signal missing');
  check(
    clues['listed_parent_of_endpoint']!.length == 1,
    'parent domain signal missing',
  );
  check(
    clues['other_fields_only']!.length == 1,
    'separate rule-field signal missing',
  );
  check(
    clues.values
        .expand((items) => items)
        .every((row) => row['matches_current_selected_record'] == false),
    'older selected-record evidence must remain explicitly historical',
  );
  final historicalFlags = ledger.communityReviewFlags(clues);
  for (final relation in [
    'exact_endpoint',
    'listed_parent_of_endpoint',
    'other_fields_only',
  ]) {
    check(
      historicalFlags['community_${relation}_current_selected_raw'] == false,
      'stale record 17 must not become a current record 18 hit',
    );
    check(
      historicalFlags['community_${relation}_other_historical_raw'] == true,
      'stale record must remain visible as a historical clue',
    );
  }
  final currentFlags = ledger.communityReviewFlags(
    ledger.communityClues(evidence, current, 17),
  );
  check(
    currentFlags['community_exact_endpoint_current_selected_raw'] == true,
    'matching selected record should be associated',
  );
  check(
    currentFlags['community_exact_endpoint_other_historical_raw'] == false,
    'current record must not be labeled historical',
  );
  check(
    ledger
        .communityClues(evidence, collision, 17)
        .values
        .every((items) => items.isEmpty),
    'same ID on a different endpoint must not inherit list clues',
  );
}

void checkObservationSemantics() {
  final response = ledger.networkObservation(
    evidence: 'fixture.json',
    method: 'GET',
    path: '/',
    endpoint: Uri.parse('https://example.com'),
    row: {
      'status': 200,
      'classification': 'http_200',
      'title': 'DO NOT COPY TITLE',
      'body': 'DO NOT COPY BODY',
      'sample': {
        'adult_signals': <String>[],
        'betting_signals': ['signal'],
      },
      'visible_text_clues': {
        'photography_or_sexy': [
          {'word': 'DO NOT COPY WORD', 'excerpt': 'DO NOT COPY EXCERPT'},
        ],
      },
    },
  );
  check(
    response['path_relation'] == 'endpoint_path',
    'empty endpoint path represents the root',
  );
  check(
    response['failure_category'] == null,
    'HTTP classification is not a failure',
  );
  check(
    response['adult_text_clue_recorded'] == false,
    'explicit empty clue list must be retained',
  );
  check(
    response['gambling_text_clue_recorded'] == true,
    'recorded text clue missing',
  );
  check(
    response['photography_or_sexy_text_clue_recorded'] == true,
    'recorded photography clue missing',
  );
  check(
    !jsonEncode(response).contains('DO NOT COPY'),
    'page title or body leaked',
  );
  final timeout = ledger.networkObservation(
    evidence: 'fixture.json',
    method: 'HEAD',
    path: '/',
    row: {'error': 'TimeoutError: timed out'},
  );
  final unknown = ledger.networkObservation(
    evidence: 'fixture.json',
    method: 'GET',
    path: '/',
    row: {},
  );
  check(
    timeout['outcome'] == 'no_http_response_recorded',
    'timeout is no response',
  );
  check(
    unknown['outcome'] == 'status_and_failure_not_recorded',
    'unrecorded is unknown',
  );
  check(
    unknown['adult_text_clue_recorded'] == null,
    'no sample cannot mean no adult text',
  );
  check(
    unknown['photography_or_sexy_text_clue_recorded'] == null,
    'no sample cannot mean no photography clue',
  );
  check(
    ledger.networkCoverage([]) == 'no_observation',
    'empty observation set',
  );
  check(
    ledger.networkCoverage([unknown]) == 'status_and_failure_not_recorded',
    'unknown coverage',
  );
  check(
    ledger.networkCoverage([timeout]) == 'no_response_recorded',
    'no-response coverage',
  );
  check(
    ledger.networkCoverage([response, timeout]) ==
        'response_and_no_response_recorded',
    'responses and no-responses must both remain visible',
  );
}

void checkScanAndDescriptionStates() {
  check(
    ledger.amsiDetectionRecorded([]) == null,
    'no AMSI scan must stay unknown',
  );
  check(
    ledger.amsiDetectionRecorded([
          {
            'root_scan_classification': 'not_scanned_or_unknown',
            'inline_detection_recorded': null,
          },
        ]) ==
        null,
    'an unscanned sample is not a negative',
  );
  check(
    ledger.amsiDetectionRecorded([
          {
            'root_scan_classification': 'not_detected',
            'inline_detection_recorded': null,
          },
        ]) ==
        false,
    'bounded non-detection should be recorded',
  );
  check(
    ledger.amsiDetectionRecorded([
          {
            'root_scan_classification': 'not_detected',
            'inline_detection_recorded': true,
          },
        ]) ==
        true,
    'inline detection must not be lost',
  );
  check(
    ledger.homepageDescriptionAdult(null) == null,
    'missing description must stay unknown',
  );
  check(
    ledger.homepageDescriptionAdult('一般小说书站') == false,
    'unmarked description clue',
  );
  check(
    ledger.homepageDescriptionAdult('免费的在线成人黄色小说站') == true,
    'reviewed adult description clue',
  );
}

void checkSelectedVersionComparison() {
  final old = source('https://www.example.com/');
  final withAdultEvidence = BookSource.fromJson({
    ...old.toJson(),
    'adultEvidence': true,
  });
  final otherRules = BookSource.fromJson({
    ...old.toJson(),
    'legado': {...old.legado!.toJson(), 'search': '/changed?q={{key}}'},
  });
  check(
    ledger.selectedVersionMatches(old, withAdultEvidence),
    'adult evidence union is allowed',
  );
  check(
    !ledger.selectedVersionMatches(withAdultEvidence, old),
    'adult evidence cannot be lost',
  );
  check(otherRules.id == old.id, 'changed rule fixture must have the same ID');
  check(
    !ledger.selectedVersionMatches(old, otherRules),
    'same-ID wrong rule version must be rejected',
  );
}

void checkExactCurrentDoh() {
  final registry = {
    'current_public_doh_observations': [
      {'host': 'example.com', 'classification': 'control'},
      {'host': 'taotaoshu8.com', 'classification': 'parent'},
      {'host': 'm.taotaoshu8.com', 'classification': 'sibling'},
      {'host': 'www.taotaoshu8.com', 'classification': 'exact'},
    ],
  };
  final exact = ledger.currentDohObservations(registry, 'www.taotaoshu8.com');
  check(exact.length == 1, 'only the exact queried host can be linked');
  check(
    exact.single['classification'] == 'exact',
    'wrong current DNS observation',
  );
  check(
    exact.single['queried_host'] == 'www.taotaoshu8.com',
    'wrong queried host',
  );
  check(
    ledger.currentDohObservations(registry, 'absent.invalid').isEmpty,
    'missing host must stay unknown',
  );
}

void checkInputFingerprints() {
  final lf = utf8.encode('packages:\n  fixture: value\n');
  final crlf = utf8.encode('packages:\r\n  fixture: value\r\n');
  final changed = utf8.encode('packages:\r\n  fixture: changed\r\n');
  check(
    ledger.inputFingerprint('pubspec.lock', lf) ==
        ledger.inputFingerprint('pubspec.lock', crlf),
    'lockfile fingerprint must be independent of CRLF checkout',
  );
  check(
    ledger.inputFingerprint('pubspec.lock', lf) !=
        ledger.inputFingerprint('pubspec.lock', changed),
    'lockfile content changes must remain detectable',
  );
  check(
    ledger.inputFingerprint('evidence.json', lf) !=
        ledger.inputFingerprint('evidence.json', crlf),
    'evidence must retain its original byte-level fingerprint',
  );
  check(
    ledger.inputFingerprint('evidence.json', crlf) ==
        sha256.convert(crlf).toString(),
    'ordinary evidence digest must use the original bytes',
  );
}

void checkNoPageContent(Object? value) {
  const forbidden = {
    'body',
    'html',
    'title',
    'description',
    'cookie',
    'headers',
  };
  if (value is Map) {
    for (final entry in value.entries) {
      check(
        !forbidden.contains(entry.key),
        'unexpected raw page field ${entry.key}',
      );
      checkNoPageContent(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      checkNoPageContent(item);
    }
  }
}

void checkActualReplay() {
  final root = Directory.systemTemp.createTempSync('zero-player-ledger-test-');
  final outputs = [
    File('${root.path}/first.json'),
    File('${root.path}/second.json'),
  ];
  try {
    for (final output in outputs) {
      final process = Process.runSync(Platform.resolvedExecutable, [
        'tool/audit_book_source_ledger.dart',
        output.path,
      ], workingDirectory: Directory.current.path);
      check(process.exitCode == 0, 'offline ledger failed: ${process.stderr}');
    }
    final first = outputs.first.readAsBytesSync();
    final second = outputs.last.readAsBytesSync();
    check(
      sha256.convert(first) == sha256.convert(second),
      'same inputs must yield identical output bytes',
    );
    final document = jsonDecode(utf8.decode(first)) as Map;
    final rows = (document['sources'] as List).cast<Map>();
    checkReplaySelection(rows);
    checkReplayClues(rows);
    checkReplayPilot(rows);
    checkReplayNetwork(rows, document);
  } finally {
    for (final output in outputs) {
      if (output.existsSync()) output.deleteSync();
    }
    root.deleteSync();
  }
}

void checkReplaySelection(List<Map> rows) {
  check(rows.length == 2139, 'current importer should select 2139 sources');
  check(
    rows.map((row) => row['source_id']).toSet().length == rows.length,
    'source IDs must be unique',
  );
  for (final row in rows) {
    check(
      (row['normalized_source_canonical_sha256'] as String).length == 64,
      'missing normalized source digest',
    );
    check(
      (row['related_same_id_and_endpoint_host_record_indices'] as List)
          .contains(row['selected_record_index']),
      'selected raw index missing',
    );
    checkNoPageContent(row);
  }
  final tao = rows.singleWhere(
    (row) =>
        row['source_id'] ==
        '827f2fea6fcae97d0fde45d48abffc4ffd50afd13f6bc8b6b721041ddeb95dc4',
  );
  check(tao['selected_record_index'] == 1014, 'unexpected 桃桃 selected record');
  check(
    (tao['static_policy'] as Map)['fixed_unavailable_rule'] == true,
    'exact unavailable rule not reflected',
  );
  check(
    (tao['static_policy'] as Map)['fixed_orphan_history_id'] == false,
    'availability must not imply an orphan blacklist',
  );
  check(
    tao['network_coverage'] == 'no_response_recorded',
    'previous no-responses must not become safe or available',
  );
  check(
    (tao['registry_and_doh_observations'] as List).isNotEmpty,
    'registry/DNS observations missing',
  );
  final currentDoh = (tao['registry_and_doh_observations'] as List)
      .cast<Map>()
      .where(
        (row) =>
            row['observation_kind'] == 'current_public_doh_exact_endpoint_host',
      )
      .toList();
  check(
    currentDoh.length == 4,
    'expected four current exact-host DNS observations',
  );
  check(
    currentDoh.every((row) => row['queried_host'] == 'www.taotaoshu8.com'),
    'parent-domain and control DNS observations must not be attached',
  );
}

void checkReplayClues(List<Map> rows) {
  final tao = rows.singleWhere(
    (row) =>
        row['source_id'] ==
        '827f2fea6fcae97d0fde45d48abffc4ffd50afd13f6bc8b6b721041ddeb95dc4',
  );
  final photography = rows.singleWhere(
    (row) => row['endpoint_host'] == 'www.635k.com',
  );
  check(
    (photography['review_clues']
            as Map)['photography_or_sexy_text_clue_recorded'] ==
        true,
    'photography clue must be retained without its source excerpt',
  );
  check(
    (tao['review_clues'] as Map)['photography_or_sexy_text_clue_recorded'] ==
        null,
    'unsampled category must remain unknown',
  );
  check(
    (tao['review_clues'] as Map)['adult_text_clue_recorded'] == null,
    'unassessed adult text must remain unknown',
  );
  check(
    (tao['review_clues'] as Map)['amsi_detection_recorded'] == null,
    'unscanned AMSI must remain unknown',
  );
  final sesebooks = rows.firstWhere(
    (row) => row['endpoint_host'] == 'sesebooks.com',
  );
  check(
    (sesebooks['review_clues'] as Map)['adult_text_clue_recorded'] == true,
    'reviewed adult homepage description must be recorded',
  );
  check(
    (sesebooks['network_observations'] as List).cast<Map>().any(
      (row) =>
          row['adult_text_clue_basis'] == 'reviewed_homepage_description' &&
          row['adult_text_clue_recorded'] == true,
    ),
    'adult homepage description provenance is required',
  );
  final bbs = rows.singleWhere(
    (row) => row['endpoint_host'] == 'bbs.fanfanu.com',
  );
  check(
    (bbs['review_clues'] as Map)['amsi_detection_recorded'] == true,
    'initial and follow-up detection must remain a review clue',
  );
  check(
    (bbs['amsi_observations'] as List).cast<Map>().any(
      (row) =>
          row['evidence'] == 'legado-amsi-template-clusters-20261115.json' &&
          row['root_scan_classification'] == 'detected' &&
          row['root_sample_sha256'] != null,
    ),
    'formal cluster recheck not associated',
  );
}

void checkReplayPilot(List<Map> rows) {
  final ant = rows.singleWhere(
    (row) =>
        row['source_id'] ==
        '483d7c92f8871bb1e84d45883d9a6ea0705afe1265615146ece1b2c9fbef90ad',
  );
  final pilot = (ant['search_and_discovery_observations'] as List).cast<Map>();
  final initialSearch = pilot.singleWhere(
    (row) => row['observation_kind'] == 'initial_synthetic_search',
  );
  final novelRanking = pilot.singleWhere(
    (row) => row['observation_kind'] == 'discovery_novel_ranking',
  );
  final comic = pilot.singleWhere(
    (row) =>
        row['observation_kind'] ==
        'experimental_comic_selector_not_novel_search',
  );
  check(
    initialSearch['row_count'] == 29 && initialSearch['books'] == 0,
    'novel source original search did not produce books',
  );
  check(
    novelRanking['old_rule_discovery_books'] == 20,
    'novel discovery observation missing',
  );
  check(
    comic['comic_books'] == 6,
    'comic selector experiment must remain separate from novel search',
  );
  check(
    rows
            .where(
              (row) =>
                  (row['search_and_discovery_observations'] as List).isNotEmpty,
            )
            .length ==
        5,
    'search pilot must link exactly five IDs',
  );
}

void checkReplayNetwork(List<Map> rows, Map document) {
  final observations = rows
      .expand((row) => (row['network_observations'] as List).cast<Map>())
      .toList();
  check(
    observations.any(
      (event) =>
          event['method'] == 'GET' && event['adult_text_clue_recorded'] == true,
    ),
    'expected prior GET text clue',
  );
  check(
    observations.every(
      (event) =>
          event['method'] != 'HEAD' ||
          event['adult_text_clue_recorded'] == null,
    ),
    'GET sample must not be attributed to HEAD',
  );
  check(
    (document['community_inputs']
            as Map)['cert_polska_matching_host_indicator_pairs'] ==
        0,
    'CERT Polska zero-match input changed',
  );
  check(
    (document['formal_amsi_rechecks_without_selected_source_match'] as List)
            .length ==
        2,
    'both formal 4qo rechecks should remain explicitly unmatched',
  );
  check(
    (document['input_sha256'] as Map).containsKey('pubspec.lock'),
    'lockfile digest missing',
  );
  check(
    (document['input_sha256'] as Map)['pubspec.lock'] ==
        ledger.inputFingerprint(
          'pubspec.lock',
          File('pubspec.lock').readAsBytesSync(),
        ),
    'ledger lockfile digest must use the normalized convention',
  );
  for (final path in [
    'lib/features/books/data/legado/legado_discovery.dart',
    'lib/features/books/data/legado/legado_request.dart',
    'lib/features/books/data/legado/legado_rule_tokens.dart',
  ]) {
    check(
      (document['normalized_source_code_sha256'] as Map).containsKey(path),
      'missing transitive source digest',
    );
  }
}

void main() {
  checkCommunityRelations();
  checkObservationSemantics();
  checkScanAndDescriptionStates();
  checkExactCurrentDoh();
  checkInputFingerprints();
  checkSelectedVersionComparison();
  checkActualReplay();
  stdout.writeln('book source ledger offline checks passed');
}
