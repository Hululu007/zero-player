"""Offline consistency checks for the two-source redirect evidence."""

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path

try:
    from . import recheck_redirected_book_sources as scan
except ImportError:
    import recheck_redirected_book_sources as scan


EVIDENCE = Path('docs/implementation/legado-redirected-sources-20261116.json')
REDIRECT_HOST = '2026-10-10.urldance.com'


def _time(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.utcoffset() is None:
        raise ValueError('observation time must include timezone')
    return parsed


def _check_observation(item, host, method, path, previous):
    if set(item) - {'host', 'purpose', 'method', 'started_at', 'observed_at',
                    'request_sha256', 'status', 'redirect', 'redirect_host', 'redirect_scheme'}:
        raise ValueError('unexpected observation field')
    expected = hashlib.sha256(f'https://{host}{path}'.encode()).hexdigest()
    if item.get('request_sha256') != expected:
        raise ValueError('request digest mismatch')
    started, observed = _time(item['started_at']), _time(item['observed_at'])
    if observed < started or (previous is not None and started < previous):
        raise ValueError('observation times are out of order')
    if (item.get('status') != 302 or item.get('redirect') != 'other_host'
            or item.get('redirect_host') != REDIRECT_HOST
            or item.get('redirect_scheme') != 'https'):
        raise ValueError('expected redirect was not observed')
    return observed


def verify(data):
    if set(data) != {'method', 'limitations', 'archive_sha256', 'historical_ledger',
                     'collector_source_sha256', 'transport_source_sha256',
                     'sources', 'rounds', 'completed_at'}:
        raise ValueError('unexpected evidence field')
    if data.get('archive_sha256') != scan.ARCHIVE_SHA256:
        raise ValueError('archive digest mismatch')
    if data.get('historical_ledger') != {
        'commit': scan.LEDGER_COMMIT, 'path': scan.LEDGER_PATH,
        'sha256': scan.LEDGER_SHA256,
    }:
        raise ValueError('historical ledger reference mismatch')
    if data.get('collector_source_sha256') != scan.source_sha('tool/recheck_redirected_book_sources.py'):
        raise ValueError('collector source changed')
    if data.get('transport_source_sha256') != scan.source_sha('tool/audit_legado_catalog.py'):
        raise ValueError('transport source changed')
    if data.get('sources') != scan.bindings():
        raise ValueError('source identity or selected record mismatch')
    rounds = data.get('rounds')
    if not isinstance(rounds, list) or len(rounds) != 2:
        raise ValueError('two rounds are required')
    previous = None
    expected = [(host, purpose, method, path) for host, candidate in scan.CANDIDATES.items()
                for purpose, method, path in candidate['requests']]
    for number, item in enumerate(rounds, 1):
        if item.get('round') != number or set(item) != {'round', 'control', 'observations'}:
            raise ValueError('round identity mismatch')
        control = item['control']
        if set(control) != {'started_at', 'observed_at', 'request_sha256', 'status'}:
            raise ValueError('invalid control fields')
        if control['status'] != 200 or control['request_sha256'] != scan.sha(b'https://example.com/'):
            raise ValueError('positive control failed')
        started, observed = _time(control['started_at']), _time(control['observed_at'])
        if observed < started or (previous is not None and started < previous):
            raise ValueError('control times are out of order')
        previous = observed
        observations = item['observations']
        if len(observations) != len(expected):
            raise ValueError('observation coverage mismatch')
        for observation, (host, purpose, method, path) in zip(observations, expected):
            if (observation.get('host'), observation.get('purpose'), observation.get('method')) != (host, purpose, method):
                raise ValueError('observation identity mismatch')
            previous = _check_observation(observation, host, method, path, previous)
    if _time(data['completed_at']) < previous:
        raise ValueError('completion precedes observations')
    return {'sources': len(data['sources']), 'rounds': len(rounds),
            'candidate_observations': len(rounds) * len(expected)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', nargs='?', type=Path, default=EVIDENCE)
    path = parser.parse_args().evidence
    raw = path.read_bytes()
    summary = verify(json.loads(raw))
    print(json.dumps({'evidence_sha256': hashlib.sha256(raw).hexdigest(),
                      'verified_summary': summary,
                      'raw_response_bodies_recomputed': False}, ensure_ascii=False))


if __name__ == '__main__':
    main()
