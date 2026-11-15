"""Recheck only bundled hosts without a HEAD response in an earlier audit.

Uses the catalog probe's public-address pinning, TLS and absolute deadline.
Windows DNS status checks are bounded, bypass cache, and never follow URLs.
No source rules, page scripts, external links or executables are run.
"""

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
from pathlib import Path
import queue
import re
import sys
import threading
import time

if __package__:
    from .audit_legado_catalog import CATALOG, inventory, probe
else:
    from audit_legado_catalog import CATALOG, inventory, probe


DNS_NAME_ERROR = 9003
DNS_NO_RECORDS = 9501
DNS_FLAGS = 0x00000008 | 0x00000040  # bypass cache and hosts file
DNS_TASKS = queue.Queue()
DNS_INIT = threading.Lock()
DNS_STARTED = False


class DnsRecord(ctypes.Structure):
    _fields_ = [('next_record', ctypes.c_void_p), ('name', ctypes.c_void_p),
                ('record_type', wintypes.WORD), ('data_length', wintypes.WORD),
                ('flags', wintypes.DWORD), ('ttl', wintypes.DWORD),
                ('reserved', wintypes.DWORD), ('data', ctypes.c_ubyte * 16)]


def _address_kinds(first_record):
    """Count address types without retaining or connecting to the addresses."""
    counts = Counter()
    current = first_record
    seen = set()
    while current and current not in seen and len(seen) < 256:
        seen.add(current)
        record = DnsRecord.from_address(current)
        if record.record_type in (1, 28):
            size = 4 if record.record_type == 1 else 16
            address = ipaddress.ip_address(ctypes.string_at(current + DnsRecord.data.offset, size))
            kind = ('unspecified' if address.is_unspecified else
                    'public' if address.is_global and not address.is_multicast and not address.is_reserved
                    else 'other_non_public')
            counts[kind] += 1
        current = record.next_record
    return dict(counts)


def classification(result):
    status = result.get('status')
    if status is not None:
        if status == 200:
            return 'http_200'
        if 300 <= status < 400:
            return 'http_redirect'
        if status in (401, 403, 429):
            return 'http_restricted'
        return 'http_other'
    error = result.get('error', '')
    if error.startswith('dns:'):
        code = re.search(r'Errno (\d+)', error)
        return {'11001': 'dns_host_not_found', '11004': 'dns_no_data',
                '11002': 'dns_temporary_failure'}.get(code.group(1) if code else '', 'dns_other')
    if error.startswith('TimeoutError: DNS'):
        return 'dns_timeout'
    if error.startswith('TimeoutError:'):
        return 'connection_or_read_timeout'
    if error.startswith(('SSLCertVerificationError:', 'SSLError:', 'SSLEOFError:')):
        return 'tls_error'
    if error.startswith(('ConnectionRefusedError:', 'ConnectionResetError:', 'RemoteDisconnected:')):
        return 'connection_error'
    if error.startswith('ValueError: DNS includes a non-public address'):
        return 'non_public_dns_rejected'
    return 'other_error'


def dns_verdict(observations):
    """Only repeated wire-query NAME_ERROR without any A/AAAA success counts."""
    if any(0 in (item.get('a'), item.get('aaaa')) for item in observations):
        return 'dns_reply_seen'
    if len(observations) != 2 or any('error' in item for item in observations):
        return 'unconfirmed'
    codes = [[item.get('a'), item.get('aaaa')] for item in observations]
    if all(DNS_NAME_ERROR in pair and all(x in (DNS_NAME_ERROR, DNS_NO_RECORDS) for x in pair)
           for pair in codes):
        return 'repeated_nxdomain'
    if all(all(x == DNS_NO_RECORDS for x in pair) for pair in codes):
        return 'repeated_no_records'
    return 'inconclusive'


def _windows_dns_query(host):
    api = ctypes.WinDLL('dnsapi', use_last_error=True)
    query = api.DnsQuery_W
    query.argtypes = [wintypes.LPCWSTR, wintypes.WORD, wintypes.DWORD, ctypes.c_void_p,
                      ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
    query.restype = wintypes.LONG
    free = api.DnsRecordListFree
    free.argtypes = [ctypes.c_void_p, ctypes.c_int]
    free.restype = None
    answer = {'observed_at': datetime.now(timezone.utc).isoformat()}
    for name, kind in (('a', 1), ('aaaa', 28)):
        records = ctypes.c_void_p()
        answer[name] = query(host, kind, DNS_FLAGS, None, ctypes.byref(records), None)
        try:
            answer[name + '_address_kinds'] = _address_kinds(records.value)
        finally:
            if records:
                free(records, 1)  # DnsFreeRecordList
    return answer


def _dns_worker():
    while True:
        host, deadline, event, result = DNS_TASKS.get()
        try:
            if time.monotonic() < deadline:
                result.append(_windows_dns_query(host))
        except (OSError, ValueError) as error:
            result.append({'error': type(error).__name__ + ': ' + str(error)})
        finally:
            event.set()
            DNS_TASKS.task_done()


def _dns_round(host, timeout):
    global DNS_STARTED
    with DNS_INIT:
        if not DNS_STARTED:
            for _ in range(12):
                threading.Thread(target=_dns_worker, daemon=True).start()
            DNS_STARTED = True
    event, result = threading.Event(), []
    observed = datetime.now(timezone.utc).isoformat()
    DNS_TASKS.put((host, time.monotonic() + timeout, event, result))
    if not event.wait(timeout) or not result:
        return {'observed_at': observed, 'error': 'DNS query deadline exceeded'}
    return result[0]


def run_batch(hosts, worker, workers, label):
    results = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(worker, host): host for host in hosts}
        for completed in as_completed(jobs):
            host = jobs[completed]
            results[host] = completed.result()
            if len(results) % 100 == 0 or len(results) == len(jobs):
                print(f'{label}: {len(results)}/{len(jobs)}', flush=True)
    return results


def source_index(imported):
    result = defaultdict(list)
    for source in imported['selected_sources']:
        result[source['host']].append(source['id'])
    return {host: sorted(ids) for host, ids in result.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first_audit', type=Path)
    parser.add_argument('import_inventory', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--workers', type=int, choices=range(1, 33), default=24)
    parser.add_argument('--timeout', type=float, default=6)
    parser.add_argument('--dns-timeout', type=float, default=8)
    parser.add_argument('--sample-html', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('explicit DNS result codes require Windows DNS client API')
    if not (1 <= args.timeout <= 15 and 1 <= args.dns_timeout <= 15):
        parser.error('timeouts must be in 1..15 seconds')
    _, catalog_hosts, _, _, manifest = inventory(CATALOG)
    first_bytes = args.first_audit.read_bytes()
    first = json.loads(first_bytes)
    inventory_bytes = args.import_inventory.read_bytes()
    imported = json.loads(inventory_bytes)
    if any(doc['archive_sha256'] != manifest['archiveSha256'] for doc in (first, imported)):
        raise ValueError('input archive digest mismatch')
    previous = {row['host']: row for row in first['results'] if 'status' not in row}
    if len(previous) != sum('status' not in row for row in first['results']):
        raise ValueError('duplicate failed host in previous audit')
    if any(host not in catalog_hosts for host in previous):
        raise ValueError('previous audit contains host outside pinned catalog')
    hosts = sorted(previous)
    print(f'rechecking exactly {len(hosts)} prior hosts without HEAD', flush=True)
    retries = run_batch(hosts, lambda h: probe(h, args.timeout, args.sample_html), args.workers, 'HEAD')
    for row in retries.values():
        row['classification'] = classification(row)
    dns_hosts = [host for host in hosts if retries[host]['classification'] in
                 ('dns_host_not_found', 'dns_no_data', 'dns_temporary_failure', 'dns_other', 'dns_timeout')]
    print(f'wire DNS verification for {len(dns_hosts)} unresolved hosts', flush=True)
    first_dns = run_batch(dns_hosts, lambda h: _dns_round(h, args.dns_timeout), 12, 'DNS 1')
    again = [host for host in dns_hosts
             if DNS_NAME_ERROR in (first_dns[host].get('a'), first_dns[host].get('aaaa'))
             or (first_dns[host].get('a') == DNS_NO_RECORDS
                 and first_dns[host].get('aaaa') == DNS_NO_RECORDS)]
    second_dns = run_batch(again, lambda h: _dns_round(h, args.dns_timeout), 12, 'DNS 2')
    sources = source_index(imported)
    rows = []
    for host in hosts:
        before = previous[host]
        item = {'host': host, 'record_indices': catalog_hosts[host],
                'selected_source_ids': sources.get(host, []),
                'previous': {'observed_at': before['observed_at'], 'error': before['error'],
                             'classification': classification(before)},
                'recheck': retries[host]}
        if host in first_dns:
            observations = [first_dns[host]]
            if host in second_dns:
                observations.append(second_dns[host])
            item['dns_observations'] = observations
            item['dns_verdict'] = dns_verdict(observations)
        rows.append(item)
    output = {'schema': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
              'archive_sha256': manifest['archiveSha256'],
              'first_audit_sha256': hashlib.sha256(first_bytes).hexdigest(),
              'import_inventory_sha256': hashlib.sha256(inventory_bytes).hexdigest(),
              'selected_source_count': len(imported['selected_sources']),
              'method': 'HTTPS HEAD, optional bounded HTML GET, no redirects; previous-no-HEAD hosts only',
              'timeout_seconds': args.timeout, 'sample_html': args.sample_html,
              'dns_method': 'Windows DnsQuery_W A/AAAA, bypass cache/hosts; repeated NAME_ERROR is resolver-observed NXDOMAIN',
              'summary': {'hosts': len(rows),
                          'first_classifications': dict(Counter(r['previous']['classification'] for r in rows)),
                          'recheck_classifications': dict(Counter(r['recheck']['classification'] for r in rows)),
                          'dns_verdicts': dict(Counter(r.get('dns_verdict', 'not_checked') for r in rows)),
                          'source_ids_covered': len({ident for row in rows for ident in row['selected_source_ids']})},
              'results': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps(output['summary'], ensure_ascii=False), flush=True)
    print(f'wrote {args.output}', flush=True)


if __name__ == '__main__':
    main()
