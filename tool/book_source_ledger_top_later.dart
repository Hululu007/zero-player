part of 'book_source_ledger_com_rdap.dart';

const topLaterEvidenceFile = 'legado-rdap-top-later-20261116.json';
const topLaterEvidenceSha =
    '7b17c6c93f31a3b97a2e8c06a8f2db2f894ef43dc82d1efa117de9bfbc746504';
const _laterTopCaptureSha =
    '36f6b1f5506196497cedfa9962c873fd44cbc1cbe9d8f0dcb41f9bf19919be33';
const _laterTopPriorSha =
    'bff7d7109129d16471b9c9e6ade4e372703420d782bbb374665d353e48beb9cb';
const _laterTopHosts = <String, String>{
  '99hanman.top': '99hanman.top',
  'duduxiaoshuo.top': 'h5.duduxiaoshuo.top',
  'shenxianfaka.top': 'www.shenxianfaka.top',
  'stxt.top': 'stxt.top',
};
const _laterTopReviewed = <String>{
  '2c42e8be93e8d9a0cba17e082bb31665d2dc717c98054dcc596a318b81775211',
  '2fa11264c96f40e2d97174ab5dc0393039f3235dad0d0c71b49fdbcee5d788c9',
};

void verifyTopLaterInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final prior = evidence['prior_evidence'] as Map;
  final recent = evidence['latest_head_evidence'] as Map;
  final capture = evidence['later_capture'] as Map;
  _require(
    evidence['schema_version'] == 1 &&
        hashes['docs/implementation/$topLaterEvidenceFile'] ==
            topLaterEvidenceSha &&
        hashes['docs/implementation/$topCcEvidenceFile'] == _laterTopPriorSha &&
        prior['path'] == 'docs/implementation/$topCcEvidenceFile' &&
        prior['sha256'] == _laterTopPriorSha &&
        recent['path'] ==
            'docs/implementation/legado-unresolved-943-recheck-20261116.json' &&
        recent['sha256'] ==
            '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0' &&
        hashes[recent['path']] == recent['sha256'] &&
        hashes[_topCcReferences['catalog_archive']] == archiveSha &&
        _sha(jsonEncode(_orderedJson(capture))) == _laterTopCaptureSha,
    'later .top evidence or historical inputs differ',
  );
}

ComRdapLedgerEvidence readTopLaterEvidence(
  Map evidence,
  Map earlier,
  Map<String, String> hashes,
  List rawRecords,
) {
  verifyTopLaterInput(
    evidence,
    hashes[_topCcReferences['catalog_archive']] ?? '',
    hashes,
  );
  final history = _verifyInputs(earlier, hashes, references: _topCcReferences);
  final historical = (earlier['candidates'] as List).cast<Map>();
  final candidates = (evidence['historical_candidates'] as List).cast<Map>();
  final reviewed = (evidence['reviewed_unavailable_source_ids'] as List)
      .cast<String>()
      .toSet();
  final capture = evidence['later_capture'] as Map;
  final round = capture['round'] as Map;
  final observations = (round['observations'] as List).cast<Map>().toList();
  final controls = (round['control_status'] as Map)['top'] as Map;
  _require(
    candidates.length == 4 &&
        reviewed.length == _laterTopReviewed.length &&
        reviewed.containsAll(_laterTopReviewed) &&
        controls['rdap'] == true &&
        controls['aliyun'] == true &&
        controls['tencent'] == true &&
        (round['skipped'] as List).isEmpty &&
        observations.length == 28,
    'later .top scope or control results differ',
  );
  final output = ComRdapLedgerEvidence();
  final domains = <String>{}, ids = <String>{};
  for (final candidate in candidates) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    final previous = historical.where(
      (row) => row['registry_domain'] == domain,
    );
    _require(
      domains.add(domain) &&
          _laterTopHosts[domain] == host &&
          previous.length == 1 &&
          previous.single['old_source_host'] == host &&
          jsonEncode(_orderedJson(previous.single['selected_sources'])) ==
              jsonEncode(_orderedJson(candidate['selected_sources'])),
      'later .top historical association differs',
    );
    final selected = (candidate['selected_sources'] as List).cast<Map>();
    _require(selected.length == 1, 'later .top source count differs');
    final source = selected.single;
    _verifyHistoricalSource(source, host, history, rawRecords);
    _require(ids.add(source['source_id'] as String), 'duplicate .top ID');
    final rdap = observations
        .where((row) => row['mode'] == 'rdap' && row['domain'] == domain)
        .toList();
    _require(rdap.length == 1, 'later .top RDAP observation missing');
    final registry = rdap.single;
    _require(
      (registry['classification'] == 'http_404_json' &&
              registry['http_status'] == 404 &&
              registry['rdap_error_code_is_404'] == true) ||
          (registry['classification'] == 'matching_domain_object' &&
              registry['http_status'] == 200 &&
              registry['rdap_object_matches'] == true),
      'later .top RDAP classification differs',
    );
    output.add(source, host, {
      'evidence': topLaterEvidenceFile,
      'observation_kind': 'official_rdap_registered_domain_context',
      'registry_domain': domain,
      'host_relation': 'registered_domain_context',
      'observed_at': registry['observed_at'],
      'http_status': registry['http_status'],
      'classification': registry['classification'],
      'rdap_error_code_is_404': registry['rdap_error_code_is_404'],
      'controls_passed': true,
      'site_security_verified': null,
      'permanent_failure_verified': null,
    });
    for (final target in {domain, host}) {
      for (final provider in ['aliyun', 'tencent']) {
        for (final type in ['A', 'AAAA']) {
          final samples = observations.where(
            (row) =>
                row['mode'] == 'doh' &&
                row['host'] == target &&
                row['provider'] == provider &&
                row['query_type'] == type,
          );
          _require(samples.length == 1, 'later .top DNS observation missing');
          output.add(source, host, {
            ..._dohObservation(
              samples.single,
              target,
              exact: target == host,
              previous: false,
              evidenceFile: topLaterEvidenceFile,
            ),
            'controls_passed': true,
            'query_performed': true,
            'permanent_failure_verified': null,
          });
        }
      }
    }
    output.add(source, host, {
      'evidence': topLaterEvidenceFile,
      'observation_kind': 'historical_review_scope',
      'separate_cross_period_review_candidate': reviewed.contains(
        source['source_id'],
      ),
      'site_security_verified': null,
      'permanent_failure_verified': null,
    });
  }
  _require(domains.length == 4 && ids.length == 4, 'later .top count differs');
  return output;
}
