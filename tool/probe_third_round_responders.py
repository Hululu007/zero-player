"""Bounded homepage probe for hosts that first returned a status in round three.

Two HTTPS GET / requests per host, no redirect follow, 32 KiB sample cap, no
scripts or external links executed. Only titles, marker counts and digests are
retained; bodies and addresses are not saved.
"""

import argparse
import hashlib
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
ROUND = 'docs/implementation/legado-unresolved-third-round-20261116.json'
ROUND_SHA = 'fa0e836dd1dd79660a72353dfd04fb7b57e003e44e5d627e4a3bfaa4728b9483'
OUTPUT = 'docs/implementation/legado-third-round-responders-20261116.json'
UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36')
LIMIT = 32 * 1024
CANONICAL_SHA = None

MARKERS = {
    'parking': ('hugedomains', 'godaddy', 'domain for sale', 'buy this domain',
                '域名出售', '域名转让', '待售', '出售此域名', 'parking'),
    'gambling': ('彩票', '博彩', '赌场', '六合彩', '时时彩', '真人娱乐', '体育投注',
                 '滚球', '新葡京', '威尼斯人', '澳门', '棋牌', '电竞竞猜', '投注'),
    'adult': ('成人', '色情', '情色', '无码', '里番', '伦理', 'porn', 'sexvideo'),
    'book': ('小说', '阅读', '书库', '章节', 'sitebox', '笔趣', 'txt', '电子书'),
    'sports': ('直播', 'nba', '足球', '篮球', '西甲', 'jrs'),
}


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf8')


def decode_sample(sample, content_type):
    charset = ''
    match = re.search(r'charset=([\w-]+)', content_type or '', re.I)
    if match:
        charset = match.group(1).lower()
    else:
        meta = re.search(rb'charset=["\']?([\w-]+)', sample[:4096], re.I)
        charset = meta.group(1).decode('ascii', 'ignore').lower() if meta else ''
    if charset in ('gbk', 'gb2312', 'gb18030'):
        return sample.decode('gb18030', 'replace')
    return sample.decode('utf-8', 'replace')


def require(value, reason):
    if not value:
        raise ValueError(reason)


def inputs():
    raw = (ROOT / ROUND).read_bytes()
    require(sha(raw) == ROUND_SHA, 'round-three evidence changed')
    document = json.loads(raw)
    hosts = [row for row in document['results'] if row['latest_head']['http_status'] is not None]
    require(len(hosts) == 4, 'responder population changed')
    return document, hosts


def probe(host):
    url = 'https://' + host + '/'
    row = {'method': 'GET', 'path': '/', 'observed_at': datetime.now(timezone.utc).isoformat()}
    try:
        response = requests.request('GET', url, headers={'User-Agent': UA, 'Accept-Language': 'zh-CN,zh;q=0.9'},
                                    timeout=15, allow_redirects=False, stream=True)
        body = response.raw.read(LIMIT + 1, decode_content=True) or b''
        sample = body[:LIMIT]
        text = decode_sample(sample, response.headers.get('content-type'))
        title = re.search(r'<title[^>]*>(.*?)</title>', text, re.S | re.I)
        row.update({'status': response.status_code,
                    'content_type': response.headers.get('content-type'),
                    'location': response.headers.get('location'),
                    'bytes': len(body), 'truncated': len(body) > LIMIT,
                    'sha256': sha(sample),
                    'title': re.sub(r'\s+', ' ', title.group(1)).strip()[:200] if title else '',
                    'markers': {name: sum(text.lower().count(word.lower()) for word in words)
                                for name, words in MARKERS.items()}})
        row['error'] = None
    except Exception as error:  # noqa: BLE001 - every failure is recorded as unknown
        row['error'] = f'{type(error).__name__}: {error}'
    return row


def collect(hosts):
    rows = []
    for index, entry in enumerate(hosts, 1):
        host = entry['host']
        requests_seen = [probe(host), probe(host)]
        rows.append({'host': host, 'selected_sources': entry['selected_sources'],
                     'requests': requests_seen})
        print(f'{index}/{len(hosts)} {host}', flush=True)
        time.sleep(2)
    return rows


def summary(rows):
    return {'hosts': len(rows),
            'requests': sum(len(row['requests']) for row in rows),
            'with_error': sum(any(request.get('error') for request in row['requests']) for row in rows),
            'statuses': sorted({request.get('status') for row in rows for request in row['requests']
                                if request.get('status') is not None}),
            'marker_hits': {name: sum(1 for row in rows for request in row['requests']
                                      if request.get('markers', {}).get(name)) for name in MARKERS}}


def evidence(rows, round_sha):
    return {'schema_version': 1, 'generated_at_utc': datetime.now(timezone.utc).isoformat(),
            'method': {'http': 'two HTTPS GET /; no redirects; 32 KiB cap',
                       'timeout_seconds': 15, 'body_saved': False,
                       'ip_addresses_saved': False, 'redirect_targets_saved': True},
            'input_references': {'round_three': {'path': ROUND, 'sha256': round_sha}},
            'limitations': ['Single client and network; a status or title is a time-limited observation.',
                            'Marker counts are keyword presence only; they do not prove site category or safety.',
                            'Bodies, scripts and links were not executed or retained.'],
            'summary': summary(rows), 'results': rows}


def verify(document, hosts):
    if CANONICAL_SHA is not None:
        require(sha(canonical(document)) == CANONICAL_SHA, 'evidence changed')
    require(document['input_references']['round_three']['sha256'] == ROUND_SHA, 'input reference changed')
    rows = document['results']
    by_host = {row['host']: row for row in rows}
    require(len(rows) == len(by_host) == 4 and set(by_host) == {entry['host'] for entry in hosts},
            'responder population changed')
    for row in rows:
        require(len(row['requests']) == 2 and all(request['method'] == 'GET' and request['path'] == '/' for request in row['requests']),
                'request shape changed')
    require(document['summary'] == summary(rows), 'summary changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    document, hosts = inputs()
    if args.verify:
        raw = (ROOT / OUTPUT).read_bytes()
        verify(json.loads(raw), hosts)
        print(json.dumps({'verified': True, 'sha256': sha(raw)}, ensure_ascii=False))
        return
    require(args.build, 'choose --build or --verify')
    rows = collect(hosts)
    result = evidence(rows, ROUND_SHA)
    verify(result, hosts)
    target = ROOT / OUTPUT
    target.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps({'path': OUTPUT, 'sha256': sha(target.read_bytes()),
                      'canonical_sha256': sha(canonical(result)),
                      'summary': result['summary']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
