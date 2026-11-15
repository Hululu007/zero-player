"""Verify five-domain RDAP/DNS evidence offline without accessing the network."""
import argparse
import bz2
from collections import Counter
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote, urlsplit

if __package__:
    from . import verify_legado_rdap_top_cc as shared
else:
    import verify_legado_rdap_top_cc as shared

common = shared.common
ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-rdap-five-20261116.json'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
COMMIT = 'f7b5697d49fdc5113274e5add45a1108638957c5'
FILES = {
    'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
    'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
    'later_host_recheck': 'docs/implementation/legado-unresolved-head-later-20261116.json',
    'older_host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
    'prior_public_doh': 'docs/implementation/legado-doh-reviewed-20261115.json',
}
PREVIOUS_RDAP = [
    'docs/implementation/legado-rdap-sample-20261115.json',
    'docs/implementation/legado-rdap-net-sample-20261115.json',
    'docs/implementation/legado-rdap-com-six-20261116.json',
    'docs/implementation/legado-rdap-com-eighteen-20261116.json',
    'docs/implementation/legado-rdap-nine-20261116.json',
    'docs/implementation/legado-rdap-top-cc-20261116.json',
]
HOSTS = {'7wav.com': 'm.7wav.com', '92yanqing.net': 'm.92yanqing.net',
         'fxsw.top': 'www.fxsw.top', 'zri.moe': 'book.zri.moe', 'cwj18.org': 'www.cwj18.org'}
SERVICES = {'com': ['https://rdap.verisign.com/com/v1/'], 'net': ['https://rdap.verisign.com/net/v1/'],
            'top': ['https://rdap.zdnsgtld.com/top/'], 'moe': ['https://rdap.nic.moe/'],
            'org': ['https://rdap.publicinterestregistry.org/rdap/']}
PROVIDERS, QTYPES = ('aliyun', 'tencent'), ('A', 'AAAA')
IANA_SHA256 = '2789f2f92f7ba785e0d3cd4cdcc70709e0ded1d331619e6784317c8bf2bc72b6'
FROZEN_ROUNDS_SHA256 = 'f41e27d735814f7519b54edebf7ec5d4ac4ac08c6af4a93e9b6ca8132ba2e6e9'
PSL = {'source': 'https://publicsuffix.org/list/public_suffix_list.dat',
       'sha256': 'fc62f83e482dd86d3c50216fcbf5bb6c3b18f13d0ffdfc462b14e36b8a97bfba',
       'version': '2026-11-15_20-28-43_UTC', 'commit': 'fd22c6c8b3fd7e854c1eff2194cfd4ebc9854b88',
       'source_host_to_registrable_domain_icann_and_including_private':
           {host: domain for domain, host in HOSTS.items()},
       'exact_observation_time_recorded': False, 'raw_list_retained': False}
COLLECTORS = {
    'tool/collect_legado_rdap_five.py': 'f275c6aff085f80275cd0793b1d0d25cd6b1d54ffb2d73cb585d40df06fe9c56',
    'tool/collect_legado_rdap_top_cc.py': '13e51248570b156e895c618e84cee73a408d051cc32136136612b7d85e5d61a4',
    'tool/audit_legado_doh_pilot.py': 'eecb9c14748ffde78c371009cf532b8a20d491f356c3364506d8eef707d57b68',
    'tool/audit_legado_catalog.py': '36f5359259ba259e84ae10875be6383884ad0cc71e829f029dd96b6dc9976563',
    'tool/verify_legado_rdap_com_eighteen.py': 'ff859c6a8e10c757a12fef5ac23263e10af0d28b0fa39032242b84bf1d4e95be',
    'tool/verify_legado_rdap_com_six.py': '8bd96099d80bcaa925e3b00edcaf0546f007c0405ce4c813cf341ff6581794d5',
}
VERIFIER_SUPPORT = {
    'tool/verify_legado_rdap_top_cc.py': '3f3fe1f3b64cab38f5f34719d478df2c02ff8d333bb02c6db4a8eeac2881d487',
}
METHOD = {
    'scope': 'Only IANA bootstrap, the fixed registry-domain RDAP services and A/AAAA DoH for registry domains and exact old endpoint hosts.',
    'network': 'Anonymous HTTPS; TLS verified and service destination vetted; no redirects, cookies, credentials or connections to any source site.',
    'bounds': 'One request at a time; at least 0.45 seconds between starts; RDAP deadline 8 seconds and maximum body 128 KiB; DoH deadline 6 seconds.',
    'controls': 'Each round uses an independent matching registered RDAP object and a fresh synthetic negative for each TLD; each resolver uses positive and per-TLD negative controls. Failed controls cause explicit skips.',
    'cache': 'Round two starts after at least 600 seconds and all observed first-round DNS TTLs, plus five seconds; missing negative TTLs are counted separately.',
    'redaction': 'Only classifications, status, timing, TTLs, generic address categories, domain names, sizes, Boolean RDAP identity checks and historical response digests are retained.',
}
LIMITATIONS = [
    'RDAP, DNS, IANA bootstrap and public-suffix response bodies were not retained; offline validation checks recorded consistency, not authenticity or omitted response contents.',
    'The public suffix list is an independent boundary aid, not a registry contract; the exact time of its preliminary observation was not captured.',
    'NXDOMAIN and RDAP 404 are observations at a time, not proof of permanent non-registration, ownership, site shutdown, maliciousness or safety.',
    'A matching registry object does not establish source availability; an absent old subdomain does not establish that its parent registration is absent.',
    'Both public resolvers use a common network path and may share upstream caches. Waiting past observed TTLs does not establish geographic independence or exclude unreported upstream caching.',
    'A timeout, a failed TLD-specific positive or negative control, and a skipped query remain unknown; none is counted as NXDOMAIN or 404.',
    'Selected IDs and rule digests refer only to the pinned bundled catalog, not user installations, external changes or historical orphan cache identity.',
    'A strict candidate requires two controlled RDAP 404s and both controlled resolvers to report NXDOMAIN for A and AAAA of both the registered domain and exact old host in each round.',
    'The separate cross-period review combines earlier two-resolver DNS observations with later controlled registry results and later Aliyun observations; skipped later Tencent queries are never counted.',
    'The Git ledger, source snapshots and historical registry evidence are required for offline verification; a shallow clone without the pinned object fails explicitly.',
]
require, sha, timestamp = common.require, common.sha, common.timestamp
canonical_sha = shared.canonical_sha


@lru_cache(maxsize=None)
def git_blob(path):
    try:
        proc = subprocess.run(['git', '-C', str(ROOT), 'show', COMMIT + ':' + path],
                              capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or the historical object is unavailable') from None
    require(proc.returncode == 0, 'historical object unavailable; shallow clones may omit it')
    return proc.stdout


def load_inputs(evidence):
    refs = evidence['input_references']
    require(set(refs) == set(FILES) | {'source_ledger_historical_git', 'previous_rdap_historical_git'},
            'input reference set mismatch')
    raw = {}
    for key, path in FILES.items():
        ref = refs[key]
        require(ref == {'path': path, 'sha256': ref.get('sha256')}, 'unexpected input path or fields')
        raw[key] = (ROOT / path).read_bytes()
        require(sha(raw[key]) == ref['sha256'] and sha(git_blob(path)) == ref['sha256'],
                'historical input digest mismatch: ' + key)
    ref = refs['source_ledger_historical_git']
    require(ref == {'commit': COMMIT, 'path': LEDGER, 'sha256': ref.get('sha256')} and
            sha(git_blob(LEDGER)) == ref['sha256'], 'historical ledger reference differs')
    ledger = json.loads(git_blob(LEDGER))
    archive = json.loads(bz2.decompress(raw['catalog_archive']))
    manifest = json.loads(raw['catalog_manifest'])
    require(manifest['archiveSha256'] == sha(raw['catalog_archive']) and
            manifest['records'] == len(archive['records']), 'catalog archive or manifest differs')
    for key in ('catalog_archive', 'catalog_manifest', 'older_host_recheck', 'prior_public_doh'):
        require(ledger['input_sha256'].get(FILES[key]) == sha(raw[key]), 'historical ledger input differs')
    source = evidence['source_code_snapshot']
    require(source == {'commit': COMMIT, 'digest_convention': 'sha256_crlf_to_lf',
                       'normalized_sha256': ledger['normalized_source_code_sha256']},
            'historical source-code snapshot differs')
    for path, expected in source['normalized_sha256'].items():
        require(sha(git_blob(path).replace(b'\r\n', b'\n')) == expected, 'historical source digest differs')
    previous = refs['previous_rdap_historical_git']
    require(set(previous) == set(PREVIOUS_RDAP), 'prior RDAP evidence set differs')
    prior_domains = set()
    for path in PREVIOUS_RDAP:
        entry = previous[path]
        require(entry == {'commit': COMMIT, 'sha256': sha(git_blob(path))}, 'prior RDAP digest differs')
        doc = json.loads(git_blob(path))
        prior_domains.update(r['registry_domain'] for r in doc.get('candidates', doc.get('results', []))
                             if 'registry_domain' in r)
    require(not set(HOSTS) & prior_domains, 'candidate overlaps previous registry evidence')
    return archive, ledger, {k: json.loads(raw[k]) for k in
                             ('later_host_recheck', 'older_host_recheck', 'prior_public_doh')}


def verify_candidates(evidence, archive, ledger, inputs):
    rows = evidence['candidates']
    require(len(rows) == len(HOSTS) and {r['registry_domain']: r['old_source_host'] for r in rows} == HOSTS,
            'candidate domain or endpoint host differs')
    byid = {row['source_id']: row for row in ledger['sources']}
    latest = {row['host']: row for row in inputs['later_host_recheck']['results']}
    older = {row['host']: row for row in inputs['older_host_recheck']['results']}
    prior = {row['host']: row for row in inputs['prior_public_doh']['results']}
    seen = set()
    for candidate in rows:
        require(set(candidate) == {'registry_domain', 'old_source_host', 'selected_sources',
                                   'latest_native_dns', 'previous_native_dns', 'previous_public_doh',
                                   'current_summary'},
                'unexpected candidate fields')
        host = candidate['old_source_host']
        record = latest[host]
        require(record['dns']['verdict'] == 'repeated_nxdomain' and candidate['latest_native_dns'] == record['dns'] and
                len(record['dns']['observations']) == 2 and
                all(not r['query_failed'] and 9003 in (r['a'], r['aaaa']) and r['a'] in (9003, 9501) and
                    r['aaaa'] in (9003, 9501) for r in record['dns']['observations']),
                'latest native DNS evidence differs')
        expected_prior = prior[host]['observations'] if host in prior else None
        require(candidate['previous_public_doh'] == expected_prior, 'prior public DNS evidence differs')
        old = older.get(host)
        expected_native = None if old is None else {'verdict': old.get('dns_verdict'),
                                                    'observations': old.get('dns_observations', [])}
        require(candidate['previous_native_dns'] == expected_native, 'prior native DNS evidence differs')
        ids = {s['source_id'] for s in candidate['selected_sources']}
        require(ids and len(ids) == len(candidate['selected_sources']) and
                ids == {s['source_id'] for s in record['selected_sources']} and
                ids == {s['source_id'] for s in ledger['sources'] if s['endpoint_host'] == host},
                'selected source association differs')
        for source in candidate['selected_sources']:
            require(source['source_id'] not in seen, 'duplicate selected source identity')
            seen.add(source['source_id'])
            verify_source_version(source, host, byid, archive)
        if host in prior:
            require(prior[host]['baseline'] == 'repeated_nxdomain' and
                    set(prior[host]['selected_source_ids']) == ids and
                    {s['selected_record_index'] for s in candidate['selected_sources']} <= set(prior[host]['record_indices']),
                    'prior public DNS source identity differs')
    require(len(seen) == 10, 'selected source count differs')


def verify_source_version(source, host, byid, archive):
    extra = {'format', 'normalized_endpoint'}
    require(extra <= set(source) and source['format'] == byid[source['source_id']]['format'] == 'html',
            'source format or endpoint missing')
    shared.shared.verify_source({k: v for k, v in source.items() if k not in extra}, host, byid, archive)
    original = archive['records'][source['selected_record_index']]['bookSourceUrl']
    parsed = urlsplit(original)
    safe = "!$&'()*+,;=:@/?-._~%"
    path, query = (quote(value, safe=safe) for value in (parsed.path, parsed.query))
    endpoint = 'https://' + host + path + ('?' + query if query else '')
    require(source['normalized_endpoint'] == endpoint and sha(endpoint.encode('utf-8')) == source['endpoint_sha256'],
            'normalized complete endpoint differs')


def derive_control_status(rows, negative):
    lookup = {shared.observation_key(row): row for row in rows}
    expected = {('rdap', name, None, None) for tld in SERVICES for name in ('google.' + tld, negative[tld])}
    expected |= {('doh', name, p, typ) for name in ('example.com', *negative.values())
                 for p in PROVIDERS for typ in QTYPES}
    require(len(rows) == len(lookup) and set(lookup) == expected, 'control query coverage differs')
    verdict = {}
    for tld in SERVICES:
        positive, absent = lookup['rdap', 'google.' + tld, None, None], lookup['rdap', negative[tld], None, None]
        verdict[tld] = {'rdap': positive['classification'] == 'matching_domain_object' and absent['http_status'] == 404 and
                        (absent['classification'] == 'http_404_empty_body' or
                         (absent['classification'] == 'http_404_json' and absent['rdap_error_code_is_404'] is True))}
        for provider in PROVIDERS:
            def good(host, typ):
                row = lookup['doh', host, provider, typ]
                if row.get('http_status') != 200 or row.get('dns_truncated'):
                    return False
                if host == negative[tld]:
                    return row['classification'] == 'nxdomain' and row['dns_rcode'] == 3
                return row.get('dns_rcode') == 0 and (typ != 'A' or row['address_categories'].get('public', 0) > 0)
            verdict[tld][provider] = all(good(h, typ) for h in ('example.com', negative[tld]) for typ in QTYPES)
    return verdict


def verify_rounds(evidence):
    rounds = evidence['rounds']
    require(len(rounds) == 2 and [r['round'] for r in rounds] == [1, 2], 'two ordered rounds required')
    outer_start, outer_end = timestamp(evidence['observed_start_utc']), timestamp(evidence['observed_end_utc'])
    full = {('rdap', domain, None, None) for domain in HOSTS}
    full |= {('doh', host, p, typ) for domain, old in HOSTS.items() for host in (domain, old)
             for p in PROVIDERS for typ in QTYPES}
    host_tld = {host: domain.rsplit('.', 1)[-1] for domain, old in HOSTS.items() for host in (domain, old)}
    prior_end = outer_start
    for row in rounds:
        require(set(row) == {'round', 'started_at', 'negative_controls', 'controls', 'control_status',
                             'observations', 'skipped', 'completed_at', 'classification_counts'},
                'unexpected round fields')
        start, end = timestamp(row['started_at']), timestamp(row['completed_at'])
        require(prior_end <= start <= end <= outer_end, 'round outside collection window')
        prior_end = end
        negative = row['negative_controls']
        require(set(negative) == set(SERVICES) and all(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.' + tld, domain)
                for tld, domain in negative.items()) and
                len({domain.rsplit('.', 1)[0] for domain in negative.values()}) == 1,
                'invalid synthetic negative controls')
        all_rows = row['controls'] + row['observations']
        for item in all_rows:
            common.validate_times(item, start, end)
        for before, after in zip(all_rows, all_rows[1:]):
            require((timestamp(after['started_at']) - timestamp(before['started_at'])).total_seconds() >= .43,
                    'request start interval too short')
        status = derive_control_status(row['controls'], negative)
        require(row['control_status'] == status, 'control status differs from observations')
        scheduled = {key for key in full if status[host_tld[key[1]]]['rdap' if key[0] == 'rdap' else key[2]]}
        observed = [shared.observation_key(item) for item in row['observations']]
        skipped = [shared.skipped_key(item) for item in row['skipped']]
        require(len(set(observed)) == len(observed) and len(set(skipped)) == len(skipped) and
                set(observed) == scheduled and set(skipped) == full - scheduled and
                not set(observed).intersection(skipped), 'candidate coverage or skipped controls differ')
        require(row['classification_counts'] == dict(Counter(item['classification'] for item in row['observations'])),
                'round classification totals differ')
    require(rounds[0]['negative_controls']['com'] != rounds[1]['negative_controls']['com'],
            'negative control must be fresh each round')
    require(evidence['cache_barrier'] == shared.barrier_for(rounds[0]), 'cache barrier differs from recorded TTLs')
    require(timestamp(rounds[1]['started_at']) >= timestamp(evidence['cache_barrier']['not_before_utc']),
            'second round started before cache barrier')
    return rounds


def strict_eligibility(candidate, rounds):
    domain, old = candidate['registry_domain'], candidate['old_source_host']
    for row in rounds:
        bykey = {shared.observation_key(item): item for item in row['observations']}
        rdap = bykey.get(('rdap', domain, None, None), {})
        if rdap.get('classification') not in ('http_404_empty_body', 'http_404_json'):
            return False
        for host in (domain, old):
            for provider in PROVIDERS:
                for typ in QTYPES:
                    if bykey.get(('doh', host, provider, typ), {}).get('classification') != 'nxdomain':
                        return False
    return True


def cross_period_zri_sources(evidence):
    candidate = next(c for c in evidence['candidates'] if c['registry_domain'] == 'zri.moe')
    old = candidate['previous_native_dns']
    public = candidate['previous_public_doh']
    controls = evidence['historical_public_doh_controls']
    expected = {(p, q) for p in PROVIDERS for q in QTYPES}
    if old is None or old['verdict'] != 'repeated_nxdomain' or len(old['observations']) != 2:
        return []
    if not all(9003 in (r['a'], r['aaaa']) and r['a'] in (9003, 9501) and r['aaaa'] in (9003, 9501)
               for r in old['observations']):
        return []
    if public is None or len(public) != 4 or {(r['provider'], r['query_type']) for r in public} != expected:
        return []
    if not all(r.get('classification') == 'nxdomain' and r.get('http_status') == 200 and
               r.get('dns_rcode') == 3 and r.get('dns_truncated') is False for r in public):
        return []
    if not all(r.get('negative_ttls_seconds') and all(type(ttl) is int and ttl >= 0
               for ttl in r['negative_ttls_seconds']) for r in public):
        return []
    if len(controls) != 4 or {(r['provider'], r['query_type']) for r in controls} != expected:
        return []
    if not all(r.get('host') == 'example.com' and r.get('http_status') == 200 and
               r.get('dns_rcode') == 0 and r.get('dns_truncated') is False and
               r.get('classification') == 'noerror_addresses' for r in controls):
        return []
    if max(timestamp(r['observed_at']) for r in controls) > min(timestamp(r['started_at']) for r in public):
        return []
    previous_end = max(timestamp(r['observed_at']) for r in public)
    max_old_ttl = max((ttl for r in public for ttl in r.get('negative_ttls_seconds', [])), default=0)
    first_start = timestamp(evidence['rounds'][0]['started_at'])
    if (first_start - previous_end).total_seconds() <= max(3600, max_old_ttl):
        return []
    for row in evidence['rounds']:
        if not row['control_status']['moe']['rdap'] or not row['control_status']['moe']['aliyun']:
            return []
        bykey = {shared.observation_key(item): item for item in row['observations']}
        if bykey.get(('rdap', 'zri.moe', None, None), {}).get('classification') not in (
                'http_404_empty_body', 'http_404_json'):
            return []
        for host in ('zri.moe', 'book.zri.moe'):
            for typ in QTYPES:
                if bykey.get(('doh', host, 'aliyun', typ), {}).get('classification') != 'nxdomain':
                    return []
    return sorted(source['source_id'] for source in candidate['selected_sources'])


def summarize(evidence):
    rounds = evidence['rounds']
    all_rows = [item for row in rounds for item in row['observations']]
    controls = [item for row in rounds for item in row['controls']]
    summaries = {c['registry_domain']: shared.candidate_summary(c, rounds) for c in evidence['candidates']}
    for candidate in evidence['candidates']:
        require(candidate['current_summary'] == summaries[candidate['registry_domain']], 'candidate summary differs')
    return {'candidate_domains': len(HOSTS),
            'selected_source_ids': sum(len(c['selected_sources']) for c in evidence['candidates']),
            'candidate_requests_attempted': len(all_rows),
            'candidate_requests_skipped_due_to_control': sum(len(r['skipped']) for r in rounds),
            'control_requests_attempted': len(controls),
            'rdap_observations': sum(r['mode'] == 'rdap' for r in all_rows),
            'doh_observations': sum(r['mode'] == 'doh' for r in all_rows),
            'candidate_doh_timeouts': sum(r['classification'] == 'provider_timeout' for r in all_rows),
            'control_doh_timeouts': sum(r['classification'] == 'provider_timeout' for r in controls),
            'domains_with_two_404': sum(len(s['rdap']) == 2 and all(
                r['classification'] in ('http_404_empty_body', 'http_404_json') for r in s['rdap'])
                for s in summaries.values()),
            'domains_with_two_matching_objects': sum(len(s['rdap']) == 2 and all(
                r['classification'] == 'matching_domain_object' for r in s['rdap']) for s in summaries.values()),
            'strictly_eligible_domains': sorted(c['registry_domain'] for c in evidence['candidates']
                                                if strict_eligibility(c, rounds)),
            'cross_period_zri_review_source_ids': cross_period_zri_sources(evidence)}


def verify(evidence):
    keys = {'schema_version', 'observed_start_utc', 'observed_end_utc', 'input_references', 'iana_bootstrap',
            'public_suffix_observation', 'source_code_snapshot', 'candidates', 'rounds', 'cache_barrier',
            'historical_public_doh_controls', 'method', 'limitations', 'collection_scripts',
            'verification_support', 'summary'}
    require(set(evidence) == keys and evidence['schema_version'] == 1, 'unexpected evidence fields or schema')
    common.reject_sensitive(evidence)
    shared.shared.reject_url_queries(evidence)
    require(evidence['method'] == METHOD and evidence['limitations'] == LIMITATIONS, 'method or limitations differ')
    bootstrap = evidence['iana_bootstrap']
    require(set(bootstrap) == {'url', 'publication', 'sha256', 'services', 'started_at', 'observed_at'} and
            bootstrap['url'] == 'https://data.iana.org/rdap/dns.json' and bootstrap['services'] == SERVICES and
            bootstrap['publication'] == '2026-10-28T22:00:04Z' and bootstrap['sha256'] == IANA_SHA256,
            'IANA bootstrap observation differs')
    require(timestamp(evidence['observed_start_utc']) <= timestamp(bootstrap['started_at']) <=
            timestamp(bootstrap['observed_at']) <= timestamp(evidence['rounds'][0]['started_at']),
            'IANA bootstrap outside collection window')
    require(evidence['public_suffix_observation'] == PSL, 'public suffix boundary observation differs')
    require(evidence['collection_scripts'] == {'digest_convention': 'sha256_crlf_to_lf', 'sha256': COLLECTORS},
            'collector script references differ')
    for path, expected in COLLECTORS.items():
        require(sha((ROOT / path).read_bytes().replace(b'\r\n', b'\n')) == expected,
                'collector script digest differs')
    require(evidence['verification_support'] == {'digest_convention': 'sha256_crlf_to_lf',
            'sha256': VERIFIER_SUPPORT}, 'verification support references differ')
    for path, expected in VERIFIER_SUPPORT.items():
        require(sha((ROOT / path).read_bytes().replace(b'\r\n', b'\n')) == expected,
                'verification support digest differs')
    archive, ledger, inputs = load_inputs(evidence)
    require(evidence['historical_public_doh_controls'] == inputs['prior_public_doh']['control_queries'],
            'historical public DNS controls differ')
    verify_candidates(evidence, archive, ledger, inputs)
    verify_rounds(evidence)
    computed = summarize(evidence)
    require(evidence['summary'] == computed, 'overall summary differs')
    require(canonical_sha(evidence['rounds']) == FROZEN_ROUNDS_SHA256, 'frozen observation digest differs')
    return computed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': verify(json.loads(raw)),
                      'historical_response_bodies_recomputed': False, 'historical_git_commit': COMMIT},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
