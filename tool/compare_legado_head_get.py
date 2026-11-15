"""Offline join of two HEAD observations with subsequent root-page GET results.

No network, source rule or HTML body is used. Status presence is based only on
the recorded response status; request failures are not interpreted as status.
"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path


def read_json(path):
    content = path.read_bytes()
    return json.loads(content), hashlib.sha256(content).hexdigest()


def host_index(rows):
    result = {}
    for row in rows:
        host = row['host']
        if host in result:
            raise ValueError(f'duplicate host: {host}')
        result[host] = row
    return result


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.utcoffset() is None:
        raise ValueError('observation must include a time zone')
    return parsed


def status_or_none(row, key):
    if key not in row:
        return None
    status = row[key]
    if isinstance(status, bool) or not isinstance(status, int) or not 100 <= status <= 599:
        raise ValueError('invalid recorded HTTP status')
    return status


def time_range(rows, key):
    values = [key(row) for row in rows]
    return [min(values, key=timestamp), max(values, key=timestamp)]


def ids_for(rows):
    return {source_id for row in rows for source_id in row['selected_source_ids']}


def counts(rows, key):
    groups = defaultdict(list)
    for row in rows:
        groups[key(row)].append(row)
    return {str(name): {'hosts': len(group), 'selected_ids': len(ids_for(group))}
            for name, group in sorted(groups.items(), key=lambda item: str(item[0]))}


def checked_inputs(first, first_hash, second, inventory, inventory_hash, stages):
    archive = first['archive_sha256']
    if second['first_audit_sha256'] != first_hash or second['archive_sha256'] != archive:
        raise ValueError('HEAD recheck does not match the first audit')
    if second['import_inventory_sha256'] != inventory_hash or inventory['archive_sha256'] != archive:
        raise ValueError('import inventory does not match the HEAD recheck')
    first_rows = host_index(first['results'])
    second_rows = host_index(second['results'])
    expected = {host for host, row in first_rows.items() if status_or_none(row, 'status') is None}
    if set(second_rows) != expected:
        raise ValueError('second HEAD pass does not cover exactly the first no-status hosts')
    get_rows = {}
    for stage in stages:
        if (stage['archive_sha256'] != archive or stage['prior_audit_sha256'] != first_hash
                or stage['import_inventory_sha256'] != inventory_hash or not stage.get('completed_at')):
            raise ValueError('GET stage is incomplete or uses different audit inputs')
        if len(stage['results']) != stage['requested_hosts']:
            raise ValueError('GET stage result count is incomplete')
        for host, row in host_index(stage['results']).items():
            if host in get_rows:
                raise ValueError(f'host appears in multiple GET stages: {host}')
            status_or_none(row, 'http_status')
            get_rows[host] = row
    if set(get_rows) != set(first_rows):
        raise ValueError('GET stages do not cover exactly the original host inventory')
    selected = defaultdict(set)
    seen_ids = set()
    for row in inventory['selected_sources']:
        if row['id'] in seen_ids:
            raise ValueError('selected import inventory contains duplicate source IDs')
        seen_ids.add(row['id'])
        selected[row['host']].add(row['id'])
    for host, row in second_rows.items():
        origin, first_get = first_rows[host], get_rows[host]
        status_or_none(row['recheck'], 'status')
        if (row['previous']['observed_at'] != origin['observed_at']
                or row['record_indices'] != origin['record_indices']
                or set(row['selected_source_ids']) != selected[host]
                or set(first_get['selected_source_ids']) != selected[host]
                or first_get['record_indices'] != origin['record_indices']):
            raise ValueError(f'host or selected ID mapping disagrees: {host}')
        first_at = timestamp(origin['observed_at'])
        second_at = timestamp(row['recheck']['observed_at'])
        get_start = timestamp(first_get['started_at'])
        get_end = timestamp(first_get['sample_observed_at'])
        if not first_at <= second_at <= get_start <= get_end:
            raise ValueError(f'observation times are not ordered: {host}')
    return first_rows, second_rows, get_rows


def get_category(result):
    status = status_or_none(result, 'http_status')
    if status is None:
        return result.get('failure', 'unclassified_no_status')
    if status == 200 and result.get('sample_bytes', 0) > 0:
        scan = result.get('amsi', {})
        return ('nonempty_html_scanned' if scan.get('hresult') == '0x00000000'
                and scan.get('amsi_result') is not None and scan.get('classification') != 'scan_error'
                else 'nonempty_html_scan_unavailable')
    if status == 200:
        return result.get('failure', 'other_200')
    if 300 <= status < 400:
        return 'redirect_not_followed'
    return 'other_http_status'


def compare(first, first_hash, second, inventory, inventory_hash, stages):
    _, head_rows, get_rows = checked_inputs(first, first_hash, second, inventory, inventory_hash, stages)
    unresolved = [row for row in head_rows.values() if status_or_none(row['recheck'], 'status') is None]
    responded = [row for row in unresolved if status_or_none(get_rows[row['host']], 'http_status') is not None]
    no_status = [row for row in unresolved if status_or_none(get_rows[row['host']], 'http_status') is None]
    details = []
    for row in sorted(responded, key=lambda item: item['host']):
        later = get_rows[row['host']]
        details.append({'host': row['host'], 'record_indices': row['record_indices'],
                        'selected_source_ids': row['selected_source_ids'],
                        'first_head_observed_at': row['previous']['observed_at'],
                        'first_head_classification': row['previous']['classification'],
                        'second_head_observed_at': row['recheck']['observed_at'],
                        'second_head_classification': row['recheck']['classification'],
                        'get_started_at': later['started_at'],
                        'get_observed_at': later['sample_observed_at'],
                        'get_status': later['http_status'], 'get_category': get_category(later),
                        'get_failure': later.get('failure'), 'html_bytes': later.get('sample_bytes'),
                        'html_truncated': later.get('truncated'), 'html_sha256': later.get('sample_sha256'),
                        'amsi': later.get('amsi')})
    return {
        'method': 'Offline join by exact host: initial HEAD no recorded status, second HEAD no recorded status, then independent root GET. Inputs and source-ID associations are validated; no network or scripts executed.',
        'limitations': ['GET and HEAD are different methods and times; one GET status does not retroactively establish a HEAD status.',
                        'An HTTP response, even 200 or HTML, does not establish usable rules, current availability or safety.',
                        'No recorded GET status includes DNS, network, TLS, timeout or incomplete-response errors; none proves permanent failure.',
                        'AMSI not-detected is not a malware clearance; the local HTML-wrapped test control was missed.',
                        'Source IDs refer to the historical deduplicated import inventory, not installed or enabled user sources.'],
        'archive_sha256': first['archive_sha256'],
        'import_inventory_generated_at': inventory['generated_at'],
        'import_code_sha256': inventory['import_code_sha256'],
        'first_head_no_status': {'hosts': len(head_rows), 'selected_ids': len(ids_for(head_rows.values()))},
        'both_heads_no_status': {'hosts': len(unresolved), 'selected_ids': len(ids_for(unresolved)),
                                 'first_head_classifications': counts(unresolved, lambda r: r['previous']['classification']),
                                 'second_head_classifications': counts(unresolved, lambda r: r['recheck']['classification'])},
        'later_get_status': {'hosts': len(responded), 'selected_ids': len(ids_for(responded)),
                             'by_status': counts(responded, lambda r: get_rows[r['host']]['http_status']),
                             'by_category': counts(responded, lambda r: get_category(get_rows[r['host']]))},
        'later_get_no_status': {'hosts': len(no_status), 'selected_ids': len(ids_for(no_status)),
                                'by_failure': counts(no_status, lambda r: get_category(get_rows[r['host']]))},
        'time_ranges_utc': {
            'first_head': time_range(unresolved, lambda r: r['previous']['observed_at']),
            'second_head': time_range(unresolved, lambda r: r['recheck']['observed_at']),
            'later_get': [min((get_rows[r['host']]['started_at'] for r in unresolved), key=timestamp),
                          max((get_rows[r['host']]['sample_observed_at'] for r in unresolved), key=timestamp)]},
        'responded_hosts': details,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--first', type=Path, required=True)
    parser.add_argument('--second', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--get-stage', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    first, first_hash = read_json(args.first)
    second, second_hash = read_json(args.second)
    inventory, inventory_hash = read_json(args.inventory)
    stage_data = [(path, *read_json(path)) for path in args.get_stage]
    result = compare(first, first_hash, second, inventory, inventory_hash, [data for _, data, _ in stage_data])
    result['inputs'] = [{'file': args.first.name, 'sha256': first_hash},
                        {'file': args.second.name, 'sha256': second_hash},
                        {'file': args.inventory.name, 'sha256': inventory_hash},
                        *({'file': path.name, 'sha256': digest} for path, _, digest in stage_data)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"{result['both_heads_no_status']['hosts']} hosts: "
          f"{result['later_get_status']['hosts']} with GET status, "
          f"{result['later_get_no_status']['hosts']} without")


if __name__ == '__main__':
    main()
