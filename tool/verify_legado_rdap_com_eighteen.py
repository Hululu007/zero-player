"""Verify the eighteen-domain RDAP/DNS evidence offline; never contact the network."""
import argparse
import bz2
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote, urlsplit

if __package__:
    from . import verify_legado_rdap_com_six as common
else:
    import verify_legado_rdap_com_six as common

ROOT = common.ROOT
EVIDENCE = 'docs/implementation/legado-rdap-com-eighteen-20261116.json'
COMMIT = 'df798cc773dd09722214cdced6eded5a2d2431ea'
LEDGER = common.LEDGER
FILES = {
    'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
    'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
    'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
    'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
    'previous_rdap_com': 'docs/implementation/legado-rdap-sample-20261115.json',
    'previous_rdap_net': 'docs/implementation/legado-rdap-net-sample-20261115.json',
    'previous_rdap_com_six': 'docs/implementation/legado-rdap-com-six-20261116.json',
    'dns_address_recheck': 'docs/implementation/legado-dns-address-recheck-20261115.json',
    'host_audit': 'docs/implementation/legado-host-audit-20261115.json',
    'amsi_other': 'docs/implementation/legado-amsi-other-hosts-20261115.json',
}
HOSTS = {
    '778buy.com': 'xs.778buy.com', 'bgwxc.com': 'm.bgwxc.com',
    'bqg70.com': 'm.bqg70.com', 'bxzwapp.com': 'open.bxzwapp.com',
    'hsjsby.com': 'wap.hsjsby.com', 'iqhmh.com': 'api.iqhmh.com',
    'iqingguo.com': 'api-new.iqingguo.com', 'iswsk.com': 'www.iswsk.com',
    'junshishu.com': 'androidapi.junshishu.com', 'kuduwxw.com': 'api.kuduwxw.com',
    'meiguixsapp.com': 'api.meiguixsapp.com', 'motie.com': 'api.motie.com',
    'pjxhmy.com': 's.pjxhmy.com', 'scamssm.com': 'm.scamssm.com',
    'uuhanman.com': 'www.uuhanman.com', 'uuxsw8.com': 'm.uuxsw8.com',
    'yjzhy.com': 'm.yjzhy.com', 'yuntuxs.com': 'book.yuntuxs.com',
}
NOT_FOUND = {'bxzwapp.com', 'iswsk.com', 'kuduwxw.com', 'meiguixsapp.com',
             'uuhanman.com', 'yjzhy.com', 'yuntuxs.com'}
SIBLING_DOMAINS = {'bgwxc.com', 'bqg70.com', 'motie.com'}
PROVIDERS = common.PROVIDERS
QTYPES = common.QTYPES
require = common.require
sha = common.sha
timestamp = common.timestamp


def load_inputs(evidence):
    refs = evidence['input_references']
    require(set(refs) == set(FILES) | {'source_ledger_historical_git'}, 'input reference set mismatch')
    raw = {}
    for key, path in FILES.items():
        ref = refs[key]
        require(ref == {'path': path, 'sha256': ref.get('sha256')}, 'unexpected input reference')
        raw[key] = (ROOT / path).read_bytes()
        require(sha(raw[key]) == ref['sha256'], 'input digest mismatch: ' + key)
    ref = refs['source_ledger_historical_git']
    require(ref.get('commit') == COMMIT and ref.get('path') == LEDGER and
            set(ref) == {'commit', 'path', 'sha256'}, 'historical ledger reference mismatch')
    try:
        proc = subprocess.run(['git', '-C', str(ROOT), 'show', COMMIT + ':' + LEDGER],
                              capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or historical ledger object is unavailable') from None
    require(proc.returncode == 0, 'historical ledger object unavailable; shallow clones may omit it')
    require(sha(proc.stdout) == ref['sha256'], 'historical ledger digest mismatch')
    ledger = json.loads(proc.stdout)
    manifest = json.loads(raw['catalog_manifest'])
    archive = json.loads(bz2.decompress(raw['catalog_archive']))
    require(manifest['archiveSha256'] == sha(raw['catalog_archive']) and
            len(archive['records']) == manifest['records'], 'catalog archive/manifest mismatch')
    for key, path in FILES.items():
        if key != 'dns_address_recheck':
            require(ledger['input_sha256'].get(path) == sha(raw[key]), 'historical ledger input mismatch: ' + key)
    return archive, ledger, {k: json.loads(v) for k, v in raw.items() if k not in ('catalog_archive', 'catalog_manifest')}


def verify_source(source, host, ledger_sources, archive):
    keys = {'source_id', 'name', 'kind', 'selected_record_index', 'normalized_legado_sha256',
            'endpoint_sha256', 'selected_raw_record_canonical_sha256'}
    require(set(source) == keys, 'unexpected source fields')
    historic = ledger_sources.get(source['source_id'])
    require(historic is not None and historic['endpoint_host'] == host and
            all(source[k] == historic[ledger_key] for k, ledger_key in [
                ('name', 'name'), ('kind', 'kind'), ('selected_record_index', 'selected_record_index'),
                ('normalized_legado_sha256', 'normalized_legado_canonical_sha256'),
                ('endpoint_sha256', 'endpoint_sha256'),
                ('selected_raw_record_canonical_sha256', 'selected_raw_record_canonical_sha256')]),
            'source does not match historical selected version')
    index = source['selected_record_index']
    require(isinstance(index, int) and 0 <= index < len(archive['records']) and
            any(index in refs for refs in archive['packs'].values()), 'selected archive record is not referenced')
    raw = archive['records'][index]
    encoded = json.dumps(raw, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
    require(sha(encoded) == source['selected_raw_record_canonical_sha256'], 'archive record digest mismatch')
    parsed = urlsplit(raw.get('bookSourceUrl', ''))
    require(parsed.scheme in ('http', 'https') and parsed.hostname == host and
            parsed.username is None and parsed.password is None and parsed.port is None,
            'unexpected raw source endpoint')
    kind = {'0': 'text', '2': 'comic'}.get(str(raw.get('bookSourceType', 0)))
    require(kind == source['kind'], 'archive record kind mismatch')
    safe = "!$&'()*+,;=:@/?-._~%"
    path, query, fragment = (quote(value, safe=safe) for value in (parsed.path, parsed.query, parsed.fragment))
    endpoint = 'https://' + host + path + ('?' + query if query else '')
    require(sha(endpoint.encode('utf-8')) == source['endpoint_sha256'], 'normalized endpoint digest mismatch')
    key = host.removeprefix('www.') + (path if path != '/' else '')
    key += ('?' + query if query else '') + ('#' + fragment if fragment else '')
    identity = (f"{kind}:html:{host.removeprefix('www.')}" if path in ('', '/') and not query and not fragment
                else f'legado:{kind}:html:{key}')
    require(sha(identity.encode('utf-8')) == source['source_id'], 'source ID derivation mismatch')


def verify_candidates(evidence, archive, ledger, inputs):
    rows = evidence['candidates']
    require(len(rows) == 18 and {r['registry_domain']: r['old_source_host'] for r in rows} == HOSTS,
            'candidate domain or host set differs')
    byid = {row['source_id']: row for row in ledger['sources']}
    heads = {row['host']: row for row in inputs['host_recheck']['results']}
    doh = {row['host']: row for row in inputs['doh_reviewed']['results']}
    queried = {r['registry_domain'] for r in inputs['previous_rdap_com']['candidates']}
    queried.update(r['registry_domain'] for r in inputs['previous_rdap_net']['results'])
    queried.update(r['registry_domain'] for r in inputs['previous_rdap_com_six']['candidates'])
    seen_ids = set()
    for candidate in rows:
        domain, host = candidate['registry_domain'], candidate['old_source_host']
        require(set(candidate) == {'registry_domain', 'old_source_host', 'selected_sources',
                                   'known_sibling_counterexample', 'previous_native_dns_verdict',
                                   'previous_local_dns_observations', 'previous_doh', 'current_summary'},
                'unexpected candidate fields')
        require(domain not in queried and '.'.join(host.split('.')[-2:]) == domain, 'invalid registry association')
        require(candidate['known_sibling_counterexample'] == (domain in SIBLING_DOMAINS), 'sibling flag differs')
        native, old = heads[host], doh[host]
        require(candidate['previous_native_dns_verdict'] == native['dns_verdict'] == 'repeated_nxdomain' and
                candidate['previous_local_dns_observations'] == native['dns_observations'] and
                len(native['dns_observations']) == 2 and
                all(9003 in (o['a'], o['aaaa']) and o['a'] in (9003, 9501) and o['aaaa'] in (9003, 9501)
                    for o in native['dns_observations']), 'old native DNS evidence differs')
        observations = old['observations']
        require(old['baseline'] == 'repeated_nxdomain' and candidate['previous_doh'] == observations and
                len(observations) == 4 and {(o['provider'], o['query_type']) for o in observations} ==
                {(provider, typ) for provider in PROVIDERS for typ in QTYPES} and
                all(o['classification'] == 'nxdomain' and o['http_status'] == 200 and o['dns_rcode'] == 3
                    for o in observations), 'old public DNS evidence differs')
        ids = {s['source_id'] for s in candidate['selected_sources']}
        expected = {s['source_id'] for s in ledger['sources'] if s['endpoint_host'] == host}
        require(ids == expected and ids == set(old['selected_source_ids']) and
                len(ids) == len(candidate['selected_sources']) and ids, 'selected source association differs')
        for source in candidate['selected_sources']:
            require(source['source_id'] not in seen_ids, 'duplicate source identity')
            seen_ids.add(source['source_id'])
            verify_source(source, host, byid, archive)
    require(len(seen_ids) == 22, 'selected source ID count differs')


def verify_rdap(row):
    require(set(row) == (common.RDAP_KEYS - {'error_code'}) | {'body_sha256'}, 'invalid RDAP fields')
    tld = row['domain'].rsplit('.', 1)[-1]
    require(tld in ('com', 'net') and row['service'] == 'verisign_' + tld, 'invalid RDAP registry')
    require(re.fullmatch(r'[0-9a-f]{64}', row['body_sha256']) is not None, 'invalid RDAP body digest')
    if row['classification'] == 'http_404_empty_body':
        require(row['body_sha256'] == sha(b''), 'empty RDAP body digest differs')
    normalized = {k: v for k, v in row.items() if k != 'body_sha256'}
    normalized.update(service='verisign_com', error_code=None)
    common.verify_rdap(normalized)


def observation_key(row):
    if 'service' in row:
        verify_rdap(row)
        return 'rdap', row['domain'], None, None
    common.verify_dns(row)
    if row['classification'] == 'provider_timeout':
        require(set(row) == {'host', 'baseline', 'provider', 'query_type', 'started_at',
                             'observed_at', 'classification'}, 'timeout contains fabricated DNS outcome')
    return 'doh', row['host'], row['provider'], row['query_type']


def skipped_key(row):
    require(row.get('reason') == 'control_failed', 'invalid skipped-query reason')
    if row.get('mode') == 'rdap':
        require(set(row) == {'mode', 'domain', 'reason'}, 'invalid skipped RDAP fields')
        return 'rdap', row['domain'], None, None
    require(row.get('mode') == 'doh' and set(row) == {'mode', 'host', 'provider', 'query_type', 'reason'},
            'invalid skipped DoH fields')
    return 'doh', row['host'], row['provider'], row['query_type']


def derived_control_status(controls, negative):
    lookup = {observation_key(row): row for row in controls}
    expected = {('rdap', d, None, None) for d in ('google.com', 'google.net', negative['com'], negative['net'])}
    expected |= {('doh', d, p, typ) for d in ('google.com', 'google.net', negative['com'], negative['net'])
                 for p in PROVIDERS for typ in QTYPES}
    require(len(controls) == len(lookup) == 20 and set(lookup) == expected, 'control query coverage differs')
    status = {}
    for tld in ('com', 'net'):
        positive, absent = 'google.' + tld, negative[tld]
        status[tld] = {'rdap': lookup['rdap', positive, None, None]['classification'] == 'matching_domain_object'
                       and lookup['rdap', absent, None, None]['classification'] == 'http_404_empty_body'}
        for provider in PROVIDERS:
            def good(name, typ):
                row = lookup['doh', name, provider, typ]
                if row.get('http_status') != 200 or row.get('dns_truncated'):
                    return False
                if name == absent:
                    return row['classification'] == 'nxdomain' and row['dns_rcode'] == 3
                return row.get('dns_rcode') == 0 and (typ != 'A' or row['address_categories'].get('public', 0) > 0)
            status[tld][provider] = all(good(name, typ) for name in (positive, absent) for typ in QTYPES)
    return status


def verify_rounds(evidence):
    negative = evidence['negative_controls']
    require(set(negative) == {'com', 'net'} and
            all(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.' + tld, name) for tld, name in negative.items()) and
            negative['com'].removesuffix('.com') == negative['net'].removesuffix('.net'), 'invalid negative controls')
    runs = evidence['rounds']
    require(len(runs) == 2 and [r['round'] for r in runs] == [1, 2], 'two ordered rounds required')
    outer_start, outer_end = timestamp(evidence['observed_start_utc']), timestamp(evidence['observed_end_utc'])
    full = {('rdap', domain, None, None) for domain in HOSTS}
    full |= {('doh', host, p, typ) for domain, old in HOSTS.items() for host in (domain, old)
             for p in PROVIDERS for typ in QTYPES}
    all_rdap, all_dns, control_timeouts = [], [], []
    expected_status = [
        {'com': {'rdap': True, 'aliyun': True, 'tencent': False},
         'net': {'rdap': True, 'aliyun': True, 'tencent': True}},
        {'com': {'rdap': True, 'aliyun': True, 'tencent': True},
         'net': {'rdap': True, 'aliyun': True, 'tencent': False}},
    ]
    for run, fixed_status in zip(runs, expected_status):
        require(set(run) == {'round', 'started_at', 'completed_at', 'controls', 'control_status', 'observations',
                             'scheduled', 'skipped', 'classification_counts'}, 'unexpected round fields')
        start, end = timestamp(run['started_at']), timestamp(run['completed_at'])
        require(outer_start <= start <= end <= outer_end, 'round outside collection window')
        for row in run['controls']:
            common.validate_times(row, start, end)
            if row['classification'] == 'provider_timeout':
                control_timeouts.append((run['round'], row['host'], row['provider'], row['query_type']))
        status = derived_control_status(run['controls'], negative)
        require(status == run['control_status'] == fixed_status, 'control status differs from observations')
        expected = {k for k in full if status['com']['rdap' if k[0] == 'rdap' else k[2]]}
        observed = set()
        for row in run['observations']:
            common.validate_times(row, start, end)
            key = observation_key(row)
            require(key not in observed, 'duplicate candidate observation')
            observed.add(key)
            (all_rdap if key[0] == 'rdap' else all_dns).append((run['round'], row))
        skipped = [skipped_key(row) for row in run['skipped']]
        require(observed == expected and set(skipped) == full - expected and len(skipped) == len(set(skipped)) and
                not observed.intersection(skipped), 'candidate query coverage or skipped controls differ')
        require(len(observed) == run['scheduled'] and
                dict(Counter(row['classification'] for row in run['observations'])) == run['classification_counts'],
                'round result totals differ')
    expected_control_timeouts = {(1, 'google.com', 'tencent', 'A'), (1, negative['com'], 'tencent', 'AAAA'),
                                 (2, 'google.net', 'tencent', 'A'), (2, negative['net'], 'tencent', 'A')}
    require(set(control_timeouts) == expected_control_timeouts and len(control_timeouts) == 4,
            'control timeout set differs')
    expected_timeouts = {(2, 'bqg70.com', 'tencent', 'A'), (2, 'open.bxzwapp.com', 'tencent', 'AAAA'),
                         (2, 'www.iswsk.com', 'tencent', 'AAAA'), (2, 'androidapi.junshishu.com', 'tencent', 'A'),
                         (2, 'meiguixsapp.com', 'tencent', 'AAAA'), (2, 'book.yuntuxs.com', 'tencent', 'AAAA')}
    actual_timeouts = {(run, row['host'], row['provider'], row['query_type']) for run, row in all_dns
                       if row['classification'] == 'provider_timeout'}
    require(actual_timeouts == expected_timeouts, 'candidate timeout set differs')
    require(len(all_rdap) == 36 and len(all_dns) == 216 and
            all(row['classification'] == ('http_404_empty_body' if row['domain'] in NOT_FOUND
                                          else 'matching_domain_object') for _, row in all_rdap),
            'domain RDAP classification differs')
    return all_rdap, all_dns


def verify_siblings(evidence, inputs):
    addresses = inputs['dns_address_recheck']['results']
    audit, amsi = inputs['host_audit']['results'], inputs['amsi_other']['results']
    address = next(row for row in addresses if row['host'] == 'www.bgwxc.com')
    expected = [{'registry_domain': 'bgwxc.com', 'sibling_host': address['host'], 'source': 'dns_address_recheck',
                 'verdict': address['verdict'], 'observations': address['observations']}]
    require(address['verdict'] == 'public_address_observed' and len(address['observations']) == 2 and
            all(row.get('a_address_kinds', {}).get('public', 0) > 0 for row in address['observations']),
            'sibling public-address evidence differs')
    for domain, host, head_status, get_status in [('bqg70.com', 'www.bqg70.com', 503, 503),
                                                   ('motie.com', 'app2.motie.com', 403, 403)]:
        head = next(row for row in audit if row['host'] == host)
        get = next(row for row in amsi if row['host'] == host)
        require(head['status'] == head_status and get['http_status'] == get_status, 'sibling HTTP evidence differs')
        expected.append({'registry_domain': domain, 'sibling_host': host,
                         'observations': [{'source': 'host_audit', 'method': 'HEAD',
                                           'observed_at': head['observed_at'], 'http_status': head['status']},
                                          {'source': 'amsi_other', 'method': 'GET',
                                           'observed_at': get['sample_observed_at'], 'http_status': get['http_status']}]})
    require(evidence['known_sibling_counterexamples'] == expected, 'same-domain counterexamples differ')


def verify_summaries(evidence, rdap, dns):
    runs = evidence['rounds']
    for candidate in evidence['candidates']:
        domain, host = candidate['registry_domain'], candidate['old_source_host']
        expected_rdap = [{'round': run, 'http_status': row['http_status'], 'classification': row['classification'],
                          'observed_at': row['observed_at']} for run, row in rdap if row['domain'] == domain]
        counts = {name: dict(Counter(row['classification'] for _, row in dns if row['host'] == name))
                  for name in (domain, host)}
        skipped = sum(row.get('host') in counts for run in runs for row in run['skipped'])
        require(candidate['current_summary'] == {'rdap': expected_rdap, 'dns_classification_counts': counts,
                                                  'skipped_due_to_control': skipped}, 'candidate summary differs')
    summary = {'candidate_domains': 18, 'selected_source_ids': 22, 'candidate_requests_attempted': 252,
               'candidate_requests_skipped_due_to_control': 72, 'control_requests_attempted': 40,
               'total_requests_attempted': 292, 'rdap_observations': 36, 'doh_observations': 216,
               'rdap_matching_domain_objects': 22, 'rdap_http_404_empty_body': 14,
               'domains_with_two_404': 7, 'domains_with_two_matching_objects': 11,
               'candidate_doh_timeouts': 6, 'control_doh_timeouts': 4, 'known_sibling_counterexample_domains': 3}
    require(evidence['summary'] == summary, 'overall summary differs from observations')
    return summary


def reject_url_queries(value):
    if isinstance(value, dict):
        for item in value.values():
            reject_url_queries(item)
    elif isinstance(value, list):
        for item in value:
            reject_url_queries(item)
    elif isinstance(value, str):
        for url in re.findall(r'https?://[^\s\"<>]+', value):
            require(not urlsplit(url).query, 'URL query found in evidence')


def verify(evidence):
    fields = {'schema_version', 'observed_start_utc', 'observed_end_utc', 'negative_controls',
              'registry_services', 'doh_providers', 'method', 'method_precision', 'input_references',
              'collection_artifacts', 'limitations', 'known_sibling_counterexamples', 'candidates', 'rounds', 'summary'}
    require(set(evidence) == fields and evidence['schema_version'] == 1, 'unexpected evidence fields or schema')
    require(evidence['registry_services'] == {'com': 'https://rdap.verisign.com/com/v1/domain/{domain}',
                                               'net': 'https://rdap.verisign.com/net/v1/domain/{domain}'} and
            evidence['doh_providers'] == {'aliyun': 'dns.alidns.com', 'tencent': 'doh.pub'}, 'unexpected services')
    artifacts = evidence['collection_artifacts']
    require(set(artifacts) == {'draft_sha256', 'collector_driver_sha256', 'collector_worker_sha256',
                               'collector_scripts_and_draft_in_repository', 'raw_rdap_and_dns_responses_in_repository'} and
            artifacts['collector_scripts_and_draft_in_repository'] is False and
            artifacts['raw_rdap_and_dns_responses_in_repository'] is False and
            all(re.fullmatch(r'[0-9a-f]{64}', artifacts[key]) for key in
                ('draft_sha256', 'collector_driver_sha256', 'collector_worker_sha256')), 'invalid artifact metadata')
    common.reject_sensitive(evidence)
    reject_url_queries(evidence)
    archive, ledger, inputs = load_inputs(evidence)
    verify_candidates(evidence, archive, ledger, inputs)
    verify_siblings(evidence, inputs)
    rdap, dns = verify_rounds(evidence)
    return verify_summaries(evidence, rdap, dns)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    summary = verify(json.loads(raw))
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': summary,
                      'historical_response_bodies_recomputed': False, 'historical_ledger_git_commit': COMMIT},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
