"""Collect bounded, redacted RDAP/DNS observations for the fixed seven domains."""
import bz2
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(Path.cwd()))
from tool import audit_legado_doh_pilot as doh
from tool.audit_legado_catalog import RequestDeadline, public_addresses
from tool.verify_legado_rdap_com_eighteen import verify_source

OUT = Path('build/rdap-topcc-20261116-8b1713/draft.json')
COMMIT = 'a6c7d9986a64a2c7328c5f74c06415a116ef27a9'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
FILES = {
    'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
    'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
    'host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
    'doh_reviewed': 'docs/implementation/legado-doh-reviewed-20261115.json',
}
HOSTS = {
    '99hanman.top': '99hanman.top',
    'duduxiaoshuo.top': 'h5.duduxiaoshuo.top',
    'stxt.top': 'stxt.top',
    'shenxianfaka.top': 'www.shenxianfaka.top',
    'wxc.cc': 'm.wxc.cc',
    'znehuo.cc': 'm.znehuo.cc',
    'shujige.cc': 'www.shujige.cc',
}
PROVIDERS = ('aliyun', 'tencent')
QTYPES = ('A', 'AAAA')
SERVICES = {'top': ('rdap.zdnsgtld.com', '/top/'),
            'cc': ('tld-rdap.verisign.com', '/cc/v1/')}
MAX_BODY = 128 * 1024
LAST_START = 0.0


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def paced():
    global LAST_START
    delay = .45 - (time.monotonic() - LAST_START)
    if delay > 0:
        time.sleep(delay)
    LAST_START = time.monotonic()


def get_https(host, path, body_limit, accept):
    """Read a single vetted service response without redirects or credentials."""
    deadline = time.monotonic() + 8
    family, address = public_addresses(host, 8)[0]
    with RequestDeadline(deadline) as limit:
        with socket.socket(family, socket.SOCK_STREAM) as plain:
            limit.attach(plain)
            plain.settimeout(limit.remaining())
            plain.connect((address, 443))
            with limit.wrap(plain, host) as secure:
                secure.settimeout(limit.remaining())
                secure.do_handshake()
                secure.settimeout(limit.remaining())
                request = (f'GET {path} HTTP/1.1\r\nHost: {host}\r\n'
                           f'User-Agent: ZeroPlayer-SourceAudit/1.0\r\nAccept: {accept}\r\n'
                           'Accept-Encoding: identity\r\nConnection: close\r\n\r\n')
                secure.sendall(request.encode('ascii'))
                response = http.client.HTTPResponse(secure)
                try:
                    response.begin()
                    limit.remaining()
                    status = response.status
                    content_type = (response.getheader('Content-Type') or '').split(';')[0].strip().lower()
                    encoding = (response.getheader('Content-Encoding') or '').strip().lower()
                    if 300 <= status < 400 or status not in (200, 404) or encoding not in ('', 'identity'):
                        return status, content_type, encoding, None
                    body = response.read(body_limit + 1)
                    limit.remaining()
                    return status, content_type, encoding, body
                finally:
                    response.close()


def bootstrap():
    paced()
    started = utc()
    status, _, encoding, body = get_https('data.iana.org', '/rdap/dns.json', 2 * 1024 * 1024,
                                          'application/json')
    if status != 200 or encoding not in ('', 'identity') or body is None or len(body) > 2 * 1024 * 1024:
        raise ValueError('IANA bootstrap unavailable or outside bounds')
    data = json.loads(body)
    expected = {tld: f'https://{host}{path}' for tld, (host, path) in SERVICES.items()}
    found = {}
    for names, urls in data['services']:
        for tld in expected:
            if tld in names:
                if tld in found:
                    raise ValueError('ambiguous IANA bootstrap mapping')
                found[tld] = urls
    if found != {tld: [url] for tld, url in expected.items()}:
        raise ValueError('IANA bootstrap mapping changed')
    return {'url': 'https://data.iana.org/rdap/dns.json', 'publication': data['publication'],
            'sha256': digest(body), 'services': found, 'started_at': started, 'observed_at': utc()}


def classify_rdap(status, body, domain):
    result = {'body_bytes': len(body), 'rdap_object_matches': None,
              'rdap_conformance_present': None, 'rdap_error_code_is_404': None}
    if len(body) > MAX_BODY:
        return {**result, 'classification': 'body_over_limit'}
    if status == 404 and not body:
        return {**result, 'classification': 'http_404_empty_body'}
    try:
        parsed = json.loads(body)
    except (ValueError, UnicodeError):
        return {**result, 'classification': 'non_json_response'}
    if not isinstance(parsed, dict):
        return {**result, 'classification': 'non_object_response'}
    if status == 404:
        result['rdap_error_code_is_404'] = parsed.get('errorCode') == 404
        return {**result, 'classification': 'http_404_json'}
    name = parsed.get('ldhName')
    result['rdap_object_matches'] = (parsed.get('objectClassName') == 'domain' and
                                     isinstance(name, str) and name.lower().rstrip('.') == domain)
    result['rdap_conformance_present'] = isinstance(parsed.get('rdapConformance'), list)
    return {**result, 'classification': ('matching_domain_object'
            if result['rdap_object_matches'] and result['rdap_conformance_present'] else 'unexpected_object')}


def rdap(domain):
    paced()
    tld = domain.rsplit('.', 1)[-1]
    host, base = SERVICES[tld]
    row = {'mode': 'rdap', 'domain': domain, 'started_at': utc(), 'http_status': None}
    try:
        status, ctype, encoding, body = get_https(host, base + 'domain/' + domain, MAX_BODY,
                                                  'application/rdap+json')
        row.update(http_status=status, content_type=ctype, content_encoding=encoding)
        if 300 <= status < 400:
            row['classification'] = 'redirect_not_followed'
        elif status not in (200, 404):
            row['classification'] = 'http_error'
        elif encoding not in ('', 'identity'):
            row['classification'] = 'unsupported_encoding'
        else:
            row.update(classify_rdap(status, body, domain))
    except (TimeoutError, socket.timeout):
        row['classification'] = 'timeout'
    except (OSError, http.client.HTTPException) as error:
        row.update(classification='connection_or_tls_error', error_type=type(error).__name__)
    except (ValueError, UnicodeError) as error:
        row.update(classification='invalid_response_or_request', error_type=type(error).__name__)
    row['observed_at'] = utc()
    return row


def dns(host, provider, typ):
    paced()
    source = doh.one({'host': host, 'baseline': 'top_cc_review'}, provider, typ)
    fields = ('host', 'provider', 'query_type', 'started_at', 'observed_at', 'http_status',
              'classification', 'dns_rcode', 'dns_truncated', 'dnssec_authenticated',
              'address_categories', 'address_ttls_seconds', 'negative_ttls_seconds')
    return {'mode': 'doh', **{key: source[key] for key in fields if key in source}}


def prepare():
    proc = subprocess.run(['git', 'show', COMMIT + ':' + LEDGER], check=True, capture_output=True, timeout=30)
    ledger = json.loads(proc.stdout)
    refs = {'source_ledger_historical_git': {'commit': COMMIT, 'path': LEDGER, 'sha256': digest(proc.stdout)}}
    contents = {}
    for key, path in FILES.items():
        raw = Path(path).read_bytes()
        refs[key] = {'path': path, 'sha256': digest(raw)}
        contents[key] = json.loads(bz2.decompress(raw) if key == 'catalog_archive' else raw)
        if ledger['input_sha256'].get(path) != digest(raw):
            raise ValueError('historical input mismatch: ' + key)
    archive = contents['catalog_archive']
    if contents['catalog_manifest']['archiveSha256'] != refs['catalog_archive']['sha256']:
        raise ValueError('catalog manifest mismatch')
    ledger_by_id = {row['source_id']: row for row in ledger['sources']}
    old_native = {row['host']: row for row in contents['host_recheck']['results']}
    old_doh = {row['host']: row for row in contents['doh_reviewed']['results']}
    candidates = []
    for domain, host in sorted(HOSTS.items()):
        native, previous = old_native[host], old_doh[host]
        if native['dns_verdict'] != 'repeated_nxdomain' or previous['baseline'] != 'repeated_nxdomain':
            raise ValueError('historical repeated NXDOMAIN baseline differs')
        records = [s for s in ledger['sources'] if s['endpoint_host'] == host]
        if len(records) != 1 or {s['source_id'] for s in records} != set(previous['selected_source_ids']):
            raise ValueError('historical selected host association differs')
        sources = []
        for s in records:
            source = {'source_id': s['source_id'], 'name': s['name'], 'kind': s['kind'],
                      'selected_record_index': s['selected_record_index'],
                      'normalized_legado_sha256': s['normalized_legado_canonical_sha256'],
                      'endpoint_sha256': s['endpoint_sha256'],
                      'selected_raw_record_canonical_sha256': s['selected_raw_record_canonical_sha256']}
            verify_source(source, host, ledger_by_id, archive)
            sources.append(source)
        candidates.append({'registry_domain': domain, 'old_source_host': host, 'selected_sources': sources,
                           'previous_native_dns': native['dns_observations'],
                           'previous_public_doh': previous['observations']})
    return refs, candidates


def controls(negative):
    rows = [rdap(name) for name in ('google.top', negative['top'], 'google.cc', negative['cc'])]
    for provider in PROVIDERS:
        for host in ('example.com', negative['top'], negative['cc']):
            for typ in QTYPES:
                rows.append(dns(host, provider, typ))
    return rows


def control_status(rows, negative):
    lookup = {(r['mode'], r.get('domain') or r.get('host'), r.get('provider'), r.get('query_type')): r for r in rows}
    verdict = {}
    for tld in ('top', 'cc'):
        positive = lookup['rdap', 'google.' + tld, None, None]
        absent = lookup['rdap', negative[tld], None, None]
        verdict[tld] = {'rdap': positive['classification'] == 'matching_domain_object' and
                        absent['http_status'] == 404 and
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


def collect_round(number):
    token = secrets.token_hex(10)
    negative = {tld: f'zp-rdap-{token}.{tld}' for tld in ('top', 'cc')}
    row = {'round': number, 'started_at': utc(), 'negative_controls': negative}
    row['controls'] = controls(negative)
    row['control_status'] = status = control_status(row['controls'], negative)
    print(json.dumps({'round': number, 'control_status': status}), flush=True)
    observations, skipped = [], []
    for domain, old in sorted(HOSTS.items()):
        tld = domain.rsplit('.', 1)[-1]
        if status[tld]['rdap']:
            observations.append(rdap(domain))
        else:
            skipped.append({'mode': 'rdap', 'domain': domain, 'reason': 'control_failed'})
        for host in sorted({domain, old}):
            for provider in PROVIDERS:
                for typ in QTYPES:
                    if status[tld][provider]:
                        observations.append(dns(host, provider, typ))
                    else:
                        skipped.append({'mode': 'doh', 'host': host, 'provider': provider,
                                        'query_type': typ, 'reason': 'control_failed'})
    row.update(observations=observations, skipped=skipped, completed_at=utc(),
               classification_counts=dict(Counter(r['classification'] for r in observations)))
    print(json.dumps({'round': number, 'counts': row['classification_counts'],
                      'skipped': len(skipped)}), flush=True)
    return row


def cache_delay(round1):
    ttls, unknown = [], 0
    for row in round1['controls'] + round1['observations']:
        if row['mode'] != 'doh' or row.get('http_status') != 200:
            continue
        values = row.get('address_ttls_seconds', []) + row.get('negative_ttls_seconds', [])
        ttls.extend(values)
        if row['classification'] in ('nxdomain', 'noerror_no_address') and not row.get('negative_ttls_seconds'):
            unknown += 1
    maximum = max(ttls, default=0)
    return {'observed_max_ttl_seconds': maximum, 'minimum_wait_seconds': max(600, maximum) + 5,
            'negative_cache_ttl_unknown_observations': unknown}


def persist(data):
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    if OUT.exists():
        raise ValueError('draft path already exists')
    refs, candidates = prepare()
    data = {'schema_version': 1, 'observed_start_utc': utc(), 'input_references': refs,
            'iana_bootstrap': bootstrap(), 'candidates': candidates, 'rounds': []}
    row = collect_round(1)
    data['rounds'].append(row)
    data['cache_barrier'] = cache_delay(row)
    barrier = data['cache_barrier']
    barrier['not_before_utc'] = (datetime.fromisoformat(row['completed_at']) +
                                 timedelta(seconds=barrier['minimum_wait_seconds'])).isoformat()
    persist(data)
    print(json.dumps({'cache_barrier': barrier}), flush=True)
    target = time.monotonic() + barrier['minimum_wait_seconds']
    while time.monotonic() < target:
        time.sleep(min(10, target - time.monotonic()))
    data['rounds'].append(collect_round(2))
    data['observed_end_utc'] = utc()
    persist(data)
    print(json.dumps({'draft': str(OUT), 'sha256': digest(OUT.read_bytes())}), flush=True)


if __name__ == '__main__':
    main()
