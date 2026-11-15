part of 'book_source_ledger_com_rdap.dart';

const rdapNineEvidenceFile = 'legado-rdap-nine-20261116.json';
const _nineReferences = <String, String>{
  'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
  'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
  'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
  'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
  'previous_rdap_com': 'docs/implementation/legado-rdap-sample-20261115.json',
  'previous_rdap_net':
      'docs/implementation/legado-rdap-net-sample-20261115.json',
  'previous_rdap_com_six':
      'docs/implementation/legado-rdap-com-six-20261116.json',
  'previous_rdap_com_eighteen':
      'docs/implementation/legado-rdap-com-eighteen-20261116.json',
  'host_audit': 'docs/implementation/legado-host-audit-20261115.json',
};

ComRdapLedgerEvidence readRdapNineEvidence(
  Map evidence,
  Map<String, String> inputHashes,
  Map priorDoh,
  List rawRecords,
  Map hostAudit,
) {
  _require(
    evidence['schema_version'] == 1,
    'unsupported nine-domain evidence schema',
  );
  final history = _verifyInputs(
    evidence,
    inputHashes,
    references: _nineReferences,
  );
  final candidates = (evidence['candidates'] as List).cast<Map>();
  final siblings = (evidence['known_sibling_counterexamples'] as List)
      .cast<Map>();
  _verifyControlledTotals(
    evidence,
    candidates,
    siblings,
    expectedDomains: 9,
    expectedSources: 12,
    expectedSiblings: 1,
  );
  final output = ComRdapLedgerEvidence();
  final domains = <String>{};
  final seenIds = <String>{};
  for (final candidate in candidates) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    _require(
      domains.add(domain) && (host == domain || host.endsWith('.$domain')),
      'invalid nine-domain registry/old-host relationship',
    );
    final selected = (candidate['selected_sources'] as List).cast<Map>();
    _require(
      selected.isNotEmpty && candidate['known_sibling_counterexample'] is bool,
      'invalid nine-domain source or sibling review state',
    );
    _verifyPreviousDoh(candidate, priorDoh);
    final matchingSiblings = siblings
        .where((item) => item['registry_domain'] == domain)
        .toList();
    _require(
      matchingSiblings.length ==
          (candidate['known_sibling_counterexample'] == true ? 1 : 0),
      'nine-domain sibling counterexample mismatch',
    );
    if (matchingSiblings.isNotEmpty) {
      _verifyNineSibling(matchingSiblings.single, domain, host, hostAudit);
    }
    for (final source in selected) {
      _verifyHistoricalSource(
        source,
        host,
        history,
        rawRecords,
        rawUrlRetained: false,
      );
      _verifyHistoricalPolicy(source, history);
      _require(
        seenIds.add(source['source_id'] as String),
        'duplicate nine-domain selected source',
      );
      _addPreviousDoh(
        output,
        candidate,
        source,
        host,
        evidenceFile: rdapNineEvidenceFile,
      );
      _addControlledRounds(
        output,
        evidence,
        source,
        domain,
        host,
        evidenceFile: rdapNineEvidenceFile,
      );
      if (matchingSiblings.isNotEmpty) {
        _addNineSibling(output, source, host, matchingSiblings.single);
      }
    }
  }
  _require(seenIds.length == 12, 'nine-domain selected source count mismatch');
  return output;
}

Object? _orderedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _orderedJson(value[key])};
  }
  if (value is List) return value.map(_orderedJson).toList();
  return value;
}

void _verifyHistoricalPolicy(Map source, Map history) {
  final selected = (history['sources'] as List)
      .cast<Map>()
      .where((row) => row['source_id'] == source['source_id'])
      .toList();
  _require(
    selected.length == 1 &&
        source['static_policy_snapshot'] is Map &&
        jsonEncode(_orderedJson(selected.single['static_policy'])) ==
            jsonEncode(_orderedJson(source['static_policy_snapshot'])),
    'nine-domain historical static policy snapshot mismatch',
  );
}

void _verifyNineSibling(
  Map sibling,
  String domain,
  String oldHost,
  Map hostAudit,
) {
  final host = sibling['host'];
  _require(
    host is String &&
        host != oldHost &&
        host.endsWith('.$domain') &&
        sibling['method'] == 'HEAD' &&
        sibling['http_status'] == 301 &&
        sibling['redirect_category'] == 'other_host' &&
        sibling['followed'] == false &&
        sibling['source'] == 'legado-host-audit-20261115.json',
    'invalid nine-domain sibling redirect counterexample',
  );
  final matches = (hostAudit['results'] as List)
      .cast<Map>()
      .where((row) => row['host'] == host)
      .toList();
  _require(
    matches.length == 1 &&
        matches.single['status'] == sibling['http_status'] &&
        matches.single['observed_at'] == sibling['observed_at'] &&
        matches.single['redirect'] == sibling['redirect_category'] &&
        matches.single['redirect_host'] == sibling['redirect_host'],
    'nine-domain sibling redirect source evidence mismatch',
  );
}

void _addNineSibling(
  ComRdapLedgerEvidence output,
  Map source,
  String oldHost,
  Map sibling,
) {
  output.add(source, oldHost, {
    'evidence': rdapNineEvidenceFile,
    'observation_kind': 'prior_sibling_http_counterexample',
    'host_relation': 'same_registered_domain_sibling',
    'queried_host': sibling['host'],
    'underlying_evidence': sibling['source'],
    'method': sibling['method'],
    'observed_at': sibling['observed_at'],
    'http_status': sibling['http_status'],
    'redirect_category': sibling['redirect_category'],
    'redirect_followed': sibling['followed'],
    'old_source_host_availability_inferred': null,
    'site_security_verified': null,
  });
}
