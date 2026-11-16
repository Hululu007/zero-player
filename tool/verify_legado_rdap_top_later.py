"""Validate the later .top observations offline; no network or source rules."""
import argparse
from collections import Counter
from functools import lru_cache
import json
from pathlib import Path
import re

if __package__:
    from . import verify_legado_rdap_top_cc as prior
else:
    import verify_legado_rdap_top_cc as prior

ROOT = prior.ROOT
EVIDENCE = 'docs/implementation/legado-rdap-top-later-20261116.json'
PRIOR_SHA = 'bff7d7109129d16471b9c9e6ade4e372703420d782bbb374665d353e48beb9cb'
CAPTURE_SHA = 'bf7c7a739799968fa8330c137a5c00a801be546593936a9c281d257d8111ad17'
CAPTURE_CANONICAL_SHA = '36f6b1f5506196497cedfa9962c873fd44cbc1cbe9d8f0dcb41f9bf19919be33'
LATEST_HEAD = 'docs/implementation/legado-unresolved-943-recheck-20261116.json'
LATEST_HEAD_SHA = '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0'
HOSTS = {
    '99hanman.top': '99hanman.top',
    'duduxiaoshuo.top': 'h5.duduxiaoshuo.top',
    'shenxianfaka.top': 'www.shenxianfaka.top',
    'stxt.top': 'stxt.top',
}
REVIEWED = {
    'shenxianfaka.top': ('2c42e8be93e8d9a0cba17e082bb31665d2dc717c98054dcc596a318b81775211', 950),
    'stxt.top': ('2fa11264c96f40e2d97174ab5dc0393039f3235dad0d0c71b49fdbcee5d788c9', 3062),
}
LIMITATIONS = [
    'Only the two listed exact historical source versions are treated as presently unavailable; this is not host-wide or permanent and does not establish maliciousness.',
    'The earlier second registry round was skipped after a failed control, not a second 404; the later round is separated by several hours and has separate controls.',
    'The duduxiaoshuo.top observations include provider timeouts, which remain unknown; 99hanman.top returned a matching registry object.',
    'The public resolvers may share caches or a network path; no independence or future state is established.',
    'No source site, source rule, account or user database was accessed by the later collector; omitted response bodies and DNS addresses cannot be authenticated offline.',
    'Historical rules use source-relative search and page links; dynamically returned links and future revisions were not verified.',
]
require, timestamp = prior.require, prior.timestamp


@lru_cache(maxsize=1)
def validated_prior():
    raw = (ROOT / prior.EVIDENCE).read_bytes()
    require(prior.sha(raw) == PRIOR_SHA, 'prior evidence digest mismatch')
    value = json.loads(raw)
    prior.verify(value)
    return value


@lru_cache(maxsize=1)
def validated_records():
    return prior.load_inputs(validated_prior())[0]['records']


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _one(rows, key):
    matches = [row for row in rows if prior.observation_key(row) == key]
    require(len(matches) == 1, 'missing or duplicate observation')
    return matches[0]


def _valid_nxdomain(rows, host, provider, query_type):
    row = _one(rows, ('doh', host, provider, query_type))
    require(row.get('classification') == 'nxdomain' and
            row.get('http_status') == 200 and row.get('dns_rcode') == 3 and
            row.get('dns_truncated') is False, 'DNS result is not NXDOMAIN')


def _round(capture, earlier):
    require(set(capture) == {'method', 'prior_formal_evidence', 'bootstrap', 'round'} and
            capture['prior_formal_evidence'] == prior.EVIDENCE and
            capture['method'] == 'One later bounded registry and public DNS round using prior collector; control failures remain skipped; no book-source requests.',
            'unexpected later capture')
    bootstrap = capture['bootstrap']
    require(set(bootstrap) == {'url', 'publication', 'sha256', 'services', 'started_at', 'observed_at'} and
            bootstrap['url'] == 'https://data.iana.org/rdap/dns.json' and
            bootstrap['publication'] == '2026-10-28T22:00:04Z' and
            bootstrap['sha256'] == prior.IANA_SHA256 and bootstrap['services'] == prior.IANA,
            'later registry bootstrap differs')
    round_ = capture['round']
    require(set(round_) == {'round', 'started_at', 'negative_controls', 'controls', 'control_status',
                            'observations', 'skipped', 'completed_at', 'classification_counts'} and
            round_['round'] == 1 and not round_['skipped'], 'later round fields or skipped queries differ')
    start, end = timestamp(round_['started_at']), timestamp(round_['completed_at'])
    require(timestamp(earlier['observed_end_utc']) < timestamp(bootstrap['started_at']) <=
            timestamp(bootstrap['observed_at']) <= start <= end, 'later round chronology differs')
    barrier = prior.barrier_for(earlier['rounds'][-1])
    require(start >= timestamp(barrier['not_before_utc']), 'later round precedes the prior TTL barrier')
    negative = round_['negative_controls']
    require(set(negative) == {'top', 'cc'} and
            all(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.' + tld, host) for tld, host in negative.items()) and
            negative['top'].removesuffix('.top') == negative['cc'].removesuffix('.cc') and
            all(negative['top'] != item['negative_controls']['top'] for item in earlier['rounds']),
            'later negative controls are invalid or reused')
    all_rows = round_['controls'] + round_['observations']
    for row in all_rows:
        prior.common.validate_times(row, start, end)
    for before, after in zip(all_rows, all_rows[1:]):
        require((timestamp(after['started_at']) - timestamp(before['started_at'])).total_seconds() >= .43,
                'later request spacing differs')
    status = prior.derive_control_status(round_['controls'], negative)
    require(round_['control_status'] == status and
            all(status['top'][key] is True for key in ('rdap', 'aliyun', 'tencent')),
            'later .top controls failed')
    expected = {('rdap', domain, None, None) for domain in HOSTS}
    expected |= {('doh', host, provider, typ)
                 for domain, old_host in HOSTS.items() for host in {domain, old_host}
                 for provider in prior.PROVIDERS for typ in prior.QTYPES}
    observed = [prior.observation_key(row) for row in round_['observations']]
    require(len(observed) == len(set(observed)) and set(observed) == expected,
            'later query coverage differs')
    require(round_['classification_counts'] == dict(Counter(row['classification'] for row in round_['observations'])),
            'later classification counts differ')
    return round_


def verify(evidence):
    require(set(evidence) == {'schema_version', 'prior_evidence', 'later_capture_sha256', 'later_capture',
                              'historical_candidates', 'reviewed_unavailable_source_ids', 'limitations',
                              'latest_head_evidence'} and
            evidence['schema_version'] == 1 and evidence['limitations'] == LIMITATIONS,
            'unexpected evidence schema or limitations')
    prior.common.reject_sensitive(evidence)
    prior.shared.reject_url_queries(evidence)
    require(evidence['prior_evidence'] == {'path': prior.EVIDENCE, 'sha256': PRIOR_SHA} and
            evidence['later_capture_sha256'] == CAPTURE_SHA and
            evidence['latest_head_evidence'] == {'path': LATEST_HEAD, 'sha256': LATEST_HEAD_SHA},
            'capture provenance differs')
    recent_bytes = (ROOT / LATEST_HEAD).read_bytes()
    require(prior.sha(recent_bytes) == LATEST_HEAD_SHA, 'recent HEAD evidence digest differs')
    recent_rows = json.loads(recent_bytes)['results']
    capture = evidence['later_capture']
    require(prior.canonical_sha(capture) == CAPTURE_CANONICAL_SHA, 'frozen later observation differs')
    earlier = validated_prior()
    current = _round(capture, earlier)
    historical = [
        {key: row[key] for key in ('registry_domain', 'old_source_host', 'selected_sources')}
        for row in earlier['candidates'] if row['registry_domain'] in HOSTS
    ]
    require(evidence['historical_candidates'] == historical and len(historical) == len(HOSTS),
            'historical source identities differ')
    require(set(evidence['reviewed_unavailable_source_ids']) == {item[0] for item in REVIEWED.values()} and
            len(evidence['reviewed_unavailable_source_ids']) == len(REVIEWED), 'review scope differs')
    records = validated_records()
    old_first, old_second = earlier['rounds']
    require(old_first['control_status']['top']['rdap'] is True and
            old_second['control_status']['top']['rdap'] is False and
            all(old_second['control_status']['top'][p] is True for p in prior.PROVIDERS),
            'earlier control interpretation differs')
    for domain, (source_id, index) in REVIEWED.items():
        candidate = next(row for row in historical if row['registry_domain'] == domain)
        selected = candidate['selected_sources']
        require(len(selected) == 1 and selected[0]['source_id'] == source_id and
                selected[0]['selected_record_index'] == index and candidate['old_source_host'] == HOSTS[domain],
                'reviewed historical source differs')
        matching = [row for row in recent_rows if row.get('host') == HOSTS[domain]]
        require(len(matching) == 1, 'recent HEAD source observation missing')
        recent = matching[0]
        head = recent['latest_head']
        dns = recent['dns']
        require({'source_id': source_id, 'record_index': index} in recent['selected_sources'] and
                head['classification'] == 'dns_host_not_found' and head['http_status'] is None and
                dns['verdict'] == 'repeated_nxdomain' and len(dns['observations']) == 2,
                'recent HEAD or DNS observation differs')
        for observation in dns['observations']:
            require(observation['query_failed'] is False and
                    observation['a'] in (9003, 9501) and observation['aaaa'] in (9003, 9501) and
                    9003 in (observation['a'], observation['aaaa']) and
                    observation['a_address_kinds'] == {} and observation['aaaa_address_kinds'] == {} and
                    timestamp(head['observed_at']) <= timestamp(observation['observed_at']) <
                    timestamp(current['started_at']), 'recent DNS observation differs')
        for round_ in (old_first, current):
            row = _one(round_['observations'], ('rdap', domain, None, None))
            require(row['classification'] == 'http_404_json' and row['http_status'] == 404 and
                    row['rdap_error_code_is_404'] is True, 'controlled registry 404 missing')
        require(any(row == {'mode': 'rdap', 'domain': domain, 'reason': 'control_failed'}
                    for row in old_second['skipped']), 'old failed-control skip missing')
        for host in {domain, HOSTS[domain]}:
            for provider in prior.PROVIDERS:
                for typ in prior.QTYPES:
                    _valid_nxdomain(old_second['observations'], host, provider, typ)
                    _valid_nxdomain(current['observations'], host, provider, typ)
        record = records[index]
        for field in ('searchUrl', 'exploreUrl', 'header', 'loginUrl', 'loginUi', 'loginCheckJs', 'jsLib',
                      'ruleSearch', 'ruleExplore', 'ruleBookInfo', 'ruleToc', 'ruleContent', 'ruleReview'):
            for value in _strings(record.get(field)):
                require(not re.search(r'https?://|\b(?:java|Packages)\s*\.|\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|eval)\s*\(', value, re.I),
                        'reviewed historical rule contains an unreviewed remote target')
    current_rows = current['observations']
    require(_one(current_rows, ('rdap', '99hanman.top', None, None))['classification'] == 'matching_domain_object' and
            any(row['classification'] == 'provider_timeout' and row.get('host') in
                {'duduxiaoshuo.top', 'h5.duduxiaoshuo.top'} for row in current_rows),
            'negative candidate observations lost')
    return {'historical_candidates': len(historical), 'reviewed_source_ids': len(REVIEWED),
            'later_observations': len(current_rows), 'earlier_skipped_rdap_preserved': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    print(json.dumps({'evidence_sha256': prior.sha(raw), 'verified_summary': verify(json.loads(raw)),
                      'historical_response_bodies_recomputed': False}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
