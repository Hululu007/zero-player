"""Validate the redacted #4371 static pilot offline; no network or build input."""
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
EVIDENCE = 'docs/implementation/legado-4371-structural-review-20261116.json'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
INVENTORY = 'docs/implementation/legado-import-inventory-20261115.json'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
COMMIT = '1247df93222ac993e04c6db57ba0471fc713a63e'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
INVENTORY_SHA = 'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
LEDGER_SHA = 'b6afb51bcce7af5f7f152ffa3f1c3bce824a0419970253e2c110eed299e09448'
CAPTURE_SHA = 'b5bbca7befd094f1924c39a764ba4f95611e7438b78c32c4b6f8f60aea0bc66d'
RAW_SHA = 'f5d78b86a28401b395081ec64aa16a93c29f312b01442c9f40681963153acd9c'
CANONICAL_SHA = 'c1cc0d3dcac27ea827bc16572fdfb694cebfb9694c2fac2b45cad5cbe761546a'
SOURCE_ID = '22fd5687b4cd8b42ce1d69d0701148e989f39833d7d94b1e1dae73795084e242'
HOST = 'www.bsxiaoshuo.com'
ENDPOINT_SHA = '8e502f1b8e3c81cbd0ce27e302bdf745660e2fe347b5e4373e02ef30966d2f8a'
RECORD_SHA = '5f5f1694a131bca90865399a6a3e9c1e57a44a7e37db649c3ad71da9080342b5'
LEGADO_SHA = '5e0ce5b6c43db101d89212f26fab8528e17f91a7c1c2cd82085c62d84e45c43c'
SOURCE_SHA = 'f225c4019a6dd2f134b691fcf4231de5009273abaaec692f94f655f7b35d3db7'
OBSERVATION_SHAS = (
    '6038f786b4ebf54c088767a888286def957bd0ba04221c3104771fccd4729121',
    '49669b2bc6d7661a2168261782340e83f07b9a6d7d065164d5ac1e74759ba9fc',
    '33637f1341d59c019be8a87128fb851b2feb58390dcd665932b1c9044d2aa7eb',
    '225583737ecdcb05fc815e267c1bb131a65c7882d14e4ca194b8a8cf1b7a8254',
    'd55e070255e41f97974b5ed0cfd532958356fd1e55bba9db04c481cb617cca7c',
    '2dbf70c34635a9208d1ba69eb165dfacdfd46fb149440b5849f38a2b8a286826',
)
METHOD_SHA = '06790b3417a0a202d19d3f2239ff52ddc3d18d34eb885d92a9b7aa8c791c610b'
LIMITATIONS_SHA = '3649cd1b2b68f84d1cb164775ee1ddd80bb56616e9ee3e8ebfacd2f402054fa1'
INTERPRETATION_SHA = 'bdb160c5c841f15689277d947b7498c9a0d8960031e6fb5f129f51385df7748f'
PROVENANCE_SHA = 'f73346bd106d6db929190f9abb4321c7d83f7b9374321c2ae48e348dd9697077'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


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
    archive = (ROOT / ARCHIVE).read_bytes()
    inventory_raw = (ROOT / INVENTORY).read_bytes()
    require(sha(archive) == ARCHIVE_SHA and sha(inventory_raw) == INVENTORY_SHA,
            'archive or inventory digest differs')
    ledger_raw = subprocess.check_output(['git', 'show', f'{COMMIT}:{LEDGER}'],
                                         cwd=ROOT, stderr=subprocess.DEVNULL)
    require(sha(ledger_raw) == LEDGER_SHA, 'historical ledger object differs')
    commit_time = subprocess.check_output(['git', 'show', '-s', '--format=%cI', COMMIT],
                                          cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
    records = json.loads(bz2.decompress(archive))['records']
    inventory, ledger = json.loads(inventory_raw), json.loads(ledger_raw)
    require(inventory['archive_sha256'] == ARCHIVE_SHA and
            ledger['input_sha256'][ARCHIVE] == ARCHIVE_SHA and
            ledger['input_sha256'][INVENTORY] == INVENTORY_SHA, 'archive linkage differs')
    rows = {row['source_id']: row for row in ledger['sources']}
    require(len(rows) == len(ledger['sources']) == 2139, 'historical ledger IDs differ')
    return {'records': records, 'selected': selected_indices(records, inventory),
            'ledger': rows, 'commit_time': commit_time}


def check_source(evidence, data):
    source = evidence['source']
    expected = {
        'selected_record_index': 4371, 'source_id': SOURCE_ID, 'endpoint_host': HOST,
        'kind': 'text', 'format': 'html', 'endpoint_sha256': ENDPOINT_SHA,
        'raw_record_canonical_sha256': RECORD_SHA, 'normalized_legado_sha256': LEGADO_SHA,
        'normalized_source_sha256': SOURCE_SHA,
    }
    require(canonical(source) == canonical(expected), 'selected source identity differs')
    row, raw = data['ledger'][SOURCE_ID], data['records'][4371]
    require(data['selected'][SOURCE_ID] == 4371 and row['selected_record_index'] == 4371 and
            row['endpoint_host'] == HOST and row['kind'] == 'text' and row['format'] == 'html' and
            row['endpoint_sha256'] == ENDPOINT_SHA and
            row['selected_raw_record_canonical_sha256'] == RECORD_SHA and
            row['normalized_legado_canonical_sha256'] == LEGADO_SHA and
            row['normalized_source_canonical_sha256'] == SOURCE_SHA and
            sha(canonical(raw)) == RECORD_SHA and urlsplit(raw['bookSourceUrl']).hostname == HOST,
            'historical ledger or archived record differs')
    require(raw['ruleSearch']['bookList'] == '#j li' and
            raw['ruleExplore']['bookList'] == 'tbody tr' and
            raw['ruleToc']['chapterList'] == '.float-list li' and
            raw['ruleContent']['content'] == '.page-content@html',
            'recorded selector interpretation differs')


def verify(evidence, data=None):
    require(set(evidence) == {'schema_version', 'scope', 'provenance', 'source', 'method',
                              'observations', 'interpretation', 'limitations'}, 'evidence schema differs')
    require(type(evidence['schema_version']) is int and evidence['schema_version'] == 1 and
            sha(canonical(evidence)) == CANONICAL_SHA, 'evidence digest differs')
    require(evidence['scope'] == 'One selected bundled source; six bounded static observations, not a safety, sitewide classification, permanent failure or full-readability verdict.' and
            sha(canonical(evidence['provenance'])) == PROVENANCE_SHA and
            sha(canonical(evidence['method'])) == METHOD_SHA and
            sha(canonical(evidence['interpretation'])) == INTERPRETATION_SHA and
            sha(canonical(evidence['limitations'])) == LIMITATIONS_SHA, 'method or limits differ')
    data = load_inputs() if data is None else data
    check_source(evidence, data)
    provenance = evidence['provenance']
    require(provenance['local_redacted_capture_sha256'] == CAPTURE_SHA and
            provenance['network_authenticity_verifiable_offline'] is False and
            provenance['collector_or_dependencies_distributed'] is False,
            'capture authentication or replay boundary differs')
    method = evidence['method']
    require(method['request_count'] == 6 and method['synthetic_searches'] == 2 and
            method['synthetic_keywords_distinct'] is True and method['works'] == 1 and
            method['chapters'] == 1 and method['redirects_followed'] is False and
            method['capture_requests_fetched_subresources'] is False and
            method['page_or_source_scripts_executed'] is False and
            method['overall_wall_deadline_enforced'] is False and
            method['max_sample_bytes'] == 65536 and
            method['dns_validator'] == 'Python ipaddress.is_global; no independent multicast exclusion',
            'sampling method differs')
    observations = evidence['observations']
    require(len(observations) == 6 and
            tuple(sha(canonical(row)) for row in observations) == OBSERVATION_SHAS,
            'observation facts differ')
    first, second, category, detail, toc, chapter = observations
    require([row['stage'] for row in observations] ==
            ['old_search', 'old_search', 'old_category', 'selected_detail', 'selected_toc', 'selected_chapter'],
            'observation stage differs')
    for search in (first, second):
        require((search['old_search_items'], search['items_with_anchor_and_bold'],
                 search['no_results_placeholder_count']) == (1, 0, 1), 'search placeholder differs')
    require(category['old_table_rows'] == 50 and detail['same_host_toc_candidate'] is True and
            toc['same_host_safe_chapter_candidates'] == 19 and
            chapter['old_content_nodes'] == 1 and chapter['visible_characters'] == 2056,
            'bounded structural counts differ')
    times = [stamp(row['http']['started_at_utc']) for row in observations]
    require(stamp(data['commit_time']) < times[0] and all(a < b for a, b in zip(times, times[1:])),
            'observation chronology differs')
    require(all(row['http']['method'] == 'GET' and row['http']['status'] == 200 and
                row['http']['sample_bytes'] <= 65536 and row['http']['truncated'] is False
                for row in observations), 'sample status or size differs')


def main():
    raw = (ROOT / EVIDENCE).read_bytes()
    require(sha(raw) == RAW_SHA, 'evidence file digest differs')
    verify(json.loads(raw))
    print('Verified selected #4371 identity and six redacted static observations without build or network.')
    print('Original capture and network responses cannot be replayed or authenticated offline.')


if __name__ == '__main__':
    main()
