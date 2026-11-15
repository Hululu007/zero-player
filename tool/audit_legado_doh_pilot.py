"""Bounded public DoH sample; never connects to catalog hosts or saves IPs."""
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import http.client
import ipaddress
import json
from pathlib import Path
import re
import secrets
import socket
import struct
import threading
import time

from tool.audit_legado_catalog import RequestDeadline, public_addresses

INPUT1 = Path('docs/implementation/legado-host-recheck-20261115.json')
INPUT2 = Path('docs/implementation/legado-dns-address-recheck-20261115.json')
OUTPUT = Path('build/doh-sample/observations.json')
PROVIDERS = {'aliyun': 'dns.alidns.com', 'tencent': 'doh.pub'}
TYPES = {'A': 1, 'AAAA': 28}
MAX_RESPONSE = 65536
gate = threading.Lock()
next_start = 0.0


def utc():
    return datetime.now(timezone.utc).isoformat()


def read_data(path):
    raw = path.read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def choose(data, tag, group, seed):
    selected = [r for r in data['results'] if r.get('dns_verdict', r.get('verdict')) == tag]
    eligible = [r for r in selected if r.get('selected_source_ids')]
    eligible.sort(key=lambda r: hashlib.sha256(f"{seed}:{group}:{r['host']}".encode()).digest())
    return [{'host': r['host'], 'baseline': group} for r in eligible[:10]], len(selected), len(eligible)


def name_wire(name):
    if not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*', name):
        raise ValueError('invalid catalog host')
    return b''.join(bytes([len(x)]) + x.encode('ascii') for x in name.split('.')) + b'\0'


def read_name(data, offset):
    labels, cursor, end, visited = [], offset, None, set()
    while True:
        if cursor >= len(data) or cursor in visited:
            raise ValueError('bad DNS name')
        visited.add(cursor)
        length = data[cursor]
        if length == 0:
            return '.'.join(labels), (end if end is not None else cursor + 1)
        if length & 0xc0 == 0xc0:
            if cursor + 1 >= len(data):
                raise ValueError('bad DNS pointer')
            if end is None:
                end = cursor + 2
            cursor = ((length & 0x3f) << 8) | data[cursor + 1]
        elif length & 0xc0 or cursor + 1 + length > len(data):
            raise ValueError('bad DNS label')
        else:
            labels.append(data[cursor + 1:cursor + 1 + length].decode('ascii').lower())
            cursor += length + 1
        if len(visited) > 128:
            raise ValueError('too many DNS labels')


def address_class(raw):
    ip = ipaddress.ip_address(raw)
    if ip.is_unspecified:
        return 'unspecified'
    if ip.is_loopback:
        return 'loopback'
    if ip.is_link_local:
        return 'link_local'
    if ip.is_multicast:
        return 'multicast'
    if ip.is_global:
        return 'public'
    if ip.is_private:
        return 'private_or_special'
    return 'reserved_or_other_non_public'


def parse_dns(data, expected_id, host, qtype):
    if len(data) < 12:
        raise ValueError('short DNS reply')
    ident, flags, qd, an, ns, ar = struct.unpack_from('!HHHHHH', data)
    if ident != expected_id or not flags & 0x8000 or flags & 0x7800 or qd != 1:
        raise ValueError('DNS response header mismatch')
    name, offset = read_name(data, 12)
    if offset + 4 > len(data):
        raise ValueError('truncated question')
    actual_type, qclass = struct.unpack_from('!HH', data, offset)
    if name != host or actual_type != qtype or qclass != 1:
        raise ValueError('DNS response question mismatch')
    offset += 4
    classes, ttls, negative_ttls = Counter(), [], []
    for idx in range(an + ns + ar):
        _, offset = read_name(data, offset)
        if offset + 10 > len(data):
            raise ValueError('truncated record')
        typ, cls, ttl, length = struct.unpack_from('!HHIH', data, offset)
        offset += 10
        end = offset + length
        if end > len(data):
            raise ValueError('truncated record data')
        if idx < an and cls == 1 and typ == qtype:
            if (typ == 1 and length != 4) or (typ == 28 and length != 16):
                raise ValueError('invalid address length')
            classes[address_class(data[offset:end])] += 1
            ttls.append(ttl)
        if an <= idx < an + ns and cls == 1 and typ == 6:
            _, pos = read_name(data, offset)
            _, pos = read_name(data, pos)
            if pos + 20 <= end:
                negative_ttls.append(min(ttl, struct.unpack_from('!IIIII', data, pos)[4]))
        offset = end
    status = flags & 15
    return {'dns_rcode': status, 'dns_truncated': bool(flags & 0x0200),
            'dnssec_authenticated': bool(flags & 0x0020), 'address_categories': dict(classes),
            'address_ttls_seconds': sorted(ttls), 'negative_ttls_seconds': sorted(negative_ttls),
            'classification': ('truncated' if flags & 0x0200 else
                               'nxdomain' if status == 3 else
                               'noerror_addresses' if status == 0 and classes else
                               'noerror_no_address' if status == 0 else
                               'servfail' if status == 2 else
                               'refused' if status == 5 else 'other_dns_rcode'),
            'response_sha256': hashlib.sha256(data).hexdigest()}


def limited_start():
    global next_start
    with gate:
        delay = max(0, next_start - time.monotonic())
        if delay:
            time.sleep(delay)
        next_start = time.monotonic() + 0.3


def send(provider_host, message, timeout):
    deadline = time.monotonic() + timeout
    addresses = public_addresses(provider_host, timeout)
    last = None
    with RequestDeadline(deadline) as limit:
        for family, address in addresses[:2]:
            try:
                with socket.socket(family, socket.SOCK_STREAM) as plain:
                    limit.attach(plain)
                    plain.settimeout(limit.remaining())
                    plain.connect((address, 443))
                    with limit.wrap(plain, provider_host) as secure:
                        secure.settimeout(limit.remaining())
                        secure.do_handshake()
                        secure.settimeout(limit.remaining())
                        head = (f'POST /dns-query HTTP/1.1\r\nHost: {provider_host}\r\n'
                                f'Content-Type: application/dns-message\r\nAccept: application/dns-message\r\n'
                                f'Content-Length: {len(message)}\r\nConnection: close\r\n\r\n').encode('ascii')
                        secure.sendall(head + message)
                        response = http.client.HTTPResponse(secure)
                        try:
                            response.begin()
                            limit.remaining()
                            if response.status != 200:
                                return response.status, None
                            if response.getheader('Content-Type', '').split(';')[0].strip().lower() != 'application/dns-message':
                                raise ValueError('unexpected DoH content type')
                            data = response.read(MAX_RESPONSE + 1)
                            limit.remaining()
                            if len(data) > MAX_RESPONSE:
                                raise ValueError('DoH response exceeds limit')
                            return response.status, data
                        finally:
                            response.close()
            except (OSError, http.client.HTTPException) as error:
                limit.remaining()
                last = error
    if last:
        raise last
    raise TimeoutError('request deadline')


def one(sample, provider, qlabel):
    limited_start()
    started = utc()
    result = {'host': sample['host'], 'baseline': sample['baseline'], 'provider': provider,
              'query_type': qlabel, 'started_at': started}
    ident = secrets.randbelow(65536)
    message = struct.pack('!HHHHHH', ident, 0x0100, 1, 0, 0, 0) + name_wire(sample['host']) + struct.pack('!HH', TYPES[qlabel], 1)
    try:
        http_status, data = send(PROVIDERS[provider], message, 6)
        result['http_status'] = http_status
        if data is None:
            result['classification'] = 'provider_http_blocked' if http_status in (401, 403, 451) else 'provider_http_error'
        else:
            result.update(parse_dns(data, ident, sample['host'], TYPES[qlabel]))
    except (TimeoutError, socket.timeout):
        result['classification'] = 'provider_timeout'
    except (OSError, http.client.HTTPException):
        result['classification'] = 'provider_connection_or_tls_error'
    except (ValueError, UnicodeError, struct.error):
        result['classification'] = 'invalid_or_unexpected_response'
    result['observed_at'] = utc()
    return result


def main():
    baseline, baseline_hash = read_data(INPUT1)
    addresses, address_hash = read_data(INPUT2)
    if addresses['archive_sha256'] != baseline['archive_sha256'] or addresses['parent_recheck_sha256'] != baseline_hash:
        raise ValueError('baseline evidence mismatch')
    nx, nx_total, nx_eligible = choose(baseline, 'repeated_nxdomain', 'repeated_nxdomain', baseline['archive_sha256'])
    unspecified, uns_total, uns_eligible = choose(addresses, 'repeated_unspecified_address', 'repeated_unspecified', baseline['archive_sha256'])
    samples = nx + unspecified
    if len({x['host'] for x in samples}) != len(samples):
        raise ValueError('duplicate sample host')
    data = {'method': 'Only A/AAAA RFC 8484 DoH to the named public providers. No catalog host is contacted. DNS wire responses are parsed in memory; no concrete IP, CNAME or raw reply is stored.',
            'limitations': 'Resolvers are separate operators but use the same client network. This is a deliberately selected small sample, not independent geography or a permanent-failure determination.',
            'providers': PROVIDERS, 'archive_sha256': baseline['archive_sha256'],
            'head_recheck_sha256': baseline_hash, 'address_recheck_sha256': address_hash,
            'sampling': {'selection': 'For each baseline group, only hosts with selected import IDs; sort by SHA256(archive:group:host), take first 10.',
                         'nxdomain_baseline_hosts': nx_total, 'nxdomain_eligible_hosts': nx_eligible,
                         'unspecified_baseline_hosts': uns_total, 'unspecified_eligible_hosts': uns_eligible,
                         'selected_hosts': len(samples)},
            'concurrency': 2, 'minimum_start_interval_seconds': 0.3, 'per_request_timeout_seconds': 6,
            'started_at': utc(), 'results': []}
    jobs = [(sample, provider, typ) for sample in samples for provider in PROVIDERS for typ in TYPES]
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(one, *args) for args in jobs]
        for future in as_completed(futures):
            data['results'].append(future.result())
    data['results'].sort(key=lambda r: (r['baseline'], r['host'], r['provider'], r['query_type']))
    data['completed_at'] = utc()
    data['summary'] = {group: dict(Counter(r['classification'] for r in data['results'] if r['baseline'] == group))
                       for group in ('repeated_nxdomain', 'repeated_unspecified')}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'selected': data['sampling'], 'summaries': data['summary']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
