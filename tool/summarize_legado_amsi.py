"""Aggregate disjoint Legado AMSI observations without accessing the network."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def summarize(prior, scans):
    expected = {x['host'] for x in prior['results']}
    all_rows, metadata = [], []
    for path in scans:
        content = path.read_bytes()
        data = json.loads(content)
        if data['archive_sha256'] != prior['archive_sha256'] or not data.get('completed_at'):
            raise ValueError('scan incomplete or catalog archive mismatch')
        if len(data['results']) != data['requested_hosts']:
            raise ValueError('scan result count does not match requested hosts')
        metadata.append({'file': path.name, 'sha256': hashlib.sha256(content).hexdigest(),
                         'offset': data['offset'], 'requested_hosts': data['requested_hosts'],
                         'started_at': data['started_at'], 'completed_at': data['completed_at'],
                         'workers': data['workers'],
                         'minimum_request_start_interval_seconds': data['minimum_request_start_interval_seconds'],
                         'network_deadline_seconds': data['network_deadline_seconds']})
        all_rows.extend(data['results'])
    unique = {x['host'] for x in all_rows}
    if len(unique) != len(all_rows) or unique != expected:
        raise ValueError('scans overlap or do not exactly cover the original host inventory')
    for row in all_rows:
        if row.get('amsi') is not None and not row.get('sample_bytes'):
            raise ValueError('an empty or absent HTML sample cannot be counted as scanned')
    samples = [s for row in all_rows for s in row.get('inline_scripts', {}).get('samples', [])]
    root_scans = [x for x in all_rows if 'amsi' in x]
    successes = [x for x in root_scans if x['amsi']['classification'] != 'scan_error']
    detections = [x for x in all_rows if x.get('amsi', {}).get('classification') == 'detected' or
                  any(s['amsi']['classification'] == 'detected'
                      for s in x.get('inline_scripts', {}).get('samples', []))]
    selected = lambda rows: {ident for x in rows for ident in x.get('selected_source_ids', [])}
    return {'method': 'Offline aggregation; each host appears in exactly one completed sampling stage. Root and inline results are reported independently.',
            'limitations': 'AMSI did not detect the HTML-wrapped or script-wrapped control in this environment. Results are limited to bounded samples, not whole-site malware verdicts; the antimalware provider may use cloud services.',
            'archive_sha256': prior['archive_sha256'], 'stages': metadata,
            'total_unique_hosts': len(unique),
            'root_outcomes': dict(Counter(x.get('amsi', {}).get('classification', x.get('failure', 'unknown'))
                                          for x in all_rows)),
            'html_nonempty_samples': len(root_scans),
            'html_scanned_with_successful_hresult': len(successes),
            'html_sampled_but_scan_error': len(root_scans) - len(successes),
            'hosts_without_successful_html_scan': len(all_rows) - len(successes),
            'html_truncated_samples': sum(bool(x.get('truncated')) for x in root_scans),
            'inline_script_samples': len(samples),
            'inline_script_outcomes': dict(Counter(x['amsi']['classification'] for x in samples)),
            'inline_script_truncated_samples': sum(bool(x['truncated']) for x in samples),
            'inline_script_omitted_count': sum(x.get('inline_scripts', {}).get('inline_scripts_omitted', 0)
                                                for x in all_rows),
            'selected_source_ids_with_successful_html_scan': len(selected(successes)),
            'detected_hosts_either_root_or_inline': len(detections),
            'selected_source_ids_on_detected_hosts': len(selected(detections)),
            'detection_observations': [{'host': x['host'], 'record_indices': x['record_indices'],
                                        'selected_source_ids': x['selected_source_ids'],
                                        'sample_observed_at': x['sample_observed_at'],
                                        'sample_bytes': x.get('sample_bytes'),
                                        'sample_sha256': x.get('sample_sha256'),
                                        'truncated': x.get('truncated'), 'amsi': x.get('amsi'),
                                        'detected_inline_scripts': [s for s in x.get('inline_scripts', {}).get('samples', [])
                                                                    if s['amsi']['classification'] == 'detected']}
                                       for x in detections]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--scan', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    previous = json.loads(args.previous.read_bytes())
    result = summarize(previous, args.scan)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"{result['total_unique_hosts']} hosts, {result['html_scanned_with_successful_hresult']} scanned HTML samples, {result['detected_hosts_either_root_or_inline']} detections")


if __name__ == '__main__':
    main()
