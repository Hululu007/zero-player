"""Create and verify the later unresolved-host HEAD evidence without network.

The committed six prior inputs reconstruct the exact sampling population. The
optional local collector output independently verifies transcription of the
later observations; its SHA is pinned, but its unredacted bytes are not shipped.
"""
import argparse
import bz2
from collections import Counter, defaultdict
import hashlib
import ipaddress
import json
from pathlib import Path
import re

if __package__:
    from . import compare_legado_head_get as earlier
    from . import recheck_legado_failures as retry
    from .triage_legado_eval_candidates import selected_indices
else:
    import compare_legado_head_get as earlier
    import recheck_legado_failures as retry
    from triage_legado_eval_candidates import selected_indices

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = 'docs/implementation/legado-unresolved-head-later-20261116.json'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
MANIFEST = 'assets/catalogs/books/legado/manifest.json'
FOLDER = 'docs/implementation/'
FIRST = FOLDER + 'legado-host-audit-20261115.json'
SECOND = FOLDER + 'legado-host-recheck-20261115.json'
INVENTORY = FOLDER + 'legado-import-inventory-20261115.json'
STAGES = [FOLDER + 'legado-amsi-pilot-20261115.json',
          FOLDER + 'legado-amsi-prior-html-20261115.json',
          FOLDER + 'legado-amsi-other-hosts-20261115.json']
BASELINE_SHA = '9bdca02d649d3d5d9dfdb162fec89d1c50998fab0fca715c1f9c7dc7b2d6a1ff'
RAW_SHA = '08f51c1c1265fec4341334aefeb97a42db39d7654a9e4a15725ffebd5866440d'
RECORDS_SHA = 'ab3a87ae28fe07719ba62469bc3b0718dfe167a5d31b3445dfba275930ab9318'
DNS_CLASSES = {'dns_host_not_found', 'dns_no_data', 'dns_temporary_failure',
               'dns_other', 'dns_timeout'}
FAILURE_CLASSES = DNS_CLASSES | {'connection_or_read_timeout', 'tls_error',
                                 'connection_error', 'non_public_dns_rejected', 'other_error'}
ADDRESS_KINDS = {'public', 'unspecified', 'other_non_public'}
LIMITATIONS = ['One later HTTP status is not proof of readability or safety.',
               'No status and DNS errors do not establish permanent failure.',
               'Results describe the selected historical import inventory and exact hosts.',
               'Collector originals are local build artifacts and are not included.']


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True,
                      separators=(',', ':')).encode('ascii')


def read(path):
    data = (ROOT / path).read_bytes()
    return json.loads(data), digest(data)


def inputs():
    first, first_sha = read(FIRST)
    second, second_sha = read(SECOND)
    inventory, inventory_sha = read(INVENTORY)
    stage_rows = [read(path) for path in STAGES]
    archive_bytes = (ROOT / ARCHIVE).read_bytes()
    manifest, manifest_sha = read(MANIFEST)
    archive_sha = digest(archive_bytes)
    archive = json.loads(bz2.decompress(archive_bytes))
    require(manifest['archiveSha256'] == archive_sha == first['archive_sha256'],
            'catalog archive mismatch')
    require(len(archive['records']) == manifest['records'], 'catalog size mismatch')
    originals, second_rows, gets = earlier.checked_inputs(
        first, first_sha, second, inventory, inventory_sha, [x[0] for x in stage_rows])
    raw_parseable, chosen = selected_indices(archive['records'], inventory)
    selected = defaultdict(list)
    for row in inventory['selected_sources']:
        ident, host = row['id'], row['host']
        idx = chosen[ident]
        require(raw_parseable[idx]['host'] == host, 'selected endpoint differs')
        selected[host].append({'source_id': ident, 'record_index': idx})
    selected = {host: sorted(rows, key=lambda row: row['source_id'])
                for host, rows in selected.items()}
    population = {host for host, item in second_rows.items()
                  if earlier.status_or_none(item['recheck'], 'status') is None
                  and earlier.status_or_none(gets[host], 'http_status') is None}
    require(len(population) == 1023, 'unexpected prior unresolved population')
    references = {FIRST: first_sha, SECOND: second_sha, INVENTORY: inventory_sha,
                  **{path: stage[1] for path, stage in zip(STAGES, stage_rows)},
                  ARCHIVE: archive_sha, MANIFEST: manifest_sha}
    return {'first': originals, 'second': second_rows, 'gets': gets,
            'selected': selected, 'population': population, 'references': references,
            'inventory': inventory}


def _host(host):
    require(isinstance(host, str) and host == host.lower() and len(host) <= 253
            and bool(re.fullmatch(r'[a-z0-9.-]+', host)) and '..' not in host,
            'invalid host')
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return
    raise ValueError('IP literal not permitted in evidence')


def _dns_observation(row):
    if 'error' in row:
        return {'observed_at': row['observed_at'], 'query_failed': True}
    return {'observed_at': row['observed_at'], 'query_failed': False,
            'a': row['a'], 'aaaa': row['aaaa'],
            'a_address_kinds': row['a_address_kinds'],
            'aaaa_address_kinds': row['aaaa_address_kinds']}


def _dns_verdict(observations):
    raw = [{'error': True} if row['query_failed'] else {'a': row['a'], 'aaaa': row['aaaa']}
           for row in observations]
    return retry.dns_verdict(raw)


def _summary(rows):
    return {'hosts': len(rows),
            'selected_source_ids': len({s['source_id'] for r in rows for s in r['selected_sources']}),
            'http_status_recorded': sum(r['latest_head']['http_status'] is not None for r in rows),
            'http_status_unrecorded': sum(r['latest_head']['http_status'] is None for r in rows),
            'http_200': sum(r['latest_head']['http_status'] == 200 for r in rows),
            'latest_classifications': dict(sorted(Counter(r['latest_head']['classification'] for r in rows).items())),
            'dns_verdicts': dict(sorted(Counter(r['dns']['verdict'] for r in rows).items()))}


def _transform(row, context):
    host = row['host']
    _host(host)
    require(host in context['population'], 'unrequested host')
    original = context['first'][host]
    latest = row['recheck']
    require(latest['host'] == host and row['record_indices'] == original['record_indices'],
            'host or archived record indices differ')
    require(row['previous']['observed_at'] == original['observed_at'] and
            row['previous']['error'] == original['error'] and
            row['previous']['classification'] == retry.classification(original),
            'prior baseline observation differs')
    selected = context['selected'].get(host, [])
    require(sorted(row['selected_source_ids']) == sorted(s['source_id'] for s in selected),
            'selected ID association differs')
    require(all(s['record_index'] in original['record_indices'] for s in selected),
            'selected record is not on exact host')
    status = earlier.status_or_none(latest, 'status')
    require(latest['classification'] == retry.classification(latest), 'HEAD classification differs')
    dns = [_dns_observation(x) for x in row.get('dns_observations', [])]
    verdict = row.get('dns_verdict', 'not_checked')
    require((not dns and verdict == 'not_checked') or (dns and verdict == _dns_verdict(dns)),
            'DNS verdict does not match observations')
    return {'host': host, 'record_indices': row['record_indices'], 'selected_sources': selected,
            'prior_head': {'observed_at': original['observed_at'],
                           'classification': retry.classification(original)},
            'latest_head': {'observed_at': latest['observed_at'], 'http_status': status,
                            'classification': latest['classification'],
                            'redirect_category': latest.get('redirect')},
            'dns': {'verdict': verdict, 'observations': dns}}


def build(baseline_bytes, raw_bytes, context):
    require(digest(baseline_bytes) == BASELINE_SHA and digest(raw_bytes) == RAW_SHA,
            'collector input digest mismatch')
    baseline, raw = json.loads(baseline_bytes), json.loads(raw_bytes)
    require(baseline['archive_sha256'] == context['references'][ARCHIVE] and
            raw['archive_sha256'] == context['references'][ARCHIVE] and
            raw['first_audit_sha256'] == BASELINE_SHA and
            raw['import_inventory_sha256'] == context['references'][INVENTORY] and
            raw['selected_source_count'] == len(context['inventory']['selected_sources']) and
            raw['sample_html'] is False and raw['schema'] == 1, 'collector provenance mismatch')
    derivation = baseline['derivation']
    require(derivation['first_sha256'] == context['references'][FIRST] and
            derivation['second_sha256'] == context['references'][SECOND] and
            derivation['inventory_sha256'] == context['references'][INVENTORY] and
            derivation['stages'] == {Path(p).name: context['references'][p] for p in STAGES},
            'baseline inputs differ')
    originals = earlier.host_index(baseline['results'])
    require(set(originals) == context['population'] and
            all(originals[h] == context['first'][h] for h in originals),
            'baseline is not the reconstructed initial HEAD data')
    raw_rows = earlier.host_index(raw['results'])
    require(set(raw_rows) == context['population'], 'collector population differs')
    rows = [_transform(raw_rows[host], context) for host in sorted(raw_rows)]
    summary = _summary(rows)
    require(raw['summary']['hosts'] == summary['hosts'] and
            raw['summary']['source_ids_covered'] == summary['selected_source_ids'] and
            raw['summary']['recheck_classifications'] == summary['latest_classifications'] and
            raw['summary']['dns_verdicts'] == summary['dns_verdicts'],
            'collector summary differs from observations')
    evidence = {'schema_version': 1, 'archive_sha256': context['references'][ARCHIVE],
                'generated_at_utc': raw['generated_at'],
                'method': {'http': 'HTTPS HEAD /; no redirects or body sampling',
                           'dns': 'Windows DnsQuery_W A/AAAA, bypass cache and hosts',
                           'timeout_seconds': raw['timeout_seconds'],
                           'body_saved': False, 'ip_addresses_saved': False,
                           'redirect_targets_saved': False},
                'input_sha256': context['references'],
                'local_collector_sha256': {'baseline': BASELINE_SHA, 'recheck': RAW_SHA},
                'limitations': LIMITATIONS,
                'summary': summary, 'results': rows}
    return evidence


def verify(evidence, context, *, pinned=True):
    require(set(evidence) == {'schema_version', 'archive_sha256', 'generated_at_utc', 'method',
                              'input_sha256', 'local_collector_sha256', 'limitations',
                              'summary', 'results'} and evidence['schema_version'] == 1,
            'unexpected evidence schema')
    require(evidence['input_sha256'] == context['references'] and
            evidence['archive_sha256'] == context['references'][ARCHIVE] and
            evidence['local_collector_sha256'] == {'baseline': BASELINE_SHA, 'recheck': RAW_SHA},
            'evidence input reference mismatch')
    require(evidence['generated_at_utc'] == '2026-11-15T20:39:10.516961+00:00' and
            evidence['limitations'] == LIMITATIONS, 'observation scope mismatch')
    require(evidence['method'] == {'http': 'HTTPS HEAD /; no redirects or body sampling',
                                  'dns': 'Windows DnsQuery_W A/AAAA, bypass cache and hosts',
                                  'timeout_seconds': 6.0, 'body_saved': False,
                                  'ip_addresses_saved': False, 'redirect_targets_saved': False},
            'method mismatch')
    rows = evidence['results']
    require(isinstance(rows, list) and len(rows) == len(context['population']), 'row count differs')
    require([r['host'] for r in rows] == sorted(context['population']), 'host coverage/order differs')
    finish = earlier.timestamp(evidence['generated_at_utc'])
    for row in rows:
        require(set(row) == {'host', 'record_indices', 'selected_sources', 'prior_head', 'latest_head', 'dns'},
                'unexpected row field')
        host = row['host']
        _host(host)
        original, latest = context['first'][host], row['latest_head']
        require(row['record_indices'] == original['record_indices'] and
                row['selected_sources'] == context['selected'].get(host, []), 'source identity differs')
        require(row['prior_head'] == {'observed_at': original['observed_at'],
                                      'classification': retry.classification(original)},
                'prior HEAD evidence differs')
        require(set(latest) == {'observed_at', 'http_status', 'classification', 'redirect_category'},
                'unexpected latest HEAD fields')
        status = latest['http_status']
        if status is None:
            require(latest['classification'] in FAILURE_CLASSES and latest['redirect_category'] is None,
                    'invalid no-response classification')
        else:
            require(not isinstance(status, bool) and isinstance(status, int) and 100 <= status <= 599 and
                    latest['classification'] == retry.classification({'status': status}), 'bad HTTP status')
            require((latest['redirect_category'] in ('same_host', 'other_host', 'parking', 'invalid'))
                    if 300 <= status < 400 else latest['redirect_category'] is None, 'bad redirect category')
        prior_get = earlier.timestamp(context['gets'][host]['sample_observed_at'])
        observed = earlier.timestamp(latest['observed_at'])
        require(prior_get <= observed <= finish, 'HEAD observation order differs')
        dns = row['dns']
        require(set(dns) == {'verdict', 'observations'} and isinstance(dns['observations'], list),
                'unexpected DNS fields')
        observations = dns['observations']
        require((len(observations) in (1, 2)) == (latest['classification'] in DNS_CLASSES),
                'DNS sampling coverage differs')
        previous_time = observed
        for sample in observations:
            when = earlier.timestamp(sample['observed_at'])
            require(previous_time <= when <= finish, 'DNS observation order differs')
            previous_time = when
            failed = sample.get('query_failed')
            require(isinstance(failed, bool), 'invalid DNS error flag')
            expected_fields = {'observed_at', 'query_failed'} if failed else {
                'observed_at', 'query_failed', 'a', 'aaaa', 'a_address_kinds', 'aaaa_address_kinds'}
            require(set(sample) == expected_fields, 'unexpected DNS sample fields')
            if not failed:
                for family in ('a', 'aaaa'):
                    require(type(sample[family]) is int and sample[family] in (0, 9003, 9501),
                            'unsupported DNS status')
                    kinds = sample[family + '_address_kinds']
                    require(isinstance(kinds, dict) and set(kinds) <= ADDRESS_KINDS and
                            all(type(v) is int and 0 < v <= 256 for v in kinds.values()),
                            'invalid address-kind counts')
        require(dns['verdict'] == (_dns_verdict(observations) if observations else 'not_checked'),
                'DNS verdict differs')
    summary = _summary(rows)
    require(evidence['summary'] == summary and summary['hosts'] == 1023 and
            summary['selected_source_ids'] == 990 and summary['http_status_recorded'] == 80 and
            summary['http_status_unrecorded'] == 943 and summary['http_200'] == 40,
            'summary differs')
    if pinned:
        require(digest(canonical(rows)) == RECORDS_SHA, 'observation digest mismatch')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--raw', type=Path)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    context = inputs()
    if args.build:
        require(args.baseline is not None and args.raw is not None and not args.evidence.exists(),
                'build requires both local inputs and a new output path')
        evidence = build(args.baseline.read_bytes(), args.raw.read_bytes(), context)
        verify(evidence, context, pinned=False)
        args.evidence.write_text(json.dumps(evidence, ensure_ascii=True, separators=(',', ':')) + '\n',
                                 encoding='utf-8')
        print('created', args.evidence, 'records_sha256', digest(canonical(evidence['results'])))
    else:
        evidence = json.loads(args.evidence.read_bytes())
        summary = verify(evidence, context)
        if args.raw is not None:
            require(args.baseline is not None, 'raw verification also requires the local baseline')
            reconstructed = build(args.baseline.read_bytes(), args.raw.read_bytes(), context)
            require(reconstructed == evidence, 'sanitized observations differ from collector output')
        print(json.dumps({'verified': True, 'summary': summary, 'collector_bytes_checked': args.raw is not None},
                         ensure_ascii=True))


if __name__ == '__main__':
    main()
