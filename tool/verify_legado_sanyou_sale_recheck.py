"""Offline verification of redacted archived-source observations."""
import bz2
from collections import Counter
from datetime import datetime
from functools import lru_cache
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = 'docs/implementation/legado-sanyou-sale-recheck-20261116.json'
EVIDENCE_SHA = '305398e39c6c83d2a99b70a6ad08e7a36ec94e7eafe4221a7b2a8c9a59708f5f'
CANONICAL_SHA = '1174642fc27c806c72e45e7cf1912e5984a2395903ad99145e8cab81a89f9ac1'
OBSERVATIONS_SHA = '3c60954ce28d207f8ae8e1f1f2054691574ff7ccaa0e94050dfa578706f838f2'
SECOND_OBSERVATIONS_SHA = '28cdb4ab540359aa8c2e462673431ec276a25b2e2de447aac5a59ff199c14c4d'
COMMIT = '1247df93222ac993e04c6db57ba0471fc713a63e'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA = 'b6afb51bcce7af5f7f152ffa3f1c3bce824a0419970253e2c110eed299e09448'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
MANIFEST = 'assets/catalogs/books/legado/manifest.json'
MANIFEST_SHA = '59bb9e3551b5a01406c1d720d2b5d5d5f21518eccbb52cd93f8d752c19f7cf66'
PILOT = 'docs/implementation/legado-eight-source-pilot-20261116.json'
PILOT_SHA = 'ab615d995deb1998f1e2cf048168610ae22fe8fb516c6d6af46f714b6c24222f'
ID = 'bc379d9cf7ee312a6d9813e14830fdc689be5b2371fa025529586fc3a67aec1d'
OTHER_ID = '6a45e0819c4f731d5a6edffd650e0b22eb49c8e2eccd5de320e0ae2c701c67e9'
ENDPOINT = 'https://www.3uxiaoshuo.com/'
ENDPOINT_SHA = '461bb4c162e0a7f0abd078b194ff10a4258333273760510ceda34710edeb8c4a'
LEGADO_SHA = '719bcc073e57846c8fa64d94d46537f5fc764f7588af24e29c6fffdf8b210834'
RAW_SHA = 'e21aeed9e48a5137e0a84fe97914f09a29303750a77ad2dcdb9446c51d1e1009'
OTHER_RULE_SHA = 'c7ccae8b1f6031b071e57473cb987969c6a075bdd65b6767d6d1375d4d7c9e58'
OTHER_RAW_SHA = '980b4eff23171322c2f21d72a1a83060bedbafab49fe5fd31ec4d447ff7d51f0'
RULE_FIELDS = {
    'raw_search_sha256': 'f3fccc70e63b8c479d85a58d50a1e4dc3d171f9e8988424d62321f5f195baeb6',
    'raw_explore_sha256': '5ef5d9b1bc2d79aa80e23b982af781a32dc9dc1918bf69af39804471f767259d',
    'raw_search_list_sha256': '921e9b5f0d5c91964b81a765d1804dcaf5ce98478494f553cbc11b58289f9b31',
    'raw_explore_list_sha256': '921e9b5f0d5c91964b81a765d1804dcaf5ce98478494f553cbc11b58289f9b31',
}


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def timestamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.utcoffset() is not None, 'timestamp lacks offset')
    return result


@lru_cache(maxsize=None)
def git_blob(path):
    try:
        result = subprocess.run(['git', '-C', str(ROOT), 'show', f'{COMMIT}:{path}'],
                                capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or historical object unavailable') from None
    require(result.returncode == 0, 'historical object unavailable; shallow clone may omit it')
    return result.stdout


def load_inputs(evidence):
    expected = {'historical_git_commit': COMMIT, 'historical_ledger_path': LEDGER,
                'historical_ledger_sha256': LEDGER_SHA, 'archive_path': ARCHIVE, 'archive_sha256': ARCHIVE_SHA,
                'manifest_path': MANIFEST, 'manifest_sha256': MANIFEST_SHA,
                'prior_pilot_path': PILOT, 'prior_pilot_sha256': PILOT_SHA}
    require(evidence['inputs'] == expected and sha(git_blob(LEDGER)) == LEDGER_SHA, 'historical references mismatch')
    ledger = json.loads(git_blob(LEDGER)); data = {}
    for path, digest in ((ARCHIVE, ARCHIVE_SHA), (MANIFEST, MANIFEST_SHA), (PILOT, PILOT_SHA)):
        raw = (ROOT / path).read_bytes()
        require(sha(raw) == digest == sha(git_blob(path)) and ledger['input_sha256'].get(path) == digest,
                'historical input digest mismatch')
        data[path] = json.loads(bz2.decompress(raw) if path == ARCHIVE else raw)
    require(data[MANIFEST]['archiveSha256'] == ARCHIVE_SHA and
            data[MANIFEST]['records'] == len(data[ARCHIVE]['records']), 'manifest mismatch')
    return ledger, data[ARCHIVE], data[PILOT]


def verify_source(evidence, ledger, archive):
    source = evidence['source']; expected = {
        'source_id': ID, 'selected_record_index': 3134, 'kind': 'text', 'format': 'html',
        'normalized_endpoint': ENDPOINT, 'endpoint_sha256': ENDPOINT_SHA, 'source_key': '',
        'raw_record_canonical_sha256': RAW_SHA, 'normalized_legado_sha256': LEGADO_SHA, **RULE_FIELDS,
    }
    require(source == expected and sha(ENDPOINT.encode()) == ENDPOINT_SHA, 'source identity or rules mismatch')
    by_id = {row['source_id']: row for row in ledger['sources']}
    for ident, index, raw_sha, rule_sha in ((ID, 3134, RAW_SHA, LEGADO_SHA),
                                            (OTHER_ID, 918, OTHER_RAW_SHA, OTHER_RULE_SHA)):
        old = by_id[ident]; raw = archive['records'][index]
        require(old['selected_record_index'] == index and old['kind'] == 'text' and old['format'] == 'html' and
                old['endpoint_host'] == 'www.3uxiaoshuo.com' and old['endpoint_sha256'] == ENDPOINT_SHA and
                old['selected_raw_record_canonical_sha256'] == sha(canonical(raw)) == raw_sha and
                old['normalized_legado_canonical_sha256'] == rule_sha and
                any(index in refs for refs in archive['packs'].values()), 'historical selected source mismatch')
    sibling = evidence['second_source']
    require(sibling == {'source_id': OTHER_ID, 'selected_record_index': 918, 'kind': 'text', 'format': 'html',
                        'normalized_endpoint': ENDPOINT, 'endpoint_sha256': ENDPOINT_SHA,
                        'source_key': '3uxiaoshuo.com#%23@%E9%81%87%E7%9F%A5',
                        'normalized_legado_sha256': OTHER_RULE_SHA, 'raw_record_canonical_sha256': OTHER_RAW_SHA,
                        'raw_search_sha256': '0e3e1cd488cd34688d8603faf3a8088c954cd8281eeb3d3d0ff1230275da0557',
                        'raw_explore_sha256': 'd98535193a1899b957f652574088a9a63985d015dadb05633a8458d7e9562885',
                        'raw_search_list_sha256': 'eae38cbf1dc54f4646bc7390b8a7125737f233f47578e24f8f873956a96fb673',
                        'raw_explore_list_absent': True, 'discovery_falls_back_to_search_list': True},
            'second selected source mismatch')
    raw = archive['records'][3134]
    fields = {'raw_search_sha256': raw['searchUrl'], 'raw_explore_sha256': raw['exploreUrl'],
              'raw_search_list_sha256': raw['ruleSearch']['bookList'],
              'raw_explore_list_sha256': raw['ruleExplore']['bookList']}
    require(all(sha(value.encode()) == RULE_FIELDS[key] for key, value in fields.items()) and
            raw['bookSourceUrl'] == ENDPOINT and
            raw['searchUrl'] == ENDPOINT + 'tag/?key={{key}}' and
            raw['exploreUrl'] == '最近更新::/xiaoshuo/1-{{page}}.html\n热门小说::/xiaoshuo/2-{{page}}.html' and
            fields['raw_search_list_sha256'] == fields['raw_explore_list_sha256'] == 'class.container@class.item',
            'old entry or selector mismatch')
    other = archive['records'][918]
    require(other['bookSourceUrl'] == 'https://www.3uxiaoshuo.com/##@遇知' and
            sha(other['searchUrl'].encode()) == sibling['raw_search_sha256'] and
            sha(other['exploreUrl'].encode()) == sibling['raw_explore_sha256'] and
            sha(other['ruleSearch']['bookList'].encode()) == sibling['raw_search_list_sha256'] and
            other['ruleSearch']['bookList'] == '.item' and
            not other['ruleExplore'].get('bookList'), 'second old entry or selector mismatch')


def verify_prior(evidence, pilot):
    first = next(row for row in pilot['initial']['observations'] if row['index'] == 3134)
    follow = next(row for row in pilot['followups'] if row['index'] == 3134)
    observations = []
    for row in (first, follow):
        step = row['steps'][0]; obs = step['observation']; analysis = step['analysis']
        observations.append({'started_at_utc': obs['started_at'], 'observed_at_utc': obs['observed_at'],
                             'status': obs['http_status'], 'sample_bytes': obs['sample_bytes'],
                             'sample_sha256': obs['sample_sha256'], 'truncated': obs['truncated'],
                             'request_path_sha256_without_query': obs['url_path_sha256'],
                             'engine_book_count': analysis['book_count']})
    require(evidence['prior_pilot_search_observations'] == observations and
            all(o['status'] == 200 and o['engine_book_count'] == 0 for o in observations),
            'prior pilot observations mismatch')


def verify_observations(evidence, *, second=False):
    rows = evidence['second_observations' if second else 'observations']
    roles = ('home', 'old_search', 'old_category_recent', 'old_category_popular')
    require(len(rows) == 8 and [(r['round'], r['role']) for r in rows] ==
            [(n, role) for n in (1, 2) for role in roles], 'observation coverage mismatch')
    require(sha(canonical(rows)) == (SECOND_OBSERVATIONS_SHA if second else OBSERVATIONS_SHA),
            'observation digest mismatch')
    require(len({r['sample_sha256'] for r in rows}) == 8, 'distinct sample hashes lost')
    path_digests = {'home': '8a5edab282632443219e051e4ade2d1d5bbc671c781051bf1437897cbdfea0f1',
                    'old_category_recent': '0719d55b01320d1aeefacaa9d97a0d9318f27dcc62533d3f011e35a6ff640ec1',
                    'old_category_popular': 'a7ab8ca3cde266512d22d808e086c83134d7440f257ced97721d166c59de23b6'}
    for row in rows:
        expected_bytes = 6988 if second and row['round'] == 2 and row['role'] == 'old_category_recent' else 6990
        require(row['method'] == 'GET' and row['status'] == 200 and row['media_type'] == 'text/html' and
                row['sample_bytes'] == expected_bytes and row['truncated'] is False and row['dns_public_answers'] == 2 and
                row['domain_sale_h1_count'] == 2 and row['contact_owner_h3'] is True and
                row['old_list_selector_nodes'] == 0 and row['script_tags_not_executed'] == 1 and
                row['external_scripts_not_requested'] == 0 and row['iframes_not_requested'] == 0 and
                re.fullmatch(r'[0-9a-f]{64}', row['sample_sha256']) is not None, 'bounded observation mismatch')
        if row['role'] in path_digests:
            require(row['path_sha256_including_synthetic_query'] == path_digests[row['role']], 'path digest mismatch')
    searches = [row for row in rows if row['role'] == 'old_search']
    require(searches[0]['path_sha256_including_synthetic_query'] == searches[1]['path_sha256_including_synthetic_query'],
            'synthetic search comparison mismatch')
    times = [timestamp(row['started_at_utc']) for row in rows]
    require(all(a <= b for a, b in zip(times, times[1:])) and (times[4] - times[3]).total_seconds() >= 5,
            'recorded round start times mismatch')


def verify_privacy(evidence):
    forbidden = {'body', 'page', 'cookie', 'authorization', 'cname', 'ip', 'address', 'response_body'}
    def walk(value):
        if isinstance(value, dict):
            require(not forbidden.intersection(k.lower() for k in value), 'raw payload or private field retained')
            for child in value.values(): walk(child)
        elif isinstance(value, list):
            for child in value: walk(child)
        elif isinstance(value, str):
            try: ipaddress.ip_address(value.strip('[]'))
            except ValueError: return
            raise ValueError('IP address retained')
    walk(evidence)
    text = canonical(evidence).decode('utf-8')
    require('?' not in text and '<script' not in text.lower(), 'query or page content retained')


def verify(evidence, *, pinned=True):
    if pinned: require(sha(canonical(evidence)) == CANONICAL_SHA, 'formal evidence digest mismatch')
    require(evidence['schema_version'] == 1 and evidence['status'] == 'bounded_historical_old_source_unavailable_candidate',
            'evidence schema mismatch')
    ledger, archive, pilot = load_inputs(evidence)
    verify_source(evidence, ledger, archive)
    verify_prior(evidence, pilot)
    verify_observations(evidence)
    verify_observations(evidence, second=True)
    require(len({row['sample_sha256'] for row in evidence['observations'] + evidence['second_observations']}) == 16,
            'separate sample hashes lost')
    method = evidence['method']
    require(method['dns_answers_all_passed_python_is_global'] is True and method['first_dns_answer_pinned'] is True and
            method['complete_nonpublic_and_multicast_exclusion_verified'] is False and method['tls_verified'] is True and
            all(method[key] is False for key in ('redirects_followed', 'scripts_executed', 'subresources_loaded',
                                                 'credentials_sent', 'whole_request_deadline_strict', 'css_or_rendering_evaluated')) and
            method['max_html_bytes'] == 65536 and method['socket_timeout_seconds'] == 7 and
            method['round_pause_seconds'] == 5 and method['for_sale_heading_match'] == 'this domain is for sale',
            'method mismatch')
    require(evidence['policy_scope'] == {'exact_archived_sources_only': True, 'host_wide': False,
            'orphan_history_id': False, 'claims_malware': False, 'claims_permanent_failure': False,
            'direct_book_or_cached_work_verified': False}, 'policy scope mismatch')
    require(evidence['collection_artifacts'] == {
        'collector_sha256': '23a2be33a4fff1049c94111cc512482d173f93ef3fb59114233c68f4b9d991d6',
        'sample_paths_sha256': 'da2701035f9de5de445bb6d8dbe45ca8f8f47b229947343a1f63d17200c8b5cf',
        'sample_roots_sha256': '47e334fb20917abef7408d6c688059f1abe7de8d28f7d81a05004843e79506f6',
        'original_redacted_capture_sha256': 'eaddf4e65ca4b08d4c3efa71a84cbe665dd509a420aaf48628086f1cd0b31a0d',
        'second_collector_sha256': '089a6a70d1bf4b0518367f5f1b680002845e03c1c058beded9c98a58a01afb4f',
        'second_original_redacted_capture_sha256': 'caf26528da3640d2fa07f14da0e2129a8d6a42a4f4cf457ef5c9c93aa3a4da2b',
        'raw_pages_or_collectors_in_repository': False, 'transitive_runtime_fully_recorded': False,
    }, 'collection provenance mismatch')
    limitations = ' '.join(evidence['limitations']).lower()
    require(all(term in limitations for term in ('same network', 'hashes differ', 'css', 'earlier',
                                                   'cached', 'not a strict end-to-end deadline', 'not retained')),
            'evidence limitation missing')
    verify_privacy(evidence)
    return {'selected_record_indices': [3134, 918], 'source_ids': [ID, OTHER_ID], 'observations': 16,
            'network_requested': False,
            'historical_pages_reconstructed': False, 'permanent_failure_verified': False}


def main():
    raw = (ROOT / EVIDENCE).read_bytes()
    require(sha(raw) == EVIDENCE_SHA, 'formal evidence byte digest mismatch')
    print(json.dumps({'sha256': sha(raw), 'verified_summary': verify(json.loads(raw))}, ensure_ascii=False))


if __name__ == '__main__':
    main()
