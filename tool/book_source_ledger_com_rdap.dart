// Offline association of the six-domain RDAP and DoH review. DNS/RDAP
// observations are time-limited evidence, not website security verdicts.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source_fingerprint.dart';

import 'book_source_ledger_nov16_evidence.dart';

part 'book_source_ledger_com_eighteen.dart';
part 'book_source_ledger_rdap_nine.dart';
part 'book_source_ledger_top_cc.dart';

const comRdapEvidenceFile = 'legado-rdap-com-six-20261116.json';
const _ledgerPath = 'docs/implementation/legado-source-ledger-20261115.json';
const _references = <String, String>{
  'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
  'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
  'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
  'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
  'previous_rdap': 'docs/implementation/legado-rdap-sample-20261115.json',
};

void _require(bool condition, String reason) {
  if (!condition) throw FormatException(reason);
}

String _key(String id, String host) => '$id\x00$host';
String _sha(String value) => sha256.convert(utf8.encode(value)).toString();

final class ComRdapLedgerEvidence {
  final registry = <String, List<Map<String, Object?>>>{};

  void add(Map source, String host, Map<String, Object?> observation) {
    final id = source['source_id'];
    final index = source['selected_record_index'];
    _require(
      id is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(id) &&
          index is int &&
          index >= 0,
      'invalid .com RDAP selected source identity',
    );
    registry.putIfAbsent(_key(id as String, host), () => []).add({
      ...observation,
      'historical_selected_record_index': index,
      'historical_source_kind': source['kind'],
      'historical_endpoint_sha256': source['endpoint_sha256'],
      'historical_normalized_legado_sha256': source['normalized_legado_sha256'],
    });
  }
}

/// Keep a prior observation as historical when a selected record or its rule
/// changes; never attach it to a different source ID or exact endpoint host.
List<Map<String, Object?>> selectComRdapEvidence(
  ComRdapLedgerEvidence evidence,
  BookSource source,
  int selectedIndex,
) => [
  for (final item
      in evidence.registry[_key(source.id, source.endpoint.host)] ??
          const <Map<String, Object?>>[])
    {
      ...item,
      'matches_current_selected_raw_record':
          item['historical_selected_record_index'] == selectedIndex,
      'matches_current_source_kind':
          item['historical_source_kind'] == source.kind.name,
      'matches_current_full_endpoint':
          item['historical_endpoint_sha256'] ==
          _sha(source.endpoint.toString()),
      'matches_current_normalized_legado_rule':
          source.legado != null &&
          item['historical_normalized_legado_sha256'] ==
              legadoSourceFingerprint(source.legado!),
    },
];

ComRdapLedgerEvidence readComRdapEvidence(
  Map evidence,
  Map<String, String> inputHashes,
  Map priorDoh,
  List rawRecords,
) {
  final history = _verifyInputs(evidence, inputHashes);
  final output = ComRdapLedgerEvidence();
  final candidates = (evidence['candidates'] as List).cast<Map>();
  _require(candidates.length == 6, '.com RDAP candidate count mismatch');
  _verifyObservationSummaries(evidence, candidates);
  final seenIds = <String>{};
  final domains = <String>{};
  for (final candidate in candidates) {
    final domain = candidate['registry_domain'] as String;
    final host = candidate['old_source_host'] as String;
    _require(
      domains.add(domain) && (host == domain || host.endsWith('.$domain')),
      'invalid .com registry-domain/old-host relationship',
    );
    final sources = (candidate['selected_sources'] as List).cast<Map>();
    _require(sources.isNotEmpty, '.com RDAP candidate lacks sources');
    _verifyPreviousDoh(candidate, priorDoh);
    for (final source in sources) {
      _verifyHistoricalSource(source, host, history, rawRecords);
      _require(
        seenIds.add(source['source_id'] as String),
        'duplicate .com RDAP source ID',
      );
      _addPreviousDoh(output, candidate, source, host);
      _addRoundObservations(output, evidence, source, domain, host);
    }
  }
  _require(seenIds.length == 8, '.com RDAP selected source count mismatch');
  return output;
}

void _verifyObservationSummaries(Map evidence, List<Map> candidates) {
  final rounds = (evidence['rounds'] as List).cast<Map>();
  final summary = evidence['summary'] as Map;
  final all = rounds
      .expand((round) => (round['observations'] as List).cast<Map>())
      .toList();
  final rdap = all.where((item) => item['service'] == 'verisign_com').toList();
  final doh = all.where((item) => item['host'] is String).toList();
  _require(
    summary['candidate_domains'] == candidates.length &&
        summary['selected_source_ids'] ==
            candidates.fold<int>(
              0,
              (count, row) => count + (row['selected_sources'] as List).length,
            ) &&
        summary['rdap_observations'] == rdap.length &&
        summary['doh_observations'] == doh.length &&
        summary['matching_domain_objects'] ==
            rdap
                .where(
                  (row) => row['classification'] == 'matching_domain_object',
                )
                .length &&
        summary['http_404_empty_body'] ==
            rdap
                .where((row) => row['classification'] == 'http_404_empty_body')
                .length &&
        summary['doh_timeouts'] ==
            doh
                .where((row) => row['classification'] == 'provider_timeout')
                .length,
    '.com RDAP overall observation summary mismatch',
  );
  for (final candidate in candidates) {
    _verifyCandidateSummary(candidate, rounds);
  }
}

void _verifyCandidateSummary(
  Map candidate,
  List<Map> rounds, {
  String registryService = 'verisign_com',
}) {
  final domain = candidate['registry_domain'];
  final oldHost = candidate['old_source_host'];
  final summary = candidate['current_summary'] as Map;
  final reportedRdap = (summary['rdap'] as List).cast<Map>();
  _require(
    reportedRdap.length == rounds.length,
    '.com RDAP candidate registry summary mismatch',
  );
  for (final round in rounds) {
    final samples = (round['observations'] as List)
        .cast<Map>()
        .where(
          (item) =>
              item['service'] == registryService && item['domain'] == domain,
        )
        .toList();
    final reported = reportedRdap
        .where((item) => item['round'] == round['round'])
        .toList();
    _require(
      samples.length == 1 &&
          reported.length == 1 &&
          [
            'http_status',
            'classification',
            'observed_at',
          ].every((key) => samples.single[key] == reported.single[key]),
      '.com RDAP candidate registry summary mismatch',
    );
  }
  final reportedDns = summary['dns_classification_counts'] as Map;
  _require(
    reportedDns.length == {domain, oldHost}.length,
    '.com RDAP candidate DoH host summary mismatch',
  );
  for (final host in {domain, oldHost}) {
    final counts = <String, int>{};
    for (final round in rounds) {
      for (final sample in (round['observations'] as List).cast<Map>().where(
        (item) => item['host'] == host,
      )) {
        final category = sample['classification'] as String;
        counts.update(category, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final reported = reportedDns[host];
    _require(
      reported is Map &&
          reported.length == counts.length &&
          counts.entries.every((entry) => reported[entry.key] == entry.value),
      '.com RDAP candidate DoH classification summary mismatch',
    );
  }
}

Map _verifyInputs(
  Map evidence,
  Map<String, String> hashes, {
  Map<String, String> references = _references,
}) {
  final inputs = evidence['input_references'] as Map;
  for (final entry in references.entries) {
    final reference = inputs[entry.key] as Map;
    _require(
      reference['path'] == entry.value &&
          hashes[entry.value] == reference['sha256'],
      '.com RDAP input digest mismatch: ${entry.key}',
    );
  }
  final reference = inputs['source_ledger_historical_git'] as Map;
  final ledger = verifiedHistoricalGitObject({
    'git_commit': reference['commit'],
    'path': reference['path'],
    'sha256': reference['sha256'],
  }, _ledgerPath);
  _require(
    (ledger['input_sha256'] as Map)[_references['catalog_archive']] ==
        hashes[_references['catalog_archive']],
    '.com RDAP historical ledger archive mismatch',
  );
  return ledger;
}

void _verifyHistoricalSource(
  Map source,
  String host,
  Map ledger,
  List rows, {
  bool rawUrlRetained = true,
}) {
  final index = source['selected_record_index'];
  _require(
    index is int && index >= 0 && index < rows.length,
    'invalid .com RDAP record index',
  );
  final matches = (ledger['sources'] as List)
      .cast<Map>()
      .where((row) => row['source_id'] == source['source_id'])
      .toList();
  _require(
    matches.length == 1,
    '.com RDAP historical source identity mismatch',
  );
  final historical = matches.single;
  _require(
    historical['selected_record_index'] == index &&
        historical['endpoint_host'] == host &&
        historical['kind'] == source['kind'] &&
        historical['endpoint_sha256'] == source['endpoint_sha256'] &&
        historical['normalized_legado_canonical_sha256'] ==
            source['normalized_legado_sha256'] &&
        historical['selected_raw_record_canonical_sha256'] ==
            source['selected_raw_record_canonical_sha256'] &&
        (!rawUrlRetained ||
            (rows[index as int] as Map)['bookSourceUrl'] ==
                source['raw_book_source_url']),
    '.com RDAP historical source or rule evidence mismatch',
  );
  final raw = parseBookSourceRecord(rows[index]);
  _require(
    raw.id == source['source_id'] &&
        raw.endpoint.host == host &&
        raw.kind.name == source['kind'],
    '.com RDAP source does not match archived record',
  );
}

void _verifyPreviousDoh(
  Map candidate,
  Map priorDoh, {
  String field = 'previous_public_doh',
}) {
  final host = candidate['old_source_host'];
  final matches = (priorDoh['results'] as List)
      .cast<Map>()
      .where((row) => row['host'] == host)
      .toList();
  _require(matches.length == 1, '.com RDAP previous DoH host mismatch');
  final expected = (matches.single['observations'] as List).cast<Map>();
  final actual = (candidate[field] as List).cast<Map>();
  String identity(Map row) => jsonEncode([
    row['provider'],
    row['query_type'],
    row['observed_at'],
    row['http_status'],
    row['dns_rcode'],
    row['dns_truncated'],
    row['dnssec_authenticated'],
    row['classification'],
    row['response_sha256'],
  ]);
  _require(
    actual.length == expected.length &&
        actual.map(identity).toSet().length == actual.length &&
        actual.map(identity).toSet().containsAll(expected.map(identity)),
    '.com RDAP previous DoH sample mismatch',
  );
}

void _addPreviousDoh(
  ComRdapLedgerEvidence output,
  Map candidate,
  Map source,
  String host, {
  String field = 'previous_public_doh',
  String evidenceFile = comRdapEvidenceFile,
}) {
  for (final sample in (candidate[field] as List).cast<Map>()) {
    output.add(
      source,
      host,
      _dohObservation(
        sample,
        host,
        exact: true,
        previous: true,
        evidenceFile: evidenceFile,
      ),
    );
  }
}

void _addRoundObservations(
  ComRdapLedgerEvidence output,
  Map evidence,
  Map source,
  String domain,
  String host,
) {
  final rounds = (evidence['rounds'] as List).cast<Map>();
  _require(rounds.length == 2, '.com RDAP round count mismatch');
  final roundIds = <int>{};
  for (final round in rounds) {
    final number = round['round'];
    _require(
      number is int && roundIds.add(number),
      'invalid .com RDAP round ID',
    );
    final controls = round['control_status'] as Map;
    _require(
      controls['rdap'] == true &&
          controls['aliyun'] == true &&
          controls['tencent'] == true,
      '.com RDAP round controls not verified',
    );
    final observations = (round['observations'] as List).cast<Map>();
    final registry = observations
        .where(
          (row) => row['domain'] == domain && row['service'] == 'verisign_com',
        )
        .toList();
    _require(registry.length == 1, '.com RDAP registry sample ambiguous');
    output.add(
      source,
      host,
      _rdapObservation(registry.single, domain, number as int),
    );
    for (final target in {domain, host}) {
      final samples = observations
          .where((row) => row['host'] == target)
          .toList();
      _require(
        samples.length == 4,
        '.com RDAP DoH target sample count mismatch',
      );
      final keys = <String>{};
      for (final sample in samples) {
        final provider = sample['provider'];
        final queryType = sample['query_type'];
        _require(
          (provider == 'aliyun' || provider == 'tencent') &&
              (queryType == 'A' || queryType == 'AAAA') &&
              keys.add('$provider:$queryType'),
          '.com RDAP DoH sample identity mismatch',
        );
        output.add(source, host, {
          ..._dohObservation(
            sample,
            target,
            exact: target == host,
            previous: false,
          ),
          'round': number,
          'controls_passed': true,
        });
      }
    }
  }
  _require(roundIds.containsAll({1, 2}), '.com RDAP round IDs mismatch');
}

Map<String, Object?> _rdapObservation(
  Map sample,
  String domain,
  int round, {
  String evidenceFile = comRdapEvidenceFile,
}) {
  final classification = sample['classification'];
  final validRegistered =
      classification == 'matching_domain_object' &&
      sample['http_status'] == 200 &&
      sample['rdap_object_matches'] == true;
  final valid404 =
      classification == 'http_404_empty_body' &&
      sample['http_status'] == 404 &&
      sample['body_bytes'] == 0 &&
      sample['rdap_object_matches'] == null &&
      sample['error_code'] == null;
  _require(
    validRegistered || valid404,
    '.com RDAP result classification mismatch',
  );
  return {
    'evidence': evidenceFile,
    'observation_kind': 'official_rdap_registered_domain_context',
    'registry_domain': domain,
    'round': round,
    'observed_at': sample['observed_at'],
    'http_status': sample['http_status'],
    'classification': classification,
    'domain_object_name_match': sample['rdap_object_matches'],
    'rdap_conformance_present': sample['rdap_conformance_present'],
    'error_code': sample['error_code'],
    'controls_passed': true,
    'site_security_verified': null,
  };
}

Map<String, Object?> _dohObservation(
  Map sample,
  String host, {
  required bool exact,
  required bool previous,
  String evidenceFile = comRdapEvidenceFile,
}) {
  final classification = sample['classification'];
  final status = sample['http_status'];
  final rcode = sample['dns_rcode'];
  final valid = classification == 'provider_timeout'
      ? status == null && rcode == null
      : status == 200 &&
            ((classification == 'nxdomain' && rcode == 3) ||
                (classification == 'servfail' && rcode == 2) ||
                ((classification == 'noerror_addresses' ||
                        classification == 'noerror_no_address') &&
                    rcode == 0));
  _require(valid, '.com RDAP DoH result classification mismatch');
  return {
    'evidence': evidenceFile,
    'observation_kind': previous
        ? 'previous_public_doh_exact_endpoint_host'
        : exact
        ? 'public_doh_exact_endpoint_host'
        : 'public_doh_registered_domain_context',
    'queried_host': host,
    'host_relation': exact
        ? 'exact_endpoint_host'
        : 'registered_domain_context',
    'observed_at': sample['observed_at'],
    'provider': sample['provider'],
    'query_type': sample['query_type'],
    'http_status': status,
    'dns_rcode': rcode,
    'dns_truncated': sample['dns_truncated'],
    'dnssec_authenticated': sample['dnssec_authenticated'],
    'dnssec_validated_locally': false,
    'classification': classification,
    'response_sha256': sample['response_sha256'],
    'site_security_verified': null,
  };
}
