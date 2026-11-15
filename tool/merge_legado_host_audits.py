"""Merge root-host audit runs against the currently pinned bundled catalog."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from audit_legado_catalog import CATALOG, inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('inputs', type=Path, nargs='+')
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    rows, hosts, unresolved, kinds, manifest = inventory(CATALOG)
    results, runs = {}, []
    sample = None
    for path in args.inputs:
        data = json.loads(path.read_text(encoding='utf-8'))
        if data['archive_sha256'] != manifest['archiveSha256'] or data.get('path', '/') != '/':
            raise ValueError(f'{path} is not a root probe for the pinned catalog')
        if sample is not None and sample != data['sample_html']:
            raise ValueError('cannot mix HEAD-only and HTML-sample probes')
        sample = data['sample_html']
        runs.append({'generated_at': data['generated_at'], 'observed_hosts': len(data['results'])})
        for row in data['results']:
            host = row['host']
            if host not in hosts:
                raise ValueError(f'{host} is no longer a catalog host')
            if host not in results or row['observed_at'] > results[host]['observed_at']:
                results[host] = {**row, 'record_indices': hosts[host]}
    if args.require_complete and set(results) != set(hosts):
        raise ValueError(f"missing hosts: {', '.join(sorted(set(hosts) - set(results)))}")
    output = {'schema': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
              'archive_sha256': manifest['archiveSha256'], 'records': len(rows),
              'pack_rows': sum(pack['count'] for pack in manifest['packs']),
              'record_kinds': kinds, 'distinct_hosts': len(hosts),
              'unresolved_record_indices': unresolved, 'path': '/',
              'method': 'HEAD https://host/; optional bounded GET HTML; no redirects or script execution',
              'sample_html': sample, 'source_runs': runs,
              'results': [results[host] for host in sorted(results)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(f'{len(results)}/{len(hosts)} hosts; wrote {args.output}')


if __name__ == '__main__':
    main()
