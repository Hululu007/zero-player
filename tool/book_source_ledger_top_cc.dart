part of 'book_source_ledger_com_rdap.dart';

const topCcEvidenceFile = 'legado-rdap-top-cc-20261116.json';
const _topCcReferences = <String, String>{
  'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
  'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
  'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
  'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
};

ComRdapLedgerEvidence readTopCcEvidence(
  Map evidence,
  Map<String, String> hashes,
  Map priorDoh,
  List rawRecords,
) {
  _require(evidence['schema_version'] == 1, 'invalid top/cc evidence schema');
  final reference =
      (evidence['input_references'] as Map)['source_ledger_historical_git']
          as Map;
  _require(
    reference['commit'] == 'a6c7d9986a64a2c7328c5f74c06415a116ef27a9',
    'top/cc historical Git object mismatch',
  );
  final history = _verifyInputs(evidence, hashes, references: _topCcReferences);
  final candidates = (evidence['candidates'] as List).cast<Map>();
  final rounds = (evidence['rounds'] as List).cast<Map>();
  final summary = evidence['summary'] as Map;
  final observations = rounds.expand(
    (r) => (r['observations'] as List).cast<Map>(),
  );
  final skipped = rounds.expand((r) => (r['skipped'] as List).cast<Map>());
  _require(
    candidates.length == 7 &&
        rounds.length == 2 &&
        summary['selected_source_ids'] == 7 &&
        observations.length == 82 &&
        skipped.length == 28 &&
        observations
                .where((r) => r['classification'] == 'provider_timeout')
                .length ==
            2 &&
        summary['domains_with_two_404'] == 0,
    'top/cc observation totals differ',
  );
  final output = ComRdapLedgerEvidence();
  final seenIds = <String>{};
  final seenDomains = <String>{};
  for (final candidate in candidates) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    final sources = (candidate['selected_sources'] as List).cast<Map>();
    _require(
      seenDomains.add(domain) &&
          (domain.endsWith('.top') || domain.endsWith('.cc')) &&
          (host == domain || host.endsWith('.$domain')) &&
          sources.length == 1,
      'invalid top/cc host association',
    );
    _verifyPreviousDoh(candidate, priorDoh);
    final source = sources.single;
    _verifyHistoricalSource(source, host, history, rawRecords);
    _require(seenIds.add(source['source_id'] as String), 'duplicate top/cc ID');
    _addPreviousDoh(
      output,
      candidate,
      source,
      host,
      evidenceFile: topCcEvidenceFile,
    );
    _addTopCcRounds(output, rounds, source, domain, host);
  }
  _require(seenIds.length == 7, 'top/cc source count mismatch');
  return output;
}

void _addTopCcRounds(
  ComRdapLedgerEvidence output,
  List<Map> rounds,
  Map source,
  String domain,
  String host,
) {
  final tld = domain.split('.').last;
  final seenRounds = <int>{};
  for (final round in rounds) {
    final number = round['round'] as int;
    _require(
      seenRounds.add(number) && (number == 1 || number == 2),
      'bad round',
    );
    final controls = (round['control_status'] as Map)[tld] as Map;
    final observations = (round['observations'] as List).cast<Map>();
    final skipped = (round['skipped'] as List).cast<Map>();
    final rdap = observations
        .where((r) => r['mode'] == 'rdap' && r['domain'] == domain)
        .toList();
    final rdapSkipped = skipped
        .where((r) => r['mode'] == 'rdap' && r['domain'] == domain)
        .toList();
    _require(
      rdap.length + rdapSkipped.length == 1,
      'ambiguous top/cc RDAP result',
    );
    if (rdap.isEmpty) {
      _require(
        controls['rdap'] == false &&
            rdapSkipped.single['reason'] == 'control_failed',
        'unjustified top/cc RDAP skip',
      );
      output.add(source, host, {
        'evidence': topCcEvidenceFile,
        'observation_kind': 'official_rdap_registered_domain_context',
        'registry_domain': domain,
        'round': number,
        'classification': 'not_queried',
        'skip_reason': 'control_failed',
        'controls_passed': false,
        'http_status': null,
        'site_security_verified': null,
      });
    } else {
      final row = rdap.single;
      final classification = row['classification'];
      _require(
        controls['rdap'] == true &&
            ((classification == 'matching_domain_object' &&
                    row['http_status'] == 200 &&
                    row['rdap_object_matches'] == true) ||
                (classification == 'http_404_json' &&
                    row['http_status'] == 404 &&
                    row['rdap_error_code_is_404'] == true)),
        'invalid top/cc RDAP result',
      );
      output.add(source, host, {
        'evidence': topCcEvidenceFile,
        'observation_kind': 'official_rdap_registered_domain_context',
        'registry_domain': domain,
        'round': number,
        'observed_at': row['observed_at'],
        'http_status': row['http_status'],
        'classification': classification,
        'domain_object_name_match': row['rdap_object_matches'],
        'rdap_conformance_present': row['rdap_conformance_present'],
        'rdap_error_code_is_404': row['rdap_error_code_is_404'],
        'controls_passed': true,
        'site_security_verified': null,
      });
    }
    for (final target in {domain, host}) {
      for (final provider in ['aliyun', 'tencent']) {
        for (final type in ['A', 'AAAA']) {
          bool matches(Map row) =>
              row['mode'] == 'doh' &&
              row['host'] == target &&
              row['provider'] == provider &&
              row['query_type'] == type;
          final samples = observations.where(matches).toList();
          final omitted = skipped.where(matches).toList();
          _require(
            samples.length + omitted.length == 1,
            'ambiguous top/cc DNS result',
          );
          if (samples.isEmpty) {
            _require(
              controls[provider] == false &&
                  omitted.single['reason'] == 'control_failed',
              'unjustified top/cc DNS skip',
            );
            output.add(source, host, {
              'evidence': topCcEvidenceFile,
              'observation_kind': target == host
                  ? 'public_doh_exact_endpoint_host'
                  : 'public_doh_registered_domain_context',
              'queried_host': target,
              'host_relation': target == host
                  ? 'exact_endpoint_host'
                  : 'registered_domain_context',
              'round': number,
              'provider': provider,
              'query_type': type,
              'classification': 'not_queried',
              'skip_reason': 'control_failed',
              'controls_passed': false,
              'dns_rcode': null,
              'site_security_verified': null,
            });
          } else {
            _require(controls[provider] == true, 'top/cc DNS control failed');
            output.add(source, host, {
              ..._dohObservation(
                samples.single,
                target,
                exact: target == host,
                previous: false,
                evidenceFile: topCcEvidenceFile,
              ),
              'round': number,
              'controls_passed': true,
            });
          }
        }
      }
    }
  }
  _require(seenRounds.length == 2, 'missing top/cc round');
}
