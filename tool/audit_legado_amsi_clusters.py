"""Compare re-fetched AMSI detections by static shape without storing pages."""

import argparse
from collections import defaultdict
import hashlib
import http.client
import json
from pathlib import Path

if __package__:
    from .audit_legado_amsi import RateLimiter, controls, defender_status, extract_inline_scripts, failure_category, now, save, scan_many_in_worker
    from .recheck_legado_amsi import decode_atob_literals, fetch_with_identity, literal_navigation, shape_digest, structural_indicators
else:
    from audit_legado_amsi import RateLimiter, controls, defender_status, extract_inline_scripts, failure_category, now, save, scan_many_in_worker
    from recheck_legado_amsi import decode_atob_literals, fetch_with_identity, literal_navigation, shape_digest, structural_indicators


def detected(row):
    return (row.get('amsi', {}).get('classification') == 'detected' or
            any(s['amsi']['classification'] == 'detected'
                for s in row.get('inline_scripts', {}).get('samples', [])))


def select_detections(paths):
    sources, selected = [], {}
    for path in paths:
        content = path.read_bytes()
        data = json.loads(content)
        sources.append({'file': path.name, 'sha256': hashlib.sha256(content).hexdigest(),
                        'archive_sha256': data['archive_sha256']})
        for row in data['results']:
            if detected(row):
                if row['host'] in selected:
                    raise ValueError('host occurs in more than one detection input')
                selected[row['host']] = row
    if len({source['archive_sha256'] for source in sources}) != 1:
        raise ValueError('inputs belong to different catalog archives')
    return sources, selected


def recheck(row, limiter):
    host = row['host']
    limiter.wait()
    result = {'host': host, 'record_indices': row['record_indices'],
              'selected_source_ids': row['selected_source_ids'], 'prior_sample_sha256': row.get('sample_sha256'),
              'started_at': now()}
    try:
        fetched, payload, identity = fetch_with_identity(host)
        result.update(fetched)
        result['connection_identity'] = identity
        result['sample_observed_at'] = now()
        if not payload:
            return result
        result['same_sha256_as_prior'] = result['sample_sha256'] == row.get('sample_sha256')
        stats, scripts = extract_inline_scripts(payload)
        result['shape_sha256'] = shape_digest(payload, host)
        result['structural_indicators'] = structural_indicators(payload, scripts)
        result['literal_navigation'] = literal_navigation(scripts, host)
        scans = scan_many_in_worker([payload] + [body for _, body in scripts])
        result['amsi'] = scans[0]
        result['inline_scripts'] = {**stats, 'samples': [
            {**meta, 'shape_sha256': shape_digest(body, host), 'amsi': scan}
            for (meta, body), scan in zip(scripts, scans[1:])]}
        decoded_stats, decoded = decode_atob_literals(scripts)
        decoded_scans = scan_many_in_worker([body for _, body in decoded]) if decoded else []
        result['static_atob'] = {**decoded_stats, 'decoded_samples': [
            {**meta, 'amsi': scan} for (meta, _), scan in zip(decoded, decoded_scans)]}
    except (OSError, ValueError, http.client.HTTPException) as error:
        result['failure'] = failure_category(error)
        result['sample_observed_at'] = now()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scan', action='append', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--interval', type=float, default=0.5)
    args = parser.parse_args()
    if not 0.5 <= args.interval <= 10:
        parser.error('interval must be 0.5..10 seconds')
    sources, selected = select_detections(args.scan)
    result = {'method': 'Re-fetch only prior detected catalog roots over bounded anonymous HTTPS, validate and pin public DNS, no redirects, no scripts executed, no external requests or credentials.',
              'limitations': 'Only static shape is compared. Replacing quoted strings and numbers can group different behavior; shared shape or network identity does not establish origin, operator, malware or safe content. AMSI provider may use cloud features.',
              'source_scans': sources, 'selected_detected_hosts': len(selected),
              'started_at': now(), 'minimum_request_interval_seconds': args.interval,
              'defender_status': defender_status(), 'controls': controls(), 'results': []}
    if not result['controls']['passed']:
        result['failure'] = 'amsi_controls_failed_no_network_requests'
        save(args.output, result)
        return
    limiter = RateLimiter(args.interval)
    for host in sorted(selected):
        result['results'].append(recheck(selected[host], limiter))
        save(args.output, result)
        print(f"Rechecked {len(result['results'])}/{len(selected)}", flush=True)
    groups = defaultdict(list)
    for row in result['results']:
        if row.get('shape_sha256'):
            groups[row['shape_sha256']].append(row['host'])
    result['shape_groups'] = [{'shape_sha256': key, 'hosts': values}
                              for key, values in sorted(groups.items())]
    result['completed_at'] = now()
    save(args.output, result)


if __name__ == '__main__':
    main()
