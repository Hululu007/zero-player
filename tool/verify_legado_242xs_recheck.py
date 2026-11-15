"""Verify the redacted 242 novel-source evidence offline; never access the network."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit

if __package__:
    from . import verify_legado_myxzm_recheck as inputs
    from . import verify_legado_rdap_com_eighteen as shared
else:
    import verify_legado_myxzm_recheck as inputs
    import verify_legado_rdap_com_eighteen as shared

ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-242xs-recheck-20261116.json'
SOURCE_ID = '67a2a1f1f3cb1fe0abba50885d93798631ac0776df9eaba887ebb6f5c0f55870'
LEGADO_SHA = '20ee8d7bb248e4657460b7b95eb51da6810e7a4d83ccc4e55992d899696642d5'
OBSERVATIONS_SHA = '4dae1bf1eb231b8b98d802653b315d7a471c451b3a7db90fc218f231990699c7'
ROOT_SAMPLE_SHA = '5cfb758283f0b9940e97855e43caa95a5c8fdddaedd95f7835f65e66abf83fed'
SOURCE = {
    'source_id': SOURCE_ID, 'selected_record_index': 2940, 'kind': 'text', 'format': 'html',
    'endpoint_host': 'www.242xs.info',
    'endpoint_sha256': 'ac1cfa9ff836f606dc46bfdb026d35b090959e3f5e9cf529b9df629bc2ae86ee',
    'selected_raw_record_canonical_sha256': '6e3bfed0b4e6cd41d205f4e4152606995ea02a798d451895782e395067bfdb07',
    'normalized_legado_sha256': LEGADO_SHA,
    'raw_search_sha256': '1c05f115d7c16f7b07e36145600547755c589955c1980dd64d3b64f882e3f0d9',
    'raw_explore_sha256': 'a60eb5fe917ab2fbae59d5ece1ba952817a90286df03273e866d3ab51d098a0e',
    'raw_search_list_sha256': '27810ef2d8679ed646a920fb8726062dfbe59b08491ad0cb82f96267ece3bc05',
    'raw_explore_list_sha256': 'e8b37af8a5d28f1d4c5e5dd0c847f2d91939bf7a2b632767f76870b6c5ef1394',
    'same_host_selected_sources_in_historical_ledger': 1,
    'same_domain_raw_source_records_in_archive': 1,
}
require = shared.require
sha = shared.sha


def verify_source(evidence, archive, ledger):
    require(evidence['source'] == SOURCE, 'selected source or rule digest metadata differs')
    byid = {row['source_id']: row for row in ledger['sources']}
    source = byid.get(SOURCE_ID)
    require(source is not None and source['selected_record_index'] == 2940 and source['format'] == 'html',
            'historical selected source differs')
    selection = {'source_id': SOURCE_ID, 'name': source['name'], 'kind': SOURCE['kind'],
                 'selected_record_index': 2940, 'normalized_legado_sha256': LEGADO_SHA,
                 'endpoint_sha256': SOURCE['endpoint_sha256'],
                 'selected_raw_record_canonical_sha256': SOURCE['selected_raw_record_canonical_sha256']}
    shared.verify_source(selection, SOURCE['endpoint_host'], byid, archive)
    require(sum(s['endpoint_host'] == SOURCE['endpoint_host'] for s in ledger['sources']) == 1,
            'same-host selected source count differs')
    raw = archive['records'][2940]
    fields = {'raw_search_sha256': raw['searchUrl'], 'raw_explore_sha256': raw['exploreUrl'],
              'raw_search_list_sha256': raw['ruleSearch']['bookList'],
              'raw_explore_list_sha256': raw['ruleExplore']['bookList']}
    require(all(isinstance(value, str) and sha(value.encode('utf-8')) == SOURCE[key]
                for key, value in fields.items()), 'archived rule field differs')
    require(raw['searchUrl'] == 'search/result.html?searchkey={{key}}', 'old search path differs')
    categories = json.loads(raw['exploreUrl'])
    require(any(c.get('title') == '玄幻小说' and c.get('url') == '/category/xuanhuan/{{page}}.html'
                for c in categories if isinstance(c, dict)), 'old category path differs')
    count = 0
    for row in archive['records']:
        address = row.get('bookSourceUrl')
        if not isinstance(address, str):
            continue
        try:
            host = (urlsplit(address.split(',{', 1)[0]).hostname or '').lower().rstrip('.')
        except ValueError:
            continue
        if host == '242xs.info' or host.endswith('.242xs.info'):
            count += 1
    require(count == 1, 'same-domain raw source record count differs')


def verify_observations(evidence):
    rows = evidence['observations']
    require(len(rows) == 6, 'expected two three-request rounds')
    ordered = [(r['round'], r['target']) for r in rows]
    require(ordered == [(n, target) for n in (1, 2) for target in ('root', 'old_search', 'old_category')],
            'round or target sequence differs')
    previous = None
    for row in rows:
        start, end = shared.timestamp(row['started_at_utc']), shared.timestamp(row['observed_at_utc'])
        require(start <= end and (end - start).total_seconds() <= 8.1 and (previous is None or previous <= start),
                'observation time or deadline differs')
        previous = end
        if row['target'] == 'root':
            require(row['path'] == '/' and row['http_status'] == 200 and row['sample_bytes'] == 1509 and
                    row['truncated'] is False and row['sample_sha256'] == ROOT_SAMPLE_SHA and
                    row['title'] == '最新视频' and row['video_term_counts'] == {'视频': 7, '播放': 1} and
                    row['novel_term_counts'] == {} and row['old_search_selector_nodes'] == 0 and
                    row['old_category_selector_nodes'] == 0, 'root observation differs')
        elif row['target'] == 'old_search':
            require(row['path'] == '/search/result.html' and row['synthetic_query'] is True and
                    row['http_status'] == 404 and row['response_body_sampled'] is False,
                    'old search observation differs')
        else:
            require(row['path'] == '/category/xuanhuan/1.html' and row['http_status'] == 404 and
                    row['response_body_sampled'] is False, 'old category observation differs')
    canonical = json.dumps(rows, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    require(sha(canonical) == OBSERVATIONS_SHA, 'recorded observations changed')


def verify(evidence):
    require(set(evidence) == {'schema_version', 'scope', 'input_references', 'source', 'method', 'observations',
                              'provenance', 'policy_scope', 'limitations'} and evidence['schema_version'] == 1,
            'unexpected evidence schema')
    require(evidence['provenance'] == {'recorded_observations_canonical_sha256': OBSERVATIONS_SHA,
                                        'raw_http_bodies_in_evidence': False,
                                        'original_collector_in_repository': False}, 'provenance differs')
    require(evidence['policy_scope'] == {
        'matches': 'Only this ID, full normalized endpoint, text/HTML kind, and full normalized Legado fingerprint.',
        'host_wide': False, 'orphan_history_id': False, 'claims_malware': False,
        'claims_permanent_failure': False}, 'policy scope differs')
    require(any('same network' in x for x in evidence['limitations']) and
            any('cannot be independently reconstructed' in x for x in evidence['limitations']),
            'historical network or reconstruction limitations missing')
    shared.common.reject_sensitive(evidence)
    shared.reject_url_queries(evidence)
    archive, ledger = inputs.load_inputs(evidence)
    verify_source(evidence, archive, ledger)
    verify_observations(evidence)
    return {'selected_record_index': 2940, 'source_id': SOURCE_ID, 'normalized_legado_sha256': LEGADO_SHA,
            'root_http_200': 2, 'old_search_http_404': 2, 'old_category_http_404': 2,
            'host_wide': False, 'orphan_history_id': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    result = verify(json.loads(raw))
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': result,
                      'historical_response_bodies_reconstructed': False,
                      'network_observations_independently_verified': False}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
