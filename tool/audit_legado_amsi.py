"""Safely sample previously observed Legado HTML and scan bytes through AMSI.

Only anonymous HTTPS root requests are made, with validated public DNS answers
pinned to the TCP connection, no redirects, scripts or subresources. Sample
bytes stay in memory and are sent only to a local, time-limited AMSI worker.
The installed antimalware provider may use cloud protection or sample upload.
Neither an AMSI detection nor a negative result establishes whole-site status.
"""

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import ctypes
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import http.client
import json
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

if __package__:
    from .audit_legado_catalog import CATALOG, RequestDeadline, TLS, hostname, inventory, public_addresses
    from .triage_legado_eval_candidates import selected_indices
else:
    from audit_legado_catalog import CATALOG, RequestDeadline, TLS, hostname, inventory, public_addresses
    from triage_legado_eval_candidates import selected_indices


MAX_SAMPLE = 32768
MAX_SCRIPTS = 6
MAX_SCRIPT_BYTES = 8192
SCAN_TIMEOUT = 15
ADMIN_START, ADMIN_END, DETECTED = 0x4000, 0x4FFF, 0x8000


def now():
    return datetime.now(timezone.utc).isoformat()


def classify_scan(hresult, value):
    if hresult != 0 or value is None:
        return 'scan_error'
    if value >= DETECTED:
        return 'detected'
    if ADMIN_START <= value <= ADMIN_END:
        return 'blocked_by_admin'
    if value in (0, 1):
        return 'not_detected'
    return 'provider_risk_score'


def amsi_scan(payload):
    """Call AMSI in a subprocess; no source or page content is persisted."""
    dll = ctypes.WinDLL('amsi.dll')
    dll.AmsiInitialize.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_void_p)]
    dll.AmsiInitialize.restype = ctypes.c_long
    dll.AmsiScanBuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong,
                                   ctypes.c_wchar_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    dll.AmsiScanBuffer.restype = ctypes.c_long
    dll.AmsiUninitialize.argtypes = [ctypes.c_void_p]
    dll.AmsiUninitialize.restype = None
    context, value = ctypes.c_void_p(), ctypes.c_uint32()
    hr = dll.AmsiInitialize('ZeroPlayer public HTML audit', ctypes.byref(context)) & 0xFFFFFFFF
    if hr:
        return {'phase': 'initialize', 'hresult': f'0x{hr:08X}',
                'amsi_result': None, 'classification': 'scan_error'}
    try:
        buffer = ctypes.create_string_buffer(payload, len(payload))
        hr = dll.AmsiScanBuffer(context, buffer, len(payload), 'public-html-sample',
                                None, ctypes.byref(value)) & 0xFFFFFFFF
        raw = value.value if hr == 0 else None
        return {'phase': 'scan', 'hresult': f'0x{hr:08X}',
                'amsi_result': raw, 'classification': classify_scan(hr, raw)}
    finally:
        dll.AmsiUninitialize(context)


def worker_error(failure, count, **extra):
    return [{'phase': 'worker', 'classification': 'scan_error', 'failure': failure,
             'hresult': None, 'amsi_result': None, **extra} for _ in range(count)]


def scan_many_in_worker(payloads):
    if not 1 <= len(payloads) <= MAX_SCRIPTS + 1 or any(not x or len(x) > MAX_SAMPLE for x in payloads):
        raise ValueError('invalid AMSI worker input')
    wire = struct.pack('>I', len(payloads)) + b''.join(struct.pack('>I', len(x)) + x for x in payloads)
    try:
        process = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--amsi-batch-worker'],
                                 input=wire, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 timeout=SCAN_TIMEOUT, check=False)
        if process.returncode:
            return worker_error('worker_exit', len(payloads), exit_code=process.returncode)
        results = json.loads(process.stdout)
        if not isinstance(results, list) or len(results) != len(payloads):
            raise ValueError('invalid scan result count')
        for result in results:
            if result.get('classification') != classify_scan(int(result['hresult'], 16), result['amsi_result']):
                raise ValueError('invalid scan response')
        return results
    except subprocess.TimeoutExpired:
        return worker_error('worker_timeout', len(payloads))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return worker_error('worker_error', len(payloads))


def controls():
    clean = b'<html><body>Public sample control.</body></html>'
    # Reconstruct the industry-standard harmless test sample only in memory.
    positive = b'X5O!P%@AP[4\\PZX54(P^)7CC)7}' + b'$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
    inline = b'var x="' + positive + b'";'
    wrapped = b'<html><script>' + inline + b'</script></html>'
    negative_result, positive_result, wrapped_result, inline_result = scan_many_in_worker(
        [clean, positive, wrapped, inline])
    return {'observed_at': now(), 'negative': negative_result, 'eicar': positive_result,
            'html_wrapped_eicar': wrapped_result, 'inline_script_with_eicar': inline_result,
            'passed': (negative_result['classification'] == 'not_detected'
                       and positive_result['classification'] == 'detected')}


class InlineScripts(HTMLParser):
    """Extract bounded script text without fetching resources or executing it."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.tags, self.nonempty = 0, 0
        self.current, self.samples = None, []

    def handle_starttag(self, tag, attrs):
        if tag == 'script' and self.current is None:
            self.tags += 1
            self.current = {'ordinal': self.tags, 'has_src_attribute': any(k == 'src' for k, _ in attrs),
                            'bytes_seen': 0, 'data': bytearray()}

    def handle_data(self, value):
        if self.current is not None:
            raw = value.encode('latin-1')
            self.current['bytes_seen'] += len(raw)
            room = MAX_SCRIPT_BYTES - len(self.current['data'])
            self.current['data'].extend(raw[:max(0, room)])

    def handle_endtag(self, tag):
        if tag == 'script' and self.current is not None:
            self.finish_script(True)

    def finish_script(self, closed):
        item, self.current = self.current, None
        if item['bytes_seen']:
            self.nonempty += 1
            if len(self.samples) < MAX_SCRIPTS:
                payload = bytes(item.pop('data'))
                item.update({'sample_bytes': len(payload), 'sample_sha256': hashlib.sha256(payload).hexdigest(),
                             'truncated': item['bytes_seen'] > len(payload) or not closed,
                             'closing_tag_observed': closed})
                self.samples.append((item, payload))


def extract_inline_scripts(payload):
    parser = InlineScripts()
    # Latin-1 preserves the original bytes; HTML tags must be ASCII-compatible.
    parser.feed(payload.decode('latin-1'))
    parser.close()
    if parser.current is not None:
        parser.finish_script(False)
    return {'script_tags_observed': parser.tags, 'nonempty_inline_scripts_observed': parser.nonempty,
            'inline_scripts_selected': len(parser.samples),
            'inline_scripts_omitted': parser.nonempty - len(parser.samples)}, parser.samples


class RateLimiter:
    def __init__(self, interval, clock=time.monotonic, sleep=time.sleep):
        self.interval, self.clock, self.sleep = interval, clock, sleep
        self.lock = threading.Lock()
        self.next_start = None

    def wait(self):
        with self.lock:
            delay = max(0, (self.next_start or 0) - self.clock())
            if delay:
                self.sleep(delay)
            self.next_start = self.clock() + self.interval


def sample_response(connection, host, limit):
    request = (f'GET / HTTP/1.1\r\nHost: {host}\r\n'
               'User-Agent: ZeroPlayer-SourceAudit/1.0\r\n'
               'Accept: text/html,application/xhtml+xml;q=0.9\r\n'
               'Accept-Encoding: identity\r\nConnection: close\r\n\r\n')
    connection.sendall(request.encode('ascii'))
    response = http.client.HTTPResponse(connection)
    try:
        response.begin()
        limit.remaining()
        result = {'http_status': response.status}
        if response.status != 200:
            result['failure'] = 'redirect_not_followed' if 300 <= response.status < 400 else 'http_status'
            return result, None
        content_type = response.getheader('Content-Type', '').lower().split(';', 1)[0].strip()
        encoding = response.getheader('Content-Encoding', '').lower().strip()
        result['content_type'] = content_type if content_type in ('text/html', 'application/xhtml+xml') else 'other'
        if content_type not in ('text/html', 'application/xhtml+xml') or encoding not in ('', 'identity'):
            result['failure'] = 'non_html_or_encoded'
            return result, None
        payload = response.read(MAX_SAMPLE + 1)
        limit.remaining()
        result['truncated'] = len(payload) > MAX_SAMPLE
        payload = payload[:MAX_SAMPLE]
        result.update({'sample_bytes': len(payload), 'sample_sha256': hashlib.sha256(payload).hexdigest()})
        if not payload:
            result['failure'] = 'empty_html'
            return result, None
        return result, payload
    finally:
        response.close()


def fetch_root(host, timeout):
    if hostname('https://' + host) != host:
        raise ValueError('invalid catalog host')
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
                        result = sample_response(connection, host, limit)
                        limit.remaining()
                        return result
            except (OSError, http.client.HTTPException) as error:
                limit.remaining()
                last = error
    if last:
        raise last
    raise TimeoutError('request deadline exceeded')


def failure_category(error):
    if isinstance(error, socket.gaierror):
        return 'dns_error'
    if isinstance(error, (TimeoutError, socket.timeout)):
        return 'timeout'
    if isinstance(error, ssl.SSLError):
        return 'tls_error'
    if isinstance(error, ValueError):
        return 'invalid_host_or_non_public_address'
    if isinstance(error, http.client.HTTPException):
        return 'http_transport_error'
    return 'connection_error'


def inspect(entry, limiter, timeout):
    limiter.wait()
    result = {'host': entry['host'], 'record_indices': entry['record_indices'],
              'selected_source_ids': entry['selected_source_ids'], 'started_at': now()}
    try:
        fetched, payload = fetch_root(entry['host'], timeout)
        result.update(fetched)
        result['sample_observed_at'] = now()
        if payload is not None:
            try:
                script_stats, scripts = extract_inline_scripts(payload)
            except (ValueError, AssertionError):
                script_stats, scripts = {'failure': 'html_parser_error'}, []
            scans = scan_many_in_worker([payload] + [sample for _, sample in scripts])
            result['amsi'] = scans[0]
            result['inline_scripts'] = {**script_stats,
                                        'samples': [{**meta, 'amsi': scan}
                                                    for (meta, _), scan in zip(scripts, scans[1:])]}
    except (OSError, ValueError, http.client.HTTPException) as error:
        result['failure'] = failure_category(error)
        result['sample_observed_at'] = now()
    return result


def defender_status():
    command = ("Get-MpComputerStatus | Select-Object AMRunningMode,AntivirusEnabled,AntivirusSignatureVersion,"
               "@{Name='AntivirusSignatureLastUpdated';Expression={$_.AntivirusSignatureLastUpdated.ToUniversalTime().ToString('o')}},"
               "AMProductVersion | ConvertTo-Json -Compress")
    try:
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command],
                                capture_output=True, timeout=15, check=True)
        return json.loads(result.stdout.decode('utf-8-sig'))
    except (OSError, subprocess.SubprocessError, ValueError):
        return {'failure': 'defender_status_unavailable'}


def select_entries(previous, imported, rows, manifest):
    if any(x['archive_sha256'] != manifest['archiveSha256'] for x in (previous, imported)):
        raise ValueError('audit and importer evidence must use this catalog archive')
    parsed, selected = selected_indices(rows, imported)
    by_host = defaultdict(list)
    for ident, index in selected.items():
        by_host[parsed[index]['host']].append(ident)
    entries = []
    for row in previous['results']:
        entries.append({'host': row['host'], 'record_indices': row['record_indices'],
                        'previous_html_sample': 'sample_bytes' in row.get('sample', {}),
                        'selected_source_ids': sorted(by_host[row['host']])})
    if len(entries) != len({x['host'] for x in entries}):
        raise ValueError('duplicate previous audit hosts')
    return sorted(entries, key=lambda x: (not x['previous_html_sample'], x['host']))


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temp.replace(path)


def run(args):
    previous_bytes, imported_bytes = args.previous.read_bytes(), args.import_inventory.read_bytes()
    previous, imported = json.loads(previous_bytes), json.loads(imported_bytes)
    rows, _, _, _, manifest = inventory(CATALOG)
    entries = select_entries(previous, imported, rows, manifest)
    chosen = entries[args.offset:args.offset + args.count]
    result = {'method': 'Anonymous HTTPS GET /, all DNS answers must be public and TCP uses a validated IP; TLS hostname checked; no redirects, credentials, scripts or subresources.',
              'scope': 'All previously inventoried bundled Legado hosts, with previously sampled HTML hosts first. A fresh bounded root-page prefix and bounded inline script text are scanned; linked scripts and downloaded files are not fetched. No whole-site malware conclusion.',
              'privacy': 'Page bodies are held in memory only and are not saved by this tool; the installed AMSI antimalware provider may use cloud protection or sample submission under its existing settings. The tool does not submit bookcase data or credentials.',
              'archive_sha256': manifest['archiveSha256'],
              'prior_audit_sha256': hashlib.sha256(previous_bytes).hexdigest(),
              'import_inventory_sha256': hashlib.sha256(imported_bytes).hexdigest(),
              'total_hosts': len(entries), 'prior_html_hosts': sum(x['previous_html_sample'] for x in entries),
              'offset': args.offset, 'requested_hosts': len(chosen),
              'workers': args.workers, 'minimum_request_start_interval_seconds': args.interval,
              'network_deadline_seconds': args.timeout, 'amsi_worker_deadline_seconds': SCAN_TIMEOUT,
              'max_html_bytes': MAX_SAMPLE, 'max_inline_scripts_per_page': MAX_SCRIPTS,
              'max_inline_script_bytes': MAX_SCRIPT_BYTES,
              'inline_script_limitations': 'ASCII-compatible HTML parser over the bounded prefix; no external script fetch. Empty tags are counted but not scanned, later scripts and excess bytes are omitted; partial tags/scripts and encodings such as UTF-16 may not be recognized.',
              'started_at': now(), 'defender_status': defender_status(),
              'controls': controls(), 'results': []}
    if not result['controls']['passed']:
        result['failure'] = 'amsi_controls_failed_no_network_requests'
        save(args.output, result)
        raise RuntimeError('AMSI controls failed; no sites were contacted')
    limiter = RateLimiter(args.interval)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(inspect, entry, limiter, args.timeout) for entry in chosen]
        for future in as_completed(futures):
            result['results'].append(future.result())
            if len(result['results']) % 20 == 0:
                print(f"Completed {len(result['results'])}/{len(chosen)}", flush=True)
                save(args.output, result)
    result['results'].sort(key=lambda x: x['host'])
    result['completed_at'] = now()
    result['outcomes'] = dict(Counter(x.get('amsi', {}).get('classification', x.get('failure', 'unknown'))
                                      for x in result['results']))
    result['inline_script_outcomes'] = dict(Counter(s['amsi']['classification'] for x in result['results']
                                                    for s in x.get('inline_scripts', {}).get('samples', [])))
    save(args.output, result)
    print(json.dumps(result['outcomes'], ensure_ascii=False), flush=True)


def main():
    if sys.argv[1:] == ['--amsi-batch-worker']:
        maximum = MAX_SAMPLE + MAX_SCRIPTS * MAX_SCRIPT_BYTES + 4 * (MAX_SCRIPTS + 2)
        wire = sys.stdin.buffer.read(maximum + 1)
        if len(wire) > maximum or len(wire) < 4:
            raise ValueError('invalid AMSI worker input length')
        count, offset, payloads = struct.unpack_from('>I', wire)[0], 4, []
        if not 1 <= count <= MAX_SCRIPTS + 1:
            raise ValueError('invalid AMSI worker input count')
        for _ in range(count):
            length = struct.unpack_from('>I', wire, offset)[0]
            offset += 4
            if not 1 <= length <= MAX_SAMPLE or offset + length > len(wire):
                raise ValueError('invalid AMSI worker payload')
            payloads.append(wire[offset:offset + length])
            offset += length
        if offset != len(wire):
            raise ValueError('unexpected AMSI worker trailing data')
        print(json.dumps([amsi_scan(payload) for payload in payloads]))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--import-inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--offset', type=int, default=0)
    parser.add_argument('--count', type=int, default=6)
    parser.add_argument('--workers', type=int, choices=range(1, 9), default=2)
    parser.add_argument('--interval', type=float, default=0.5)
    parser.add_argument('--timeout', type=float, default=6)
    args = parser.parse_args()
    if args.offset < 0 or not 1 <= args.count <= 2500 or not 0.25 <= args.interval <= 10 or not 1 <= args.timeout <= 10:
        parser.error('invalid bounds: offset >= 0, count 1..2500, interval 0.25..10, timeout 1..10')
    run(args)


if __name__ == '__main__':
    main()
