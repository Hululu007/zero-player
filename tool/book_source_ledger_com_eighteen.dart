part of 'book_source_ledger_com_rdap.dart';

const comRdapEighteenEvidenceFile = 'legado-rdap-com-eighteen-20261116.json';
const _eighteenReferences = <String, String>{
  'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
  'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
  'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
  'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
  'previous_rdap_com': 'docs/implementation/legado-rdap-sample-20261115.json',
  'previous_rdap_net':
      'docs/implementation/legado-rdap-net-sample-20261115.json',
  'previous_rdap_com_six':
      'docs/implementation/legado-rdap-com-six-20261116.json',
  'dns_address_recheck':
      'docs/implementation/legado-dns-address-recheck-20261115.json',
  'host_audit': 'docs/implementation/legado-host-audit-20261115.json',
  'amsi_other': 'docs/implementation/legado-amsi-other-hosts-20261115.json',
};

ComRdapLedgerEvidence readComRdapEighteenEvidence(
  Map evidence,
  Map<String, String> inputHashes,
  Map priorDoh,
  List rawRecords,
  Map<String, Map> siblingInputs,
) {
  _require(
    evidence['schema_version'] == 1,
    'unsupported eighteen-domain evidence schema',
  );
  final history = _verifyInputs(
    evidence,
    inputHashes,
    references: _eighteenReferences,
  );
  final output = ComRdapLedgerEvidence();
  final candidates = (evidence['candidates'] as List).cast<Map>();
  final siblings = (evidence['known_sibling_counterexamples'] as List)
      .cast<Map>();
  _verifyControlledTotals(
    evidence,
    candidates,
    siblings,
    expectedDomains: 18,
    expectedSources: 22,
    expectedSiblings: 3,
  );
  final seenIds = <String>{};
  final domains = <String>{};
  for (final candidate in candidates) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    _require(
      domains.add(domain) && (host == domain || host.endsWith('.$domain')),
      'invalid eighteen-domain registry/old-host relationship',
    );
    final selected = (candidate['selected_sources'] as List).cast<Map>();
    _require(
      selected.isNotEmpty,
      'eighteen-domain candidate lacks selected sources',
    );
    _require(
      candidate['known_sibling_counterexample'] is bool,
      'missing eighteen-domain sibling review state',
    );
    _verifyPreviousDoh(candidate, priorDoh, field: 'previous_doh');
    final matchingSiblings = siblings
        .where((item) => item['registry_domain'] == domain)
        .toList();
    _require(
      matchingSiblings.length ==
          (candidate['known_sibling_counterexample'] == true ? 1 : 0),
      'eighteen-domain sibling counterexample mismatch',
    );
    if (matchingSiblings.isNotEmpty) {
      _verifySibling(matchingSiblings.single, domain, host, siblingInputs);
    }
    for (final source in selected) {
      _verifyHistoricalSource(
        source,
        host,
        history,
        rawRecords,
        rawUrlRetained: false,
      );
      _require(
        seenIds.add(source['source_id'] as String),
        'duplicate eighteen-domain selected source',
      );
      _addPreviousDoh(
        output,
        candidate,
        source,
        host,
        field: 'previous_doh',
        evidenceFile: comRdapEighteenEvidenceFile,
      );
      _addControlledRounds(
        output,
        evidence,
        source,
        domain,
        host,
        evidenceFile: comRdapEighteenEvidenceFile,
      );
      if (matchingSiblings.isNotEmpty) {
        _addSibling(output, source, host, matchingSiblings.single);
      }
    }
  }
  _require(
    seenIds.length == 22,
    'eighteen-domain selected source count mismatch',
  );
  return output;
}

void _verifyControlledTotals(
  Map evidence,
  List<Map> candidates,
  List<Map> siblings, {
  required int expectedDomains,
  required int expectedSources,
  required int expectedSiblings,
}) {
  final rounds = (evidence['rounds'] as List).cast<Map>();
  final summary = evidence['summary'] as Map;
  final observations = rounds
      .expand((round) => (round['observations'] as List).cast<Map>())
      .toList();
  final rdap = observations
      .where(
        (row) =>
            row['service'] == 'verisign_com' ||
            row['service'] == 'verisign_net',
      )
      .toList();
  final doh = observations.where((row) => row['host'] is String).toList();
  final skipped = rounds.fold<int>(
    0,
    (sum, round) => sum + (round['skipped'] as List).length,
  );
  final controls = rounds.fold<int>(
    0,
    (sum, round) => sum + (round['controls'] as List).length,
  );
  _require(
    rounds.length == 2 &&
        candidates.length == expectedDomains &&
        siblings.length == expectedSiblings &&
        summary['candidate_domains'] == candidates.length &&
        summary['selected_source_ids'] ==
            candidates.fold<int>(
              0,
              (sum, row) => sum + (row['selected_sources'] as List).length,
            ) &&
        summary['selected_source_ids'] == expectedSources &&
        summary['candidate_requests_attempted'] == observations.length &&
        summary['candidate_requests_skipped_due_to_control'] == skipped &&
        summary['control_requests_attempted'] == controls &&
        summary['total_requests_attempted'] == observations.length + controls &&
        summary['rdap_observations'] == rdap.length &&
        summary['doh_observations'] == doh.length &&
        summary['rdap_matching_domain_objects'] ==
            rdap
                .where(
                  (row) => row['classification'] == 'matching_domain_object',
                )
                .length &&
        summary['rdap_http_404_empty_body'] ==
            rdap
                .where((row) => row['classification'] == 'http_404_empty_body')
                .length &&
        summary['candidate_doh_timeouts'] ==
            doh
                .where((row) => row['classification'] == 'provider_timeout')
                .length &&
        summary['control_doh_timeouts'] ==
            rounds
                .expand((round) => (round['controls'] as List).cast<Map>())
                .where((row) => row['classification'] == 'provider_timeout')
                .length &&
        summary['known_sibling_counterexample_domains'] == siblings.length,
    'eighteen-domain overall observation summary mismatch',
  );
  final zones = candidates
      .map((candidate) => _registryZone(candidate['registry_domain'] as String))
      .toSet();
  for (final round in rounds) {
    for (final zone in zones) {
      _verifyRegistryControls(evidence, round, zone);
    }
    _verifyRoundCounts(round);
  }
  for (final candidate in candidates) {
    final zone = _registryZone(candidate['registry_domain'] as String);
    _verifyCandidateSummary(
      candidate,
      rounds,
      registryService: 'verisign_$zone',
    );
    final targetHosts = {
      candidate['registry_domain'],
      candidate['old_source_host'],
    };
    final count = rounds.fold<int>(
      0,
      (sum, round) =>
          sum +
          (round['skipped'] as List)
              .cast<Map>()
              .where((row) => targetHosts.contains(row['host']))
              .length,
    );
    _require(
      (candidate['current_summary'] as Map)['skipped_due_to_control'] == count,
      'eighteen-domain candidate skipped count mismatch',
    );
  }
  final byDomain = <String, List<Map>>{};
  for (final row in rdap) {
    byDomain.putIfAbsent(row['domain'] as String, () => []).add(row);
  }
  _require(
    summary['domains_with_two_404'] ==
            byDomain.values
                .where(
                  (items) =>
                      items.length == 2 &&
                      items.every(
                        (row) => row['classification'] == 'http_404_empty_body',
                      ),
                )
                .length &&
        summary['domains_with_two_matching_objects'] ==
            byDomain.values
                .where(
                  (items) =>
                      items.length == 2 &&
                      items.every(
                        (row) =>
                            row['classification'] == 'matching_domain_object',
                      ),
                )
                .length,
    'eighteen-domain registered/404 domain summary mismatch',
  );
}

void _verifyRoundCounts(Map round) {
  final rows = (round['observations'] as List).cast<Map>();
  final counts = <String, int>{};
  for (final row in rows) {
    final category = row['classification'] as String;
    counts.update(category, (count) => count + 1, ifAbsent: () => 1);
  }
  final reported = round['classification_counts'] as Map;
  _require(
    round['scheduled'] == rows.length &&
        reported.length == counts.length &&
        counts.entries.every((entry) => reported[entry.key] == entry.value),
    'eighteen-domain round classification count mismatch',
  );
}

String _registryZone(String domain) {
  if (domain.endsWith('.com')) return 'com';
  if (domain.endsWith('.net')) return 'net';
  throw const FormatException('unsupported registry zone');
}

void _verifyRegistryControls(Map evidence, Map round, String zone) {
  final controlStatus = (round['control_status'] as Map)[zone] as Map;
  final controls = (round['controls'] as List).cast<Map>();
  final negative = (evidence['negative_controls'] as Map)[zone];
  final positiveHost = 'google.$zone';
  final rdap = controls
      .where((row) => row['service'] == 'verisign_$zone')
      .toList();
  final positive = rdap.where((row) => row['domain'] == positiveHost).toList();
  final neg = rdap.where((row) => row['domain'] == negative).toList();
  final rdapPassed =
      positive.length == 1 &&
      neg.length == 1 &&
      positive.single['classification'] == 'matching_domain_object' &&
      positive.single['http_status'] == 200 &&
      positive.single['rdap_object_matches'] == true &&
      neg.single['classification'] == 'http_404_empty_body' &&
      neg.single['http_status'] == 404 &&
      neg.single['body_bytes'] == 0 &&
      neg.single['rdap_object_matches'] == null;
  _require(
    controlStatus['rdap'] == rdapPassed,
    'eighteen-domain RDAP control status mismatch',
  );
  for (final provider in ['aliyun', 'tencent']) {
    final samples = controls
        .where(
          (row) =>
              row['provider'] == provider &&
              (row['host'] == positiveHost || row['host'] == negative),
        )
        .toList();
    final keys = samples
        .map((row) => '${row['host']}:${row['query_type']}')
        .toSet();
    _require(
      samples.length == 4 &&
          keys.length == 4 &&
          keys.containsAll({
            '$positiveHost:A',
            '$positiveHost:AAAA',
            '$negative:A',
            '$negative:AAAA',
          }),
      'eighteen-domain DNS control coverage mismatch',
    );
    final passed = samples.every((row) {
      final isNegative = row['host'] == negative;
      return row['http_status'] == 200 &&
          row['dns_truncated'] == false &&
          row['dns_rcode'] == (isNegative ? 3 : 0) &&
          (isNegative
              ? row['classification'] == 'nxdomain'
              : row['classification'] == 'noerror_addresses' ||
                    row['classification'] == 'noerror_no_address');
    });
    _require(
      controlStatus[provider] == passed,
      'eighteen-domain DNS control status mismatch',
    );
  }
}

void _addControlledRounds(
  ComRdapLedgerEvidence output,
  Map evidence,
  Map source,
  String domain,
  String host, {
  required String evidenceFile,
}) {
  final zone = _registryZone(domain);
  final roundIds = <int>{};
  for (final round in (evidence['rounds'] as List).cast<Map>()) {
    final number = round['round'];
    _require(
      number is int && roundIds.add(number),
      'invalid eighteen-domain round ID',
    );
    final controls = (round['control_status'] as Map)[zone] as Map;
    final observations = (round['observations'] as List).cast<Map>();
    final registry = observations
        .where(
          (row) =>
              row['service'] == 'verisign_$zone' && row['domain'] == domain,
        )
        .toList();
    _require(
      controls['rdap'] == true && registry.length == 1,
      'eighteen-domain registry sample unavailable',
    );
    output.add(
      source,
      host,
      _rdapObservation(
        registry.single,
        domain,
        number as int,
        evidenceFile: evidenceFile,
      ),
    );
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
            evidenceFile,
          );
        }
      }
    }
  }
  _require(roundIds.containsAll({1, 2}), 'eighteen-domain round IDs mismatch');
}

void _addControlledDoh(
  ComRdapLedgerEvidence output,
  Map round,
  Map source,
  String sourceHost,
  String target,
  String provider,
  String type,
  bool controlPassed,
  String evidenceFile,
) {
  bool same(Map row) =>
      row['host'] == target &&
      row['provider'] == provider &&
      row['query_type'] == type;
  final samples = (round['observations'] as List)
      .cast<Map>()
      .where(same)
      .toList();
  final skipped = (round['skipped'] as List).cast<Map>().where(same).toList();
  _require(
    samples.length + skipped.length == 1 &&
        (controlPassed ? samples.length == 1 : skipped.length == 1) &&
        (skipped.isEmpty ||
            (skipped.single['mode'] == 'doh' &&
                skipped.single['reason'] == 'control_failed')),
    'eighteen-domain missing or invalid DoH attempt/skip',
  );
  final exact = target == sourceHost;
  if (samples.isNotEmpty) {
    output.add(source, sourceHost, {
      ..._dohObservation(
        samples.single,
        target,
        exact: exact,
        previous: false,
        evidenceFile: evidenceFile,
      ),
      'round': round['round'],
      'controls_passed': true,
      'query_performed': true,
    });
  } else {
    output.add(source, sourceHost, {
      'evidence': evidenceFile,
      'observation_kind': exact
          ? 'public_doh_exact_endpoint_host'
          : 'public_doh_registered_domain_context',
      'queried_host': target,
      'host_relation': exact
          ? 'exact_endpoint_host'
          : 'registered_domain_context',
      'round': round['round'],
      'provider': provider,
      'query_type': type,
      'classification': 'not_attempted_control_failed',
      'observed_at': null,
      'http_status': null,
      'dns_rcode': null,
      'dnssec_authenticated': null,
      'query_performed': false,
      'controls_passed': false,
      'site_security_verified': null,
    });
  }
}

void _verifySibling(
  Map sibling,
  String domain,
  String oldHost,
  Map<String, Map> inputs,
) {
  final host = sibling['sibling_host'];
  _require(
    host is String && host != oldHost && host.endsWith('.$domain'),
    'invalid same-domain sibling counterexample host',
  );
  final observations = (sibling['observations'] as List).cast<Map>();
  _require(
    observations.isNotEmpty,
    'sibling counterexample has no observations',
  );
  if (sibling['source'] == 'dns_address_recheck') {
    final matches = (inputs['dns_address_recheck']!['results'] as List)
        .cast<Map>()
        .where((row) => row['host'] == host)
        .toList();
    _require(
      matches.length == 1 && matches.single['verdict'] == sibling['verdict'],
      'sibling DNS source evidence mismatch',
    );
    final expected = (matches.single['observations'] as List).cast<Map>();
    String identity(Map row) => jsonEncode([
      row['observed_at'],
      row['a'],
      row['aaaa'],
      row['a_address_kinds'],
      row['aaaa_address_kinds'],
    ]);
    _require(
      observations.length == expected.length &&
          observations.map(identity).toSet().length == observations.length &&
          observations
              .map(identity)
              .toSet()
              .containsAll(expected.map(identity)),
      'sibling DNS observations mismatch',
    );
    return;
  }
  final methods = observations
      .map((row) => '${row['source']}:${row['method']}')
      .toSet();
  _require(
    observations.length == 2 &&
        methods.containsAll({'host_audit:HEAD', 'amsi_other:GET'}),
    'sibling HTTP observation coverage mismatch',
  );
  for (final observation in observations) {
    final source = observation['source'];
    _require(
      source == 'host_audit' || source == 'amsi_other',
      'unknown sibling HTTP evidence',
    );
    final matches = (inputs[source]!['results'] as List)
        .cast<Map>()
        .where((row) => row['host'] == host)
        .toList();
    _require(matches.length == 1, 'sibling HTTP host evidence mismatch');
    final prior = matches.single;
    _require(
      observation['method'] == (source == 'host_audit' ? 'HEAD' : 'GET') &&
          observation['http_status'] ==
              (source == 'host_audit'
                  ? prior['status']
                  : prior['http_status']) &&
          observation['observed_at'] ==
              (source == 'host_audit'
                  ? prior['observed_at']
                  : prior['sample_observed_at']),
      'sibling HTTP observation mismatch',
    );
  }
}

void _addSibling(
  ComRdapLedgerEvidence output,
  Map source,
  String oldHost,
  Map sibling,
) {
  final dns = sibling['source'] == 'dns_address_recheck';
  for (final sample in (sibling['observations'] as List).cast<Map>()) {
    output.add(source, oldHost, {
      'evidence': comRdapEighteenEvidenceFile,
      'observation_kind': dns
          ? 'prior_sibling_dns_counterexample'
          : 'prior_sibling_http_counterexample',
      'host_relation': 'same_registered_domain_sibling',
      'queried_host': sibling['sibling_host'],
      'underlying_evidence': dns ? 'dns_address_recheck' : sample['source'],
      'observed_at': sample['observed_at'],
      if (dns) ...{
        'classification': sibling['verdict'],
        'dns_a_result': sample['a'],
        'dns_aaaa_result': sample['aaaa'],
        'dns_a_address_kinds': sample['a_address_kinds'],
        'dns_aaaa_address_kinds': sample['aaaa_address_kinds'],
      } else ...{
        'method': sample['method'],
        'http_status': sample['http_status'],
      },
      'old_source_host_availability_inferred': null,
      'site_security_verified': null,
    });
  }
}
