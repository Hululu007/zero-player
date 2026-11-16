"""Bounded live recheck of the curated built-in book sources.

Anonymous same-host HTTPS GET only; no POST, no credentials, no redirects.
Evidence keeps only status, byte counts, title text and page hashes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFIED = ROOT / 'assets/catalogs/books/verified.json'
OUTPUT = ROOT / 'docs/implementation/legado-builtin-sources-recheck-20261116.json'
UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36')
KEYWORD = '剑来'
MAX_BYTES = 256 * 1024
TIMEOUT = 12.0
WORKERS = 8
PRINT_LOCK = threading.Lock()

TITLE_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.I | re.S)
CHARSET_RE = re.compile(rb'<meta[^>]+charset=["\']?([\w-]+)', re.I)
ABSOLUTE_RE = re.compile(r'^https?://', re.I)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def log(message: str) -> None:
    with PRINT_LOCK:
        print(message, flush=True)


def decode(body: bytes, content_type: str) -> str:
    match = CHARSET_RE.search(body[:4096])
    charset = match.group(1).decode('ascii', 'replace') if match else ''
    if not charset:
        charset = 'utf-8'
        header = re.search(r'charset=([\w-]+)', content_type, re.I)
        if header:
            charset = header.group(1)
    for candidate in (charset, 'utf-8', 'gb18030'):
        try:
            return body.decode(candidate, 'replace')
        except LookupError:
            continue
    return body.decode('utf-8', 'replace')


def fetch(url: str) -> dict:
    if not url.startswith('https://'):
        raise ValueError(f'refusing non-HTTPS target: {url}')
    context = ssl.create_default_context()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=context), _NoRedirect()
    )
    request = urllib.request.Request(
        url,
        headers={
            'User-Agent': UA,
            'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        method='GET',
    )
    started = time.monotonic()
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            body = response.read(MAX_BYTES + 1)
            truncated = len(body) > MAX_BYTES
            body = body[:MAX_BYTES]
            content_type = response.headers.get('Content-Type', '')
            text = decode(body, content_type) if 'html' in content_type.lower() or not content_type else ''
            title_match = TITLE_RE.search(text)
            title = re.sub(r'\s+', ' ', title_match.group(1)).strip() if title_match else ''
            row = {
                'status': response.status,
                'bytes': len(body),
                'truncated': truncated,
                'content_type': content_type.split(';')[0].strip().lower(),
                'title': title[:160],
                'sha256': hashlib.sha256(body).hexdigest(),
                'path_sha256': hashlib.sha256(urllib.parse.urlsplit(response.geturl()).path.encode()).hexdigest(),
            }
    except urllib.error.HTTPError as error:
        body = error.read(MAX_BYTES) if error.fp else b''
        row = {
            'status': error.code,
            'bytes': len(body),
            'truncated': False,
            'content_type': (error.headers.get('Content-Type', '') if error.headers else '').split(';')[0].strip().lower(),
            'title': '',
            'sha256': hashlib.sha256(body).hexdigest(),
            'path_sha256': hashlib.sha256(urllib.parse.urlsplit(error.geturl()).path.encode()).hexdigest(),
        }
    except Exception as error:  # noqa: BLE001 - bounded probe records the failure class
        row = {'status': None, 'error': type(error).__name__, 'bytes': 0}
    row['elapsed_ms'] = int((time.monotonic() - started) * 1000)
    return row


def address(rule: str) -> str:
    return rule.split(',{', 1)[0].strip()


def expand(template: str, page: int = 1) -> str:
    value = template.replace('{{key}}', urllib.parse.quote(KEYWORD))
    value = value.replace('{key}', urllib.parse.quote(KEYWORD))
    value = value.replace('{{page}}', str(page)).replace('{page}', str(page))
    return value


def build_plan() -> list[dict]:
    entries = json.loads(VERIFIED.read_text(encoding='utf-8'))
    plan = []
    for entry in entries:
        url = entry['url'].rstrip('/')
        home = url + '/' if entry.get('kind') == 'text' else entry['url']
        search = None
        legacy = entry.get('legado') or {}
        if entry.get('kind') == 'text':
            base = url + '/'
            raw = entry.get('search') or legacy.get('search')
            if raw:
                target = expand(address(raw))
                if not ABSOLUTE_RE.match(target):
                    target = urllib.parse.urljoin(base, target)
                form = entry.get('searchForm') or {}
                if form:
                    query = {
                        str(name): expand(str(value))
                        for name, value in form.items()
                        if str(value)
                    }
                    if query:
                        joiner = '&' if '?' in target else '?'
                        target = target + joiner + urllib.parse.urlencode(query)
                search = target
            else:
                explore = legacy.get('explore') or []
                if explore:
                    first = explore[0]
                    target = expand(first)
                    search = target if ABSOLUTE_RE.match(target) else urllib.parse.urljoin(base, target)
        plan.append(
            {
                'name': entry['name'],
                'url': url,
                'kind': entry.get('kind'),
                'defaultEnabled': entry.get('defaultEnabled') is not False,
                'home': home,
                'search': search,
            }
        )
    return plan


def run(plan: list[dict], workers: int) -> list[dict]:
    def observe(url: str) -> dict:
        first = fetch(url)
        if first.get('status') is not None:
            first['attempts'] = 1
            return first
        second = fetch(url)
        second['attempts'] = 2
        second['first_error'] = first.get('error')
        return second

    def probe(item: dict) -> dict:
        result = dict(item)
        result['home_observation'] = observe(item['home'])
        result['search_observation'] = observe(item['search']) if item.get('search') else None
        result.pop('home')
        result.pop('search')
        log(f"{item['name']}: home={result['home_observation'].get('status')} "
            f"search={(result['search_observation'] or {}).get('status')}")
        return result

    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(probe, plan))


def summarize(rows: list[dict]) -> dict:
    text = [r for r in rows if r['kind'] == 'text']
    audio = [r for r in rows if r['kind'] != 'text']

    def ok(row: dict) -> bool:
        return (row.get('status') or 0) == 200

    return {
        'sources': len(rows),
        'text': len(text),
        'audio': len(audio),
        'home_200': sum(1 for r in rows if ok(r['home_observation'])),
        'search_200': sum(1 for r in text if r.get('search_observation') and ok(r['search_observation'])),
        'text_without_search': sum(1 for r in text if not r.get('search_observation')),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--workers', type=int, default=WORKERS)
    args = parser.parse_args()
    archive = ROOT / 'assets/catalogs/books/legado/catalog.json.bz2'
    plan = build_plan()
    started = datetime.now(timezone.utc)
    rows = run(plan, max(1, min(args.workers, 16)))
    finished = datetime.now(timezone.utc)
    evidence = {
        'schema': 'legado-builtin-sources-recheck/1',
        'generated_at': finished.isoformat(),
        'started_at_utc': started.isoformat(),
        'completed_at_utc': finished.isoformat(),
        'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'verified_sha256': hashlib.sha256(VERIFIED.read_bytes()).hexdigest(),
        'keyword': KEYWORD,
        'method': {
            'request': 'anonymous same-host HTTPS GET',
            'follow_redirect': False,
            'send_credentials': False,
            'submit_post': False,
            'body_limit_bytes': MAX_BYTES,
            'timeout_seconds': TIMEOUT,
            'network_error_attempts': 2,
        },
        'summary': summarize(rows),
        'results': rows,
        'limitations': [
            'HTTP status and page title only; a search page returning 200 does not prove results parse.',
            'No POST, credentials, redirects or subresources were used; bot gates may answer 403 to this probe.',
            'A failure today does not prove permanent death; a 200 does not prove safety or readability.',
        ],
    }
    if args.build:
        OUTPUT.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print('wrote', OUTPUT)
    print(json.dumps(evidence['summary'], ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
