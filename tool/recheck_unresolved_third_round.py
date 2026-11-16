"""Third bounded HEAD recheck of hosts still without a status after 2026-11-16 rounds.

Reuses the catalog probe's public-address pinning, TLS verification and absolute
deadline. Only HTTPS HEAD / is requested; redirects are not followed, HTML bodies
and addresses are not saved, and no source rules or page scripts run.
"""

import argparse
import hashlib
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

try:
    from .audit_legado_catalog import probe
    from .recheck_legado_failures import (DNS_NAME_ERROR, DNS_NO_RECORDS, classification,
                                          _dns_round)
    from .verify_legado_unresolved_head import _dns_observation, _dns_verdict
except ImportError:
    from audit_legado_catalog import probe
    from recheck_legado_failures import (DNS_NAME_ERROR, DNS_NO_RECORDS, classification,
                                         _dns_round)
    from verify_legado_unresolved_head import _dns_observation, _dns_verdict

ROOT = Path(__file__).resolve().parents[1]
PRIOR = 'docs/implementation/legado-unresolved-943-recheck-20261116.json'
PRIOR_SHA = '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0'
INVENTORY = 'docs/implementation/legado-import-inventory-20261115.json'
INVENTORY_SHA = 'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
OUTPUT = 'docs/implementation/legado-unresolved-third-round-20261116.json'
CATALOG_TOOL = 'tool/audit_legado_catalog.py'
RETRY_TOOL = 'tool/recheck_legado_failures.py'
CANONICAL_SHA = None  # filled after the first build

FAILURES = {'connection_or_read_timeout', 'dns_host_not_found', 'non_public_dns_rejected',
            'connection_error', 'tls_error', 'dns_timeout', 'dns_no_data', 'dns_other',
            'dns_temporary_failure', 'other_error'}
DNS_CLASSES = {'dns_host_not_found', 'dns_no_data', 'dns_temporary_failure', 'dns_other', 'dns_timeout'}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf8')


def tool_hashes():
    return {CATALOG_TOOL: sha((ROOT / CATALOG_TOOL).read_bytes()),
            RETRY_TOOL: sha((ROOT / RETRY_TOOL).read_bytes())}


def inputs():
    prior_bytes = (ROOT / PRIOR).read_bytes()
    inventory_bytes = (ROOT / INVENTORY).read_bytes()
    archive = (ROOT / ARCHIVE).read_bytes()
    require(sha(prior_bytes) == PRIOR_SHA and sha(inventory_bytes) == INVENTORY_SHA and
            sha(archive) == ARCHIVE_SHA, 'pinned input changed')
    prior = json.loads(prior_bytes)
    inventory = json.loads(inventory_bytes)
    require(prior['input_references']['archive']['sha256'] == ARCHIVE_SHA and
            prior['input_references']['import_inventory']['sha256'] == INVENTORY_SHA and
            inventory['archive_sha256'] == ARCHIVE_SHA, 'input cross-reference changed')
    population = {row['host']: row for row in prior['results']
                  if row['latest_head']['http_status'] is None}
    require(len(population) == 939, 'unresolved population changed')
    return population


def run(population, workers, timeout, dns_timeout):
    hosts = sorted(population)
    results = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(probe, host, timeout, False): host for host in hosts}
        for index, future in enumerate(as_completed(jobs), 1):
            host = jobs[future]
            row = future.result()
            row['classification'] = classification(row)
            results[host] = row
            if index % 100 == 0 or index == len(jobs):
                print(f'HEAD: {index}/{len(jobs)}', flush=True)
    dns_hosts = [host for host in hosts if results[host]['classification'] in DNS_CLASSES]
    print(f'wire DNS verification for {len(dns_hosts)} hosts', flush=True)
    first = _batch(dns_hosts, lambda h: _dns_round(h, dns_timeout), 12, 'DNS 1')
    again = [host for host in dns_hosts
             if DNS_NAME_ERROR in (first[host].get('a'), first[host].get('aaaa')) or
             (first[host].get('a') == DNS_NO_RECORDS and first[host].get('aaaa') == DNS_NO_RECORDS)]
    second = _batch(again, lambda h: _dns_round(h, dns_timeout), 12, 'DNS 2')
    rows = []
    for host in hosts:
        before = population[host]
        observations = []
        if host in first:
            observations.append(_dns_observation(first[host]))
            if host in second:
                observations.append(_dns_observation(second[host]))
        row = {'host': host, 'record_indices': before['record_indices'],
               'selected_sources': before['selected_sources'],
               'prior_head': {'observed_at': before['latest_head']['observed_at'],
                              'classification': before['latest_head']['classification']},
               'latest_head': {'observed_at': results[host]['observed_at'],
                               'http_status': results[host].get('status'),
                               'classification': results[host]['classification']},
               'dns': {'verdict': _dns_verdict(observations) if observations else 'not_checked',
                       'observations': observations}}
        rows.append(row)
    return rows


def _batch(hosts, worker, workers, label):
    results = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(worker, host): host for host in hosts}
        for index, future in enumerate(as_completed(jobs), 1):
            results[jobs[future]] = future.result()
            if index % 50 == 0 or index == len(jobs):
                print(f'{label}: {index}/{len(jobs)}', flush=True)
    return results


def summary(rows):
    return {'hosts': len(rows),
            'selected_source_ids': len({s['source_id'] for r in rows for s in r['selected_sources']}),
            'http_status_recorded': sum(r['latest_head']['http_status'] is not None for r in rows),
            'http_status_unrecorded': sum(r['latest_head']['http_status'] is None for r in rows),
            'http_200': sum(r['latest_head']['http_status'] == 200 for r in rows),
            'latest_classifications': dict(sorted(Counter(r['latest_head']['classification'] for r in rows).items())),
            'dns_verdicts': dict(sorted(Counter(r['dns']['verdict'] for r in rows).items()))}


def references():
    return {'archive': {'path': ARCHIVE, 'sha256': ARCHIVE_SHA},
            'previous_round': {'path': PRIOR, 'sha256': PRIOR_SHA},
            'import_inventory': {'path': INVENTORY, 'sha256': INVENTORY_SHA}}


def evidence(rows, generated):
    return {'schema_version': 1, 'generated_at_utc': generated,
            'method': {'http': 'HTTPS HEAD /; no redirects or HTML GET',
                       'dns': 'Windows DnsQuery_W A/AAAA, bypass cache and hosts',
                       'timeout_seconds': TIMEOUT, 'body_saved': False,
                       'ip_addresses_saved': False, 'redirect_targets_saved': False},
            'input_references': references(), 'collector_sha256': tool_hashes(),
            'limitations': [
                'HTTP status and lack of status are time-limited observations, not safety or permanent availability conclusions.',
                'All requests share this client and network; later DNS checks may share caches.',
                'DNS failures and unspecified addresses are not automatically classed as permanent source failure.',
                'HTML bodies, redirect targets and addresses are not saved; new observations cannot be replayed offline.',
                'Source identity refers to the archived selected record, not personal installation or settings.'],
            'summary': summary(rows), 'results': rows}


def verify(document, population):
    if CANONICAL_SHA is not None:
        require(sha(canonical(document)) == CANONICAL_SHA, 'evidence changed')
    require(document['schema_version'] == 1 and document['input_references'] == references() and
            document['collector_sha256'] == tool_hashes(), 'evidence provenance changed')
    rows = document['results']
    by_host = {row['host']: row for row in rows}
    require(len(rows) == len(by_host) == 939 and set(by_host) == set(population), 'evidence population changed')
    for host, row in by_host.items():
        before = population[host]
        head = row['latest_head']
        require(row['record_indices'] == before['record_indices'] and
                row['selected_sources'] == before['selected_sources'] and
                row['prior_head'] == {'observed_at': before['latest_head']['observed_at'],
                                      'classification': before['latest_head']['classification']},
                'evidence host, ID or prior observation changed')
        if head['http_status'] is None:
            require(head['classification'] in FAILURES, 'missing status classification changed')
        else:
            require(head['classification'] == classification({'status': head['http_status']}),
                    'status classification changed')
        dns = row['dns']
        require((not dns['observations'] and dns['verdict'] == 'not_checked') or
                (dns['observations'] and dns['verdict'] == _dns_verdict(dns['observations'])),
                'DNS verdict changed')
    require(document['summary'] == summary(rows), 'summary changed')
    require(document['summary']['hosts'] == 939, 'population size changed')
    return document['summary']


TIMEOUT = 6.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--workers', type=int, choices=range(1, 33), default=24)
    parser.add_argument('--timeout', type=float, default=6)
    parser.add_argument('--dns-timeout', type=float, default=8)
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('explicit DNS result codes require Windows DNS client API')
    if not (1 <= args.timeout <= 15 and 1 <= args.dns_timeout <= 15):
        parser.error('timeouts must be in 1..15 seconds')
    global TIMEOUT
    TIMEOUT = args.timeout
    population = inputs()
    if args.verify:
        document = json.loads((ROOT / OUTPUT).read_text(encoding='utf-8'))
        result = verify(document, population)
        print(json.dumps({'verified': True, 'summary': result}, ensure_ascii=False))
        return
    require(args.build, 'choose --build or --verify')
    rows = run(population, args.workers, args.timeout, args.dns_timeout)
    document = evidence(rows, datetime.now(timezone.utc).isoformat())
    verify(document, population)
    target = ROOT / OUTPUT
    target.write_text(json.dumps(document, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps({'path': OUTPUT, 'sha256': sha(target.read_bytes()),
                      'canonical_sha256': sha(canonical(document)),
                      'summary': document['summary']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
