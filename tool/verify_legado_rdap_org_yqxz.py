"""Verify the redacted yqxz.org RDAP/DNS evidence without network access."""
import bz2
from collections import Counter
from datetime import datetime, timedelta
from functools import lru_cache
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = 'docs/implementation/legado-rdap-org-yqxz-20261116.json'
EVIDENCE_SHA = '7202ec6faabf7e612b15b8782608bcbb0b4ba6e95cdbdbde22c78ce6f0902f82'
CANONICAL_SHA = '435dd6e5e0024cef78e12f85e1b98c3055560e080532c5f39efc668b8ded8a81'
COMMIT = '56955b3d441678f4734d4c8cb4bf377a373212c4'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA = 'cfd87a165b3fb175d603385eb7a64192f9ae11e5c0441ff35d94323594b7265e'
DOMAIN, HOST, INDEX = 'yqxz.org', 'www.yqxz.org', 1483
SOURCE_ID = 'adf7fb3063ed743cadafd19afc8a980d610adf508bef68d4ed71068cb412068a'
RULE_SHA = '70d5b4969261b02fd5815790184a68abe79b9e6d3ee35310b64920319b5438e0'
ENDPOINT_SHA = '9ad83839efa13f583ab2c8c7268eb620ff8bfc85388c4bd6ff5b5cda721b3187'
RAW_SHA = 'c6308180cb8fa47e3cd0f0290ee507d3ea974e7c78ca4c4e171dfe002abdaf0d'
IANA_SHA = '2789f2f92f7ba785e0d3cd4cdcc70709e0ded1d331619e6784317c8bf2bc72b6'
INPUTS = {
    'archive': ('assets/catalogs/books/legado/catalog.json.bz2', '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'),
    'manifest': ('assets/catalogs/books/legado/manifest.json', '59bb9e3551b5a01406c1d720d2b5d5d5f21518eccbb52cd93f8d752c19f7cf66'),
    'native_recheck': ('docs/implementation/legado-host-recheck-20261115.json', 'fcb543ff2a41e7e4960d2a0112af9c311d8e55148b8716d8854c09360b1080af'),
    'public_doh': ('docs/implementation/legado-doh-reviewed-20261115.json', '4729489824e1f653d5e18872789a75e9f0ebe919286add025e738606f4243059'),
    'later_head': ('docs/implementation/legado-unresolved-head-later-20261116.json', '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd'),
    'later_943_head': ('docs/implementation/legado-unresolved-943-recheck-20261116.json', '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0'),
}
DEPENDENCIES = {
    'tool/collect_legado_rdap_top_cc.py': '13e51248570b156e895c618e84cee73a408d051cc32136136612b7d85e5d61a4',
    'tool/audit_legado_catalog.py': '36f5359259ba259e84ae10875be6383884ad0cc71e829f029dd96b6dc9976563',
    'tool/audit_legado_doh_pilot.py': 'eecb9c14748ffde78c371009cf532b8a20d491f356c3364506d8eef707d57b68',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def timestamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.utcoffset() is not None, 'timestamp lacks offset')
    return result


@lru_cache(maxsize=None)
def git_blob(path):
    try:
        result = subprocess.run(['git', '-C', str(ROOT), 'show', f'{COMMIT}:{path}'],
                                capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or historical object unavailable') from None
    require(result.returncode == 0, 'historical object unavailable; shallow clone may omit it')
    return result.stdout


def load_inputs(evidence):
    refs = evidence['inputs']
    require(set(refs) == set(INPUTS) | {'historical_ledger'}, 'input reference set mismatch')
    require(refs['historical_ledger'] == {'git_commit': COMMIT, 'path': LEDGER, 'sha256': LEDGER_SHA} and
            sha(git_blob(LEDGER)) == LEDGER_SHA, 'historical ledger mismatch')
    ledger = json.loads(git_blob(LEDGER))
    result = {}
    for key, (path, expected) in INPUTS.items():
        require(refs[key] == {'path': path, 'sha256': expected}, 'input reference mismatch: ' + key)
        raw = (ROOT / path).read_bytes()
        require(sha(raw) == expected and sha(git_blob(path)) == expected and
                ledger['input_sha256'].get(path) == expected, 'input digest mismatch: ' + key)
        result[key] = json.loads(bz2.decompress(raw) if key == 'archive' else raw)
    archive, manifest = result['archive'], result['manifest']
    require(manifest['archiveSha256'] == INPUTS['archive'][1] and
            len(archive['records']) == manifest['records'], 'archive manifest mismatch')
    return ledger, result


def verify_source(evidence, ledger, inputs):
    candidate = evidence['candidate']
    source = candidate['selected_source']
    records = [row for row in ledger['sources'] if row['source_id'] == SOURCE_ID]
    require(len(records) == 1, 'historical source is not unique')
    old = records[0]
    raw = inputs['archive']['records'][INDEX]
    require(candidate['registry_domain'] == DOMAIN and candidate['old_source_host'] == HOST and
            source['source_id'] == SOURCE_ID and source['selected_record_index'] == INDEX and
            source['name'] == old['name'] and source['kind'] == old['kind'] == 'text' and
            old['selected_record_index'] == INDEX and old['endpoint_host'] == HOST and
            source['endpoint_sha256'] == old['endpoint_sha256'] == ENDPOINT_SHA and
            source['normalized_legado_sha256'] == old['normalized_legado_canonical_sha256'] == RULE_SHA and
            source['selected_raw_record_canonical_sha256'] == old['selected_raw_record_canonical_sha256'] ==
            sha(canonical(raw)) == RAW_SHA and
            any(INDEX in refs for refs in inputs['archive']['packs'].values()),
            'historical selected source or rule mismatch')
    require(raw['bookSourceUrl'] == 'https://www.yqxz.org/' and
            candidate['old_search_method'] == 'POST not attempted' and
            candidate['discovery'] == 'relative paths, not requested', 'old endpoint or method mismatch')
    search, options = raw['searchUrl'].split(',', 1)
    require(search.startswith('/') and json.loads(options)['method'] == 'POST', 'old search method mismatch')
    native = next(row for row in inputs['native_recheck']['results'] if row['host'] == HOST)
    public = next(row for row in inputs['public_doh']['results'] if row['host'] == HOST)
    require(native['dns_verdict'] == 'repeated_nxdomain' and SOURCE_ID in native['selected_source_ids'] and
            candidate['historical_native_dns'] == native['dns_observations'] and
            candidate['historical_public_doh'] == public['observations'] and
            [row['classification'] for row in public['observations']] ==
            ['nxdomain', 'nxdomain', 'nxdomain', 'provider_timeout'],
            'historical DNS observations mismatch')
    for name in ('later_head', 'later_943_head'):
        row = next(item for item in inputs[name]['results'] if item['host'] == HOST)
        observed = next(item for item in candidate['later_network'] if item['file'] == INPUTS[name][0])
        require(observed['latest_head'] == row['latest_head'] and observed['dns'] == row['dns'] and
                observed['dns']['verdict'] == 'unconfirmed', 'later unknown DNS observation mismatch')


def check_dns(row):
    status, code, truncated = row.get('http_status'), row.get('dns_rcode'), row.get('dns_truncated')
    classification = row['classification']
    if classification == 'nxdomain':
        require(status == 200 and code == 3 and truncated is False, 'NXDOMAIN fields conflict')
    elif classification == 'noerror_no_address':
        require(status == 200 and code == 0 and truncated is False and not row.get('address_categories'),
                'NOERROR no-address fields conflict')
    elif classification == 'noerror_addresses':
        require(status == 200 and code == 0 and truncated is False and bool(row.get('address_categories')),
                'NOERROR address fields conflict')
    elif classification == 'provider_timeout':
        require(status is None and code is None, 'timeout was given a DNS result')


def verify_controls(round_data):
    rows, status, negative = round_data['controls'], round_data['control_status'], round_data['negative_control']
    require(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.org', negative) is not None and len(rows) == 10,
            'control domain or count mismatch')
    def get(mode, host, provider=None, query=None):
        matches = [r for r in rows if r['mode'] == mode and (r.get('domain') or r.get('host')) == host and
                   r.get('provider') == provider and r.get('query_type') == query]
        require(len(matches) == 1, 'control missing or duplicated')
        return matches[0]
    positive, absent = get('rdap', 'google.org'), get('rdap', negative)
    rdap_ok = positive['classification'] == 'matching_domain_object' and positive['http_status'] == 200 and \
        positive.get('rdap_object_matches') is True and positive.get('rdap_conformance_present') is True and \
        absent['http_status'] == 404 and (absent['classification'] == 'http_404_empty_body' or
        (absent['classification'] == 'http_404_json' and absent['rdap_error_code_is_404'] is True))
    require(status['rdap'] == rdap_ok, 'RDAP control status mismatch')
    for provider in ('aliyun', 'tencent'):
        def good(host, qtype):
            row = get('doh', host, provider, qtype)
            check_dns(row)
            if row.get('http_status') != 200 or row.get('dns_truncated'):
                return False
            if host == negative:
                return row.get('dns_rcode') == 3 and row['classification'] == 'nxdomain'
            return row.get('dns_rcode') == 0 and (qtype != 'A' or row.get('address_categories', {}).get('public', 0) > 0)
        require(status[provider] == all(good(h, q) for h in ('example.com', negative) for q in ('A', 'AAAA')),
                'DoH control status mismatch')
    require(all(status.values()), 'recorded controls are not all valid')


def verify_round(round_data):
    verify_controls(round_data)
    expected = {('rdap', DOMAIN, None, None)} | {
        ('doh', host, provider, qtype) for host in (DOMAIN, HOST)
        for provider in ('aliyun', 'tencent') for qtype in ('A', 'AAAA')
    }
    seen = set()
    for row in round_data['observations']:
        key = (row['mode'], row.get('domain') or row.get('host'), row.get('provider'), row.get('query_type'))
        require(key in expected and key not in seen, 'candidate query unexpected or duplicated')
        seen.add(key)
        if row['mode'] == 'doh':
            check_dns(row)
        else:
            require(row['http_status'] == 200 and row['classification'] == 'matching_domain_object' and
                    row.get('rdap_object_matches') is True and row.get('rdap_conformance_present') is True,
                    'RDAP matching object mismatch')
    require(seen == expected and not round_data['skipped'], 'candidate query coverage mismatch')
    ordered = round_data['controls'] + round_data['observations']
    started, completed = timestamp(round_data['started_at_utc']), timestamp(round_data['completed_at_utc'])
    for i, row in enumerate(ordered):
        begin, end = timestamp(row['started_at']), timestamp(row['observed_at'])
        require(started <= begin <= end <= completed, 'request time outside round')
        if i:
            require(begin >= timestamp(ordered[i-1]['observed_at']) and
                    (begin - timestamp(ordered[i-1]['started_at'])).total_seconds() >= .449,
                    'requests overlapped or pacing changed')
    return Counter((r.get('host'), r['classification']) for r in round_data['observations'] if r['mode'] == 'doh')


def verify_timing(evidence):
    rounds = evidence['rounds']
    require(len(rounds) == 2 and [r['round'] for r in rounds] == [1, 2] and
            rounds[0]['negative_control'] != rounds[1]['negative_control'], 'round identity mismatch')
    barrier = evidence['cache_barrier']
    values, unknown = [], 0
    for row in rounds[0]['controls'] + rounds[0]['observations']:
        if row['mode'] != 'doh' or row.get('http_status') != 200:
            continue
        values.extend(row.get('address_ttls_seconds', []) + row.get('negative_ttls_seconds', []))
        if row['classification'] in ('nxdomain', 'noerror_no_address') and not row.get('negative_ttls_seconds'):
            unknown += 1
    observed = max(values, default=0)
    wait = max(600, observed) + 5
    start = timestamp(rounds[0]['completed_at_utc'])
    require(barrier['observed_max_ttl_seconds'] == observed == 600 and
            barrier['negative_cache_ttl_unknown_observations'] == unknown == 0 and
            barrier['minimum_wait_seconds'] == wait == 605 and
            timestamp(barrier['not_before_utc']) == start + timedelta(seconds=wait) and
            timestamp(rounds[1]['started_at_utc']) >= timestamp(barrier['not_before_utc']) and
            timestamp(evidence['started_at_utc']) <= timestamp(rounds[0]['started_at_utc']) and
            timestamp(rounds[1]['completed_at_utc']) <= timestamp(evidence['ended_at_utc']),
            'TTL barrier or round time mismatch')


def verify_privacy(evidence):
    forbidden = {'address', 'addresses', 'ip', 'cname', 'registrant', 'query',
                 'body', 'authorization', 'cookie', 'token', 'raw', 'response_body'}
    def walk(value):
        if isinstance(value, dict):
            require(not forbidden.intersection(k.lower() for k in value), 'raw private or network field retained')
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
        elif isinstance(value, str):
            try:
                ipaddress.ip_address(value.strip('[]'))
            except ValueError:
                return
            raise ValueError('IP address retained')
    walk(evidence)
    text = canonical(evidence).decode('utf-8')
    require('?' not in text and '<script' not in text.lower(), 'query or page content retained')
    for value in re.findall(r'(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])', text):
        try:
            ipaddress.ip_address(value)
        except ValueError:
            continue
        raise ValueError('IP address retained')


def verify(evidence, *, pinned=True):
    if pinned:
        require(sha(canonical(evidence)) == CANONICAL_SHA, 'formal evidence digest mismatch')
    require(evidence['status'] == 'formal_redacted_historical_registry_and_dns_observations', 'evidence status mismatch')
    ledger, inputs = load_inputs(evidence)
    verify_source(evidence, ledger, inputs)
    boot = evidence['iana_bootstrap']
    require(boot['url'] == 'https://data.iana.org/rdap/dns.json' and boot['sha256'] == IANA_SHA and
            boot['publication'] == '2026-10-28T22:00:04Z' and
            boot['services'] == {'org': ['https://rdap.publicinterestregistry.org/rdap/']} and
            timestamp(evidence['started_at_utc']) <= timestamp(boot['started_at']) <=
            timestamp(boot['observed_at']) <= timestamp(evidence['rounds'][0]['started_at_utc']),
            'IANA observed bootstrap mapping mismatch')
    method = evidence['method']
    require(method['concurrency'] == 1 and method['request_spacing_seconds'] == .45 and
            method['service_dns_public_validation_and_ip_pinning'] is True and
            method['tls_certificate_verification'] is True and
            method['rdap_deadline_seconds'] == 8 and method['rdap_body_limit_bytes'] == 131072 and
            method['doh_deadline_seconds'] == 6 and method['doh_body_limit_bytes'] == 65536 and
            method['candidate_requests_skipped_if_control_failed'] is True and
            all(method[key] is False for key in ('redirects_followed', 'source_host_http_requested',
                                                 'source_rules_executed', 'credentials_sent')),
            'network method mismatch')
    artifacts = evidence['collection_artifacts']
    require(artifacts['tracked_probe_dependencies_git_commit'] == COMMIT and
            artifacts['tracked_probe_dependencies_sha256'] == DEPENDENCIES and
            artifacts['dependency_snapshot_complete'] is False and
            artifacts['collection_script_retained_in_repository'] is False and
            artifacts['raw_network_responses_retained'] is False, 'collection limitations mismatch')
    for path, expected in DEPENDENCIES.items():
        require(sha(git_blob(path)) == expected, 'historical probe dependency mismatch')
    verify_timing(evidence)
    counts = Counter()
    for row in evidence['rounds']:
        counts.update(verify_round(row))
    require(counts == {(DOMAIN, 'noerror_no_address'): 8, (HOST, 'nxdomain'): 7,
                       (HOST, 'provider_timeout'): 1}, 'DNS outcomes mismatch')
    require(evidence['summary'] == {
        'candidate_domains': 1, 'historical_selected_source_ids': 1,
        'rdap_matching_domain_objects': 2, 'rdap_404': 0,
        'apex_noerror_no_address': 8, 'old_subdomain_nxdomain': 7,
        'old_subdomain_timeout': 1, 'candidate_queries': 18,
        'control_queries': 20, 'source_http_requests': 0,
        'registry_or_dns_result_is_site_safety_verdict': False,
        'whole_source_permanently_unavailable_verified': None,
    }, 'summary mismatch')
    verify_privacy(evidence)
    return {'sources': 1, 'rdap_matching_objects': 2, 'old_host_nxdomain': 7,
            'old_host_timeout': 1, 'network_requests': 0,
            'raw_responses_reconstructed': False, 'site_safety_verified': False}


def main():
    raw = (ROOT / EVIDENCE).read_bytes()
    require(sha(raw) == EVIDENCE_SHA, 'formal evidence byte digest mismatch')
    print(json.dumps({'sha256': sha(raw), 'verified_summary': verify(json.loads(raw))}, ensure_ascii=False))


if __name__ == '__main__':
    main()
