"""Extend the bounded DNS-only pilot to all previously anomalous catalog hosts.

The pilot is reused without requerying its hosts. Only provider endpoints are
contacted; DNS answers are reduced in memory to status, TTL, categories and
digests. Do not persist IP addresses, CNAMEs or raw response bodies.
"""

from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path

if __package__:
    from . import audit_legado_doh_pilot as probe
else:
    import audit_legado_doh_pilot as probe


PILOT = Path('docs/implementation/legado-doh-sample-20261115.json')
CHECKPOINT = Path('build/doh-sample/full-in-progress.json')
OUTPUT = Path('docs/implementation/legado-doh-full-20261115.json')


def groups(head, addresses):
    result = {}
    for baseline, dataset, key, label in [
        ('repeated_nxdomain', head, 'dns_verdict', 'repeated_nxdomain'),
        ('repeated_unspecified', addresses, 'verdict', 'repeated_unspecified_address'),
    ]:
        for row in dataset['results']:
            if row.get(key) != label:
                continue
            host = row['host']
            if host in result:
                raise ValueError('baseline groups contain a duplicate host')
            probe.name_wire(host)
            result[host] = {'host': host, 'baseline': baseline, 'record_indices': row['record_indices'],
                            'selected_source_ids': sorted(set(row['selected_source_ids']))}
    return result


def validated_pilot(pilot, head_hash, address_hash, hosts):
    if pilot['head_recheck_sha256'] != head_hash or pilot['address_recheck_sha256'] != address_hash:
        raise ValueError('pilot does not match baseline evidence')
    if pilot['providers'] != probe.PROVIDERS or pilot['sampling']['selected_hosts'] != 20:
        raise ValueError('pilot provider or selection metadata differs')
    results = {}
    for row in pilot['results']:
        key = row['host'], row['provider'], row['query_type']
        if key in results or row['host'] not in hosts or row['baseline'] != hosts[row['host']]['baseline']:
            raise ValueError('pilot contains duplicate or mismatched observation')
        results[key] = row
    chosen = {host for host, _, _ in results}
    expected = {(host, provider, typ) for host in chosen for provider in probe.PROVIDERS for typ in probe.TYPES}
    if len(chosen) != 20 or set(results) != expected:
        raise ValueError('pilot does not contain four results for each of 20 hosts')
    return results, chosen


def control_ok(results):
    for provider in probe.PROVIDERS:
        for typ in probe.TYPES:
            row = results[(provider, typ)]
            if row.get('http_status') != 200 or row.get('dns_rcode') != 0 or row.get('dns_truncated'):
                return False
            if typ == 'A' and not row.get('address_categories', {}).get('public'):
                return False
    return True


def compact_observation(row):
    return {key: value for key, value in row.items() if key not in ('host', 'baseline')}


def metrics(hosts, observations):
    output = {}
    for group in ('repeated_nxdomain', 'repeated_unspecified'):
        group_rows = [row for row in hosts.values() if row['baseline'] == group]
        query_counts, flags = Counter(), Counter()
        ids = {ident for row in group_rows for ident in row['selected_source_ids']}
        for host in group_rows:
            rows = [observations[(host['host'], provider, typ)] for provider in probe.PROVIDERS for typ in probe.TYPES]
            query_counts.update(row['classification'] for row in rows)
            if all(row['classification'] == 'nxdomain' for row in rows):
                flags['both_providers_nxdomain_for_a_and_aaaa'] += 1
            has_public = {p: any(r['provider'] == p and r.get('address_categories', {}).get('public') for r in rows)
                          for p in probe.PROVIDERS}
            if any(has_public.values()):
                flags['at_least_one_provider_public_address'] += 1
            if all(has_public.values()):
                flags['both_providers_public_address'] += 1
            if any(r['classification'] not in ('nxdomain', 'noerror_addresses', 'noerror_no_address') for r in rows):
                flags['one_or_more_dns_or_transport_errors'] += 1
            for typ in probe.TYPES:
                pair = [r for r in rows if r['query_type'] == typ]
                signatures = {(r['classification'], tuple(sorted(r.get('address_categories', {})))) for r in pair}
                if len(signatures) > 1:
                    flags['provider_disagreement_at_least_one_type'] += 1
                    break
        output[group] = {'hosts': len(group_rows), 'selected_source_ids': len(ids),
                         'query_classifications': dict(query_counts), 'host_observations': dict(flags)}
    return output


def persist(data, observations, hosts, completed=False):
    data['results'] = [{**entry, 'observations': [compact_observation(observations[(host, provider, typ)])
                         for provider in probe.PROVIDERS for typ in probe.TYPES
                         if (host, provider, typ) in observations]}
                       for host, entry in sorted(hosts.items())]
    data['completed_queries'] = len(observations)
    if completed:
        data['completed_at'] = probe.utc()
        data['summary'] = metrics(hosts, observations)
    path = OUTPUT if completed else CHECKPOINT
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    head, head_hash = probe.read_data(probe.INPUT1)
    addresses, address_hash = probe.read_data(probe.INPUT2)
    pilot, pilot_hash = probe.read_data(PILOT)
    if addresses['archive_sha256'] != head['archive_sha256'] or addresses['parent_recheck_sha256'] != head_hash:
        raise ValueError('baseline evidence mismatch')
    hosts = groups(head, addresses)
    observations, sampled_hosts = validated_pilot(pilot, head_hash, address_hash, hosts)
    nx, _, _ = probe.choose(head, 'repeated_nxdomain', 'repeated_nxdomain', head['archive_sha256'])
    unspecified, _, _ = probe.choose(addresses, 'repeated_unspecified_address', 'repeated_unspecified', head['archive_sha256'])
    if sampled_hosts != {row['host'] for row in nx + unspecified}:
        raise ValueError('pilot hosts do not match the deterministic sampling rule')
    data = {'method': 'Only A/AAAA RFC 8484 DoH to two named providers; never contact catalog hosts or execute source rules. Parse DNS responses in memory and store no IP, CNAME or raw answer.',
            'limitations': 'Resolvers are operated separately but queries share one client/network path and observations span hours. DNS is time-varying and response digests cannot be regenerated later without the original raw answers, which are intentionally not saved. A single result is not a permanent-failure or safety verdict.',
            'providers': probe.PROVIDERS, 'archive_sha256': head['archive_sha256'],
            'head_recheck_sha256': head_hash, 'address_recheck_sha256': address_hash,
            'pilot_sha256': pilot_hash, 'pilot_started_at': pilot['started_at'],
            'pilot_script_sha256': hashlib.sha256(Path(probe.__file__).read_bytes()).hexdigest(),
            'full_script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'pilot_completed_at': pilot['completed_at'], 'pilot_hosts_reused': len(sampled_hosts),
            'baseline_hosts': len(hosts), 'concurrency': 2, 'minimum_start_interval_seconds': 0.3,
            'per_request_timeout_seconds': 6, 'started_at': probe.utc()}
    control_sample = {'host': 'example.com', 'baseline': 'control'}
    with ThreadPoolExecutor(max_workers=2) as pool:
        control_futures = {pool.submit(probe.one, control_sample, p, t): (p, t)
                           for p in probe.PROVIDERS for t in probe.TYPES}
        control = {control_futures[f]: f.result() for f in as_completed(control_futures)}
        data['control_queries'] = [control[k] for k in sorted(control)]
        if not control_ok(control):
            data['failure'] = 'provider_control_failed_no_additional_catalog_queries'
            persist(data, observations, hosts)
            print(data['failure'], flush=True)
            return
        pending = [(entry, provider, typ) for host, entry in sorted(hosts.items()) if host not in sampled_hosts
                   for provider in probe.PROVIDERS for typ in probe.TYPES]
        futures = {pool.submit(probe.one, entry, provider, typ): (entry['host'], provider, typ)
                   for entry, provider, typ in pending}
        for future in as_completed(futures):
            observations[futures[future]] = future.result()
            if (len(observations) - len(pilot['results'])) % 40 == 0:
                persist(data, observations, hosts)
                print(f"completed {len(observations)}/{len(hosts) * 4} catalog queries", flush=True)
    expected = {(host, p, t) for host in hosts for p in probe.PROVIDERS for t in probe.TYPES}
    if set(observations) != expected:
        raise ValueError('catalog query coverage is incomplete')
    persist(data, observations, hosts, completed=True)
    print(json.dumps(data['summary'], ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
