part of 'book_source_ledger_com_rdap.dart';

const rdapFiveEvidenceFile = 'legado-rdap-five-20261116.json';
const rdapFiveEvidenceSha =
    '3e3c902141ca9c5d97a20732fe7c0636622ce500e49381142dce025faf749665';
const _fiveCanonicalSha =
    'c3fdaf3cc17316e577bf7eab9a484d44521b21a69aebac8ff8deda066b2e8416';
const _fiveCommit = 'f7b5697d49fdc5113274e5add45a1108638957c5';
const _fiveLedgerSha =
    'fb6b8ace9e42eed5ab9756cb3a35d115a83466479b1946e968afe13306aee8c6';
const _fiveReferences = <String, String>{
  'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
  'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
  'later_host_recheck':
      'docs/implementation/legado-unresolved-head-later-20261116.json',
  'older_host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
  'prior_public_doh': 'docs/implementation/legado-doh-reviewed-20261115.json',
};
const _fiveHosts = {
  '7wav.com': 'm.7wav.com',
  '92yanqing.net': 'm.92yanqing.net',
  'fxsw.top': 'www.fxsw.top',
  'zri.moe': 'book.zri.moe',
  'cwj18.org': 'www.cwj18.org',
};
const _fivePreviousRdap = {
  'docs/implementation/legado-rdap-sample-20261115.json',
  'docs/implementation/legado-rdap-net-sample-20261115.json',
  'docs/implementation/legado-rdap-com-six-20261116.json',
  'docs/implementation/legado-rdap-com-eighteen-20261116.json',
  'docs/implementation/legado-rdap-nine-20261116.json',
  'docs/implementation/legado-rdap-top-cc-20261116.json',
};

void verifyRdapFiveInput(
  Map evidence,
  String archiveSha,
  Map<String, String> hashes,
) {
  final inputs = evidence['input_references'] as Map;
  final historical = inputs['source_ledger_historical_git'] as Map;
  _require(
    hashes['docs/implementation/$rdapFiveEvidenceFile'] ==
            rdapFiveEvidenceSha &&
        _sha(jsonEncode(_orderedJson(evidence))) == _fiveCanonicalSha &&
        (inputs['catalog_archive'] as Map)['sha256'] == archiveSha &&
        historical['commit'] == _fiveCommit &&
        historical['path'] == _ledgerPath &&
        historical['sha256'] == _fiveLedgerSha,
    'five-domain evidence or historical inputs mismatch',
  );
}

ComRdapLedgerEvidence readRdapFiveEvidence(
  Map evidence,
  Map<String, String> hashes,
  Map priorDoh,
  List rawRecords,
) {
  verifyRdapFiveInput(
    evidence,
    hashes[_fiveReferences['catalog_archive']] ?? '',
    hashes,
  );
  final history = _verifyInputs(evidence, hashes, references: _fiveReferences);
  final refs =
      (evidence['input_references'] as Map)['previous_rdap_historical_git']
          as Map;
  _require(
    refs.keys.toSet().length == _fivePreviousRdap.length &&
        refs.keys.toSet().containsAll(_fivePreviousRdap),
    'five-domain prior RDAP set mismatch',
  );
  for (final path in _fivePreviousRdap) {
    final ref = refs[path] as Map;
    _require(
      ref['commit'] == _fiveCommit,
      'five-domain prior Git commit mismatch',
    );
    verifiedHistoricalGitObject({
      'git_commit': ref['commit'],
      'path': path,
      'sha256': ref['sha256'],
    }, path);
  }
  final candidates = (evidence['candidates'] as List).cast<Map>();
  final rounds = (evidence['rounds'] as List).cast<Map>();
  final summary = evidence['summary'] as Map;
  final observations = rounds
      .expand((round) => (round['observations'] as List).cast<Map>())
      .toList();
  final skipped = rounds
      .expand((round) => (round['skipped'] as List).cast<Map>())
      .toList();
  final controls = rounds
      .expand((round) => (round['controls'] as List).cast<Map>())
      .toList();
  _require(
    candidates.length == 5 &&
        rounds.length == 2 &&
        summary['candidate_domains'] == 5 &&
        summary['selected_source_ids'] == 10 &&
        observations.length == 70 &&
        skipped.length == 20 &&
        controls.length == 68 &&
        observations.where((row) => row['mode'] == 'rdap').length == 10 &&
        observations.where((row) => row['mode'] == 'doh').length == 60 &&
        observations
                .where((row) => row['classification'] == 'provider_timeout')
                .length ==
            1 &&
        controls
                .where((row) => row['classification'] == 'provider_timeout')
                .length ==
            5 &&
        (summary['strictly_eligible_domains'] as List).isEmpty,
    'five-domain observation coverage mismatch',
  );
  final crossPeriod = (summary['cross_period_zri_review_source_ids'] as List)
      .cast<String>()
      .toSet();
  _require(
    crossPeriod.length == 4,
    'five-domain cross-period review scope mismatch',
  );
  final output = ComRdapLedgerEvidence();
  final seenDomains = <String>{}, seenIds = <String>{}, zriIds = <String>{};
  for (final candidate in candidates) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    _require(
      seenDomains.add(domain) && _fiveHosts[domain] == host,
      'five-domain host relationship mismatch',
    );
    if (candidate['previous_public_doh'] != null) {
      _verifyPreviousDoh(candidate, priorDoh);
    }
    for (final source in (candidate['selected_sources'] as List).cast<Map>()) {
      _verifyHistoricalSource(
        source,
        host,
        history,
        rawRecords,
        rawUrlRetained: false,
      );
      final index = source['selected_record_index'] as int;
      final parsed = parseBookSourceRecord(rawRecords[index]);
      final historic = (history['sources'] as List).cast<Map>().singleWhere(
        (row) => row['source_id'] == source['source_id'],
      );
      _require(
        seenIds.add(source['source_id'] as String) &&
            historic['format'] == source['format'] &&
            parsed.format.name == source['format'] &&
            parsed.endpoint.toString() == source['normalized_endpoint'] &&
            _sha(jsonEncode(_orderedJson(rawRecords[index]))) ==
                source['selected_raw_record_canonical_sha256'],
        'five-domain selected archived identity mismatch',
      );
      if (domain == 'zri.moe') zriIds.add(source['source_id'] as String);
      if (candidate['previous_public_doh'] != null) {
        _addPreviousDoh(
          output,
          candidate,
          source,
          host,
          evidenceFile: rdapFiveEvidenceFile,
        );
      }
      _addFiveRounds(output, rounds, source, domain, host);
      output.add(source, host, {
        'evidence': rdapFiveEvidenceFile,
        'observation_kind': 'historical_review_scope',
        'registry_domain': domain,
        'strictly_eligible_in_this_study': false,
        if (domain == 'zri.moe')
          'separate_cross_period_review_candidate': crossPeriod.contains(
            source['source_id'],
          ),
        'scope_note':
            'Strict review uses two controlled resolvers; cross-period review is separate and does not count skipped queries.',
        'site_security_verified': null,
        'permanent_failure_verified': null,
      });
    }
  }
  _require(
    seenDomains.length == 5 &&
        seenIds.length == 10 &&
        zriIds.length == 4 &&
        zriIds.containsAll(crossPeriod),
    'five-domain selected source count or cross-period IDs mismatch',
  );
  return output;
}

void _addFiveRounds(
  ComRdapLedgerEvidence output,
  List<Map> rounds,
  Map source,
  String domain,
  String host,
) {
  final zone = domain.split('.').last;
  final seen = <int>{};
  for (final round in rounds) {
    final number = round['round'];
    _require(number is int && seen.add(number), 'five-domain invalid round');
    final controls = (round['control_status'] as Map)[zone] as Map;
    final results = (round['observations'] as List)
        .cast<Map>()
        .where((row) => row['mode'] == 'rdap' && row['domain'] == domain)
        .toList();
    _require(
      controls['rdap'] == true && results.length == 1,
      'five-domain registry control or observation missing',
    );
    final sample = results.single;
    final classification = sample['classification'];
    _require(
      (classification == 'matching_domain_object' &&
              sample['http_status'] == 200 &&
              sample['rdap_object_matches'] == true) ||
          (classification == 'http_404_json' &&
              sample['http_status'] == 404 &&
              sample['rdap_error_code_is_404'] == true),
      'five-domain RDAP classification mismatch',
    );
    output.add(source, host, {
      'evidence': rdapFiveEvidenceFile,
      'observation_kind': 'official_rdap_registered_domain_context',
      'registry_domain': domain,
      'host_relation': 'registered_domain_context',
      'round': number,
      'observed_at': sample['observed_at'],
      'http_status': sample['http_status'],
      'classification': classification,
      'domain_object_name_match': sample['rdap_object_matches'],
      'rdap_conformance_present': sample['rdap_conformance_present'],
      'rdap_error_code_is_404': sample['rdap_error_code_is_404'],
      'controls_passed': true,
      'query_performed': true,
      'site_security_verified': null,
    });
    for (final target in {domain, host}) {
      for (final provider in ['aliyun', 'tencent']) {
        for (final type in ['A', 'AAAA']) {
          _addControlledDoh(
            output,
            round,
            source,
            host,
            target,
            provider,
            type,
            controls[provider] == true,
            rdapFiveEvidenceFile,
          );
        }
      }
    }
  }
  _require(
    seen.length == 2 && seen.containsAll({1, 2}),
    'five-domain missing round',
  );
}
