"""Recheck two exact legacy sources without following redirects or executing rules.

Only the allowlisted roots, a public search query, and one static category are
requested. Page bodies, redirect paths/queries, IPs and credentials are not
persisted. The historical ledger and bundled record hashes pin attribution.
"""

import argparse
import bz2
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import time
from urllib.parse import quote

try:
    from .audit_legado_catalog import fetch
except ImportError:
    from audit_legado_catalog import fetch


ROOT = Path(__file__).resolve().parents[1]
LEDGER_COMMIT = 'a6c7d9986a64a2c7328c5f74c06415a116ef27a9'
LEDGER_PATH = 'docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA256 = 'b3962a059b2d577dd88df6d263ce2227c55cf23881eba6e6de7f339bf0885c22'
ARCHIVE_PATH = 'assets/catalogs/books/legado/catalog.json.bz2'
ARCHIVE_SHA256 = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
KEY = quote('三国演义')
CANDIDATES = {
    'm.newbiquge.org': {
        'id': '579f77abbbbe0d480ebcf75b9aca291c573954fac9496263f2747ac0dd2e0156',
        'index': 3107,
        'endpoint': 'https://m.newbiquge.org',
        'legado_sha256': 'c9fdc25ee7e1a4cabee2d83860b0d38b5d92bbdeb0a5627490ee8c9613cbf181',
        'requests': (
            ('root', 'HEAD', '/'),
            ('search', 'HEAD', '/book/search.aspx?ie=utf-8&siteid=xinbiquge.org&s=000&key=' + KEY),
            ('search', 'GET', '/book/search.aspx?ie=utf-8&siteid=xinbiquge.org&s=000&key=' + KEY),
        ),
    },
    'www.3ubook.com': {
        'id': 'd4b04ca5fb5f99ec4197fa67c2555cbac933b04534fd16f41eefec29c21d3d29',
        'index': 3041,
        'endpoint': 'https://www.3ubook.com',
        'legado_sha256': '384f712065d76ffc451e03883e1b56bb1f76f427d29f3f9cce3363d7c55af81c',
        'requests': (
            ('root', 'HEAD', '/'),
            ('search', 'HEAD', '/search/?keyword=' + KEY),
            ('search', 'GET', '/search/?keyword=' + KEY),
            ('category', 'HEAD', '/c_1.html'),
            ('category', 'GET', '/c_1.html'),
        ),
    },
}


def sha(value):
    return hashlib.sha256(value).hexdigest()


def source_sha(path):
    return sha((ROOT / path).read_bytes().replace(b'\r\n', b'\n'))


def now():
    return datetime.now(timezone.utc).isoformat()


def bindings():
    ledger_bytes = subprocess.check_output(
        ['git', 'show', f'{LEDGER_COMMIT}:{LEDGER_PATH}'], cwd=ROOT
    )
    if sha(ledger_bytes) != LEDGER_SHA256:
        raise ValueError('historical ledger digest mismatch')
    archive = (ROOT / ARCHIVE_PATH).read_bytes()
    if sha(archive) != ARCHIVE_SHA256:
        raise ValueError('catalog archive digest mismatch')
    records = json.loads(bz2.decompress(archive))['records']
    ledger = json.loads(ledger_bytes)
    selected = {row['source_id']: row for row in ledger['sources']}
    result = []
    for host, expected in CANDIDATES.items():
        row = selected[expected['id']]
        raw = json.dumps(records[expected['index']], ensure_ascii=False,
                         sort_keys=True, separators=(',', ':')).encode('utf-8')
        if (row['endpoint_host'] != host or row['selected_record_index'] != expected['index']
                or row['kind'] != 'text' or row['format'] != 'html'
                or row['endpoint_sha256'] != sha(expected['endpoint'].encode())
                or row['normalized_legado_canonical_sha256'] != expected['legado_sha256']
                or row['selected_raw_record_canonical_sha256'] != sha(raw)):
            raise ValueError('historical source binding mismatch: ' + host)
        result.append({
            'host': host, 'source_id': expected['id'],
            'selected_record_index': expected['index'],
            'endpoint': expected['endpoint'],
            'selected_raw_record_canonical_sha256': sha(raw),
            'normalized_legado_canonical_sha256': expected['legado_sha256'],
        })
    return result


def check(host, method, path):
    started = now()
    result = {'started_at': started, 'request_sha256': sha(
        f'https://{host}{path}'.encode('utf-8'))}
    try:
        observed = fetch(host, method, 8, path)
        result.update({key: observed[key] for key in
                       ('status', 'redirect', 'redirect_host', 'redirect_scheme')
                       if key in observed})
    except (OSError, ValueError, http.client.HTTPException) as error:
        result['error'] = type(error).__name__
    result['observed_at'] = now()
    return result


def collect():
    result = {
        'method': 'Public HTTPS with pinned public DNS; root HEAD and fixed search/category HEAD/GET; no redirects or scripts.',
        'limitations': [
            'The two rounds share one network and may share caches.',
            'Redirects do not establish malicious content or permanent closure.',
            'Only the recorded old source versions and request paths were checked.',
            'Raw pages, redirect paths and queries, IPs and credentials are not retained.',
        ],
        'archive_sha256': ARCHIVE_SHA256,
        'historical_ledger': {'commit': LEDGER_COMMIT, 'path': LEDGER_PATH, 'sha256': LEDGER_SHA256},
        'collector_source_sha256': source_sha('tool/recheck_redirected_book_sources.py'),
        'transport_source_sha256': source_sha('tool/audit_legado_catalog.py'),
        'sources': bindings(), 'rounds': [],
    }
    for number in (1, 2):
        control = check('example.com', 'HEAD', '/')
        passed = control.get('status') == 200
        round_result = {'round': number, 'control': control, 'observations': []}
        for host, candidate in CANDIDATES.items():
            for purpose, method, path in candidate['requests']:
                item = {'host': host, 'purpose': purpose, 'method': method}
                if passed:
                    item.update(check(host, method, path))
                else:
                    item['skipped'] = 'control_failed'
                round_result['observations'].append(item)
                time.sleep(0.5)
        result['rounds'].append(round_result)
    result['completed_at'] = now()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    output = parser.parse_args().output
    if output.exists():
        raise SystemExit('refusing to overwrite existing evidence')
    output.parent.mkdir(parents=True, exist_ok=True)
    result = collect()
    with output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(f"Recorded {sum(len(r['observations']) for r in result['rounds'])} bounded observations: {output}")


if __name__ == '__main__':
    main()
