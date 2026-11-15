"""Recompute a completed DoH audit's counts offline without any network calls."""

import argparse
import json
from pathlib import Path
import re

if __package__:
    from . import audit_legado_doh_full as audit
    from . import audit_legado_doh_pilot as probe
    from . import classify_legado_doh as classify
else:
    import audit_legado_doh_full as audit
    import audit_legado_doh_pilot as probe
    import classify_legado_doh as classify


ALLOWED_OBSERVATION_KEYS = {
    'provider', 'query_type', 'started_at', 'observed_at', 'http_status',
    'dns_rcode', 'dns_truncated', 'dnssec_authenticated', 'address_categories',
    'address_ttls_seconds', 'negative_ttls_seconds', 'classification', 'response_sha256',
}
ADDRESS_CATEGORIES = {'unspecified', 'loopback', 'link_local', 'multicast', 'public',
                      'private_or_special', 'reserved_or_other_non_public'}


def verify_observation(value):
    if set(value) - ALLOWED_OBSERVATION_KEYS:
        raise ValueError('unexpected observation field: possible raw answer')
    categories = value.get('address_categories', {})
    if (not isinstance(categories, dict) or set(categories) - ADDRESS_CATEGORIES
            or any(isinstance(count, bool) or not isinstance(count, int) or count <= 0
                   for count in categories.values())):
        raise ValueError('unexpected address category')
    classification, code = value['classification'], value.get('dns_rcode')
    expected = {'nxdomain': 3, 'servfail': 2, 'refused': 5,
                'noerror_addresses': 0, 'noerror_no_address': 0}
    if classification in expected:
        if value.get('http_status') != 200 or code != expected[classification]:
            raise ValueError('DNS classification and response code disagree')
        if not re.fullmatch(r'[a-f0-9]{64}', value.get('response_sha256', '')):
            raise ValueError('DNS response digest missing')
        if classification == 'noerror_addresses' and not categories:
            raise ValueError('address result has no categories')
        if classification == 'noerror_no_address' and categories:
            raise ValueError('no-address result contains address categories')


def verify(evidence, head, head_hash, addresses, address_hash, pilot, pilot_hash):
    if (not evidence.get('completed_at') or evidence['head_recheck_sha256'] != head_hash
            or evidence['address_recheck_sha256'] != address_hash or evidence['pilot_sha256'] != pilot_hash
            or evidence['archive_sha256'] != head['archive_sha256']
            or addresses['archive_sha256'] != head['archive_sha256']
            or addresses['parent_recheck_sha256'] != head_hash):
        raise ValueError('evidence is incomplete or has different input digests')
    if evidence['providers'] != probe.PROVIDERS:
        raise ValueError('unexpected provider set')
    hosts = audit.groups(head, addresses)
    old, sampled = audit.validated_pilot(pilot, head_hash, address_hash, hosts)
    nx, _, _ = probe.choose(head, 'repeated_nxdomain', 'repeated_nxdomain', head['archive_sha256'])
    unspecified, _, _ = probe.choose(addresses, 'repeated_unspecified_address', 'repeated_unspecified', head['archive_sha256'])
    if sampled != {row['host'] for row in nx + unspecified}:
        raise ValueError('pilot does not match the deterministic sample')
    controls = {(r['provider'], r['query_type']): r for r in evidence['control_queries']}
    if len(evidence['control_queries']) != 4 or len(controls) != 4 or not audit.control_ok(controls):
        raise ValueError('missing or failed provider controls')
    for row in controls.values():
        if row.get('host') != 'example.com' or row.get('baseline') != 'control':
            raise ValueError('unexpected control query')
        verify_observation({k: v for k, v in row.items() if k not in ('host', 'baseline')})
    observations, seen_hosts = {}, set()
    for row in evidence['results']:
        host = row['host']
        if (host in seen_hosts or host not in hosts or row['baseline'] != hosts[host]['baseline']
                or row['record_indices'] != hosts[host]['record_indices']
                or row['selected_source_ids'] != hosts[host]['selected_source_ids']):
            raise ValueError('duplicate host or mismatched baseline association')
        seen_hosts.add(host)
        for value in row['observations']:
            verify_observation(value)
            key = host, value['provider'], value['query_type']
            if key in observations:
                raise ValueError('duplicate DoH observation')
            observations[key] = {**value, 'host': host, 'baseline': row['baseline']}
    expected = {(host, provider, typ) for host in hosts for provider in probe.PROVIDERS for typ in probe.TYPES}
    if seen_hosts != set(hosts) or set(observations) != expected or len(observations) != evidence['completed_queries']:
        raise ValueError('DoH query coverage is incomplete')
    if any(observations[key] != row for key, row in old.items()):
        raise ValueError('reused pilot observation has changed')
    summary = (classify.summarize(hosts, observations)
               if evidence.get('summary_method') == 'valid_dns_responses_only_for_disagreement'
               else audit.metrics(hosts, observations))
    if summary != evidence['summary'] or len(sampled) != evidence['pilot_hosts_reused']:
        raise ValueError('stored summary does not match observations')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=audit.OUTPUT)
    parser.add_argument('--head', type=Path, default=probe.INPUT1)
    parser.add_argument('--addresses', type=Path, default=probe.INPUT2)
    parser.add_argument('--pilot', type=Path, default=audit.PILOT)
    args = parser.parse_args()
    evidence, _ = probe.read_data(args.evidence)
    head, head_hash = probe.read_data(args.head)
    addresses, address_hash = probe.read_data(args.addresses)
    pilot, pilot_hash = probe.read_data(args.pilot)
    summary = verify(evidence, head, head_hash, addresses, address_hash, pilot, pilot_hash)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
