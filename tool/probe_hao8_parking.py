"""Two-sample parking check for hao8.net after the third unresolved-host round.

HTTPS GET / with no redirect follow, 32 KiB cap. Only title, byte/digest,
marker booleans and one short visible-text quote are retained; no scripts run.
"""

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
HOST = 'hao8.net'
OUTPUT = 'docs/implementation/legado-hao8-parking-20261116.json'
UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36')
LIMIT = 32 * 1024
ROUND_SHA = 'fa0e836dd1dd79660a72353dfd04fb7b57e003e44e5d627e4a3bfaa4728b9483'
CANONICAL_SHA = None

MARKERS = {
    'domain_can_transfer': '域名可以转让',
    'domain_for_sale_en': 'this domain name is for sale',
    'fixed_price_sale': '一口价出售',
    'price_cny': 'cny',
    'book_search_form': 'searchkey',
}


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf8')


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sample():
    row = {'method': 'GET', 'path': '/', 'observed_at': datetime.now(timezone.utc).isoformat()}
    try:
        response = requests.request('GET', 'https://' + HOST + '/',
                                    headers={'User-Agent': UA, 'Accept-Language': 'zh-CN,zh;q=0.9'},
                                    timeout=15, allow_redirects=False, stream=True)
        body = response.raw.read(LIMIT + 1, decode_content=True) or b''
        sample_bytes = body[:LIMIT]
        text = sample_bytes.decode('utf-8', 'replace')
        title = re.search(r'<title[^>]*>(.*?)</title>', text, re.S | re.I)
        plain = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', text)).strip()
        row.update({'status': response.status_code,
                    'content_type': response.headers.get('content-type'),
                    'bytes': len(body), 'truncated': len(body) > LIMIT,
                    'sha256': sha(sample_bytes),
                    'title': re.sub(r'\s+', ' ', title.group(1)).strip()[:160] if title else '',
                    'markers': {name: (word.lower() in text.lower() or word.lower() in plain.lower())
                                for name, word in MARKERS.items()},
                    'book_link_count': len(re.findall(r'href="[^"]*(?:/book/|/\d+\.html)', text)),
                    'quote': plain[:160]})
        row['error'] = None
    except Exception as error:  # noqa: BLE001 - every failure is recorded as unknown
        row['error'] = f'{type(error).__name__}: {error}'
    return row


def build(rows):
    return {'schema_version': 1, 'generated_at_utc': datetime.now(timezone.utc).isoformat(),
            'host': HOST,
            'method': {'http': 'two HTTPS GET /; no redirects; 32 KiB cap',
                       'timeout_seconds': 15, 'body_saved': False, 'addresses_saved': False},
            'input_references': {'third_round': {
                'path': 'docs/implementation/legado-unresolved-third-round-20261116.json',
                'sha256': ROUND_SHA}},
            'limitations': ['Two samples from one client and network; parking pages can change.',
                            'The quote is visible text only, not a legal or ownership conclusion.',
                            'Scripts and links were not executed or fetched.'],
            'summary': {'samples': len(rows),
                        'statuses': [row.get('status') for row in rows],
                        'marker_counts': {name: sum(1 for row in rows if row.get('markers', {}).get(name))
                                          for name in MARKERS},
                        'book_links': [row.get('book_link_count') for row in rows]},
            'results': rows}


def verify(document, rows):
    if CANONICAL_SHA is not None:
        require(sha(canonical(document)) == CANONICAL_SHA, 'evidence changed')
    require(document['host'] == HOST and document['input_references']['third_round']['sha256'] == ROUND_SHA,
            'identity changed')
    require(len(document['results']) == 2 and all(
        row['method'] == 'GET' and row['path'] == '/' for row in document['results']), 'request shape changed')
    require(document['results'] == rows or sha(canonical(document['results'])) == sha(canonical(rows)),
            'sample rows changed')
    require(document['summary']['samples'] == 2, 'sample count changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    rows = [sample(), sample()]
    document = build(rows)
    verify(document, rows)
    require(args.build, 'choose --build')
    target = ROOT / OUTPUT
    target.write_text(json.dumps(document, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps({'path': OUTPUT, 'sha256': sha(target.read_bytes()),
                      'canonical_sha256': sha(canonical(document)),
                      'summary': document['summary']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
