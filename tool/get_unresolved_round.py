"""Bounded HTTPS GET round for hosts that still lacked a status after round three.

Reuses the catalog probe's public-address pinning, absolute deadline, charset
handling and redirect classification. Only the root path is requested, redirects
are not followed, at most 32 KiB is inspected, and bodies and addresses are not
saved. Visible-text title, betting/adult keyword lists and redirect host are the
only page-derived fields retained.
"""

import argparse
import hashlib
import http.client
import json
import socket
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
import sys

try:
    from .audit_legado_catalog import fetch
    from .recheck_legado_failures import classification
except ImportError:
    from audit_legado_catalog import fetch
    from recheck_legado_failures import classification

ROOT = Path(__file__).resolve().parents[1]
ROUND = 'docs/implementation/legado-unresolved-third-round-20261116.json'
ROUND_SHA = 'fa0e836dd1dd79660a72353dfd04fb7b57e003e44e5d627e4a3bfaa4728b9483'
OUTPUT = 'docs/implementation/legado-unresolved-get-round-20261116.json'
CANONICAL_SHA = None
FAILURES = {'connection_or_read_timeout', 'dns_host_not_found', 'non_public_dns_rejected',
            'connection_error', 'tls_error', 'dns_timeout', 'dns_no_data', 'dns_other',
            'dns_temporary_failure', 'other_error'}


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf8')


def require(value, reason):
    if not value:
        raise ValueError(reason)


def inputs():
    raw = (ROOT / ROUND).read_bytes()
    require(sha(raw) == ROUND_SHA, 'round-three evidence changed')
    document = json.loads(raw)
    population = {row['host']: row for row in document['results']
                  if row['latest_head']['http_status'] is None}
    require(len(population) == 935, 'unresolved population changed')
    return population


def probe(host, timeout):
    row = {'observed_at': datetime.now(timezone.utc).isoformat()}
    try:
        row.update(fetch(host, 'GET', timeout, '/'))
    except (OSError, ValueError, http.client.HTTPException) as error:
        row['error'] = ('dns: ' if isinstance(error, socket.gaierror) else type(error).__name__ + ': ') + str(error)
    row['classification'] = classification(row)
    return row


def summary(rows):
    return {'hosts': len(rows),
            'http_status_recorded': sum(r['get'].get('status') is not None for r in rows),
            'http_200': sum(r['get'].get('status') == 200 for r in rows),
            'http_redirect': sum(r['get'].get('status') in (301, 302, 303, 307, 308) for r in rows),
            'error_only': sum(r['get'].get('status') is None for r in rows),
            'classifications': dict(sorted(Counter(r['get']['classification'] for r in rows).items())),
            'betting_signal_hosts': sum(bool(r['get'].get('betting_signals')) for r in rows),
            'adult_signal_hosts': sum(bool(r['get'].get('adult_signals')) for r in rows),
            'titled_hosts': sum(bool(r['get'].get('title')) for r in rows),
            'redirect_hosts': sum(1 for r in rows if r['get'].get('redirect_host'))}


def references():
    return {'round_three': {'path': ROUND, 'sha256': ROUND_SHA}}


def build(population, timeout, workers):
    hosts = sorted(population)
    results = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(probe, host, timeout): host for host in hosts}
        for index, future in enumerate(as_completed(jobs), 1):
            results[jobs[future]] = future.result()
            if index % 100 == 0 or index == len(jobs):
                print(f'GET: {index}/{len(jobs)}', flush=True)
    rows = []
    for host in hosts:
        before = population[host]
        rows.append({'host': host, 'record_indices': before['record_indices'],
                     'selected_sources': before['selected_sources'],
                     'prior': {'observed_at': before['latest_head']['observed_at'],
                               'classification': before['latest_head']['classification'],
                               'dns_verdict': before['dns']['verdict']},
                     'get': results[host]})
    document = {'schema_version': 1, 'generated_at_utc': datetime.now(timezone.utc).isoformat(),
                'method': {'http': 'HTTPS GET /; no redirects; max 32 KiB inspected',
                           'timeout_seconds': timeout, 'body_saved': False,
                           'ip_addresses_saved': False, 'redirect_host_saved': True},
                'input_references': references(), 'collector_sha256': {
                    'tool/audit_legado_catalog.py': sha((ROOT / 'tool/audit_legado_catalog.py').read_bytes()),
                    'tool/recheck_legado_failures.py': sha((ROOT / 'tool/recheck_legado_failures.py').read_bytes())},
                'limitations': ['Single client, network and moment; status or absence is not a permanent availability conclusion.',
                                'Visible-text keyword lists are presence checks, not a safety or category verdict.',
                                'Bodies, scripts, links and addresses were not saved or executed.'],
                'summary': summary(rows), 'results': rows}
    return document


def verify(document, population):
    if CANONICAL_SHA is not None:
        require(sha(canonical(document)) == CANONICAL_SHA, 'evidence changed')
    require(document['input_references'] == references() and
            document['collector_sha256'] == {
                'tool/audit_legado_catalog.py': sha((ROOT / 'tool/audit_legado_catalog.py').read_bytes()),
                'tool/recheck_legado_failures.py': sha((ROOT / 'tool/recheck_legado_failures.py').read_bytes())},
            'provenance changed')
    rows = document['results']
    by_host = {row['host']: row for row in rows}
    require(len(rows) == len(by_host) == 935 and set(by_host) == set(population), 'population changed')
    for host, row in by_host.items():
        before = population[host]
        require(row['record_indices'] == before['record_indices'] and
                row['selected_sources'] == before['selected_sources'] and
                row['prior'] == {'observed_at': before['latest_head']['observed_at'],
                                 'classification': before['latest_head']['classification'],
                                 'dns_verdict': before['dns']['verdict']}, 'prior association changed')
        observed = row['get']
        require(observed['classification'] == classification(
            {'status': observed['status']} if observed.get('status') is not None else {'error': observed.get('error', '')}),
            'classification mismatch')
        if observed.get('status') is not None:
            require(observed['status'] > 0, 'status changed')
        else:
            require(observed['classification'] in FAILURES, 'failure classification changed')
    require(document['summary'] == summary(rows), 'summary changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--workers', type=int, choices=range(1, 33), default=24)
    parser.add_argument('--timeout', type=float, default=8)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 15:
        parser.error('timeout must be 1..15 seconds')
    population = inputs()
    if args.verify:
        raw = (ROOT / OUTPUT).read_bytes()
        verify(json.loads(raw), population)
        print(json.dumps({'verified': True, 'sha256': sha(raw)}, ensure_ascii=False))
        return
    require(args.build, 'choose --build or --verify')
    document = build(population, args.timeout, args.workers)
    verify(document, population)
    target = ROOT / OUTPUT
    target.write_text(json.dumps(document, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps({'path': OUTPUT, 'sha256': sha(target.read_bytes()),
                      'canonical_sha256': sha(canonical(document)),
                      'summary': document['summary']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
