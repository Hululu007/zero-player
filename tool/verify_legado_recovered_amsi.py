"""Check provenance and bounded results for 40 newly responding hosts.

This is an offline consistency check. It cannot reconstruct the historical
pages, prove the observations authentic, or establish website safety.
"""

import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re

try:
    from .audit_legado_amsi import classify_scan
except ImportError:
    from audit_legado_amsi import classify_scan


EVIDENCE = Path('docs/implementation/legado-recovered-amsi-20261116.json')
HEAD = Path('docs/implementation/legado-unresolved-head-later-20261116.json')
HEAD_SHA = '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd'
INVENTORY = Path('docs/implementation/legado-import-inventory-20261115.json')
ARCHIVE = Path('assets/catalogs/books/legado/catalog.json.bz2')
SHA = re.compile(r'^[0-9a-f]{64}$')


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _time(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.utcoffset() is None:
        raise ValueError('time lacks timezone')
    return result


def _scan_result(value):
    if set(value) != {'phase', 'hresult', 'amsi_result', 'classification'}:
        raise ValueError('unexpected scanner result fields')
    if value['phase'] != 'scan' or not isinstance(value['hresult'], str):
        raise ValueError('invalid scanner phase')
    number = value['amsi_result']
    if isinstance(number, bool) or not isinstance(number, int) or not 0 <= number <= 0xffffffff:
        raise ValueError('invalid scanner result')
    if value['classification'] != classify_scan(int(value['hresult'], 16), number):
        raise ValueError('scanner classification mismatch')


def verify(data, head, head_bytes, inventory_bytes, archive_bytes):
    root_fields = {'method', 'scope', 'privacy', 'archive_sha256', 'prior_audit_sha256',
                   'import_inventory_sha256', 'total_hosts', 'prior_html_hosts', 'offset',
                   'requested_hosts', 'workers', 'minimum_request_start_interval_seconds',
                   'network_deadline_seconds', 'amsi_worker_deadline_seconds', 'max_html_bytes',
                   'max_inline_scripts_per_page', 'max_inline_script_bytes', 'inline_script_limitations',
                   'started_at', 'defender_status', 'controls', 'results', 'completed_at',
                   'outcomes', 'inline_script_outcomes'}
    if set(data) != root_fields:
        raise ValueError('unexpected evidence field')
    if _sha(head_bytes) != HEAD_SHA:
        raise ValueError('later HEAD evidence changed')
    if _sha(archive_bytes) != head['archive_sha256'] or data['archive_sha256'] != head['archive_sha256']:
        raise ValueError('catalog archive mismatch')
    if _sha(inventory_bytes) != data['import_inventory_sha256']:
        raise ValueError('import inventory mismatch')
    expected_rows = [
        {'host': row['host'], 'record_indices': row['record_indices']}
        for row in head['results'] if row['latest_head'].get('http_status') == 200
    ]
    if len(expected_rows) != 40 or len({row['host'] for row in expected_rows}) != 40:
        raise ValueError('expected HEAD-200 population changed')
    # The original temporary baseline was written with Windows CRLF.
    baseline = {
        'archive_sha256': head['archive_sha256'],
        'source_recheck_sha256': head['local_collector_sha256']['recheck'],
        'results': expected_rows,
    }
    wire = json.dumps(baseline, ensure_ascii=False, separators=(',', ':')).encode() + b'\r\n'
    if _sha(wire) != data['prior_audit_sha256']:
        raise ValueError('reconstructed sampling baseline mismatch')
    if (data['total_hosts'], data['offset'], data['requested_hosts'], data['max_html_bytes']) != (40, 0, 40, 32768):
        raise ValueError('unexpected sample bounds')
    controls = data['controls']
    if set(controls) != {'observed_at', 'negative', 'eicar', 'html_wrapped_eicar',
                         'inline_script_with_eicar', 'passed'} or controls['passed'] is not True:
        raise ValueError('scanner controls invalid')
    for name in ('negative', 'eicar', 'html_wrapped_eicar', 'inline_script_with_eicar'):
        _scan_result(controls[name])
    if (controls['negative']['classification'] != 'not_detected'
            or controls['eicar']['classification'] != 'detected'
            or controls['html_wrapped_eicar']['classification'] != 'not_detected'
            or controls['inline_script_with_eicar']['classification'] != 'not_detected'):
        raise ValueError('observed control limitations changed')

    by_host = {row['host']: row for row in head['results']}
    results = data['results']
    if len(results) != 40 or {row['host'] for row in results} != {row['host'] for row in expected_rows}:
        raise ValueError('sample host coverage mismatch')
    if len({row['host'] for row in results}) != len(results):
        raise ValueError('duplicate sample host')
    allowed = {'host', 'record_indices', 'selected_source_ids', 'started_at', 'http_status',
               'content_type', 'truncated', 'sample_bytes', 'sample_sha256',
               'sample_observed_at', 'amsi', 'inline_scripts', 'failure'}
    outcomes, inline_outcomes = Counter(), Counter()
    truncated = truncated_scripts = omitted_scripts = 0
    for row in results:
        if set(row) - allowed:
            raise ValueError('unexpected page-result field')
        prior = by_host[row['host']]
        ids = sorted(x['source_id'] for x in prior['selected_sources'])
        if row['record_indices'] != prior['record_indices'] or row['selected_source_ids'] != ids:
            raise ValueError('host or source association mismatch')
        started, observed = _time(row['started_at']), _time(row['sample_observed_at'])
        if started < _time(prior['latest_head']['observed_at']) or observed < started:
            raise ValueError('sample times out of order')
        if 'amsi' not in row:
            if (row.get('failure') != 'connection_error' or set(row) != {
                'host', 'record_indices', 'selected_source_ids', 'started_at',
                'sample_observed_at', 'failure',
            }):
                raise ValueError('unscanned sample must remain a failure')
            outcomes[row['failure']] += 1
            continue
        if (row.get('http_status') != 200 or row.get('content_type') != 'text/html'
                or type(row.get('truncated')) is not bool
                or not isinstance(row.get('sample_bytes'), int)
                or not 1 <= row['sample_bytes'] <= data['max_html_bytes']
                or not SHA.fullmatch(row.get('sample_sha256', ''))):
            raise ValueError('invalid HTML sample')
        _scan_result(row['amsi'])
        outcomes[row['amsi']['classification']] += 1
        truncated += row['truncated']
        scripts = row['inline_scripts']
        if set(scripts) != {'script_tags_observed', 'nonempty_inline_scripts_observed',
                            'inline_scripts_selected', 'inline_scripts_omitted', 'samples'}:
            raise ValueError('unexpected script summary fields')
        if scripts['inline_scripts_selected'] != len(scripts['samples']):
            raise ValueError('script sample count mismatch')
        if (scripts['nonempty_inline_scripts_observed'] !=
                scripts['inline_scripts_selected'] + scripts['inline_scripts_omitted']):
            raise ValueError('omitted script count mismatch')
        omitted_scripts += scripts['inline_scripts_omitted']
        for sample in scripts['samples']:
            if set(sample) != {'ordinal', 'has_src_attribute', 'bytes_seen', 'sample_bytes',
                               'sample_sha256', 'truncated', 'closing_tag_observed', 'amsi'}:
                raise ValueError('unexpected script sample fields')
            if (not isinstance(sample['sample_bytes'], int) or not 1 <= sample['sample_bytes'] <= data['max_inline_script_bytes']
                    or not SHA.fullmatch(sample['sample_sha256'])):
                raise ValueError('invalid bounded script sample')
            _scan_result(sample['amsi'])
            inline_outcomes[sample['amsi']['classification']] += 1
            if type(sample['truncated']) is not bool:
                raise ValueError('invalid script truncation flag')
            truncated_scripts += sample['truncated']
    if dict(outcomes) != data['outcomes'] or dict(inline_outcomes) != data['inline_script_outcomes']:
        raise ValueError('scanner outcome summary mismatch')
    if (outcomes != Counter({'not_detected': 39, 'connection_error': 1})
            or truncated != 20 or truncated_scripts != 2 or omitted_scripts != 6):
        raise ValueError('observed sample summary changed')
    if _time(data['completed_at']) < max(_time(row['sample_observed_at']) for row in results):
        raise ValueError('completion precedes observations')
    return {'hosts': 40, 'html_not_detected': 39, 'connection_failure': 1,
            'truncated_html': truncated, 'inline_not_detected': inline_outcomes['not_detected'],
            'truncated_inline': truncated_scripts, 'omitted_inline': omitted_scripts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', nargs='?', type=Path, default=EVIDENCE)
    path = parser.parse_args().evidence
    raw, head_bytes = path.read_bytes(), HEAD.read_bytes()
    summary = verify(json.loads(raw), json.loads(head_bytes), head_bytes,
                     INVENTORY.read_bytes(), ARCHIVE.read_bytes())
    print(json.dumps({'evidence_sha256': _sha(raw), 'verified_summary': summary,
                      'raw_pages_reconstructed': False,
                      'not_detected_establishes_safety': False}, ensure_ascii=False))


if __name__ == '__main__':
    main()
