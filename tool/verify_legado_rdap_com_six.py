"""Verify the six-domain RDAP/DNS evidence offline; never contact the network."""
import argparse
import bz2
from collections import Counter
from datetime import datetime
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = 'docs/implementation/legado-rdap-com-six-20261116.json'
COMMIT = '9e875ff22e4dcef7727538765d4007892ca33c89'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
FILES = {
    'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
    'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
    'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
    'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
    'previous_rdap': 'docs/implementation/legado-rdap-sample-20261115.json',
}
HOSTS = {'biqugedd.com': 'm.biqugedd.com', 'ecc6.com': 'm.ecc6.com',
         'nvdushu.com': 'm.nvdushu.com', 'qiremanhua.com': 'm.qiremanhua.com',
         'x5200.com': 'm.x5200.com', 'aslwx.com': 'www.aslwx.com'}
PROVIDERS = ('aliyun', 'tencent')
QTYPES = ('A', 'AAAA')
DNS_KEYS = {'host', 'baseline', 'provider', 'query_type', 'started_at', 'observed_at',
            'http_status', 'dns_rcode', 'dns_truncated', 'dnssec_authenticated',
            'address_categories', 'address_ttls_seconds', 'negative_ttls_seconds',
            'classification', 'response_sha256'}
RDAP_KEYS = {'service', 'domain', 'started_at', 'observed_at', 'http_status',
             'classification', 'content_type', 'content_encoding', 'body_bytes',
             'rdap_object_matches', 'rdap_conformance_present', 'error_code'}
ADDRESS_CLASSES = {'public', 'unspecified', 'loopback', 'link_local', 'multicast',
                   'private_or_special', 'reserved_or_other_non_public'}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def timestamp(value):
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00'))
    except (AttributeError, ValueError):
        raise ValueError('invalid observation timestamp') from None


def load_inputs(evidence):
    refs = evidence['input_references']
    require(set(refs) == set(FILES) | {'source_ledger_historical_git'}, 'input reference set mismatch')
    files = {}
    for key, path in FILES.items():
        ref = refs[key]
        require(ref == {'path': path, 'sha256': ref.get('sha256')}, 'unexpected input path or fields')
        data = (ROOT / path).read_bytes()
        require(sha(data) == ref['sha256'], 'input digest mismatch: ' + key)
        files[key] = data
    ref = refs['source_ledger_historical_git']
    require(ref.get('commit') == COMMIT and ref.get('path') == LEDGER and set(ref) == {'commit', 'path', 'sha256'},
            'historical ledger reference mismatch')
    try:
        proc = subprocess.run(['git', '-C', str(ROOT), 'show', COMMIT + ':' + LEDGER],
                              capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or the historical ledger object is unavailable') from None
    require(proc.returncode == 0, 'historical ledger object unavailable; shallow clones may omit it')
    require(sha(proc.stdout) == ref['sha256'], 'historical ledger digest mismatch')
    ledger = json.loads(proc.stdout)
    manifest = json.loads(files['catalog_manifest'])
    archive = json.loads(bz2.decompress(files['catalog_archive']))
    require(manifest['archiveSha256'] == sha(files['catalog_archive']), 'archive/manifest mismatch')
    require(len(archive['records']) == manifest['records'], 'archive record count mismatch')
    for key in FILES:
        path = FILES[key]
        if key in ('catalog_archive', 'catalog_manifest', 'host_recheck', 'doh_reviewed'):
            require(ledger['input_sha256'].get(path) == sha(files[key]), 'historical ledger input mismatch')
    return archive, ledger, json.loads(files['host_recheck']), json.loads(files['doh_reviewed']), json.loads(files['previous_rdap'])


def reject_sensitive(value):
    forbidden = {'body', 'response_body', 'raw_dns', 'registrant', 'registrar', 'entities',
                 'vcardarray', 'nameservers', 'ip', 'ip_address', 'cname'}
    if isinstance(value, dict):
        for key, item in value.items():
            require(key.lower() not in forbidden, 'unexpected sensitive response field')
            reject_sensitive(item)
    elif isinstance(value, list):
        for item in value:
            reject_sensitive(item)
    elif isinstance(value, str):
        candidates = [value, *re.findall(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])', value),
                      *re.findall(r'(?<![\w:])(?:[a-fA-F0-9]{0,4}:){2,}[a-fA-F0-9:.]+', value)]
        for candidate in candidates:
            try:
                ipaddress.ip_address(candidate)
            except ValueError:
                continue
            raise ValueError('literal IP address found in evidence')


def verify_source(source, candidate, ledger_sources, archive):
    expected_keys = {'source_id', 'name', 'kind', 'selected_record_index', 'normalized_legado_sha256',
                     'endpoint_sha256', 'selected_raw_record_canonical_sha256', 'raw_book_source_url'}
    require(set(source) == expected_keys, 'unexpected source fields')
    historic = ledger_sources.get(source['source_id'])
    require(historic is not None, 'source not selected by historical ledger')
    require(historic['endpoint_host'] == candidate['old_source_host'] and
            historic['selected_record_index'] == source['selected_record_index'] and
            historic['name'] == source['name'] and historic['kind'] == source['kind'] and
            historic['normalized_legado_canonical_sha256'] == source['normalized_legado_sha256'] and
            historic['endpoint_sha256'] == source['endpoint_sha256'] and
            historic['selected_raw_record_canonical_sha256'] == source['selected_raw_record_canonical_sha256'],
            'source does not match historical selected version')
    index = source['selected_record_index']
    require(isinstance(index, int) and 0 <= index < len(archive['records']), 'invalid selected record index')
    require(any(index in refs for refs in archive['packs'].values()), 'selected record is not referenced by a pack')
    raw = archive['records'][index]
    raw_digest = sha(json.dumps(raw, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8'))
    require(raw_digest == source['selected_raw_record_canonical_sha256'], 'archive record digest mismatch')
    url = raw.get('bookSourceUrl')
    require(url == source['raw_book_source_url'], 'raw endpoint mismatch')
    parsed = urlsplit(url)
    require(parsed.scheme in ('http', 'https') and parsed.hostname == candidate['old_source_host'] and
            parsed.username is None and parsed.password is None and parsed.port is None and
            parsed.path in ('', '/') and not parsed.query, 'unexpected source endpoint shape')
    kind = {'0': 'text', '2': 'comic'}.get(str(raw.get('bookSourceType', 0)))
    require(kind == source['kind'], 'record kind mismatch')
    endpoint = 'https://' + parsed.hostname + parsed.path
    require(sha(endpoint.encode('utf-8')) == source['endpoint_sha256'], 'normalized endpoint digest mismatch')
    host = parsed.hostname.removeprefix('www.')
    fragment = quote(parsed.fragment, safe="!$&'()*+,;=:@/?-._~%")
    key = host + '#' + fragment if parsed.fragment else ''
    identity = f'legado:{kind}:html:{key}' if key else f'{kind}:html:{host}'
    require(sha(identity.encode('utf-8')) == source['source_id'], 'source ID derivation mismatch')


def verify_candidates(evidence, archive, ledger, head, old_doh, old_rdap):
    ledger_sources = {row['source_id']: row for row in ledger['sources']}
    heads = {row['host']: row for row in head['results']}
    previous = {row['host']: row for row in old_doh['results']}
    old_domains = {row['registry_domain'] for row in old_rdap['candidates']}
    candidates = evidence['candidates']
    require(len(candidates) == len(HOSTS), 'unexpected candidate count')
    require({row['registry_domain']: row['old_source_host'] for row in candidates} == HOSTS,
            'candidate domains or hosts differ')
    source_ids = set()
    for candidate in candidates:
        require(set(candidate) == {'registry_domain', 'old_source_host', 'selected_sources',
                                   'previous_local_head_and_dns', 'previous_public_doh', 'current_summary'},
                'unexpected candidate fields')
        domain, host = candidate['registry_domain'], candidate['old_source_host']
        require(domain not in old_domains, 'candidate had previous RDAP observation')
        require(candidate['previous_local_head_and_dns'] == heads[host] and
                candidate['previous_public_doh'] == previous[host]['observations'],
                'historical DNS/HEAD observation mismatch')
        old = previous[host]
        require(old['baseline'] == 'repeated_nxdomain' and len(old['observations']) == 4 and
                all(o['classification'] == 'nxdomain' and o['http_status'] == 200 and o['dns_rcode'] == 3
                    for o in old['observations']), 'old public DNS evidence mismatch')
        native = heads[host]
        require(native['dns_verdict'] == 'repeated_nxdomain' and len(native['dns_observations']) == 2 and
                all(9003 in (o['a'], o['aaaa']) and o['a'] in (9003, 9501) and o['aaaa'] in (9003, 9501)
                    for o in native['dns_observations']), 'old native DNS evidence mismatch')
        expected_ids = {sid for sid in old['selected_source_ids']
                        if sid in ledger_sources and ledger_sources[sid]['endpoint_host'] == host}
        require({row['source_id'] for row in candidate['selected_sources']} == expected_ids and expected_ids,
                'source association differs')
        for source in candidate['selected_sources']:
            require(source['source_id'] not in source_ids, 'duplicate source identity')
            source_ids.add(source['source_id'])
            verify_source(source, candidate, ledger_sources, archive)
    require(len(source_ids) == 8, 'selected source count mismatch')


def verify_dns(row):
    require(set(row) <= DNS_KEYS and row.get('provider') in PROVIDERS and row.get('query_type') in QTYPES,
            'invalid DNS observation fields')
    require(row.get('baseline') == 'new_review', 'invalid DNS observation baseline')
    classification = row['classification']
    if classification == 'provider_timeout':
        require('dns_rcode' not in row and 'response_sha256' not in row, 'timeout treated as DNS response')
        return
    codes = {'nxdomain': 3, 'noerror_addresses': 0, 'noerror_no_address': 0}
    require(classification in codes and row.get('http_status') == 200 and row.get('dns_rcode') == codes[classification],
            'DNS classification and status disagree')
    require(row.get('dns_truncated') is False and isinstance(row.get('dnssec_authenticated'), bool),
            'invalid DNS flags')
    categories = row.get('address_categories')
    require(isinstance(categories, dict) and set(categories) <= ADDRESS_CLASSES and
            all(isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in categories.values()),
            'invalid DNS address categories')
    require((classification == 'noerror_addresses') == bool(categories), 'DNS answer category mismatch')
    require(re.fullmatch(r'[0-9a-f]{64}', row.get('response_sha256', '')) is not None, 'missing DNS response digest')
    for field in ('address_ttls_seconds', 'negative_ttls_seconds'):
        require(isinstance(row.get(field), list) and all(isinstance(v, int) and v >= 0 for v in row[field]),
                'invalid TTL metadata')


def verify_rdap(row):
    require(set(row) == RDAP_KEYS and row['service'] == 'verisign_com', 'invalid RDAP observation fields')
    require(row['content_type'] == 'application/rdap+json' and row['content_encoding'] in ('', 'identity'),
            'unexpected RDAP response type')
    require(row['error_code'] is None, 'unexpected RDAP error object')
    if row['classification'] == 'matching_domain_object':
        require(row['http_status'] == 200 and row['rdap_object_matches'] is True and
                row['rdap_conformance_present'] is True and 0 < row['body_bytes'] <= 131072,
                'invalid RDAP matching object')
    elif row['classification'] == 'http_404_empty_body':
        require(row['http_status'] == 404 and row['body_bytes'] == 0 and
                row['rdap_object_matches'] is None and row['rdap_conformance_present'] is None,
                'invalid empty RDAP 404')
    else:
        raise ValueError('unexpected RDAP classification')


def validate_times(row, start, end):
    require(start <= timestamp(row['started_at']) <= timestamp(row['observed_at']) <= end,
            'observation outside recorded round')


def verify_rounds(evidence):
    negative = evidence['negative_control_domain']
    require(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.com', negative) is not None, 'invalid negative control')
    rounds = evidence['rounds']
    require(len(rounds) == 2 and [run['round'] for run in rounds] == [1, 2], 'two ordered rounds required')
    outer_start, outer_end = timestamp(evidence['observed_start_utc']), timestamp(evidence['observed_end_utc'])
    all_rdap, all_dns = [], []
    for run in rounds:
        require(set(run) == {'round', 'started_at', 'controls', 'observations', 'control_status',
                             'completed_at', 'scheduled', 'classification_counts'}, 'unexpected round fields')
        start, end = timestamp(run['started_at']), timestamp(run['completed_at'])
        require(outer_start <= start <= end <= outer_end, 'round outside collection window')
        controls = run['controls']
        require(len(controls) == 10, 'unexpected control count')
        seen_controls = set()
        for row in controls:
            validate_times(row, start, end)
            if row.get('service') == 'verisign_com':
                verify_rdap(row)
                key = ('rdap', row['domain'])
                require((row['domain'] == 'google.com' and row['classification'] == 'matching_domain_object') or
                        (row['domain'] == negative and row['classification'] == 'http_404_empty_body'),
                        'RDAP control failed')
            else:
                verify_dns(row)
                key = ('doh', row['host'], row['provider'], row['query_type'])
                if row['host'] == negative:
                    require(row['classification'] == 'nxdomain', 'DNS negative control failed')
                else:
                    require(row['host'] == 'example.com' and row['dns_rcode'] == 0 and
                            (row['query_type'] != 'A' or row['address_categories'].get('public', 0) > 0),
                            'DNS positive control failed')
            require(key not in seen_controls, 'duplicate control observation')
            seen_controls.add(key)
        expected_controls = {('rdap', domain) for domain in ('google.com', negative)} | {
            ('doh', domain, provider, typ) for domain in ('example.com', negative)
            for provider in PROVIDERS for typ in QTYPES}
        require(seen_controls == expected_controls and run['control_status'] == {'rdap': True, 'aliyun': True, 'tencent': True},
                'control coverage differs')
        observed = run['observations']
        require(len(observed) == run['scheduled'] == 54, 'round observation count differs')
        keys = set()
        for row in observed:
            validate_times(row, start, end)
            if row.get('service') == 'verisign_com':
                verify_rdap(row)
                key = ('rdap', row['domain'])
                all_rdap.append(row)
            else:
                verify_dns(row)
                key = ('doh', row['host'], row['provider'], row['query_type'])
                all_dns.append(row)
            require(key not in keys, 'duplicate candidate observation')
            keys.add(key)
        expected = {('rdap', domain) for domain in HOSTS} | {
            ('doh', hostname, provider, typ) for domain, host in HOSTS.items()
            for hostname in (domain, host) for provider in PROVIDERS for typ in QTYPES}
        require(keys == expected, 'candidate observation coverage differs')
        require(dict(Counter(row['classification'] for row in observed)) == run['classification_counts'],
                'round summary differs from observations')
    require(len(all_rdap) == 12 and len(all_dns) == 96, 'observation total mismatch')
    require(Counter(row['classification'] for row in all_rdap) ==
            {'matching_domain_object': 10, 'http_404_empty_body': 2}, 'RDAP outcome totals differ')
    require(sum(row['classification'] == 'provider_timeout' for row in all_dns) == 5, 'DNS timeout total differs')
    require(all(row['classification'] == ('http_404_empty_body' if row['domain'] == 'aslwx.com'
                                          else 'matching_domain_object') for row in all_rdap),
            'domain RDAP classification differs')
    return all_rdap, all_dns


def verify_summaries(evidence, rdap, dns):
    for candidate in evidence['candidates']:
        domain, host = candidate['registry_domain'], candidate['old_source_host']
        expected_rdap = []
        for run in evidence['rounds']:
            for row in run['observations']:
                if row.get('service') == 'verisign_com' and row['domain'] == domain:
                    expected_rdap.append({'round': run['round'], 'http_status': row['http_status'],
                                          'classification': row['classification'], 'observed_at': row['observed_at']})
        expected_dns = {name: dict(Counter(row['classification'] for row in dns if row['host'] == name))
                        for name in (domain, host)}
        require(candidate['current_summary'] == {'rdap': expected_rdap, 'dns_classification_counts': expected_dns},
                'candidate summary differs from observations')
    expected = {'candidate_domains': len(HOSTS), 'selected_source_ids': 8, 'rdap_observations': len(rdap),
                'doh_observations': len(dns), 'matching_domain_objects': 10, 'http_404_empty_body': 2,
                'doh_timeouts': 5}
    require(evidence['summary'] == expected, 'overall summary differs from observations')
    return expected


def verify(evidence):
    require(evidence.get('schema_version') == 1, 'unsupported schema')
    require(set(evidence) == {'schema_version', 'observed_start_utc', 'observed_end_utc',
                              'negative_control_domain', 'official_registry_documentation',
                              'registry_service', 'doh_providers', 'method', 'method_precision',
                              'input_references', 'collection_artifacts', 'limitations', 'candidates',
                              'rounds', 'summary'}, 'unexpected evidence fields')
    require(evidence.get('registry_service') == 'https://rdap.verisign.com/com/v1/domain/{domain}' and
            evidence.get('doh_providers') == {'aliyun': 'dns.alidns.com', 'tencent': 'doh.pub'},
            'unexpected registry or providers')
    require(set(evidence['method']) == {'rdap', 'doh', 'rate', 'privacy'}, 'unexpected method fields')
    artifacts = evidence['collection_artifacts']
    require(set(artifacts) == {'draft_sha256', 'collector_driver_sha256', 'collector_worker_sha256',
                               'collector_scripts_and_draft_in_repository', 'raw_rdap_and_dns_responses_in_repository'} and
            artifacts['collector_scripts_and_draft_in_repository'] is False and
            artifacts['raw_rdap_and_dns_responses_in_repository'] is False and
            all(re.fullmatch(r'[0-9a-f]{64}', artifacts[key]) for key in
                ('draft_sha256', 'collector_driver_sha256', 'collector_worker_sha256')),
            'unexpected collection artifact metadata')
    reject_sensitive(evidence)
    archive, ledger, head, doh, old_rdap = load_inputs(evidence)
    verify_candidates(evidence, archive, ledger, head, doh, old_rdap)
    rdap, dns = verify_rounds(evidence)
    return verify_summaries(evidence, rdap, dns)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    data = args.evidence.read_bytes()
    summary = verify(json.loads(data))
    print(json.dumps({'evidence_sha256': sha(data), 'verified_summary': summary,
                      'historical_response_bodies_recomputed': False,
                      'historical_ledger_git_commit': COMMIT}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
