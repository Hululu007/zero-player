"""Validate the seven-domain RDAP/DoH evidence offline; make no network requests."""
import argparse
import bz2
from collections import Counter
from datetime import timedelta
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

if __package__:
    from . import verify_legado_rdap_com_eighteen as shared
else:
    import verify_legado_rdap_com_eighteen as shared

common = shared.common
ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-rdap-top-cc-20261116.json'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
COMMIT = 'a6c7d9986a64a2c7328c5f74c06415a116ef27a9'
FILES = {
    'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
    'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
    'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
    'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
}
HOSTS = {
    '99hanman.top': '99hanman.top', 'duduxiaoshuo.top': 'h5.duduxiaoshuo.top',
    'stxt.top': 'stxt.top', 'shenxianfaka.top': 'www.shenxianfaka.top',
    'wxc.cc': 'm.wxc.cc', 'znehuo.cc': 'm.znehuo.cc', 'shujige.cc': 'www.shujige.cc',
}
PROVIDERS, QTYPES = ('aliyun', 'tencent'), ('A', 'AAAA')
IANA = {'top': ['https://rdap.zdnsgtld.com/top/'],
        'cc': ['https://tld-rdap.verisign.com/cc/v1/']}
IANA_SHA256 = '2789f2f92f7ba785e0d3cd4cdcc70709e0ded1d331619e6784317c8bf2bc72b6'
COLLECTOR_SHA256 = '13e51248570b156e895c618e84cee73a408d051cc32136136612b7d85e5d61a4'
FROZEN_ROUNDS_SHA256 = '132827a0434813368c60c0510053d86fb8fbe16b49f2815d33d7367db033c7ca'
METHOD = {
    'scope': 'IANA bootstrap, registry-domain RDAP, and A/AAAA DoH for registry domains and exact old hosts only.',
    'network': 'Anonymous HTTPS, verified TLS, public service addresses, no redirects, cookies, credentials or source-site connections.',
    'bounds': 'One request at a time; start spacing at least 0.45 seconds; RDAP deadline 8 seconds and body at most 128 KiB; DoH deadline 6 seconds.',
    'controls': 'Each round has independently selected registered RDAP controls and fresh random negative controls; each resolver has positive and per-TLD negative controls. Failed controls cause explicit skips.',
    'cache': 'Round two starts after at least 600 seconds and every observed round-one DNS TTL, plus five seconds; missing negative TTLs are counted separately.',
    'redaction': 'Only classifications, status, times, TTLs, generic address categories, domain names, sizes, Boolean RDAP identity checks and historical response digests are retained.',
}
LIMITATIONS = [
    'RDAP, DNS, and IANA bootstrap response bodies were not retained; offline verification checks recorded consistency, not the authenticity or contents of the omitted historical responses.',
    'NXDOMAIN and RDAP 404 are observations at the stated time, not proof of permanent non-registration, ownership, site shutdown, maliciousness, or safety.',
    'A matching registry object does not imply the old source or its subdomain works; a missing old subdomain does not establish that the registered domain is missing.',
    'Both resolvers use a common network path and may share upstream caches. Waiting past reported TTLs does not prove geographic independence or prevent unreported upstream caching.',
    'A timeout, failed positive or negative control, and a skipped query remain unknown; none is counted as NXDOMAIN or 404.',
    'Source identities and rule digests refer to the selected bundled catalog snapshot, not user installations or the future state of any site.',
    'The referenced Git ledger and normalized import sources are required for offline validation; shallow clones without the historical object will fail explicitly.',
    'Source endpoints are reproduced only from the bundled archive; no source webpage was requested, no bundled source rule was executed, and no user database was accessed. Raw responses, registry personal information, DNS answers, and concrete network addresses were not output or retained.',
]
require, sha, timestamp = common.require, common.sha, common.timestamp


def canonical_sha(value):
    return sha(json.dumps(value, ensure_ascii=False, sort_keys=True,
                          separators=(',', ':')).encode('utf-8'))


@lru_cache(maxsize=None)
def git_blob(path):
    try:
        result = subprocess.run(['git', '-C', str(ROOT), 'show', COMMIT + ':' + path],
                                capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or the historical object is unavailable') from None
    require(result.returncode == 0, 'historical object unavailable; shallow clones may omit it')
    return result.stdout


def load_inputs(evidence):
    refs = evidence['input_references']
    require(set(refs) == set(FILES) | {'source_ledger_historical_git'}, 'input reference set mismatch')
    raw = {}
    for key, path in FILES.items():
        ref = refs[key]
        require(ref == {'path': path, 'sha256': ref.get('sha256')}, 'unexpected input path or fields')
        raw[key] = (ROOT / path).read_bytes()
        require(sha(raw[key]) == ref['sha256'], 'input digest mismatch: ' + key)
    ref = refs['source_ledger_historical_git']
    require(ref == {'commit': COMMIT, 'path': LEDGER, 'sha256': ref.get('sha256')},
            'historical ledger reference mismatch')
    ledger_raw = git_blob(LEDGER)
    require(sha(ledger_raw) == ref['sha256'], 'historical ledger digest mismatch')
    ledger = json.loads(ledger_raw)
    archive = json.loads(bz2.decompress(raw['catalog_archive']))
    manifest = json.loads(raw['catalog_manifest'])
    require(manifest['archiveSha256'] == sha(raw['catalog_archive']) and
            manifest['records'] == len(archive['records']), 'archive/manifest mismatch')
    for key, path in FILES.items():
        require(ledger['input_sha256'].get(path) == sha(raw[key]), 'historical input mismatch: ' + key)
    for path, expected in ledger['normalized_source_code_sha256'].items():
        normalized = git_blob(path).replace(b'\r\n', b'\n')
        require(sha(normalized) == expected, 'historical normalized import source differs: ' + path)
    return archive, ledger, {key: json.loads(raw[key]) for key in ('host_recheck', 'doh_reviewed')}


def verify_candidates(evidence, archive, ledger, inputs):
    candidates = evidence['candidates']
    require(len(candidates) == len(HOSTS) and
            {r['registry_domain']: r['old_source_host'] for r in candidates} == HOSTS,
            'candidate domain or host set differs')
    byid = {r['source_id']: r for r in ledger['sources']}
    native = {r['host']: r for r in inputs['host_recheck']['results']}
    previous = {r['host']: r for r in inputs['doh_reviewed']['results']}
    seen = set()
    for row in candidates:
        require(set(row) == {'registry_domain', 'old_source_host', 'selected_sources',
                             'previous_native_dns', 'previous_public_doh', 'current_summary'},
                'unexpected candidate fields')
        domain, host = row['registry_domain'], row['old_source_host']
        require('.'.join(host.split('.')[-2:]) == domain, 'registry and old host mismatch')
        prior, dns = native[host], previous[host]
        require(prior['dns_verdict'] == 'repeated_nxdomain' and
                row['previous_native_dns'] == prior['dns_observations'] and
                len(prior['dns_observations']) == 2 and
                all(9003 in (r['a'], r['aaaa']) and r['a'] in (9003, 9501) and
                    r['aaaa'] in (9003, 9501) for r in prior['dns_observations']),
                'historical native DNS mismatch')
        observations = dns['observations']
        require(dns['baseline'] == 'repeated_nxdomain' and row['previous_public_doh'] == observations and
                len(observations) == 4 and {(r['provider'], r['query_type']) for r in observations} ==
                {(p, typ) for p in PROVIDERS for typ in QTYPES}, 'historical public DNS mismatch')
        ids = {r['source_id'] for r in row['selected_sources']}
        require(len(ids) == len(row['selected_sources']) == 1 and ids == set(dns['selected_source_ids']) and
                ids == {r['source_id'] for r in ledger['sources'] if r['endpoint_host'] == host},
                'selected source association differs')
        for source in row['selected_sources']:
            verify_selected_source(source, host, byid, archive)
            require(source['source_id'] not in seen, 'duplicate selected source identity')
            seen.add(source['source_id'])
    require(len(seen) == 7, 'selected source count differs')


def verify_selected_source(source, host, byid, archive):
    extra = {'format', 'raw_book_source_url', 'normalized_endpoint'}
    require(extra <= set(source), 'missing selected source fields')
    shared.verify_source({k: v for k, v in source.items() if k not in extra}, host, byid, archive)
    selected = byid[source['source_id']]
    require(source['format'] == selected['format'] == 'html', 'selected source format differs')
    raw_url = archive['records'][source['selected_record_index']]['bookSourceUrl']
    parsed = urlsplit(raw_url)
    require(source['raw_book_source_url'] == raw_url and parsed.hostname == host and
            parsed.path in ('', '/') and not parsed.query and not parsed.fragment,
            'raw source endpoint differs')
    endpoint = 'https://' + host + parsed.path
    require(source['normalized_endpoint'] == endpoint and sha(endpoint.encode('utf-8')) == source['endpoint_sha256'],
            'normalized endpoint differs')


def verify_rdap(row):
    required = {'mode', 'domain', 'started_at', 'observed_at', 'http_status', 'classification'}
    response = {'content_type', 'content_encoding'}
    details = {'body_bytes', 'rdap_object_matches', 'rdap_conformance_present', 'rdap_error_code_is_404'}
    allowed = required | response | details | {'error_type'}
    require(required <= set(row) <= allowed and row['mode'] == 'rdap', 'invalid RDAP fields')
    classification, status = row['classification'], row['http_status']
    if classification in ('matching_domain_object', 'http_404_empty_body', 'http_404_json'):
        require(set(row) == required | response | details and row['content_encoding'] in ('', 'identity') and
                isinstance(row['body_bytes'], int) and not isinstance(row['body_bytes'], bool) and
                0 <= row['body_bytes'] <= 131072, 'invalid RDAP response metadata')
        if classification == 'matching_domain_object':
            require(status == 200 and row['body_bytes'] > 0 and row['rdap_object_matches'] is True and
                    row['rdap_conformance_present'] is True and row['rdap_error_code_is_404'] is None,
                    'invalid matching RDAP object')
        elif classification == 'http_404_empty_body':
            require(status == 404 and row['body_bytes'] == 0 and all(row[k] is None for k in
                    ('rdap_object_matches', 'rdap_conformance_present', 'rdap_error_code_is_404')),
                    'invalid empty RDAP 404')
        else:
            require(status == 404 and row['body_bytes'] > 0 and row['rdap_error_code_is_404'] is True and
                    row['rdap_object_matches'] is None and row['rdap_conformance_present'] is None,
                    'invalid RDAP 404 object')
    elif classification in ('timeout', 'connection_or_tls_error', 'invalid_response_or_request'):
        require(not details.intersection(row), 'failed RDAP query contains fabricated response')
    elif classification == 'redirect_not_followed':
        require(isinstance(status, int) and 300 <= status < 400 and not details.intersection(row),
                'invalid redirect classification')
    elif classification in ('http_error', 'unsupported_encoding', 'body_over_limit', 'non_json_response',
                            'non_object_response', 'unexpected_object'):
        pass
    else:
        raise ValueError('unknown RDAP classification')


def verify_dns(row):
    base = {'mode', 'host', 'provider', 'query_type', 'started_at', 'observed_at', 'classification'}
    response = {'http_status', 'dns_rcode', 'dns_truncated', 'dnssec_authenticated', 'address_categories',
                'address_ttls_seconds', 'negative_ttls_seconds'}
    require(base <= set(row) <= base | response and row['mode'] == 'doh' and
            row['provider'] in PROVIDERS and row['query_type'] in QTYPES, 'invalid DNS observation fields')
    classification = row['classification']
    if classification in ('provider_timeout', 'provider_connection_or_tls_error'):
        require(set(row) == base, 'failed DNS query contains fabricated response')
        return
    if classification == 'invalid_or_unexpected_response':
        require(set(row) in (base, base | {'http_status'}), 'failed DNS query contains fabricated response')
        return
    if classification in ('provider_http_error', 'provider_http_blocked'):
        require(set(row) == base | {'http_status'} and row['http_status'] != 200, 'invalid DNS HTTP error')
        return
    require(set(row) == base | response and row['http_status'] == 200, 'incomplete DNS response metadata')
    codes = {'nxdomain': 3, 'noerror_addresses': 0, 'noerror_no_address': 0, 'servfail': 2, 'refused': 5}
    if classification in codes:
        require(row['dns_rcode'] == codes[classification] and row['dns_truncated'] is False,
                'DNS classification and status disagree')
    elif classification == 'truncated':
        require(row['dns_truncated'] is True, 'invalid truncated DNS result')
    else:
        require(classification == 'other_dns_rcode' and row['dns_rcode'] not in codes.values(),
                'unknown DNS classification')
    require(isinstance(row['dnssec_authenticated'], bool), 'invalid DNSSEC flag')
    categories = row['address_categories']
    require(isinstance(categories, dict) and set(categories) <= common.ADDRESS_CLASSES and
            all(isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in categories.values()),
            'invalid DNS address categories')
    if classification in ('noerror_addresses', 'noerror_no_address', 'nxdomain'):
        require((classification == 'noerror_addresses') == bool(categories), 'DNS answer category mismatch')
    for field in ('address_ttls_seconds', 'negative_ttls_seconds'):
        require(isinstance(row[field], list) and all(isinstance(v, int) and not isinstance(v, bool) and v >= 0
                                                       for v in row[field]), 'invalid DNS TTL metadata')


def observation_key(row):
    if row.get('mode') == 'rdap':
        verify_rdap(row)
        return ('rdap', row['domain'], None, None)
    verify_dns(row)
    return ('doh', row['host'], row['provider'], row['query_type'])


def skipped_key(row):
    require(row.get('reason') == 'control_failed', 'invalid skipped-query reason')
    if row.get('mode') == 'rdap':
        require(set(row) == {'mode', 'domain', 'reason'}, 'invalid skipped RDAP fields')
        return ('rdap', row['domain'], None, None)
    require(row.get('mode') == 'doh' and set(row) == {'mode', 'host', 'provider', 'query_type', 'reason'},
            'invalid skipped DNS fields')
    return ('doh', row['host'], row['provider'], row['query_type'])


def derive_control_status(rows, negative):
    lookup = {observation_key(row): row for row in rows}
    names = ('example.com', negative['top'], negative['cc'])
    expected = {('rdap', name, None, None) for name in ('google.top', 'google.cc', *negative.values())}
    expected |= {('doh', name, p, typ) for name in names for p in PROVIDERS for typ in QTYPES}
    require(len(rows) == len(lookup) and set(lookup) == expected, 'control query coverage differs')
    status = {}
    for tld in ('top', 'cc'):
        pos, absent = lookup['rdap', 'google.' + tld, None, None], lookup['rdap', negative[tld], None, None]
        status[tld] = {'rdap': pos['classification'] == 'matching_domain_object' and absent['http_status'] == 404 and
                       (absent['classification'] == 'http_404_empty_body' or
                        (absent['classification'] == 'http_404_json' and absent['rdap_error_code_is_404'] is True))}
        for provider in PROVIDERS:
            def valid(host, typ):
                row = lookup['doh', host, provider, typ]
                if row.get('http_status') != 200 or row.get('dns_truncated'):
                    return False
                if host == negative[tld]:
                    return row['classification'] == 'nxdomain' and row['dns_rcode'] == 3
                return row.get('dns_rcode') == 0 and (typ != 'A' or row['address_categories'].get('public', 0) > 0)
            status[tld][provider] = all(valid(host, typ) for host in ('example.com', negative[tld]) for typ in QTYPES)
    return status


def barrier_for(round1):
    ttls, unknown = [], 0
    for row in round1['controls'] + round1['observations']:
        if row['mode'] != 'doh' or row.get('http_status') != 200:
            continue
        ttls.extend(row.get('address_ttls_seconds', []) + row.get('negative_ttls_seconds', []))
        if row['classification'] in ('nxdomain', 'noerror_no_address') and not row.get('negative_ttls_seconds'):
            unknown += 1
    maximum = max(ttls, default=0)
    wait = max(600, maximum) + 5
    not_before = (timestamp(round1['completed_at']) + timedelta(seconds=wait)).isoformat()
    return {'observed_max_ttl_seconds': maximum, 'minimum_wait_seconds': wait,
            'negative_cache_ttl_unknown_observations': unknown, 'not_before_utc': not_before}


def verify_rounds(evidence):
    rounds = evidence['rounds']
    require(len(rounds) == 2 and [r['round'] for r in rounds] == [1, 2], 'two ordered rounds required')
    overall_start, overall_end = timestamp(evidence['observed_start_utc']), timestamp(evidence['observed_end_utc'])
    full = {('rdap', domain, None, None) for domain in HOSTS}
    full |= {('doh', host, provider, typ) for domain, old in HOSTS.items() for host in {domain, old}
             for provider in PROVIDERS for typ in QTYPES}
    host_tld = {host: domain.rsplit('.', 1)[-1] for domain, old in HOSTS.items() for host in (domain, old)}
    prior_end = overall_start
    for row in rounds:
        require(set(row) == {'round', 'started_at', 'negative_controls', 'controls', 'control_status',
                             'observations', 'skipped', 'completed_at', 'classification_counts'},
                'unexpected round fields')
        start, end = timestamp(row['started_at']), timestamp(row['completed_at'])
        require(prior_end <= start <= end <= overall_end, 'round outside collection window')
        prior_end = end
        negative = row['negative_controls']
        require(set(negative) == {'top', 'cc'} and all(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.' + tld, domain)
                for tld, domain in negative.items()) and
                negative['top'].removesuffix('.top') == negative['cc'].removesuffix('.cc'),
                'invalid negative controls')
        all_rows = row['controls'] + row['observations']
        for item in all_rows:
            common.validate_times(item, start, end)
        for before, after in zip(all_rows, all_rows[1:]):
            require((timestamp(after['started_at']) - timestamp(before['started_at'])).total_seconds() >= .43,
                    'request start interval too short')
        status = derive_control_status(row['controls'], negative)
        require(row['control_status'] == status, 'control status differs from observations')
        scheduled = {key for key in full if status[host_tld[key[1]]]['rdap' if key[0] == 'rdap' else key[2]]}
        observed = [observation_key(item) for item in row['observations']]
        skipped = [skipped_key(item) for item in row['skipped']]
        require(len(set(observed)) == len(observed) and len(set(skipped)) == len(skipped) and
                set(observed) == scheduled and set(skipped) == full - scheduled and
                not set(observed).intersection(skipped), 'candidate coverage or skipped controls differ')
        require(row['classification_counts'] == dict(Counter(item['classification'] for item in row['observations'])),
                'round classification totals differ')
    require(rounds[0]['negative_controls']['top'] != rounds[1]['negative_controls']['top'],
            'negative control must be fresh each round')
    require(evidence['cache_barrier'] == barrier_for(rounds[0]), 'cache barrier differs from recorded TTLs')
    require(timestamp(rounds[1]['started_at']) >= timestamp(evidence['cache_barrier']['not_before_utc']),
            'second round started before cache barrier')
    return rounds


def candidate_summary(candidate, rounds):
    domain, old = candidate['registry_domain'], candidate['old_source_host']
    rdap = [{'round': r['round'], 'http_status': item['http_status'], 'classification': item['classification'],
             'observed_at': item['observed_at']} for r in rounds for item in r['observations']
            if item.get('mode') == 'rdap' and item['domain'] == domain]
    def role(host):
        observations = [item for r in rounds for item in r['observations']
                        if item.get('mode') == 'doh' and item['host'] == host]
        skipped = sum(item.get('mode') == 'doh' and item['host'] == host for r in rounds for item in r['skipped'])
        return {'host': host, 'classification_counts': dict(Counter(item['classification'] for item in observations)),
                'skipped_due_to_control': skipped}
    rdap_skipped = sum(item.get('mode') == 'rdap' and item.get('domain') == domain
                       for r in rounds for item in r['skipped'])
    return {'rdap': rdap, 'rdap_skipped_due_to_control': rdap_skipped,
            'registry_domain_dns': role(domain), 'old_endpoint_host_dns': role(old),
            'roles_share_host': domain == old}


def summarize(evidence):
    rounds = evidence['rounds']
    all_rows = [item for r in rounds for item in r['observations']]
    controls = [item for r in rounds for item in r['controls']]
    summaries = {c['registry_domain']: candidate_summary(c, rounds) for c in evidence['candidates']}
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
            'domains_with_two_404': sum(len(s['rdap']) == 2 and
                all(r['classification'] in ('http_404_empty_body', 'http_404_json') for r in s['rdap'])
                for s in summaries.values()),
            'domains_with_two_matching_objects': sum(len(s['rdap']) == 2 and
                all(r['classification'] == 'matching_domain_object' for r in s['rdap'])
                for s in summaries.values())}


def verify(evidence):
    keys = {'schema_version', 'observed_start_utc', 'observed_end_utc', 'input_references', 'iana_bootstrap',
            'candidates', 'rounds', 'cache_barrier', 'method', 'limitations', 'collection_script', 'summary'}
    require(set(evidence) == keys and evidence['schema_version'] == 1, 'unexpected evidence fields or schema')
    common.reject_sensitive(evidence)
    shared.reject_url_queries(evidence)
    require(evidence['method'] == METHOD and evidence['limitations'] == LIMITATIONS,
            'method or limitations differ')
    bootstrap = evidence['iana_bootstrap']
    require(set(bootstrap) == {'url', 'publication', 'sha256', 'services', 'started_at', 'observed_at'} and
            bootstrap['url'] == 'https://data.iana.org/rdap/dns.json' and bootstrap['services'] == IANA and
            bootstrap['publication'] == '2026-10-28T22:00:04Z' and bootstrap['sha256'] == IANA_SHA256,
            'IANA bootstrap observation differs')
    require(timestamp(evidence['observed_start_utc']) <= timestamp(bootstrap['started_at']) <=
            timestamp(bootstrap['observed_at']) <= timestamp(evidence['rounds'][0]['started_at']),
            'IANA bootstrap outside collection window')
    artifact = evidence['collection_script']
    require(set(artifact) == {'path', 'sha256', 'digest_convention'} and
            artifact['path'] == 'tool/collect_legado_rdap_top_cc.py' and
            artifact['digest_convention'] == 'sha256_crlf_to_lf' and
            artifact['sha256'] == COLLECTOR_SHA256 and
            sha((ROOT / artifact['path']).read_bytes().replace(b'\r\n', b'\n')) == artifact['sha256'],
            'collection script digest differs')
    archive, ledger, inputs = load_inputs(evidence)
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
    summary = verify(json.loads(raw))
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': summary,
                      'historical_response_bodies_recomputed': False,
                      'historical_ledger_git_commit': COMMIT}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
