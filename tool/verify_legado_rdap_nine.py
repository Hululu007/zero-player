"""Verify the nine-domain RDAP/DNS evidence offline; never contact the network."""
import argparse
import bz2
from collections import Counter
import json
from pathlib import Path
import re
import subprocess

if __package__:
    from . import verify_legado_rdap_com_eighteen as shared
else:
    import verify_legado_rdap_com_eighteen as shared

ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-rdap-nine-20261116.json'
COMMIT = shared.COMMIT
LEDGER = shared.LEDGER
FILES = {key: shared.FILES[key] for key in ('catalog_archive', 'catalog_manifest', 'host_recheck', 'doh_reviewed',
                                             'previous_rdap_com', 'previous_rdap_net', 'previous_rdap_com_six',
                                             'host_audit')}
FILES['previous_rdap_com_eighteen'] = shared.EVIDENCE
HOSTS = {
    'aoyekanshu.com': 'get.aoyekanshu.com', 'bulasw.com': 'm.bulasw.com',
    'dmx5.com': 'm.dmx5.com', 'hanmandq.com': 'www.hanmandq.com',
    'ndlib.com': 'm.ndlib.com', 'txt86w.com': 'www.txt86w.com',
    'xichubao.com': 'www.xichubao.com', 'yunhai9.com': 'm.yunhai9.com',
    'uu234.net': 'www.uu234.net',
}
NOT_FOUND = {'aoyekanshu.com', 'hanmandq.com', 'xichubao.com'}
require = shared.require
sha = shared.sha
timestamp = shared.timestamp


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
        if key != 'previous_rdap_com_eighteen':
            require(ledger['input_sha256'].get(path) == sha(raw[key]), 'historical ledger input mismatch: ' + key)
    return archive, ledger, {k: json.loads(v) for k, v in raw.items() if k not in ('catalog_archive', 'catalog_manifest')}


def verify_candidates(evidence, archive, ledger, inputs):
    candidates = evidence['candidates']
    require(len(candidates) == 9 and {r['registry_domain']: r['old_source_host'] for r in candidates} == HOSTS,
            'candidate domain or host set differs')
    byid = {row['source_id']: row for row in ledger['sources']}
    heads = {row['host']: row for row in inputs['host_recheck']['results']}
    doh = {row['host']: row for row in inputs['doh_reviewed']['results']}
    queried = {r['registry_domain'] for r in inputs['previous_rdap_com']['candidates']}
    queried.update(r['registry_domain'] for r in inputs['previous_rdap_net']['results'])
    queried.update(r['registry_domain'] for r in inputs['previous_rdap_com_six']['candidates'])
    queried.update(r['registry_domain'] for r in inputs['previous_rdap_com_eighteen']['candidates'])
    seen = set()
    for c in candidates:
        domain, host = c['registry_domain'], c['old_source_host']
        require(set(c) == {'registry_domain', 'old_source_host', 'selected_sources', 'known_sibling_counterexample',
                           'previous_native_dns', 'previous_public_doh', 'current_summary'}, 'unexpected candidate fields')
        require(domain not in queried and '.'.join(host.split('.')[-2:]) == domain, 'invalid registry association')
        require(c['known_sibling_counterexample'] == (domain == 'bulasw.com'), 'sibling flag differs')
        native, old = heads[host], doh[host]
        require(native['dns_verdict'] == 'repeated_nxdomain' and c['previous_native_dns'] == native['dns_observations']
                and len(native['dns_observations']) == 2 and
                all(9003 in (r['a'], r['aaaa']) and r['a'] in (9003, 9501) and r['aaaa'] in (9003, 9501)
                    for r in native['dns_observations']), 'old native DNS evidence differs')
        obs = old['observations']
        require(old['baseline'] == 'repeated_nxdomain' and c['previous_public_doh'] == obs and len(obs) == 4 and
                {(r['provider'], r['query_type']) for r in obs} ==
                {(provider, typ) for provider in shared.PROVIDERS for typ in shared.QTYPES} and
                any(r['classification'] != 'nxdomain' or r.get('dns_rcode') != 3 or r.get('http_status') != 200
                    for r in obs), 'old public DNS evidence differs')
        ids = {s['source_id'] for s in c['selected_sources']}
        require(ids and len(ids) == len(c['selected_sources']) and ids == set(old['selected_source_ids']) and
                ids == {s['source_id'] for s in ledger['sources'] if s['endpoint_host'] == host},
                'selected source association differs')
        for source in c['selected_sources']:
            ident = source['source_id']
            require(ident not in seen, 'duplicate source identity')
            seen.add(ident)
            require(source.get('static_policy_snapshot') == byid[ident]['static_policy'], 'static policy snapshot differs')
            shared.verify_source({k: v for k, v in source.items() if k != 'static_policy_snapshot'}, host, byid, archive)
    require(len(seen) == 12, 'selected source ID count differs')


def verify_sibling(evidence, inputs):
    row = next(r for r in inputs['host_audit']['results'] if r['host'] == 'www.bulasw.com')
    require(row.get('status') == 301 and row.get('redirect') == 'other_host', 'sibling HTTP evidence differs')
    expected = {'registry_domain': 'bulasw.com', 'host': row['host'], 'method': 'HEAD',
                'observed_at': row['observed_at'], 'http_status': row['status'], 'redirect_category': row['redirect'],
                'redirect_host': row['redirect_host'], 'followed': False, 'source': 'legado-host-audit-20261115.json'}
    require(evidence['known_sibling_counterexamples'] == [expected], 'same-domain counterexample differs')


def verify_rounds(evidence):
    negative = evidence['negative_controls']
    require(set(negative) == {'com', 'net'} and
            all(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.' + tld, name) for tld, name in negative.items()) and
            negative['com'].removesuffix('.com') == negative['net'].removesuffix('.net'), 'invalid negative controls')
    runs = evidence['rounds']
    require(len(runs) == 2 and [r['round'] for r in runs] == [1, 2], 'two ordered rounds required')
    outer_start, outer_end = timestamp(evidence['observed_start_utc']), timestamp(evidence['observed_end_utc'])
    full = {('rdap', domain, None, None) for domain in HOSTS}
    full |= {('doh', host, provider, typ) for domain, old in HOSTS.items() for host in (domain, old)
             for provider in shared.PROVIDERS for typ in shared.QTYPES}
    tld_by_host = {host: root.rsplit('.', 1)[-1] for root, old in HOSTS.items() for host in (root, old)}
    fixed_status = [
        {'com': {'rdap': True, 'aliyun': True, 'tencent': False},
         'net': {'rdap': True, 'aliyun': True, 'tencent': True}},
        {'com': {'rdap': True, 'aliyun': True, 'tencent': True},
         'net': {'rdap': True, 'aliyun': True, 'tencent': True}},
    ]
    all_rdap, all_dns, control_timeouts = [], [], []
    last_end = outer_start
    for run, expected_status in zip(runs, fixed_status):
        require(set(run) == {'round', 'started_at', 'completed_at', 'controls', 'control_status', 'observations',
                             'scheduled', 'skipped', 'classification_counts'}, 'unexpected round fields')
        start, end = timestamp(run['started_at']), timestamp(run['completed_at'])
        require(last_end <= start <= end <= outer_end, 'round outside collection window')
        last_end = end
        for row in run['controls']:
            shared.common.validate_times(row, start, end)
            if row['classification'] == 'provider_timeout':
                control_timeouts.append((run['round'], row['host'], row['provider'], row['query_type']))
        status = shared.derived_control_status(run['controls'], negative)
        require(status == run['control_status'] == expected_status, 'control status differs from observations')
        scheduled = {k for k in full if status[tld_by_host[k[1]]]['rdap' if k[0] == 'rdap' else k[2]]}
        observed = set()
        for row in run['observations']:
            shared.common.validate_times(row, start, end)
            key = shared.observation_key(row)
            require(key not in observed, 'duplicate candidate observation')
            observed.add(key)
            (all_rdap if key[0] == 'rdap' else all_dns).append((run['round'], row))
        skipped = [shared.skipped_key(row) for row in run['skipped']]
        require(observed == scheduled and set(skipped) == full - scheduled and len(skipped) == len(set(skipped)) and
                not observed.intersection(skipped), 'candidate query coverage or skipped controls differ')
        require(len(observed) == run['scheduled'] and
                dict(Counter(row['classification'] for row in run['observations'])) == run['classification_counts'],
                'round result totals differ')
    expected_control_timeouts = {(1, 'google.com', 'tencent', 'A'), (1, negative['com'], 'tencent', 'AAAA')}
    require(set(control_timeouts) == expected_control_timeouts and len(control_timeouts) == 2,
            'control timeout set differs')
    expected_timeouts = {(2, 'aoyekanshu.com', 'tencent', 'A'), (2, 'get.aoyekanshu.com', 'tencent', 'A'),
                         (2, 'get.aoyekanshu.com', 'tencent', 'AAAA'), (2, 'txt86w.com', 'tencent', 'AAAA')}
    actual_timeouts = {(run, row['host'], row['provider'], row['query_type']) for run, row in all_dns
                       if row['classification'] == 'provider_timeout'}
    require(actual_timeouts == expected_timeouts, 'candidate timeout set differs')
    require(len(all_rdap) == 18 and len(all_dns) == 112 and
            all(row['classification'] == ('http_404_empty_body' if row['domain'] in NOT_FOUND
                                          else 'matching_domain_object') for _, row in all_rdap),
            'domain RDAP classification differs')
    return all_rdap, all_dns


def verify_summaries(evidence, rdap, dns):
    runs = evidence['rounds']
    for c in evidence['candidates']:
        domain, host = c['registry_domain'], c['old_source_host']
        expected_rdap = [{'round': run, 'http_status': row['http_status'], 'classification': row['classification'],
                          'observed_at': row['observed_at']} for run, row in rdap if row['domain'] == domain]
        counts = {name: dict(Counter(row['classification'] for _, row in dns if row['host'] == name))
                  for name in (domain, host)}
        skipped = sum(row.get('host') in counts for run in runs for row in run['skipped'])
        require(c['current_summary'] == {'rdap': expected_rdap, 'dns_classification_counts': counts,
                                         'skipped_due_to_control': skipped}, 'candidate summary differs')
    summary = {'candidate_domains': 9, 'selected_source_ids': 12, 'candidate_requests_attempted': 130,
               'candidate_requests_skipped_due_to_control': 32, 'control_requests_attempted': 40,
               'total_requests_attempted': 170, 'rdap_observations': 18, 'doh_observations': 112,
               'rdap_matching_domain_objects': 12, 'rdap_http_404_empty_body': 6,
               'domains_with_two_404': 3, 'domains_with_two_matching_objects': 6,
               'candidate_doh_timeouts': 4, 'control_doh_timeouts': 2, 'known_sibling_counterexample_domains': 1}
    require(evidence['summary'] == summary, 'overall summary differs from observations')
    return summary


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
                               'reused_driver_sha256', 'collector_scripts_and_draft_in_repository',
                               'raw_rdap_and_dns_responses_in_repository'} and
            artifacts['collector_scripts_and_draft_in_repository'] is False and
            artifacts['raw_rdap_and_dns_responses_in_repository'] is False and
            all(re.fullmatch(r'[0-9a-f]{64}', artifacts[key]) for key in
                ('draft_sha256', 'collector_driver_sha256', 'collector_worker_sha256', 'reused_driver_sha256')),
            'invalid artifact metadata')
    shared.common.reject_sensitive(evidence)
    shared.reject_url_queries(evidence)
    archive, ledger, inputs = load_inputs(evidence)
    verify_candidates(evidence, archive, ledger, inputs)
    verify_sibling(evidence, inputs)
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
