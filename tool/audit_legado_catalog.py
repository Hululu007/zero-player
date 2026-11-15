"""Inventory and cautiously probe the bundled Legado hosts without running rules.

Only HTTPS / is requested, with redirects disabled. DNS answers must all be
public and the socket connects to a validated address, not a second lookup.
The optional GET sample never loads resources and reads at most 32 KiB of HTML.
Results are observations, not an assessment that a source is safe or usable.
"""

import argparse
import bz2
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import http.client
import ipaddress
import json
from pathlib import Path
import re
import queue
import socket
import ssl
import threading
import time
from urllib.parse import urljoin, urlsplit


CATALOG = Path('assets/catalogs/books/legado')
HOST_RE = re.compile(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$')
OPTIONS = re.compile(r',\s*\{')
CONTROLS = re.compile(r'[\x00-\x20\x7f\\]')
PARKED = ('hugedomains.com', 'sedo.com', 'godaddy.com', 'domainmarket.com',
          'dan.com', 'afternic.com', 'above.com', 'parkingcrew.net')
BETTING = ('在线博彩', '博彩平台', '博彩网站', '网上赌场', '在线赌场', '真人百家乐',
           '体育投注', '体育博彩', '赌博平台', '赌场官网', '澳门赌场', '六合彩',
           '赌博网站', '线上赌场', '棋牌投注')
ADULT = ('成人视频', '国产自拍', '成人小说', '成人漫画', '十八禁', '色情小说',
         '色情漫画', '色情视频', '成人视频', '情色小说', '成人网站')
MAX_SAMPLE = 32768
TLS = ssl.create_default_context()
DNS_QUEUE = queue.Queue()
DNS_LOCK = threading.Lock()
DNS_STARTED = False


def address_part(value):
    if not isinstance(value, str):
        return ''
    return OPTIONS.split(value, maxsplit=1)[0].strip()


def hostname(value, *, allow_alias=False):
    """Use the app's HTTPS/default-port and public-domain input boundaries."""
    value = address_part(value)
    # Fragments can contain Legado identity labels and are never sent to hosts.
    value = value.split('#', 1)[0]
    if not value or CONTROLS.search(value) or len(value) > 2048:
        return None
    if allow_alias and '://' not in value and re.match(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:[/?#]|$)', value, re.I):
        value = 'https://' + value
    value = re.sub(r'\{\{.*?\}\}', 'test', value)
    try:
        parts = urlsplit(value)
        host = (parts.hostname or '').lower()
        if (parts.scheme not in ('http', 'https') or parts.username is not None
                or parts.password is not None or not HOST_RE.fullmatch(host)
                or parts.port not in (None, 80 if parts.scheme == 'http' else 443)
                or host.endswith(('.localhost', '.local', '.internal', '.home.arpa'))):
            return None
        return host
    except ValueError:
        return None


def inventory(folder):
    manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
    archive = (folder / 'catalog.json.bz2').read_bytes()
    digest = hashlib.sha256(archive).hexdigest()
    if digest != manifest['archiveSha256']:
        raise ValueError('catalog archive SHA-256 does not match manifest')
    data = json.loads(bz2.decompress(archive))
    rows = data['records']
    if len(rows) != manifest['records']:
        raise ValueError('catalog record count does not match manifest')
    for pack in manifest['packs']:
        references = data['packs'][pack['id']]
        if len(references) != pack['count'] or any(not 0 <= i < len(rows) for i in references):
            raise ValueError(f"invalid pack references: {pack['id']}")
    hosts, unresolved, types = defaultdict(list), [], Counter()
    for index, row in enumerate(rows):
        kind = str(row.get('bookSourceType', 0))
        types[kind] += 1
        declared = address_part(row.get('bookSourceUrl', ''))
        host = hostname(declared, allow_alias=True)
        if not host and '://' not in declared:
            host = hostname(row.get('searchUrl', ''), allow_alias=True)
        if not host:
            unresolved.append(index)
        else:
            hosts[host].append(index)
    return rows, dict(hosts), unresolved, dict(types), manifest


def _dns_worker():
    while True:
        host, deadline, event, result = DNS_QUEUE.get()
        try:
            if time.monotonic() < deadline:
                result.append(socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM))
        except OSError as error:
            result.append(error)
        finally:
            event.set()
            DNS_QUEUE.task_done()


def _bounded_lookup(host, timeout):
    # getaddrinfo itself has no timeout. A fixed daemon pool bounds caller wait
    # and resource use, even if a system resolver hangs indefinitely.
    global DNS_STARTED
    with DNS_LOCK:
        if not DNS_STARTED:
            for _ in range(32):
                threading.Thread(target=_dns_worker, daemon=True).start()
            DNS_STARTED = True
    event, result = threading.Event(), []
    DNS_QUEUE.put((host, time.monotonic() + timeout, event, result))
    if not event.wait(timeout) or not result:
        raise TimeoutError('DNS deadline exceeded')
    if isinstance(result[0], OSError):
        raise result[0]
    return result[0]


def public_addresses(host, timeout=5):
    addresses = set()
    for family, _, _, _, target in _bounded_lookup(host, timeout):
        ip = ipaddress.ip_address(target[0].split('%')[0])
        if not ip.is_global or ip.is_multicast or ip.is_reserved:
            raise ValueError('DNS includes a non-public address')
        addresses.add((family, str(ip)))
    if not addresses:
        raise ValueError('DNS returned no address')
    return sorted(addresses, key=lambda item: item[0] != socket.AF_INET)


def destination(host, location):
    try:
        if not location.strip():
            return {'redirect': 'invalid'}
        parts = urlsplit(urljoin('https://' + host + '/', location))
        target = (parts.hostname or '').lower()
        if not target or parts.scheme not in ('http', 'https'):
            return {'redirect': 'invalid'}
        result = {'redirect_host': target, 'redirect_scheme': parts.scheme}
        result['redirect'] = ('same_host' if host == target else
                              'parking' if any(target == x or target.endswith('.' + x) for x in PARKED)
                              else 'other_host')
        return result
    except ValueError:
        return {'redirect': 'invalid'}


class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = 0
        self.in_title = False
        self.title = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'noscript'):
            self.hidden += 1
        if tag == 'title':
            self.in_title = True

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'noscript') and self.hidden:
            self.hidden -= 1
        if tag == 'title':
            self.in_title = False

    def handle_data(self, text):
        if not self.hidden:
            self.text.append(text)
            if self.in_title:
                self.title.append(text)


def signals(payload, charset):
    if not charset:
        meta = re.search(rb'charset\s*=\s*["\']?([a-zA-Z0-9_-]+)', payload[:4096], re.I)
        charset = meta.group(1).decode('ascii') if meta else None
    encoding = (charset or 'utf-8').lower().strip(' "\'')
    if encoding not in ('utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030', 'big5'):
        encoding = 'utf-8'
    try:
        html = payload.decode(encoding, errors='replace')
    except LookupError:
        html = payload.decode('utf-8', errors='replace')
    parser = VisibleText()
    parser.feed(html)
    visible = ' '.join(parser.text)
    return {'title': ' '.join(' '.join(parser.title).split())[:160],
            'betting_signals': [word for word in BETTING if word in visible],
            'adult_signals': [word for word in ADULT if word in visible]}


class RequestDeadline:
    """Abort the active socket at one absolute deadline, even during trickle reads."""

    def __init__(self, deadline):
        self.deadline = deadline
        self.lock = threading.Lock()
        self.expired = threading.Event()
        self.active = None
        self.timer = threading.Timer(max(0, deadline - time.monotonic()), self._abort)
        self.timer.daemon = True

    def __enter__(self):
        self.timer.start()
        return self

    def __exit__(self, *_):
        self.timer.cancel()
        with self.lock:
            self.active = None

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0 or self.expired.is_set():
            raise TimeoutError('overall request deadline exceeded')
        return remaining

    def attach(self, connection):
        with self.lock:
            self.remaining()
            self.active = connection

    def wrap(self, connection, host):
        # Transfer ownership while holding the lock, so the timer cannot try
        # to close the detached plain socket during the TLS transition.
        with self.lock:
            self.remaining()
            secure = TLS.wrap_socket(connection, server_hostname=host,
                                     do_handshake_on_connect=False)
            self.active = secure
            return secure

    def _abort(self):
        self.expired.set()
        with self.lock:
            if self.active is not None:
                try:
                    self.active.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass


def fetch(host, method, timeout, path='/'):
    """Connect to vetted numeric DNS answers within one end-to-end deadline."""
    deadline = time.monotonic() + timeout
    addresses = public_addresses(host, timeout)
    last = None
    with RequestDeadline(deadline) as limit:
        for family, address in addresses[:3]:
            try:
                with socket.socket(family, socket.SOCK_STREAM) as plain:
                    limit.attach(plain)
                    plain.settimeout(limit.remaining())
                    plain.connect((address, 443))
                    with limit.wrap(plain, host) as connection:
                        connection.settimeout(limit.remaining())
                        connection.do_handshake()
                        connection.settimeout(limit.remaining())
                        result = _read_response(connection, host, method, path, limit)
                        limit.remaining()
                        return result
            except (OSError, http.client.HTTPException) as error:
                # Shutdown may produce EOF or a protocol error; report it as a
                # deadline instead of accepting a truncated partial sample.
                limit.remaining()
                last = error
    if last:
        raise last
    raise TimeoutError('overall request deadline exceeded')


def _read_response(connection, host, method, path, limit):
    request = (f'{method} {path} HTTP/1.1\r\nHost: {host}\r\n'
               'User-Agent: ZeroPlayer-SourceAudit/1.0\r\n'
               'Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.1\r\n'
               'Accept-Encoding: identity\r\nConnection: close\r\n\r\n')
    connection.sendall(request.encode('ascii'))
    response = http.client.HTTPResponse(connection)
    try:
        response.begin()
        limit.remaining()
        result = {'status': response.status}
        if response.status in (301, 302, 303, 307, 308):
            result.update(destination(host, response.getheader('Location', '')))
        if method == 'GET' and response.status == 200:
            content_type = response.getheader('Content-Type', '').lower()
            encoding = response.getheader('Content-Encoding', '').lower()
            if ('text/html' in content_type or 'application/xhtml+xml' in content_type) and encoding in ('', 'identity'):
                charset = re.search(r'charset\s*=\s*([^;]+)', content_type)
                sample = response.read(MAX_SAMPLE)
                limit.remaining()
                result.update(signals(sample, charset.group(1) if charset else None))
                result['sample_bytes'] = len(sample)
            else:
                result['sample_skipped'] = 'non-html or encoded response'
        return result
    finally:
        response.close()


def probe(host, timeout, sample, path='/'):
    result = {'host': host, 'observed_at': datetime.now(timezone.utc).isoformat()}
    try:
        result.update(fetch(host, 'HEAD', timeout, path))
    except (OSError, ValueError, http.client.HTTPException) as error:
        result['error'] = _error_text(error)
    if sample and result.get('status') == 200:
        try:
            result['sample'] = fetch(host, 'GET', timeout, path)
        except (OSError, ValueError, http.client.HTTPException) as error:
            result['sample'] = {'error': _error_text(error)}
    return result


def _error_text(error):
    return ('dns: ' if isinstance(error, socket.gaierror) else type(error).__name__ + ': ') + str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='output JSON path')
    parser.add_argument('--workers', type=int, choices=range(1, 49), default=32)
    parser.add_argument('--timeout', type=float, default=5.0)
    parser.add_argument('--sample-html', action='store_true', help='GET at most 32 KiB of root HTML after HEAD 200')
    parser.add_argument('--host', action='append', default=[], help='limit to exact catalog host (repeatable)')
    parser.add_argument('--limit', type=int, help='limit sorted catalog hosts')
    parser.add_argument('--path', default='/', help='explicit static path without query for selected catalog hosts')
    args = parser.parse_args()
    if not 1 <= args.timeout <= 15 or (args.limit is not None and args.limit < 1):
        parser.error('timeout must be 1..15 seconds; limit must be positive')
    if (not re.fullmatch(r'/[a-zA-Z0-9._~/-]*', args.path)
            or '//' in args.path or any(part in ('.', '..') for part in args.path.split('/'))
            or len(args.path) > 512 or (args.path != '/' and not args.host)):
        parser.error('a non-root static path requires explicit hosts and cannot contain a query or traversal')
    rows, hosts, unresolved, kinds, manifest = inventory(CATALOG)
    selected = sorted(hosts)
    if args.host:
        missing = sorted(set(args.host) - hosts.keys())
        if missing:
            parser.error('not catalog hosts: ' + ', '.join(missing))
        selected = sorted(set(args.host))
    if args.limit:
        selected = selected[:args.limit]
    print(f'{len(rows)} raw distinct records, {len(hosts)} resolved input hosts, '
          f'{len(unresolved)} records without a probeable host; probing {len(selected)}', flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(probe, host, args.timeout, args.sample_html, args.path): host for host in selected}
        for done in as_completed(jobs):
            result = done.result()
            result['record_indices'] = hosts[result['host']]
            results.append(result)
            if len(results) % 100 == 0 or len(results) == len(jobs):
                print(f'probed {len(results)}/{len(jobs)}', flush=True)
    payload = {'schema': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
               'archive_sha256': manifest['archiveSha256'], 'records': len(rows),
               'pack_rows': sum(pack['count'] for pack in manifest['packs']),
               'record_kinds': kinds, 'distinct_hosts': len(hosts),
               'unresolved_record_indices': unresolved,
               'method': 'HEAD https://host + path; optional bounded GET HTML; no redirects or script execution',
               'path': args.path,
               'sample_html': args.sample_html, 'results': sorted(results, key=lambda r: r['host'])}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'wrote {args.output}', flush=True)


if __name__ == '__main__':
    main()
