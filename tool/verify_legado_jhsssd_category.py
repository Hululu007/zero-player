"""Offline integrity and identity checks for the redacted jhsssd sample."""
import bz2
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/implementation/legado-jhsssd-category-recheck-20261116.json'
ARCHIVE_PATH = 'assets/catalogs/books/legado/catalog.json.bz2'
ARCHIVE_SHA256 = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
COMMIT = '3454dc75b61d5f1156fc7d577d061b01f0dd6a91'
LEDGER_PATH = 'docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA256 = '2ad2348ab2d2435297d8d6cc04625b62ee07d1c198d8fd70fc7b73b9b79b5e87'
CANONICAL_SHA256 = 'b8cc24dd538e3286d32e07054aa542c2be24c55073aa15454c5e2e1a9a41bb48'
SOURCE_ID = '3ea17136a0ff8e7ece79d304346edb613c2230e4c0ce806a0003e4a9b102dcc5'
OLD = '022794ec9f9953e5468daf7c04e4cec7797bc49d50c28e7fe17f473272a193a3'
NEW = '14abaed50f2c2546b6404056b9980533b5d0709064a641415ed9dc3d4573c598'
SELECTOR = '[property="og:novel:category"]@content'
OTHERS = {
    3054: ('350b49ddbad98b9dbab6fd72722eafcb6827fee88de11e722247a06f6577e7e1', 'www.paper027.com', 404, 'http_status'),
    1055: ('8c0388910159e08cb2f8247cdccf21faec6c093546dc7b8c0cb6dbca7d8686d2', 'www.bxwx5.cc', None, 'ConnectionResetError'),
    1576: ('9f6a31e8f55b360db8171bd458f115b99942bd8c5cb655120be8fefb91279e6c', 'www.biqusa.com', 200, 'non_html_or_encoded'),
    2627: ('b3162a05bcb980f600d5b9527536ea49faad38baa5153eb14b712dd3b3490bf7', 'm.52biquge.com', 200, None),
    4108: ('81fcb67f12ea76659569ed6629060fb1b8c679635d099ae37226802676dea089', 'www.maojiuxs.com', 301, 'redirect_not_followed'),
    3404: ('0e2b98a3ba7c54d6f0f68f10e55a8df690e16c3fe41363c056bf4fad6e5a2236', 'm.bjcan8.com', 502, 'http_status'),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def require(condition, label):
    if not condition:
        raise ValueError(label)


def load_inputs():
    archive = (ROOT / ARCHIVE_PATH).read_bytes()
    ledger = subprocess.check_output(['git', 'show', f'{COMMIT}:{LEDGER_PATH}'], cwd=ROOT)
    return archive, ledger


def validate(evidence, archive, ledger):
    require(digest(canonical(evidence)) == CANONICAL_SHA256, 'evidence changed')
    require(digest(archive) == ARCHIVE_SHA256, 'archive changed')
    require(digest(ledger) == LEDGER_SHA256, 'historical ledger changed')
    refs = evidence['inputs']
    require(refs['archive_path'] == ARCHIVE_PATH and refs['archive_sha256'] == ARCHIVE_SHA256 and
            refs['historical_commit'] == COMMIT and refs['historical_ledger_path'] == LEDGER_PATH and
            refs['historical_ledger_sha256'] == LEDGER_SHA256, 'input reference changed')
    records = json.loads(bz2.decompress(archive))['records']
    sources = {item['selected_record_index']: item for item in json.loads(ledger)['sources']}
    raw, saved, observed = records[4651], sources[4651], evidence['source']
    require(raw['bookSourceUrl'] == 'https://m.jhsssd.com' and
            digest(b'text:html:m.jhsssd.com') == observed['id'] == saved['source_id'] == SOURCE_ID and
            observed['index'] == 4651 and observed['host'] == saved['endpoint_host'] == 'm.jhsssd.com' and
            observed['source_key'] == '' and observed['kind'] == saved['kind'] == 'text' and
            observed['format'] == saved['format'] == 'html', 'source identity changed')
    require(observed['endpoint_sha256'] == saved['endpoint_sha256'] == digest(raw['bookSourceUrl'].encode()) and
            observed['raw_record_canonical_sha256'] == saved['selected_raw_record_canonical_sha256'] == digest(canonical(raw)) and
            observed['old_legado_canonical_sha256'] == saved['normalized_legado_canonical_sha256'] == OLD and
            observed['candidate_legado_canonical_sha256'] == NEW, 'source fingerprint changed')
    fields = ('searchUrl', 'ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent')
    require(set(observed['raw_field_sha256']) == set(fields), 'raw field set changed')
    for field in fields:
        value = raw.get(field)
        encoded = value.encode('utf-8') if isinstance(value, str) else canonical(value)
        require(observed['raw_field_sha256'][field] == digest(encoded), f'raw field changed: {field}')
    require(not raw['ruleSearch']['kind'] and not raw['ruleBookInfo']['kind'] and
            observed['old_search_category_empty'] and observed['old_detail_category_empty'] and
            observed['candidate_info_category'] == SELECTOR and
            observed['candidate_info_category_sha256'] == digest(SELECTOR.encode()), 'category rule changed')
    prior = next(x for x in saved['network_observations'] if x['evidence'] == 'legado-amsi-prior-html-20261115.json')
    expected_prior = {'observed_at': prior['observed_at'], 'http_status': prior['http_status'],
                      'sample_bytes': prior['sample_bytes'], 'sample_sha256': prior['sample_sha256']}
    require(observed['historical_root_get'] == expected_prior, 'prior observation changed')
    _validate_observations(evidence['observations'])
    fixture = evidence['synthetic_fixture']
    require(fixture['engine_extraction'] == {'高H': '高H', '成人小说': '成人小说', '科幻小说': '科幻小说'} and
            fixture['policy_expected'] == {'高H': False, '成人小说': False, '科幻小说': True} and
            fixture['flutter_test_result'] == '4 passed', 'synthetic fixture changed')
    _validate_other_probes(evidence['other_search_probes'], sources)
    serialized = canonical(evidence).decode('utf-8')
    require('?' not in serialized and not re.search(r'https?://|<script|\b(?:\d{1,3}\.){3}\d{1,3}\b', serialized, re.I),
            'unexpected URL, query, script or IP in evidence')
    return {'verified_sources': 1, 'sampled_works': 2, 'other_search_probes': len(OTHERS),
            'network_requests': 0, 'limitation': 'page bodies and collector not retained'}


def _validate_observations(observations):
    before = observations['pre_repair_two_works']
    after = observations['candidate_two_works']
    require(len(before['works']) == len(after['works']) == 2, 'sample count changed')
    for ordinal, (old, new) in enumerate(zip(before['works'], after['works'])):
        require(old['outcome'] == new['outcome'] == 'content_sample', 'sample outcome changed')
        for stage in ('detail', 'content'):
            x, y = old[stage]['observation'], new[stage]['observation']
            require(x['http_status'] == y['http_status'] == 200 and not x['truncated'] and not y['truncated'] and
                    x['sample_sha256'] == y['sample_sha256'] and x['sample_bytes'] == y['sample_bytes'],
                    'paired sample changed')
        x, y = old['detail']['analysis'], new['detail']['analysis']
        require(x['toc_chapter_count'] == y['toc_chapter_count'] == 24 and
                x['detail_category_length'] == 0 and y['detail_category_length'] == 4 and
                x['category_diag']['og_category_nonempty'] and y['category_diag']['engine_matches_og'],
                'category observation changed')
        x, y = old['content']['analysis'], new['content']['analysis']
        require(x['content_characters'] == y['content_characters'] == (1241, 1316)[ordinal] and
                x['content_sha256_utf8'] == y['content_sha256_utf8'] and
                x['same_host_next_content_links'] == y['same_host_next_content_links'] == 1 and
                y['next_links_equal_sampled_toc_chapter'] == 0 and
                y['next_links_match_split_path_pattern'] == 1, 'content observation changed')


def _validate_other_probes(probes, sources):
    require(len(probes) == len(OTHERS), 'other probe count changed')
    for probe in probes:
        index = probe['index']
        require(index in OTHERS, 'other probe identity changed')
        identity, host, status, failure = OTHERS[index]
        require(probe['id'] == sources[index]['source_id'] == identity and
                probe['host'] == sources[index]['endpoint_host'] == host and len(probe['steps']) == 1,
                'other probe source changed')
        observation = probe['steps'][0]['observation']
        require(observation['phase'] == 'search' and observation['http_status'] == status and
                observation['failure'] == failure, 'other probe result changed')


def main():
    evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
    print(json.dumps(validate(evidence, *load_inputs()), ensure_ascii=False))


if __name__ == '__main__':
    main()
