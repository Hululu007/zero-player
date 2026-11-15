"""Classify inconsistent DNS replies without connecting to returned addresses."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

if __package__:
    from .recheck_legado_failures import _dns_round, run_batch
else:
    from recheck_legado_failures import _dns_round, run_batch


def address_verdict(observations):
    if len(observations) != 2 or any('error' in item for item in observations):
        return 'dns_query_timeout_or_error'
    kinds = []
    for item in observations:
        counts = Counter(item.get('a_address_kinds', {}))
        counts.update(item.get('aaaa_address_kinds', {}))
        kinds.append(counts)
    if all(count and set(count) == {'unspecified'} for count in kinds):
        return 'repeated_unspecified_address'
    if any(count.get('public') for count in kinds):
        return 'public_address_observed'
    if any(count.get('other_non_public') for count in kinds):
        return 'other_non_public_address_observed'
    return 'no_address_or_inconsistent'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recheck', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--timeout', type=float, default=8)
    args = parser.parse_args()
    if sys.platform != 'win32' or not 1 <= args.timeout <= 15:
        parser.error('requires Windows and timeout 1..15 seconds')
    raw = args.recheck.read_bytes()
    previous = json.loads(raw)
    selected = {r['host']: r for r in previous['results']
                if any(0 in (o.get('a'), o.get('aaaa')) for o in r.get('dns_observations', []))}
    hosts = sorted(selected)
    print(f'querying address types for {len(hosts)} prior inconsistent DNS replies', flush=True)
    first = run_batch(hosts, lambda h: _dns_round(h, args.timeout), 12, 'DNS address 1')
    second = run_batch(hosts, lambda h: _dns_round(h, args.timeout), 12, 'DNS address 2')
    rows = []
    for host in hosts:
        previous_row = selected[host]
        observations = [first[host], second[host]]
        rows.append({'host': host, 'selected_source_ids': previous_row['selected_source_ids'],
                     'record_indices': previous_row['record_indices'],
                     'previous_classification': previous_row['recheck']['classification'],
                     'observations': observations, 'verdict': address_verdict(observations)})
    output = {'schema': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
              'archive_sha256': previous['archive_sha256'],
              'parent_recheck_sha256': hashlib.sha256(raw).hexdigest(),
              'method': 'two Windows DNS A/AAAA queries, bypass local DNS cache and hosts; address classes only, no connections',
              'summary': {'hosts': len(rows), 'verdicts': dict(Counter(r['verdict'] for r in rows)),
                          'source_ids_covered': len({i for r in rows for i in r['selected_source_ids']})},
              'results': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps(output['summary'], ensure_ascii=False), flush=True)
    print(f'wrote {args.output}', flush=True)


if __name__ == '__main__':
    main()
