// Adapters for the four recent, already collected evidence files. These do not
// perform network requests, execute source rules, or retain page descriptions.
typedef NetworkNormalizer =
    Map<String, Object?> Function({
      required String evidence,
      required String method,
      required String path,
      required Map row,
      Uri? endpoint,
    });

const _netRdap = 'legado-rdap-net-sample-20261115.json';
const _redirect = 'legado-amsi-redirect-recheck-20261115.json';
const _adult = 'legado-adult-category-recheck-20261115.json';
const _reading = 'legado-560xs-recheck-20261115.json';

String _key(String sourceId, String host) => '$sourceId\x00$host';

final class RecentLedgerEvidence {
  final network = <String, List<Map<String, Object?>>>{};
  final registry = <String, List<Map<String, Object?>>>{};
  final categories = <String, List<Map<String, Object?>>>{};
  final reading = <String, List<Map<String, Object?>>>{};

  void add(
    Map<String, List<Map<String, Object?>>> destination,
    Object? sourceId,
    Object? host,
    Object? selectedIndex,
    Map<String, Object?> observation,
  ) {
    if (sourceId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceId) ||
        host is! String ||
        host.isEmpty ||
        selectedIndex is! int ||
        selectedIndex < 0) {
      throw const FormatException('invalid selected source evidence identity');
    }
    destination.putIfAbsent(_key(sourceId, host), () => []).add({
      ...observation,
      'historical_selected_record_index': selectedIndex,
    });
  }
}

/// Identity association is exact; the source selected-index match is recorded
/// independently since an evidence snapshot can refer to a previous version.
List<Map<String, Object?>> selectRecentEvidence(
  Map<String, List<Map<String, Object?>>> evidence,
  String sourceId,
  String endpointHost,
  int selectedIndex,
) => [
  for (final item in evidence[_key(sourceId, endpointHost)] ?? const [])
    {
      ...item,
      'matches_current_selected_raw_record':
          item['historical_selected_record_index'] == selectedIndex,
    },
];

RecentLedgerEvidence readRecentEvidence(
  Map<String, Map> data,
  NetworkNormalizer networkObservation,
) {
  final evidence = RecentLedgerEvidence();
  _addNetRegistry(evidence, data[_netRdap]!);
  _addRedirects(evidence, data[_redirect]!, networkObservation);
  _addAdultCategories(evidence, data[_adult]!, networkObservation);
  _add560Review(evidence, data[_reading]!, networkObservation);
  return evidence;
}

void _addNetRegistry(RecentLedgerEvidence output, Map evidence) {
  for (final row in (evidence['results'] as List).cast<Map>()) {
    final host = row['old_endpoint_host'];
    for (final source in (row['selected_sources'] as List).cast<Map>()) {
      void add(Map<String, Object?> observation) => output.add(
        output.registry,
        source['id'],
        host,
        source['record_index'],
        observation,
      );
      for (final sample
          in (row['official_registry_rdap'] as List).cast<Map>()) {
        add({
          'evidence': _netRdap,
          'observation_kind': 'rdap_registered_domain',
          'registry_domain': row['registry_domain'],
          'observed_at': sample['observed_at_utc'],
          'http_status': sample['http_status'],
          'classification': sample['classification'],
          'error_type': sample['error_type'],
          'domain_object_name_match': sample['domain_object_name_match'],
          'rdap_conformance_present': sample['rdap_conformance_present'],
        });
      }
      for (final sample in (row['prior_public_doh'] as List).cast<Map>()) {
        add({
          'evidence': _netRdap,
          'observation_kind': 'previous_public_doh_exact_endpoint_host',
          'queried_host': host,
          'observed_at': sample['observed_at'],
          'provider': sample['provider'],
          'query_type': sample['query_type'],
          'dns_rcode': sample['dns_rcode'],
          'dnssec_authenticated': sample['dnssec_authenticated'],
          'classification': sample['classification'],
        });
      }
      for (final sample in (row['prior_native_dns'] as List).cast<Map>()) {
        add({
          'evidence': _netRdap,
          'observation_kind': 'previous_native_dns_exact_endpoint_host',
          'queried_host': host,
          'observed_at': sample['observed_at'],
          'classification': sample['classification'],
        });
      }
    }
  }
}

void _addRedirects(
  RecentLedgerEvidence output,
  Map evidence,
  NetworkNormalizer normalize,
) {
  for (final row in (evidence['results'] as List).cast<Map>()) {
    final sample = row['current_observation'] as Map;
    if (sample['host'] != row['host']) {
      throw const FormatException('redirect observation host mismatch');
    }
    output.add(
      output.network,
      row['selected_source_id'],
      row['host'],
      row['selected_record_index'],
      {
        ...normalize(
          evidence: _redirect,
          method: sample['method'] as String,
          path: sample['path'] as String,
          row: sample,
        ),
        'redirect_target_category': sample['target_category'],
        'redirect_target_scheme': sample['resolved_target_scheme'],
        'additional_amsi_scan_performed': false,
      },
    );
  }
}

void _addAdultCategories(
  RecentLedgerEvidence output,
  Map evidence,
  NetworkNormalizer normalize,
) {
  for (final row in (evidence['sources'] as List).cast<Map>()) {
    final sample = row['current_homepage_observation'] as Map;
    if (sample['host'] != row['host']) {
      throw const FormatException('homepage observation host mismatch');
    }
    final observed = sample['description_explicit_adult_business'];
    output.add(
      output.network,
      row['source_id'],
      row['host'],
      row['selected_record_index'],
      {
        ...normalize(evidence: _adult, method: 'GET', path: '/', row: sample),
        'adult_text_clue_recorded': observed is bool ? observed : null,
        if (observed is bool)
          'adult_text_clue_basis': 'reviewed_homepage_description',
      },
    );
    output.add(
      output.categories,
      row['source_id'],
      row['host'],
      row['selected_record_index'],
      {
        'evidence': _adult,
        'observation_kind': 'historical_raw_category_metadata',
        'raw_explore_sha256_utf8': row['raw_explore_sha256_utf8'],
        'menu_entry_count': row['menu_entry_count'],
        'explicit_menu_entry_count': row['explicit_menu_entry_count'],
        'unique_path_count': row['unique_path_count'],
        'explicit_unique_path_count': row['explicit_unique_path_count'],
        'current_normalized_categories_may_differ': true,
      },
    );
  }
}

void _add560Review(
  RecentLedgerEvidence output,
  Map evidence,
  NetworkNormalizer normalize,
) {
  final source = evidence['source'] as Map;
  for (final sample in (evidence['observations'] as List).cast<Map>()) {
    output.add(
      output.network,
      source['id'],
      source['host'],
      source['selected_record_index'],
      normalize(
        evidence: _reading,
        method: sample['method'] as String,
        path: sample['path'] as String,
        row: sample,
      ),
    );
  }
  final get = evidence['old_get_search'] as Map;
  final post = evidence['post_search'] as Map;
  final chain = evidence['separate_book_chain'] as Map;
  output.add(
    output.reading,
    source['id'],
    source['host'],
    source['selected_record_index'],
    {
      'evidence': _reading,
      'observation_kind': 'bounded_separate_search_and_reading_samples',
      'old_get_sanguo_book_count':
          (get['sanguo_counts'] as Map)['old_engine_books'],
      'old_get_shuihu_book_count':
          (get['shuihu_counts'] as Map)['old_engine_books'],
      'experimental_post_books': post['actual_engine_book_count'],
      'experimental_post_same_host_books':
          post['actual_engine_same_host_book_count'],
      'experimental_post_keyword_matches':
          post['actual_engine_keyword_match_count'],
      'experimental_post_result_content_classification':
          post['result_content_classification'],
      'post_result_detail_fetched': false,
      'separate_book_sample': true,
      'toc_http_status': chain['toc_http_status'],
      'toc_body_state': chain['toc_body'],
      'toc_chapters_verified': null,
      'old_parsed_content_characters': chain['old_parsed_content_characters'],
      'visible_content_text_characters':
          chain['visible_content_text_characters'],
      'page_scripts_executed': false,
      'complete_reading_chain_verified': null,
      'content_safety_verified': null,
    },
  );
}
