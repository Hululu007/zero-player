"""Verify the three-source redirect comparison offline without visiting sources."""
import argparse
import json
from pathlib import Path
import re

if __package__:
    from . import verify_legado_myxzm_recheck as inputs
    from . import verify_legado_rdap_com_eighteen as shared
else:
    import verify_legado_myxzm_recheck as inputs
    import verify_legado_rdap_com_eighteen as shared

ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-three-redirect-recheck-20261116.json'
PREVIOUS = 'docs/implementation/legado-unresolved-head-later-20261116.json'
PREVIOUS_SHA = '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd'
OBSERVATIONS_SHA = 'daa8195241818acec4e6cd1850c1d5b012a09caee8b60e6dac1ec5a7f4c39957'
MOBILE_UA = 'Mozilla/5.0 (Linux; Android 9) Mobile Safari/537.36'
METHOD = {
    'previous': 'Earlier evidence reports HEAD /, no redirect following or body sample; its user agent was not recorded.',
    'current': 'Two rounds of anonymous HTTPS GET, public DNS checked and pinned, TLS hostname verified, no redirects, credentials, body reads or subresources; 6-second overall deadline, at most two concurrent requests, minimum 0.25 seconds between starts.',
    'current_user_agents': {'generic': 'ZeroPlayer-SourceAudit/1.0', 'bundled_mobile': MOBILE_UA},
    'search_and_scope': 'Only synthetic GET queries were sent. liquge search was POST and was not submitted; 37yq declared a login URL but it was not requested. Two declared discovery paths per source were tested, not all entries.',
}
SOURCES = {
    'm.liquge.com': {
        'source_id': '8331f056d5f55d30f06d402a554628b75a8d0b3225b633a78e95b3187fd895ea', 'index': 1647,
        'search_sha256': '07260c3cafe7319c855c42c1b79eb98bbebb070cc847c3cac2a519c2f27f9627',
        'explore_sha256': 'ae61ddfb79e6e2fc6c1270c0aaa0da60c0e24f4ff44cd773e99e467a5b2f7ed8',
        'endpoint_sha256': 'f29bce5e9bde0d6b5b07230fc990075c89d0000982ebb6ec177f2a34d66525db',
        'raw_sha256': '50fe071b9d1c1ba2b311be469e83c88016bbff034b07cd0232929f9d1d2e97f8',
        'legado_sha256': '16c6efb392c396e21ca1e1c914b128b95fdfa6e8c8bd3b8f2fe25db877c2d51d',
        'adult': True, 'count': 13, 'search_mode': 'POST_not_sent', 'ua_profile': 'generic'},
    'm.quge7.cc': {
        'source_id': '823e542023d25223e7e3726237ff427b0ae0e204977553859408d457a78c472a', 'index': 3256,
        'search_sha256': '59418f053a9da0edb3f5d2f36ef3792d0f10e6944442f53514d5b986907fde91',
        'explore_sha256': 'a5910db203382de81420d92483ba514d4400b8f393ea3e1a0592a2f3a97d6ebe',
        'endpoint_sha256': '52fef0691cab58025758da7c2a4f05713bb8a5f0327b3dc18ad4a53a426d7a40',
        'raw_sha256': 'facf1ae0b7661afde60be324f5c50563a998c0a520488ff7ce07aab2fe323db2',
        'legado_sha256': '113726a2704a2f8ca2af0b3024e925d62b1b4b5f461ee3f37d060ddbc6a5b9c0',
        'adult': False, 'count': 8, 'search_mode': 'GET_webview_option_not_rendered', 'ua_profile': 'bundled_mobile'},
    'www.37yq.com': {
        'source_id': '28ca4bcd9d92f3557a0ac54bd4bcb2751f66fb7b15bacb53c5fadffff68d6be2', 'index': 3967,
        'search_sha256': '8a162963c9c57c855781c7df1116363c9317f04e877db204a563619fc4c8f29a',
        'explore_sha256': '1dd39bddc9d2de56b34688d3973afd797f45a011046344a2045d42a3469bba0b',
        'endpoint_sha256': 'ac3bf5e4a28232b151278b0d7fadd45e130c27ae390dd897c9c4e239e6a11975',
        'raw_sha256': '9bd70d8d6f898bd83b4817cbc28e9af418252926c230ffbe5047d686a0f479a9',
        'legado_sha256': 'f0eed240f055a41732eb2bd193d63c188ad14222808851ebbf0ca585d80b4f0b',
        'adult': False, 'count': 47, 'search_mode': 'GET_declared_login_not_used', 'ua_profile': 'generic'},
}
TARGETS = {
    'm.liquge.com': {'root': '/', 'discovery_rank': '/rank/weekvisit/', 'discovery_genre': '/all/1/1.html'},
    'm.quge7.cc': {'root': '/', 'search': '/s', 'discovery_fantasy': '/xuanhuan/', 'discovery_urban': '/dushi/'},
    'www.37yq.com': {'root': '/', 'search': '/so.html',
                      'discovery_rank': '/wenku/allvisit_0_0_0_0_0_0_0_1.html',
                      'discovery_library': '/wenku/postdate_1_0_0_0_0_0_0_1.html'},
}
require = shared.require
sha = shared.sha


def load_inputs(evidence):
    refs = evidence['input_references']
    require(set(refs) == {'catalog_archive', 'catalog_manifest', 'source_ledger_historical_git', 'previous_head'},
            'input reference set differs')
    require(refs['previous_head'] == {'path': PREVIOUS, 'sha256': PREVIOUS_SHA}, 'prior HEAD reference differs')
    archive, ledger = inputs.load_inputs({'input_references': {k: v for k, v in refs.items() if k != 'previous_head'}})
    raw = (ROOT / PREVIOUS).read_bytes()
    require(sha(raw) == PREVIOUS_SHA, 'prior HEAD evidence digest differs')
    previous = json.loads(raw)
    require(previous['archive_sha256'] == inputs.ARCHIVE_SHA, 'prior HEAD archive differs')
    return archive, ledger, previous


def declared_categories(host, raw):
    text = raw['exploreUrl']
    if host == 'm.liquge.com':
        return [row['url'] for row in json.loads(text) if row.get('url')]
    if host == 'm.quge7.cc':
        return [line.split('::', 1)[1] for line in text.splitlines() if '::' in line and line.split('::', 1)[1]]
    return [m.group(2) for m in re.finditer(r'''["']url["']\s*:\s*(["'])(.*?)\1''', text) if m.group(2)]


def verify_sources(evidence, archive, ledger):
    sources = evidence['sources']
    require(len(sources) == 3 and {s['host'] for s in sources} == set(SOURCES), 'source set differs')
    byid = {row['source_id']: row for row in ledger['sources']}
    for entry in sources:
        host = entry['host']
        expected = SOURCES[host]
        historical = byid.get(expected['source_id'])
        require(historical is not None and historical['endpoint_host'] == host and
                historical['selected_record_index'] == expected['index'], 'selected source differs')
        snapshot = {'host': host, 'source_id': expected['source_id'], 'selected_record_index': expected['index'],
                    'name': historical['name'], 'kind': 'text', 'format': 'html',
                    'endpoint_sha256': expected['endpoint_sha256'],
                    'selected_raw_record_canonical_sha256': expected['raw_sha256'],
                    'normalized_legado_sha256': expected['legado_sha256'],
                    'static_adult_source': expected['adult'], 'search_sha256': expected['search_sha256'],
                    'explore_sha256': expected['explore_sha256'], 'declared_nonempty_entries': expected['count'],
                    'search_mode': expected['search_mode'], 'ua_profile': expected['ua_profile']}
        require(entry == snapshot and historical['static_policy']['adult_source_classified'] == expected['adult'],
                'source metadata, flags or rule hashes differ')
        selection = {'source_id': entry['source_id'], 'name': entry['name'], 'kind': entry['kind'],
                     'selected_record_index': entry['selected_record_index'],
                     'normalized_legado_sha256': entry['normalized_legado_sha256'],
                     'endpoint_sha256': entry['endpoint_sha256'],
                     'selected_raw_record_canonical_sha256': entry['selected_raw_record_canonical_sha256']}
        shared.verify_source(selection, host, byid, archive)
        raw = archive['records'][expected['index']]
        require(sha(raw['searchUrl'].encode('utf-8')) == expected['search_sha256'] and
                sha(raw['exploreUrl'].encode('utf-8')) == expected['explore_sha256'], 'raw rule digest differs')
        categories = declared_categories(host, raw)
        require(len(categories) == expected['count'] and raw.get('enabledExplore') is not False,
                'declared discovery count differs')
        if host == 'm.liquge.com':
            require("'method': 'post'" in raw['searchUrl'].lower() and '/rank/weekvisit/' in categories and
                    '/all/1/{{page}}.html' in categories, 'POST or sampled discovery rule differs')
        elif host == 'm.quge7.cc':
            require('"webView": true' in raw['searchUrl'] and
                    json.loads(raw['header'])['User-Agent'] == MOBILE_UA and
                    '/xuanhuan/<,{{page}}.html>' in categories and '/dushi/<,{{page}}.html>' in categories,
                    'mobile UA or sampled discovery rule differs')
        else:
            require(raw['loginUrl'] == 'https://www.37yq.com/login.php' and
                    '/wenku/allvisit_0_0_0_0_0_0_0_{{page}}.html' in categories and
                    '/wenku/postdate_1_0_0_0_0_0_0_{{page}}.html' in categories, 'sampled discovery rule differs')


def verify_previous(evidence, previous):
    head = {row['host']: row for row in previous['results']}
    expected = []
    for host in SOURCES:
        row = head[host]
        latest = row['latest_head']
        require(latest['http_status'] == 302 and latest['redirect_category'] == 'other_host' and
                row['selected_sources'] == [{'source_id': SOURCES[host]['source_id'],
                                              'record_index': SOURCES[host]['index']}], 'prior HEAD differs')
        expected.append({'host': host, 'method': 'HEAD', 'observed_at_utc': latest['observed_at'],
                         'http_status': 302, 'redirect_category': 'other_host', 'user_agent': 'not_recorded'})
    require(evidence['previous_head_observations'] == expected, 'prior HEAD transcription differs')


def verify_get(evidence):
    rows = evidence['get_observations']
    expected = {(n, host, target, path) for n in (1, 2) for host, targets in TARGETS.items()
                for target, path in targets.items()}
    actual = {(r['round'], r['host'], r['target'], r['path']) for r in rows}
    require(len(rows) == len(actual) == 22 and actual == expected, 'GET target coverage differs')
    for row in rows:
        host, target, number = row['host'], row['target'], row['round']
        require(row['synthetic_query'] == (target == 'search'), 'synthetic query marker differs')
        if row['observed_at_utc'] is not None:
            observed = shared.timestamp(row['observed_at_utc'])
            require(shared.timestamp('2026-11-15T21:35:25+00:00') <= observed <=
                    shared.timestamp('2026-11-15T21:35:35+00:00'), 'GET observation outside time window')
        if host == 'm.quge7.cc':
            require(row['http_status'] == 200 and row['redirect_host'] is None and row['body_read'] is False and
                    not row['missing_fields'], 'quge GET observation differs')
        elif host == 'm.liquge.com':
            if number == 2 and target == 'root':
                require(row['http_status'] is None and row['body_read'] is None and
                        row['missing_fields'] == ['http_status', 'body_read'], 'truncated liquge status misreported')
            else:
                require(row['http_status'] == 302 and row['body_read'] is False and not row['missing_fields'],
                        'liquge GET observation differs')
            require(row['redirect_host'] == 'ww17.liquge.com' and row['redirect_category'] == 'other_host',
                    'liquge redirect target differs')
        else:
            require(row['http_status'] == 302, '37yq GET status differs')
            if number == 1 and target == 'discovery_library':
                require(row['redirect_host'] is None and row['redirect_scheme'] is None and
                        row['redirect_category'] is None and row['observed_at_utc'] is None and row['body_read'] is None and
                        row['missing_fields'] == ['redirect_host', 'redirect_scheme', 'redirect_category',
                                                  'observed_at_utc', 'body_read'], 'truncated 37yq target misreported')
            else:
                require(row['redirect_host'] == 'ww17.37yq.com' and row['redirect_category'] == 'other_host' and
                        row['body_read'] is False and not row['missing_fields'], '37yq redirect target differs')
    canonical = json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
    require(sha(canonical) == OBSERVATIONS_SHA, 'GET observation record changed')


def verify(evidence):
    require(set(evidence) == {'schema_version', 'scope', 'input_references', 'method', 'sources',
                              'previous_head_observations', 'get_observations', 'provenance', 'limitations'} and
            evidence['schema_version'] == 1, 'unexpected evidence schema')
    require(evidence['provenance'] == {'get_observations_canonical_sha256': OBSERVATIONS_SHA,
                                        'collector_saved': False, 'response_bodies_saved': False,
                                        'output_truncated': True}, 'observation provenance differs')
    require(evidence['method'] == METHOD, 'request method, scope or user agents differ')
    require(any('cannot be independently authenticated' in x for x in evidence['limitations']) and
            any('explicitly null' in x for x in evidence['limitations']) and
            any('not evidence of a functioning reader' in x for x in evidence['limitations']),
            'missing network or truncation limitations')
    shared.common.reject_sensitive(evidence)
    shared.reject_url_queries(evidence)
    archive, ledger, previous = load_inputs(evidence)
    verify_sources(evidence, archive, ledger)
    verify_previous(evidence, previous)
    verify_get(evidence)
    return {'sources': 3, 'previous_head_redirects': 3, 'get_requests': 22,
            'quge_previous_head': 302, 'quge_later_get_200': 8,
            'liquge_post_submitted': False, 'discovery_entries_fully_tested': False,
            'truncated_rows': 2, 'sourcewide_invalidation_proven': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    result = verify(json.loads(raw))
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': result,
                      'original_get_responses_reconstructed': False,
                      'network_observations_independently_verified': False}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
