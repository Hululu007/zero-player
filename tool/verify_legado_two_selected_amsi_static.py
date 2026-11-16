"""Validate two redacted source observations offline, without build or network.

Git history and the bundled archive establish identity, not network authenticity.
The original responses and interactive collector are not available to replay.
"""
import bz2
from datetime import datetime, timezone
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = 'docs/implementation/legado-two-selected-amsi-static-20261116.json'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
INVENTORY = 'docs/implementation/legado-import-inventory-20261115.json'
PRIOR = 'docs/implementation/legado-amsi-other-hosts-20261115.json'
LATER = 'docs/implementation/legado-amsi-template-clusters-20261115.json'
COMMIT = '1247df93222ac993e04c6db57ba0471fc713a63e'
LEDGER_SHA = 'b6afb51bcce7af5f7f152ffa3f1c3bce824a0419970253e2c110eed299e09448'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
INVENTORY_SHA = 'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
PRIOR_SHA = '25180e804c1df15165af8bb20ae58c5b4dd6b2e24f6a0a092d50281ca5e25750'
LATER_SHA = '0aaff7d86529327f67ea09f741d62a00a0cf47a03a90175b982619beeed9de3e'
CANONICAL_SHA = 'b6d5b776ccfc3ec60efe862fa4dfc0bca4871c2fbf2cceb1c9fc11a7f5501fed'
RAW_SHA = '84eb42ddbcf6b4ba3e51234dd565811d1323529a0e87c25790bd344589bbaec9'
SOURCES = {
    4838: ('825bca65b0ffd75ab89a26aafc8b0f956f0075f28ee56305201766c2c86b70d0',
           'kuronavi.blog', 'df957d27c917e25550f587b8f906cadd6c2e1be04d1ec353a7af33c3a84c0091',
           '3f9f1bde2c7952b9992a8263263b6f07b7f5eba91c12ad2e91d4847a8429a729',
           '53fd11c63af3a2d5f12e92d51101773023703aedcd4ed0e84a22be7f0c02129e'),
    3558: ('b0764c15a1a2830da1600ae84b8ac459a73a8dcbabe968630e10a66c9618137b',
           'm.69shu.la', '4044f101332ff9360e5d7a251335bd9b2292f70e087d39261b435bb11ab36762',
           '8e546ffe239470fe1013e4e37e6d250ab3d6b91039b21e03a83a5c16aaa96753',
           '26d58f87b3f69ed69ce0a81e598d2d87c4dc5ab28b6bc4789877670b8ffa5826'),
}
OBSERVATION_SHAS = (
    '372befc722617718a7be0b702ada2f528ab78b8136b66aecb0973788cc2d2ad6',
    'dfc295c881e2539ce7d996a9f034b8f8034fb1219bd1f7c296e409c6e8b0655f',
    '9f1aa9c3a4668883b1217ff496fa6cbab412d3004021c0316c6225c0abe5d476',
    'cbaabae7a0c6d0f6e44e7732f4691bd89465a0e1d0e05ceea027768501e4f419',
)
CONTROL_SHA = 'a6b67f82ba7cafe1f54671dd8e4f0c0d6221f367cd683fc2128f0dbbe25455b7'
METHOD = ('Each exact host: at most two anonymous HTTPS GET /; all DNS results must be public, '
          'one numeric IP pinned per request, verified TLS, eight-second deadline, no redirects, '
          'no JS execution, cookies, subresources or response body persisted. '
          'At most 32768 response bytes plus one truncation byte.')
LIMITATIONS = ('Only short bounded homepage samples; text and regex matches do not establish execution, '
               'malware, whole-site adult classification, source parsing or safety. Inline samples are '
               'bounded, comments and strings may match; no redirect targets are requested. AMSI provider '
               'may use cloud protection or submit samples. Controls cover a test marker, not actual malware; '
               'repeated matching templates are not independent threats. Original responses and interactive '
               'collector were not distributed; offline verification checks recorded evidence consistency, '
               'not the authenticity of network events. HTTP 302 Location was not collected.')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def same(left, right):
    # Python compares 0 == False and 1 == True; JSON types must stay exact.
    return canonical(left) == canonical(right)


def stamp(value):
    parsed = datetime.fromisoformat(value)
    require(parsed.tzinfo is not None, 'timestamp lacks timezone')
    return parsed.astimezone(timezone.utc)


def selected_indices(records, inventory):
    parsed = {row['index']: row for row in inventory['raw_parseable']}
    selected, times = {}, {}
    for refs in inventory['pack_references'].values():
        for index in refs:
            item = parsed.get(index)
            if item is None:
                continue
            raw = str(records[index].get('lastUpdateTime', ''))
            value = int(raw) if re.fullmatch(r'[+-]?\d+', raw) else 0
            if item['id'] not in times or value > times[item['id']]:
                selected[item['id']], times[item['id']] = index, value
    require(len(selected) == len(inventory['selected_sources']) == 2139,
            'selected population differs')
    return selected


@lru_cache(maxsize=1)
def load_inputs():
    paths = (ARCHIVE, INVENTORY, PRIOR, LATER)
    files = [(ROOT / path).read_bytes() for path in paths]
    require([sha(v) for v in files] == [ARCHIVE_SHA, INVENTORY_SHA, PRIOR_SHA, LATER_SHA],
            'offline input digest differs')
    ledger_raw = subprocess.check_output(['git', 'show', f'{COMMIT}:{LEDGER}'],
                                         cwd=ROOT, stderr=subprocess.DEVNULL)
    require(sha(ledger_raw) == LEDGER_SHA, 'historical ledger object differs')
    commit_time = subprocess.check_output(['git', 'show', '-s', '--format=%cI', COMMIT],
                                          cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
    records = json.loads(bz2.decompress(files[0]))['records']
    inventory = json.loads(files[1])
    ledger = json.loads(ledger_raw)
    require(inventory['archive_sha256'] == ARCHIVE_SHA and
            ledger['input_sha256'][ARCHIVE] == ARCHIVE_SHA, 'archive linkage differs')
    rows = {row['source_id']: row for row in ledger['sources']}
    require(len(rows) == len(ledger['sources']) == 2139, 'ledger IDs differ')
    return {'records': records, 'selected': selected_indices(records, inventory),
            'ledger': rows, 'commit_time': commit_time,
            'prior': {row['host']: row for row in json.loads(files[2])['results']},
            'later': {row['host']: row for row in json.loads(files[3])['results']}}


def check_sources(evidence, data):
    rows = evidence['sources']
    require(len(rows) == 2 and {row['selected_record_index'] for row in rows} == set(SOURCES),
            'source identity count differs')
    for row in rows:
        require(set(row) == {'host', 'selected_record_index', 'source_id', 'kind', 'format',
                             'endpoint_sha256', 'raw_record_sha256', 'normalized_legado_sha256'},
                'source schema differs')
        index = row['selected_record_index']
        identity, host, endpoint, raw, rules = SOURCES[index]
        require((row['source_id'], row['host'], row['endpoint_sha256'],
                 row['raw_record_sha256'], row['normalized_legado_sha256'], row['kind'], row['format']) ==
                (identity, host, endpoint, raw, rules, 'text', 'html'), 'source identity differs')
        source, archived = data['ledger'][identity], data['records'][index]
        require(data['selected'][identity] == index and source['selected_record_index'] == index and
                source['endpoint_host'] == host and source['endpoint_sha256'] == endpoint and
                source['selected_raw_record_canonical_sha256'] == raw and
                source['normalized_legado_canonical_sha256'] == rules and
                source['kind'] == 'text' and source['format'] == 'html' and
                sha(canonical(archived)) == raw and
                urlsplit(archived['bookSourceUrl']).hostname == host, 'historical source differs')
        for stage in ('prior', 'later'):
            old = data[stage][host]
            require(index in old['record_indices'] and identity in old['selected_source_ids'] and
                    old['amsi']['classification'] == 'detected', 'historical detection differs')


def verify(evidence, data=None):
    require(set(evidence) == {'schema', 'started_at', 'completed_at', 'ledger_git_commit',
                              'ledger_sha256', 'archive_sha256', 'prior_evidence_sha256',
                              'sources', 'method', 'limitations', 'control', 'observations',
                              'provenance_limits', 'method_details', 'interpretation'}, 'schema differs')
    require(sha(canonical(evidence)) == CANONICAL_SHA, 'evidence digest differs')
    require(type(evidence['schema']) is int and evidence['schema'] == 1 and evidence['ledger_git_commit'] == COMMIT and
            evidence['ledger_sha256'] == LEDGER_SHA and evidence['archive_sha256'] == ARCHIVE_SHA and
            evidence['prior_evidence_sha256'] == {Path(PRIOR).name: PRIOR_SHA, Path(LATER).name: LATER_SHA},
            'provenance differs')
    require(evidence['method'] == METHOD and evidence['limitations'] == LIMITATIONS,
            'method or limitations differ')
    data = load_inputs() if data is None else data
    require(stamp(data['commit_time']) < stamp(evidence['started_at']) < stamp(evidence['completed_at']),
            'collection chronology differs')
    require(same(evidence['provenance_limits'], {
        'ledger_object_identifies_entire_runtime': False, 'collector_distributed': False,
        'response_body_or_script_saved': False, 'offline_can_authenticate_network_response': False,
        'http_redirect_target_recorded': False, 'historical_git_object_required': True,
    }), 'provenance boundary differs')
    require(same(evidence['method_details'], {
        'max_requests_per_host': 2, 'max_sample_bytes': 32768, 'truncation_probe_bytes': 1,
        'timeout_seconds': 8, 'dns_all_answers_checked_public': True,
        'connect_to_checked_address': True, 'tls_hostname_validation': True,
        'http_redirects_followed': False, 'page_or_source_scripts_executed': False,
        'subresources_requested': False, 'credentials_or_cookies_sent': False,
        'antimalware_provider_may_upload_samples': True,
    }), 'collection boundary differs')
    require(same(evidence['interpretation'], {
        'current_host_security_verified': None, 'current_host_malware_confirmed': None,
        'sitewide_adult_classification': None, 'full_source_readability_verified': None,
        'permanent_unavailability_verified': None, 'legacy_rules_executed': False,
        'script_samples_executed': False, 'tls_errors_prove_permanent_failure': False,
        'wrapped_control_misses_do_not_prove_safety': True,
        'same_template_does_not_prove_independent_threats': True,
    }), 'interpretation exceeds evidence')
    check_sources(evidence, data)
    control = evidence['control']
    require(sha(canonical(control)) == CONTROL_SHA and control['passed'] is True and
            control['negative']['classification'] == 'not_detected' and
            control['eicar']['classification'] == 'detected' and
            control['html_wrapped_eicar']['classification'] == 'not_detected' and
            control['inline_script_with_eicar']['classification'] == 'not_detected',
            'control results differ')
    observations = evidence['observations']
    require(len(observations) == 4 and
            tuple(sha(canonical(row)) for row in observations) == OBSERVATION_SHAS,
            'observation facts differ')
    first, second, sample, fourth = observations
    require((first['host'], first['attempt'], first['http_status'], first['failure']) ==
            ('kuronavi.blog', 1, 302, 'redirect_not_followed') and
            (second['host'], second['attempt'], second['failure']) ==
            ('m.69shu.la', 1, 'tls_error') and
            (fourth['host'], fourth['attempt'], fourth['failure']) ==
            ('m.69shu.la', 2, 'tls_error') and
            'http_status' not in second and 'http_status' not in fourth,
            'redirect or unknown TLS outcome differs')
    require((sample['host'], sample['attempt'], sample['http_status'], sample['sample_bytes'],
             sample['truncated'], sample['amsi']['classification']) ==
            ('kuronavi.blog', 2, 200, 475, False, 'detected') and
            len(sample['inline_scans']) == 1 and sample['inline_scans'][0]['sample_bytes'] == 371 and
            sample['inline_scans'][0]['amsi']['classification'] == 'not_detected',
            'root and inline scan attribution differs')
    times = [stamp(row['started_at']) for row in observations]
    require(all(a < b for a, b in zip(times, times[1:])) and
            stamp(evidence['started_at']) <= times[0] and
            all(stamp(row['started_at']) <= stamp(row['observed_at']) <= stamp(evidence['completed_at'])
                for row in observations), 'observation chronology differs')


def main():
    raw = (ROOT / EVIDENCE).read_bytes()
    require(sha(raw) == RAW_SHA, 'evidence file digest differs')
    verify(json.loads(raw))
    print('Verified two selected identities and four bounded observations without network or build.')
    print('The original network responses and collector cannot be authenticated offline.')


if __name__ == '__main__':
    main()
