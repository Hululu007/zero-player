"""Collect five fixed-domain RDAP and DoH results with independent controls."""
import bz2
from collections import Counter
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import secrets
import subprocess
import sys
import time

sys.path.insert(0, str(Path.cwd()))
from tool import collect_legado_rdap_top_cc as base
from tool.verify_legado_rdap_com_eighteen import verify_source

COMMIT = 'f7b5697d49fdc5113274e5add45a1108638957c5'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
FILES = {
    'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
    'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
    'later_host_recheck': 'docs/implementation/legado-unresolved-head-later-20261116.json',
    'prior_public_doh': 'docs/implementation/legado-doh-reviewed-20261115.json',
}
HOSTS = {'7wav.com': 'm.7wav.com', '92yanqing.net': 'm.92yanqing.net',
         'fxsw.top': 'www.fxsw.top', 'zri.moe': 'book.zri.moe', 'cwj18.org': 'www.cwj18.org'}
SERVICES = {'com': ('rdap.verisign.com', '/com/v1/'),
            'net': ('rdap.verisign.com', '/net/v1/'),
            'top': ('rdap.zdnsgtld.com', '/top/'),
            'moe': ('rdap.nic.moe', '/'),
            'org': ('rdap.publicinterestregistry.org', '/rdap/')}
PROVIDERS, QTYPES = ('aliyun', 'tencent'), ('A', 'AAAA')
OUT = Path('build/rdap-five-20261116-a03e1b/draft.json')
PSL = {'source': 'https://publicsuffix.org/list/public_suffix_list.dat',
       'sha256': 'fc62f83e482dd86d3c50216fcbf5bb6c3b18f13d0ffdfc462b14e36b8a97bfba',
       'version': '2026-11-15_20-28-43_UTC', 'commit': 'fd22c6c8b3fd7e854c1eff2194cfd4ebc9854b88',
       'source_host_to_registrable_domain_icann_and_including_private':
           {host: domain for domain, host in HOSTS.items()},
       'exact_observation_time_recorded': False, 'raw_list_retained': False}

base.SERVICES = SERVICES


def utc():
    return datetime.now(timezone.utc).isoformat()


def prepare():
    proc = subprocess.run(['git', 'show', COMMIT + ':' + LEDGER], capture_output=True, check=True, timeout=30)
    ledger = json.loads(proc.stdout)
    refs = {'source_ledger_historical_git': {'commit': COMMIT, 'path': LEDGER, 'sha256': base.digest(proc.stdout)}}
    docs = {}
    for key, path in FILES.items():
        data = Path(path).read_bytes()
        refs[key] = {'path': path, 'sha256': base.digest(data)}
        docs[key] = json.loads(bz2.decompress(data) if key == 'catalog_archive' else data)
    if docs['catalog_manifest']['archiveSha256'] != refs['catalog_archive']['sha256']:
        raise ValueError('catalog manifest differs')
    for key in ('catalog_archive', 'catalog_manifest', 'prior_public_doh'):
        if ledger['input_sha256'].get(FILES[key]) != refs[key]['sha256']:
            raise ValueError('historical ledger input differs')
    byid = {s['source_id']: s for s in ledger['sources']}
    latest = {r['host']: r for r in docs['later_host_recheck']['results']}
    prior = {r['host']: r for r in docs['prior_public_doh']['results']}
    prior_domains = set()
    for path in Path('docs/implementation').glob('legado-rdap-*.json'):
        document = json.loads(path.read_text(encoding='utf-8'))
        prior_domains.update(r['registry_domain'] for r in document.get('candidates', document.get('results', []))
                             if 'registry_domain' in r)
    if set(HOSTS) & prior_domains:
        raise ValueError('candidate was already included in an RDAP evidence batch')
    candidates = []
    for domain, host in sorted(HOSTS.items()):
        record = latest[host]
        if record['dns']['verdict'] != 'repeated_nxdomain':
            raise ValueError('latest native DNS baseline differs')
        selected = [s for s in ledger['sources'] if s['endpoint_host'] == host]
        if not selected or {s['source_id'] for s in selected} != {s['source_id'] for s in record['selected_sources']}:
            raise ValueError('selected sources differ from later audit')
        sources = []
        for s in selected:
            snapshot = {'source_id': s['source_id'], 'name': s['name'], 'kind': s['kind'],
                        'selected_record_index': s['selected_record_index'],
                        'normalized_legado_sha256': s['normalized_legado_canonical_sha256'],
                        'endpoint_sha256': s['endpoint_sha256'],
                        'selected_raw_record_canonical_sha256': s['selected_raw_record_canonical_sha256']}
            verify_source(snapshot, host, byid, docs['catalog_archive'])
            sources.append(snapshot)
        public = prior.get(host)
        candidates.append({'registry_domain': domain, 'old_source_host': host, 'selected_sources': sources,
                           'latest_native_dns': record['dns'],
                           'previous_public_doh': None if public is None else public['observations']})
    if len(candidates) != 5 or sum(len(c['selected_sources']) for c in candidates) != 10:
        raise ValueError('candidate source count differs')
    return refs, candidates


def controls(negative):
    rows = []
    for tld in SERVICES:
        rows.append(base.rdap('google.' + tld))
        rows.append(base.rdap(negative[tld]))
    for provider in PROVIDERS:
        for host in ('example.com', *negative.values()):
            for typ in QTYPES:
                rows.append(base.dns(host, provider, typ))
    return rows


def control_status(rows, negative):
    lookup = {(r['mode'], r.get('domain') or r.get('host'), r.get('provider'), r.get('query_type')): r for r in rows}
    verdict = {}
    for tld in SERVICES:
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
    negative = {tld: f'zp-rdap-{token}.{tld}' for tld in SERVICES}
    row = {'round': number, 'started_at': utc(), 'negative_controls': negative}
    row['controls'] = controls(negative)
    row['control_status'] = status = control_status(row['controls'], negative)
    print(json.dumps({'round': number, 'control_status': status}), flush=True)
    observations, skipped = [], []
    for domain, old in sorted(HOSTS.items()):
        tld = domain.rsplit('.', 1)[-1]
        if status[tld]['rdap']:
            observations.append(base.rdap(domain))
        else:
            skipped.append({'mode': 'rdap', 'domain': domain, 'reason': 'control_failed'})
        for host in (domain, old):
            for provider in PROVIDERS:
                for typ in QTYPES:
                    if status[tld][provider]:
                        observations.append(base.dns(host, provider, typ))
                    else:
                        skipped.append({'mode': 'doh', 'host': host, 'provider': provider,
                                        'query_type': typ, 'reason': 'control_failed'})
    row.update(observations=observations, skipped=skipped, completed_at=utc(),
               classification_counts=dict(Counter(r['classification'] for r in observations)))
    print(json.dumps({'round': number, 'counts': row['classification_counts'], 'skipped': len(skipped)}), flush=True)
    return row


def persist(data):
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    if OUT.exists():
        raise ValueError('draft path already exists')
    refs, candidates = prepare()
    data = {'schema_version': 1, 'observed_start_utc': utc(), 'input_references': refs,
            'iana_bootstrap': base.bootstrap(), 'public_suffix_observation': PSL,
            'candidates': candidates, 'rounds': []}
    first = collect_round(1)
    data['rounds'].append(first)
    data['cache_barrier'] = base.cache_delay(first)
    barrier = data['cache_barrier']
    barrier['not_before_utc'] = (datetime.fromisoformat(first['completed_at']) +
                                 timedelta(seconds=barrier['minimum_wait_seconds'])).isoformat()
    persist(data)
    print(json.dumps({'cache_barrier': barrier}), flush=True)
    target = time.monotonic() + barrier['minimum_wait_seconds']
    while time.monotonic() < target:
        time.sleep(min(10, target - time.monotonic()))
    data['rounds'].append(collect_round(2))
    data['observed_end_utc'] = utc()
    persist(data)
    print(json.dumps({'draft': str(OUT), 'sha256': base.digest(OUT.read_bytes())}), flush=True)


if __name__ == '__main__':
    main()
