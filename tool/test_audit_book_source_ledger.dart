// Run with `dart tool/test_audit_book_source_ledger.dart`; no Flutter or network.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'audit_book_source_ledger.dart' as ledger;
import 'book_source_ledger_recent_evidence.dart' as recent;
import 'book_source_ledger_nov16_evidence.dart' as nov16;
import 'book_source_ledger_com_rdap.dart' as com;

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

recent.RecentLedgerEvidence loadRecentEvidence() {
  final data = <String, Map>{};
  for (final name in [
    'legado-rdap-net-sample-20261115.json',
    'legado-amsi-redirect-recheck-20261115.json',
    'legado-adult-category-recheck-20261115.json',
    'legado-560xs-recheck-20261115.json',
  ]) {
    data[name] =
        jsonDecode(File('docs/implementation/$name').readAsStringSync()) as Map;
  }
  return recent.readRecentEvidence(data, ledger.networkObservation);
}

void checkRecentRegistry(recent.RecentLedgerEvidence evidence) {
  const id = 'ca828313e6ceaa40c92460bc887e80428500586838f387e9dee325a104768804';
  final records = recent.selectRecentEvidence(
    evidence.registry,
    id,
    'www.feiyuefw.net',
    466,
  );
  final rdap = records
      .where((item) => item['observation_kind'] == 'rdap_registered_domain')
      .toList();
  check(
    rdap.where((item) => item['http_status'] == 404).length == 2,
    'both registry 404 observations must remain visible',
  );
  check(
    rdap
            .where(
              (item) =>
                  item['http_status'] == null &&
                  item['error_type'] == 'URLError',
            )
            .length ==
        2,
    'registry request errors must remain unknown',
  );
  check(
    records.every(
      (item) => item['matches_current_selected_raw_record'] == true,
    ),
    'expected current source index association',
  );
  check(
    recent
        .selectRecentEvidence(evidence.registry, id, 'feiyuefw.net', 466)
        .isEmpty,
    'registry evidence cannot cross exact endpoint hosts',
  );
  final stale = recent.selectRecentEvidence(
    evidence.registry,
    id,
    'www.feiyuefw.net',
    467,
  );
  check(
    stale.every((item) => item['matches_current_selected_raw_record'] == false),
    'historical source-version mismatch must remain explicit',
  );
  const counterexample =
      '955dc0ed76b43c148ce8afdfdb54faf7f6ee4a8ac3d51081184b43c2697e935e';
  final registered = recent.selectRecentEvidence(
    evidence.registry,
    counterexample,
    'afdian.net',
    3252,
  );
  check(
    registered
            .where((item) => item['classification'] == 'matching_domain_object')
            .length ==
        2,
    'registered-domain counterexample missing',
  );
}

void checkRecentRedirects(recent.RecentLedgerEvidence evidence) {
  const id = '99dec828e154116574529a7c8013e0e1d08c12ccb01ffa57a1da3ee7aebb8654';
  final events = recent
      .selectRecentEvidence(evidence.network, id, 'bbs.fanfanu.com', 168)
      .where(
        (item) =>
            item['evidence'] == 'legado-amsi-redirect-recheck-20261115.json',
      )
      .toList();
  check(
    events.length == 1 && events.single['http_status'] == 302,
    'later redirect observation missing',
  );
  check(
    events.single['additional_amsi_scan_performed'] == false,
    'redirect must not be represented as a new AMSI scan',
  );
  check(
    recent
        .selectRecentEvidence(evidence.network, id, 'www.fanfanu.com', 168)
        .isEmpty,
    'redirect evidence cannot cross sibling hosts',
  );
}

void checkRecentAdultCategories(recent.RecentLedgerEvidence evidence) {
  const adultId =
      '1f9aaa829a5d0312520cbcce9a4b9b84c7c12cd1d9f0adc6faecb042a9b15c17';
  const mixedId =
      '68051e1286ea64cd9e4dd6d05fd5f3ed286ade6837c4fff648aeb9b016e735cd';
  final adult = recent
      .selectRecentEvidence(evidence.network, adultId, 'zhanvxs.net', 4653)
      .single;
  final mixed = recent
      .selectRecentEvidence(evidence.network, mixedId, '123xiaoqiang.me', 4464)
      .single;
  check(
    adult['adult_text_clue_recorded'] == true &&
        mixed['adult_text_clue_recorded'] == false,
    'two reviewed homepage descriptions must remain distinct',
  );
  final mixedCategories = recent
      .selectRecentEvidence(
        evidence.categories,
        mixedId,
        '123xiaoqiang.me',
        4464,
      )
      .single;
  check(
    mixedCategories['explicit_unique_path_count'] == 4 &&
        mixedCategories['current_normalized_categories_may_differ'] == true,
    'mixed historical category evidence missing',
  );
  check(
    !jsonEncode(adult).contains('description_excerpt'),
    'homepage description must not be copied',
  );
  check(
    recent
        .selectRecentEvidence(
          evidence.categories,
          adultId,
          'www.zhanvxs.net',
          4653,
        )
        .isEmpty,
    'adult evidence cannot cross hosts even if an ID collides',
  );
}

void checkRecent560Review(recent.RecentLedgerEvidence evidence) {
  const id = 'bca6e55770d00d422fc5ca90194c062433fd5955601b573c28cc5533a22f4bf4';
  final review = recent
      .selectRecentEvidence(evidence.reading, id, 'www.560xs.com', 282)
      .single;
  check(
    review['experimental_post_books'] == 1 &&
        review['post_result_detail_fetched'] == false,
    'POST result must remain separate from other book samples',
  );
  check(
    review['toc_http_status'] == 200 &&
        review['toc_body_state'] == 'timeout_unknown' &&
        review['toc_chapters_verified'] == null &&
        review['complete_reading_chain_verified'] == null,
    'response headers cannot imply a verified table of contents or reading chain',
  );
  check(
    review['old_parsed_content_characters'] == 0 &&
        review['page_scripts_executed'] == false &&
        review['content_safety_verified'] == null,
    'content sample must not imply reading or safety',
  );
  final events = recent.selectRecentEvidence(
    evidence.network,
    id,
    'www.560xs.com',
    282,
  );
  check(
    events.any(
      (item) =>
          item['path'] == '/xs/isookbj/mulu_1.html' &&
          item['http_status'] == 200 &&
          item['failure_category'] == 'timeout',
    ),
    'body timeout following HTTP headers must be retained',
  );
  check(
    recent
        .selectRecentEvidence(evidence.reading, '0' * 64, 'www.560xs.com', 282)
        .isEmpty,
    'same host with different ID cannot inherit the specialized review',
  );
}

void checkComRdapEvidence() {
  final evidence =
      jsonDecode(
            File(
              'docs/implementation/${com.comRdapEvidenceFile}',
            ).readAsStringSync(),
          )
          as Map;
  final prior =
      jsonDecode(
            File(
              'docs/implementation/legado-doh-reviewed-20261115.json',
            ).readAsStringSync(),
          )
          as Map;
  final references = evidence['input_references'] as Map;
  final hashes = <String, String>{};
  for (final key in [
    'catalog_archive',
    'catalog_manifest',
    'host_recheck',
    'doh_reviewed',
    'previous_rdap',
  ]) {
    final reference = references[key] as Map;
    final path = reference['path'] as String;
    hashes[path] = sha256.convert(File(path).readAsBytesSync()).toString();
  }
  final rows =
      (jsonDecode(
                utf8.decode(
                  BZip2Decoder().decodeBytes(
                    File(
                      'assets/catalogs/books/legado/catalog.json.bz2',
                    ).readAsBytesSync(),
                  ),
                ),
              )
              as Map)['records']
          as List;
  final linked = com.readComRdapEvidence(evidence, hashes, prior, rows);
  checkComRdapAssociation(linked, rows);
  checkComRdapTampering(evidence, hashes, prior, rows);
}

void checkComRdapAssociation(com.ComRdapLedgerEvidence evidence, List rows) {
  final old = parseBookSourceRecord(rows[123]);
  final values = com.selectComRdapEvidence(evidence, old, 123);
  final rdap = values
      .where(
        (item) =>
            item['observation_kind'] ==
            'official_rdap_registered_domain_context',
      )
      .toList();
  final exact = values
      .where(
        (item) => item['observation_kind'] == 'public_doh_exact_endpoint_host',
      )
      .toList();
  final parent = values
      .where(
        (item) =>
            item['observation_kind'] == 'public_doh_registered_domain_context',
      )
      .toList();
  final previous = values
      .where(
        (item) =>
            item['observation_kind'] ==
            'previous_public_doh_exact_endpoint_host',
      )
      .toList();
  check(
    rdap.length == 2 &&
        rdap.every(
          (item) =>
              item['http_status'] == 404 &&
              item['classification'] == 'http_404_empty_body' &&
              item['error_code'] == null,
        ),
    'both empty-body 404 responses must remain distinct from registered objects',
  );
  check(
    exact.length == 8 &&
        exact.every(
          (item) =>
              item['queried_host'] == 'www.aslwx.com' &&
              item['classification'] == 'nxdomain' &&
              item['dns_rcode'] == 3,
        ),
    'old endpoint observations must only describe the exact host',
  );
  check(
    parent.length == 8 &&
        parent.every(
          (item) =>
              item['queried_host'] == 'aslwx.com' &&
              item['host_relation'] == 'registered_domain_context',
        ),
    'registered-domain DoH observations must remain separate from endpoint-host DNS',
  );
  check(
    previous.length == 4 &&
        values.every(
          (item) =>
              item['matches_current_selected_raw_record'] == true &&
              item['matches_current_full_endpoint'] == true &&
              item['matches_current_normalized_legado_rule'] == true &&
              item['site_security_verified'] == null,
        ),
    'historical identity, rule and unknown safety state must remain explicit',
  );
  final alternateHost = BookSource.fromJson({
    ...old.toJson(),
    'url': 'https://aslwx.com/',
  });
  check(
    alternateHost.id == old.id &&
        com.selectComRdapEvidence(evidence, alternateHost, 123).isEmpty,
    'same legacy ID cannot transfer evidence to a sibling host',
  );
  final otherId = BookSource.fromJson({
    ...old.toJson(),
    'sourceKey': 'another-source',
  });
  check(
    otherId.id != old.id &&
        com.selectComRdapEvidence(evidence, otherId, 123).isEmpty,
    'same host cannot transfer evidence to another ID',
  );
  final changed = BookSource.fromJson({
    ...old.toJson(),
    'legado': {...old.legado!.toJson(), 'search': '/new?q={{key}}'},
  });
  final changedRows = com.selectComRdapEvidence(evidence, changed, 123);
  check(
    changed.id == old.id &&
        changedRows.isNotEmpty &&
        changedRows.every(
          (item) => item['matches_current_normalized_legado_rule'] == false,
        ),
    'same-ID rule revision must keep the observation historical',
  );
  final differentPath = BookSource.fromJson({
    ...old.toJson(),
    'url': 'https://www.aslwx.com/other',
  });
  final differentPathRows = com.selectComRdapEvidence(
    evidence,
    differentPath,
    123,
  );
  check(
    differentPath.id == old.id &&
        differentPathRows.isNotEmpty &&
        differentPathRows.every(
          (item) => item['matches_current_full_endpoint'] == false,
        ),
    'same-host changed endpoint must not match the historical endpoint',
  );
  check(
    com
        .selectComRdapEvidence(evidence, old, 124)
        .every((item) => item['matches_current_selected_raw_record'] == false),
    'different selected index must remain explicitly historical',
  );
  final registered = parseBookSourceRecord(rows[326]);
  final registeredRows = com.selectComRdapEvidence(evidence, registered, 326);
  check(
    registeredRows
                .where(
                  (item) => item['classification'] == 'matching_domain_object',
                )
                .length ==
            2 &&
        registeredRows.any(
          (item) =>
              item['classification'] == 'provider_timeout' &&
              item['http_status'] == null &&
              item['dns_rcode'] == null &&
              item['host_relation'] == 'registered_domain_context',
        ),
    'registered-domain responses and DoH timeouts must remain distinct',
  );
}

void checkComRdapTampering(
  Map original,
  Map<String, String> hashes,
  Map prior,
  List rows,
) {
  Map copy() => jsonDecode(jsonEncode(original)) as Map;
  void rejects(void Function(Map) modify, String reason) {
    final changed = copy();
    modify(changed);
    var rejected = false;
    try {
      com.readComRdapEvidence(changed, hashes, prior, rows);
    } on FormatException {
      rejected = true;
    }
    check(rejected, reason);
  }

  rejects(
    (value) => (value['input_references']['catalog_archive'] as Map)['sha256'] =
        '0' * 64,
    'different archive digest must be rejected',
  );
  rejects(
    (value) =>
        (value['input_references']['source_ledger_historical_git']
                as Map)['sha256'] =
            '0' * 64,
    'different historical Git object digest must be rejected',
  );
  rejects(
    (value) =>
        (value['candidates'][0]['selected_sources'][0] as Map)['source_id'] =
            '0' * 64,
    'altered selected source ID must be rejected',
  );
  rejects(
    (value) =>
        (value['candidates'][0]['selected_sources'][0]
                as Map)['normalized_legado_sha256'] =
            '0' * 64,
    'altered historical normalized rule must be rejected',
  );
  rejects(
    (value) => (value['candidates'][0] as Map)['old_source_host'] =
        'wrong.biqugedd.com',
    'altered old host must be rejected',
  );
  rejects(
    (value) =>
        (value['candidates'][0]['previous_public_doh'][0] as Map)['dns_rcode'] =
            0,
    'altered previous DoH observation must be rejected',
  );
  rejects((value) {
    final samples = (value['rounds'][0]['observations'] as List).cast<Map>();
    samples.firstWhere((item) => item['host'] == 'm.biqugedd.com')['host'] =
        'biqugedd.com';
  }, 'a host observation cannot be transferred to its parent');
  rejects(
    (value) {
      final samples = (value['rounds'][0]['observations'] as List).cast<Map>();
      final sample = samples.firstWhere(
        (item) => item['host'] == 'm.biqugedd.com',
      );
      sample['classification'] = 'noerror_no_address';
      sample['dns_rcode'] = 0;
    },
    'a coherent but altered DoH classification must disagree with the recorded summary',
  );
  rejects((value) {
    final samples = (value['rounds'][0]['observations'] as List).cast<Map>();
    final sample = samples.firstWhere((item) => item['domain'] == 'aslwx.com');
    sample['classification'] = 'matching_domain_object';
    sample['http_status'] = 200;
    sample['rdap_object_matches'] = true;
  }, 'a 404 cannot be silently replaced by a registered-domain observation');
}

void checkNov16ExactAssociation() {
  final current = source('https://www.example.com/');
  final sibling = source('https://example.com/');
  check(current.id == sibling.id, 'fixture must exercise legacy ID collision');
  final evidence = nov16.Nov16LedgerEvidence();
  evidence.add(evidence.adultReview, current.id, current.endpoint.host, 17, {
    'historical_normalized_legado_sha256': legadoSourceFingerprint(
      current.legado!,
    ),
  });
  final matching = nov16.selectNov16Evidence(evidence.adultReview, current, 17);
  check(
    matching.length == 1 &&
        matching.single['matches_current_normalized_legado_rule'] == true,
    'exact ID, host, index and normalized rule must match',
  );
  check(
    nov16.selectNov16Evidence(evidence.adultReview, sibling, 17).isEmpty,
    'same ID must not transfer evidence to another endpoint host',
  );
  check(
    nov16.selectNov16Evidence(evidence.adultReview, current, 18).isEmpty,
    'evidence must not transfer to another selected raw record',
  );
  final sameHostOtherId = BookSource.fromJson({
    ...current.toJson(),
    'sourceKey': 'independent-source',
  });
  check(
    sameHostOtherId.id != current.id &&
        nov16
            .selectNov16Evidence(evidence.adultReview, sameHostOtherId, 17)
            .isEmpty,
    'same host and index must not transfer evidence to another ID',
  );
  final revised = BookSource.fromJson({
    ...current.toJson(),
    'legado': {...current.legado!.toJson(), 'search': '/new?q={{key}}'},
  });
  check(revised.id == current.id, 'fixture must keep source identity');
  check(
    nov16
            .selectNov16Evidence(evidence.adultReview, revised, 17)
            .single['matches_current_normalized_legado_rule'] ==
        false,
    'same-ID changed rule must remain explicitly historical',
  );
  evidence.add(evidence.reading, current.id, current.endpoint.host, 17, {
    'historical_search_rule_sha256': sha256
        .convert(utf8.encode(current.legado!.search))
        .toString(),
    'historical_rule_sha256': <String, String>{},
  });
  check(
    nov16
                .selectNov16Evidence(evidence.reading, current, 17)
                .single['matches_current_normalized_pilot_rules'] ==
            true &&
        nov16
                .selectNov16Evidence(evidence.reading, revised, 17)
                .single['matches_current_normalized_pilot_rules'] ==
            false,
    'pilot observations must report later source-rule changes',
  );
  var rejected = false;
  try {
    nov16.verifiedHistoricalGitObject({
      'git_commit': '6c18b625ee81176c130aef6c33bd6dd3ee5159f1',
      'path': 'docs/implementation/legado-source-ledger-20261115.json',
      'sha256': '0' * 64,
    }, 'docs/implementation/legado-source-ledger-20261115.json');
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'historical Git digest mismatch must be rejected');
  final data = <String, Map>{};
  for (final file in [
    nov16.uaaEvidenceFile,
    nov16.equivalentEvidenceFile,
    nov16.twoChainEvidenceFile,
  ]) {
    data[file] =
        jsonDecode(File('docs/implementation/$file').readAsStringSync()) as Map;
  }
  rejected = false;
  try {
    nov16.readNov16Evidence(
      data,
      [],
      '0' * 64,
      '0' * 64,
      ledger.networkObservation,
    );
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'historical evidence must reject a different source archive');
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
    checkReplayRecent(rows, document);
    checkReplayNov16(rows, document);
    checkReplayComRdap(rows, document);
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
    'lib/features/books/domain/fanfanu_legacy_source_fix.dart',
    'lib/features/books/domain/net_rdap_legacy_quarantine.dart',
    'lib/features/books/domain/com_rdap_legacy_quarantine.dart',
    'tool/book_source_ledger_recent_evidence.dart',
    'tool/book_source_ledger_nov16_evidence.dart',
    'tool/book_source_ledger_com_rdap.dart',
  ]) {
    check(
      (document['normalized_source_code_sha256'] as Map).containsKey(path),
      'missing transitive source digest',
    );
  }
  for (final path in [
    'lib/features/books/application/book_category_policy.dart',
    'lib/features/books/application/book_site_checks.dart',
    'lib/features/books/data/book_discovery_paging.dart',
    'lib/features/books/data/book_repository_discovery.dart',
    'lib/features/books/data/book_repository_site_checks.dart',
    'lib/features/books/data/books_repository.dart',
    'lib/features/supervision/application/content_policy.dart',
  ]) {
    check(
      (document['runtime_policy_reference_only_normalized_sha256'] as Map)
          .containsKey(path),
      'missing runtime-only policy reference',
    );
  }
  check(
    (document['limitations'] as List).any(
      (item) => (item as String).contains(
        'Runtime discovery-category filtering is not simulated',
      ),
    ),
    'runtime-only category policy must not be represented as simulated',
  );
  check(
    (document['limitations'] as List).any(
      (item) => (item as String).contains(
        'historical working-tree book_source_risk.dart digest',
      ),
    ),
    'unretained historical .net policy snapshot must be disclosed',
  );
}

void checkReplayComRdap(List<Map> rows, Map document) {
  final associated = rows
      .where(
        (row) => (row['registry_and_doh_observations'] as List).cast<Map>().any(
          (item) => item['evidence'] == com.comRdapEvidenceFile,
        ),
      )
      .toList();
  check(
    associated.length == 8 &&
        (document['overlapping_summary']
                as Map)['sources_with_com_rdap_observations'] ==
            8,
    'six-domain observations must attach to exactly eight selected source IDs',
  );
  final aslwx = associated.singleWhere(
    (row) => row['selected_record_index'] == 123,
  );
  final events = (aslwx['registry_and_doh_observations'] as List)
      .cast<Map>()
      .where((item) => item['evidence'] == com.comRdapEvidenceFile)
      .toList();
  check(
    events.length == 22 &&
        events.every((item) => item['site_security_verified'] == null),
    'all historical sample observations must remain distinct and not prove safety',
  );
  check(
    (aslwx['static_policy'] as Map)['fixed_unavailable_rule'] == true &&
        events
                .where(
                  (item) => item['classification'] == 'http_404_empty_body',
                )
                .length ==
            2,
    'exact source quarantine and observed 404s must both remain visible',
  );
  final reference = document['com_rdap_historical_ledger_reference'] as Map;
  check(
    reference['commit'] == '9e875ff22e4dcef7727538765d4007892ca33c89' &&
        reference['verified_from_git_object'] == true,
    'six-domain evidence must retain its verified historical Git reference',
  );
}

void checkReplayNov16(List<Map> rows, Map document) {
  Map find(String id) => rows.singleWhere((row) => row['source_id'] == id);
  const uaa =
      'f55889c694e46c91b0cb834eb5a36c861eb49963e8f86c042f164732dbdb6f06';
  const unresolved =
      'f44c7e7d83ca20312dd48786f9bb53448cbbf8bfd737f5bff7108798d7c97ddd';
  const firstEquivalent =
      '5c917c26905991075f4d33ffdc650a6f525e5e80f10837da497af751686cab1a';
  const secondEquivalent =
      'f13fda5de688afbafbe3ac0e5f3d0b6cbeb858fc022c42b44f25a734e0e51374';
  const sameHostDifferentRule =
      'b62b1166d3a5c9736ff5c4ca16427a9485f9de33dc401bfed8d144595b00fc9f';
  for (final id in [uaa, firstEquivalent, secondEquivalent]) {
    final row = find(id);
    final review = (row['historical_adult_source_review_observations'] as List)
        .cast<Map>()
        .single;
    check(
      (row['static_policy'] as Map)['adult_source_classified'] == true &&
          review['historical_source_adult_business_evidence'] == true &&
          review['matches_current_selected_raw_record'] == true &&
          review['matches_current_normalized_legado_rule'] == true &&
          review['current_webpage_verified'] == null,
      'new precise adult source evidence must remain linked and time scoped',
    );
  }
  for (final id in [unresolved, sameHostDifferentRule]) {
    final row = find(id);
    final review = (row['historical_adult_source_review_observations'] as List)
        .cast<Map>()
        .single;
    check(
      (row['static_policy'] as Map)['adult_source_classified'] == false &&
          review['historical_source_adult_business_evidence'] == null,
      'same-host and dynamic-category candidates must stay unresolved',
    );
  }
  final references = document['adult_source_historical_references'] as Map;
  check(
    (references['ledger'] as Map)['verified_from_git_object'] == true &&
        (references['label_evidence'] as Map)['verified_from_git_object'] ==
            true,
    'historical ledger and labels must be verified Git objects',
  );
  check(
    (document['overlapping_summary']
            as Map)['sources_with_historical_adult_source_review_observations'] ==
        10,
    'adult review must associate exactly the ten documented source identities',
  );
  checkReplayTwoChain(rows);
}

void checkReplayTwoChain(List<Map> rows) {
  Map find(String id) => rows.singleWhere((row) => row['source_id'] == id);
  final zhulang = find(
    'b1fe65efa82c23d08fddb9948d5ec920801618ad35e2a722cc798d6f7508d376',
  );
  final zhuishu = find(
    '59d5b907db94c9109b3b45f2fb1033e562e4c196b1c1a1d7f1f00d6bc4ba8aeb',
  );
  Map reading(Map row) => (row['specialized_reading_observations'] as List)
      .cast<Map>()
      .singleWhere((item) => item['evidence'] == nov16.twoChainEvidenceFile);
  final first = reading(zhulang);
  final second = reading(zhuishu);
  check(
    first['content_sample_parsed'] == true &&
        first['prior_one_sample_reading_chain_reported'] == true &&
        first['toc_chapters_observed'] == 50 &&
        first['toc_pagination_fetched'] == false &&
        first['full_book_reading_verified'] == null,
    'one chapter must not imply full-book or pagination verification',
  );
  check(
    second['content_sample_parsed'] == false &&
        second['prior_one_sample_reading_chain_reported'] == null &&
        second['full_book_reading_verified'] == null &&
        jsonEncode(second['content_limit_rechecks_bytes']) ==
            '[524288,2097152]',
    'oversized 追书神器 content must not become a successful reading chain',
  );
  final events = (zhuishu['network_observations'] as List)
      .cast<Map>()
      .where((item) => item['evidence'] == nov16.twoChainEvidenceFile)
      .toList();
  final truncated = events
      .where((item) => item['sample_truncated'] == true)
      .toList();
  check(
    events.length == 4 &&
        truncated.length == 2 &&
        truncated.every(
          (item) =>
              item['truncated_sample_parsed'] == false &&
              item['sample_sha256'] == null &&
              item['observed_at'] != null &&
              item['historical_response_body_retained'] == false &&
              item['historical_intermediate_snapshots_version_controlled'] ==
                  false,
        ),
    'sample caps, timestamps and unretained bodies must remain visible',
  );
  check(
    first['historical_page_parsing_independently_recomputed'] == false &&
        first['historical_workspace_policy_snapshots_retained'] == null &&
        first['historical_workspace_policy_sha256_initial'] !=
            first['historical_workspace_policy_sha256_followup'],
    'unavailable intermediate snapshots must not be represented as replayed',
  );
  check(
    first['matches_current_normalized_pilot_rules'] == true &&
        second['matches_current_normalized_pilot_rules'] == true,
    'pilot rule fingerprints must be compared to the current source',
  );
}

void checkReplayRecent(List<Map> rows, Map document) {
  Map find(String id) => rows.singleWhere((row) => row['source_id'] == id);
  final dushu = find(
    'b269ecd1a1c9ce6693119d5e20fc3ae82998662478c507ba7b4a1604be981ff8',
  );
  check(
    (dushu['static_policy'] as Map)['fixed_unavailable_rule'] == true,
    'the selected .net old rule must reflect current fixed policy',
  );
  check(
    (dushu['registry_and_doh_observations'] as List).cast<Map>().any(
      (item) =>
          item['evidence'] == 'legado-rdap-net-sample-20261115.json' &&
          item['http_status'] == 404,
    ),
    '.net RDAP evidence missing',
  );
  final bbs = find(
    '99dec828e154116574529a7c8013e0e1d08c12ccb01ffa57a1da3ee7aebb8654',
  );
  check(
    (bbs['network_observations'] as List).cast<Map>().any(
      (item) =>
          item['evidence'] == 'legado-amsi-redirect-recheck-20261115.json' &&
          item['http_status'] == 302 &&
          item['additional_amsi_scan_performed'] == false,
    ),
    'redirect recheck must not be represented as a new AMSI scan',
  );
  final adult = find(
    '1f9aaa829a5d0312520cbcce9a4b9b84c7c12cd1d9f0adc6faecb042a9b15c17',
  );
  final mixed = find(
    '68051e1286ea64cd9e4dd6d05fd5f3ed286ade6837c4fff648aeb9b016e735cd',
  );
  check(
    (adult['static_policy'] as Map)['adult_source_classified'] == true &&
        (mixed['static_policy'] as Map)['adult_source_classified'] == false,
    'mixed categories alone must not label the entire source adult',
  );
  check(
    (mixed['historical_category_observations'] as List)
            .cast<Map>()
            .single['explicit_unique_path_count'] ==
        4,
    'mixed historical category metadata missing',
  );
  final source560 = find(
    'bca6e55770d00d422fc5ca90194c062433fd5955601b573c28cc5533a22f4bf4',
  );
  final review = (source560['specialized_reading_observations'] as List)
      .cast<Map>()
      .single;
  check(
    review['toc_body_state'] == 'timeout_unknown' &&
        review['complete_reading_chain_verified'] == null,
    '560 full reading must remain unverified',
  );
  final history = document['adult_category_historical_ledger_reference'] as Map;
  check(
    history['git_commit'] == '6c18b625ee81176c130aef6c33bd6dd3ee5159f1' &&
        history['verified_from_git_object'] == true,
    'adult category evidence must use the historical Git snapshot',
  );
}

void main() {
  checkCommunityRelations();
  checkObservationSemantics();
  checkScanAndDescriptionStates();
  checkExactCurrentDoh();
  checkInputFingerprints();
  checkSelectedVersionComparison();
  final recentEvidence = loadRecentEvidence();
  checkRecentRegistry(recentEvidence);
  checkRecentRedirects(recentEvidence);
  checkRecentAdultCategories(recentEvidence);
  checkRecent560Review(recentEvidence);
  checkNov16ExactAssociation();
  checkComRdapEvidence();
  checkActualReplay();
  stdout.writeln('book source ledger offline checks passed');
}
