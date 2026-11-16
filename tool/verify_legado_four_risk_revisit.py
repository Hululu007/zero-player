"""Verify four-source redacted evidence offline, without build or network.

This checks fixed Git ledger objects, the packaged archive/inventory, previous
AMSI evidence, internal consistency and the frozen recorded claims. It cannot
authenticate the original HTTP responses or replay the lost collector.
"""
import bz2
from collections import Counter
import datetime
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = 'docs/implementation/legado-four-risk-revisit-20261116.json'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
INVENTORY = 'docs/implementation/legado-import-inventory-20261115.json'
AMSI = 'docs/implementation/legado-amsi-template-clusters-20261115.json'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
LEGADO_REQUEST = 'lib/features/books/data/legado/legado_request.dart'
SAMPLE_COMMIT = 'd02eb41033e22932273e0613fb133f9e395e11df'
SUMMARY_COMMIT = '56955b3d441678f4734d4c8cb4bf377a373212c4'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
INVENTORY_SHA = 'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
AMSI_SHA = '0aaff7d86529327f67ea09f741d62a00a0cf47a03a90175b982619beeed9de3e'
SAMPLE_LEDGER_SHA = '170da0a6054483e83ae0827b7d6f7af18b44f8c20a5a5231856a656fb148fae4'
SUMMARY_LEDGER_SHA = 'cfd87a165b3fb175d603385eb7a64192f9ae11e5c0441ff35d94323594b7265e'
LOCAL_SUMMARY_SHA = 'bff455ac6a1a96b134d9a16130251799540c501de2282aadf31c137d15c150d6'
LEGADO_REQUEST_LF_SHA = 'da65df24e85c72e12e9b6305407612084bd8ea2f6d9197ce66fc96e0bd717914'
CANONICAL_SHA = 'feb2e4cb804b4d6e14a3085b208b05125fd74fd6464201294f06fcc0965730b8'
SOURCES = {
    36: ('1f08fd713aac15e302299bffa11eaed3964cb16a0d6c6024cbaf0cb2e2539c9f', 'get.xiashuzhan.com'),
    1439: ('49288d9a4a46a7b884896dab3a61500fb815269d48f710dbd640dfed9848bf1b', 's.fjwhcbsh.com'),
    2098: ('5395fcb9dde14042bb1d7f37a878fe7400d5e87d0f96178b0e48561e386879e2', 'wap.18biquge.com'),
    4568: ('b580d46efc572f59d536293067e2671c03744bddfda42321e19ff36a058da206', 'www.zongcaixiaoshuow.com'),
}
LIMITATIONS = [
    'The original web responses, temporary collectors, actual network observations, application Legado engine and WebView cannot be recreated or authenticated by offline verification.',
    'The sampling-ledger byte-identical Git object was committed after the first observations; it does not establish the full runtime or prove a commit existed at collection time.',
    'The later summary-ledger Git object matches the ledger at local summary assembly, not the collection-time runtime.',
    'The historical rule declares webView: true; the inspected LegadoRequest parser source does not implement that option, and application behavior was not run.',
    'Git and both named historical objects are required for offline association; a shallow clone may not contain them.',
    'A 7-second bound applies separately to DNS, connection and socket read operations; there was no total wall-clock deadline.',
    'No webpage, chapter text, work title, work path, query data, cookie, source IP or account information is included.',
    'Text clue booleans cover only the defined terms in sampled prefixes; missing terms do not establish safety or absence of adult content.',
    'The sample uses one anonymous synthetic search; zero structural matches does not establish permanent failure.',
    'The two detail samples are limited to 65536 bytes and both truncate; a single chapter and static selector counts do not establish full reading or safety.',
    'Network paths, public DNS caches, security providers and hosted content can change; repeated observations do not prove independent infrastructure.',
]
CLUE_KEYS = {'gambling_business', 'gambling_invitation', 'adult_business',
             'age_gate', 'ordinary_genres', 'challenge'}
OBSERVATIONS = [
    (36,'initial_home','homepage','GET',302,'2026-11-16T02:19:48.112159+00:00',None),
    (1439,'initial_home','homepage','GET',302,'2026-11-16T02:19:50.120387+00:00',None),
    (2098,'initial_home','homepage','GET',302,'2026-11-16T02:19:51.986173+00:00',None),
    (4568,'initial_home','homepage','GET',200,'2026-11-16T02:19:54.290633+00:00',(20598,'f5dc8f8eebb11eb2d10c58b901894efe867c9c12a417dff9ba865e3658178048',False)),
    (36,'repeat_home','homepage','GET',200,'2026-11-16T02:21:39.967978+00:00',None),
    (1439,'repeat_home','homepage','GET',200,'2026-11-16T02:21:41.776287+00:00',None),
    (2098,'repeat_home','homepage','GET',302,'2026-11-16T02:21:43.689392+00:00',None),
    (2098,'old_category_headers','old_genre_page','GET',200,'2026-11-16T02:21:45.990380+00:00',None),
    (36,'later_home_html','homepage','GET',200,'2026-11-16T02:24:59.944631+00:00',(480,'bf76c07e70e38debab47ceac2c15f3519ae38554caccec2f5b29f55aad37cc39',False)),
    (1439,'later_home_html','homepage','GET',200,'2026-11-16T02:25:01.902921+00:00',(476,'19407dfed055c52f9150cb93b2eee073521aecf50780d58d2a8a2260a059d442',False)),
    (2098,'old_category_html','old_genre_page','GET',200,'2026-11-16T02:25:03.641998+00:00',(487,'a03ca6e13b45057c1eec65545b4bd9ee48a7aa2cffde290ed612dac193b7af7e',False)),
    (4568,'synthetic_search','old_search_form','POST',200,'2026-11-16T02:25:06.698647+00:00',(1103,'efd683c46b336efcf4ce411530a5cbabcc6581d2aca49def7eb864cee9d35bc9',False)),
    (4568,'genre_1','old_ordinary_genre','GET',200,'2026-11-16T02:26:05.971848+00:00',(13869,'1c11d5ba8a1656f32bd85278d907b629a91828747a4262073dff1a592464800d',False)),
    (4568,'detail_1','derived_same_host_detail','GET',200,'2026-11-16T02:26:07.704552+00:00',(65536,'cd89ddc0997a74898c557f29e2c3874b9e7cc193363d76479676d6478774d725',True)),
    (4568,'genre_2','old_ordinary_genre','GET',200,'2026-11-16T02:27:19.273234+00:00',(13869,'1c11d5ba8a1656f32bd85278d907b629a91828747a4262073dff1a592464800d',False)),
    (4568,'detail_2','derived_same_host_detail','GET',200,'2026-11-16T02:27:21.016506+00:00',(65536,'cd89ddc0997a74898c557f29e2c3874b9e7cc193363d76479676d6478774d725',True)),
    (4568,'chapter_1','derived_same_host_chapter','GET',200,'2026-11-16T02:27:23.525768+00:00',(11765,'e440cff6e9446babfd9a79b459dbecd6eb5ec97424052a9f076ee6fd10b51fd7',False)),
]
REDIRECTS = {
    (36,'initial_home'):('http',None),
    (1439,'initial_home'):('http',None),
    (2098,'initial_home'):('https',None),
    (2098,'repeat_home'):('https','zairuc.com'),
}
CHECKS = {
    (4568,'synthetic_search'):{'tbody_rows':0,'usable_links':0},
    (4568,'genre_1'):{'tbody_rows':25,'eligible_book_links':25},
    (4568,'genre_2'):{'tbody_rows':25,'eligible_book_links':25},
    (4568,'detail_1'):{'old_toc_anchor_count':366},
    (4568,'detail_2'):{'old_toc_anchor_count':366},
    (4568,'chapter_1'):{'old_content_selector_matches':1,'old_content_visible_characters':1646},
}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def timestamp(value):
    parsed = datetime.datetime.fromisoformat(value)
    require(parsed.tzinfo is not None, 'timestamp lacks timezone')
    return parsed.astimezone(datetime.timezone.utc)


@lru_cache(maxsize=None)
def git_blob(commit, path):
    return subprocess.check_output(['git','show',f'{commit}:{path}'], cwd=ROOT, stderr=subprocess.DEVNULL)


@lru_cache(maxsize=None)
def git_commit_time(commit):
    raw = subprocess.check_output(['git','show','-s','--format=%cI',commit], cwd=ROOT, stderr=subprocess.DEVNULL)
    return timestamp(raw.decode().strip())


def selected_indices(records, inventory):
    parsed = {row['index']:row for row in inventory['raw_parseable']}
    selected, stamps = {}, {}
    for references in inventory['pack_references'].values():
        for index in references:
            item = parsed.get(index)
            if item is None:
                continue
            raw = str(records[index].get('lastUpdateTime',''))
            stamp = int(raw) if re.fullmatch(r'[+-]?\d+', raw) else 0
            if item['id'] not in stamps or stamp > stamps[item['id']]:
                selected[item['id']] = index
                stamps[item['id']] = stamp
    require(len(selected) == len(inventory['selected_sources']) == 2139,
            'inventory selection size differs')
    for item in inventory['selected_sources']:
        actual = parsed[selected[item['id']]]
        require(all(actual[key] == item[key] for key in ('id','name','group','host','kind')),
                'inventory selected record differs')
    return selected


@lru_cache(maxsize=1)
def load_inputs():
    archive, inventory, amsi = [(ROOT / p).read_bytes() for p in (ARCHIVE, INVENTORY, AMSI)]
    old, new = git_blob(SAMPLE_COMMIT, LEDGER), git_blob(SUMMARY_COMMIT, LEDGER)
    require([sha(v) for v in (archive, inventory, amsi, old, new)] ==
            [ARCHIVE_SHA, INVENTORY_SHA, AMSI_SHA, SAMPLE_LEDGER_SHA, SUMMARY_LEDGER_SHA],
            'offline input digest differs')
    records = json.loads(bz2.decompress(archive))['records']
    inventory = json.loads(inventory)
    old, new = json.loads(old), json.loads(new)
    require(inventory['archive_sha256'] == ARCHIVE_SHA and
            old['input_sha256'][ARCHIVE] == new['input_sha256'][ARCHIVE] == ARCHIVE_SHA,
            'archive linkage differs')
    return {'records':records,'selected':selected_indices(records, inventory),
            'old':{r['source_id']:r for r in old['sources']},
            'new':{r['source_id']:r for r in new['sources']},
            'amsi':{r['host']:r for r in json.loads(amsi)['results']}}


def check_provenance(evidence):
    p = evidence['provenance']
    require(set(p) == {'archive','import_inventory','historical_amsi','sampling_ledger','summary_ledger','legado_request_static_source',
                       'local_redacted_summary_sha256','local_summary_assembled_at_utc',
                       'local_redacted_files_distributed','collector_distributed',
                       'local_capture_or_network_authenticity_offline_verifiable'}, 'provenance schema differs')
    require(p['archive'] == {'path':ARCHIVE,'sha256':ARCHIVE_SHA} and
            p['import_inventory'] == {'path':INVENTORY,'sha256':INVENTORY_SHA} and
            p['historical_amsi'] == {'path':AMSI,'sha256':AMSI_SHA}, 'provenance files differ')
    require(p['sampling_ledger'] == {
        'path':LEDGER,'sha256':SAMPLE_LEDGER_SHA,'matching_git_commit':SAMPLE_COMMIT,
        'matching_commit_at_utc':'2026-11-16T02:26:02+00:00',
        'matching_object_identified_after_initial_observations':True,
        'commit_does_not_identify_entire_runtime':True}, 'sampling ledger provenance differs')
    require(p['summary_ledger'] == {
        'path':LEDGER,'sha256':SUMMARY_LEDGER_SHA,'matching_git_commit':SUMMARY_COMMIT,
        'matching_commit_at_utc':'2026-11-16T02:31:18+00:00',
        'scope':'ledger bytes at local summary assembly; not the collection-time runtime'},
        'summary ledger provenance differs')
    require(p['legado_request_static_source'] == {
        'path':LEGADO_REQUEST,'matching_git_commit':SAMPLE_COMMIT,
        'normalized_lf_sha256':LEGADO_REQUEST_LF_SHA,
        'scope':'later-matched single parser file; static inspection, not the collection-time runtime'},
        'parser source provenance differs')
    source = git_blob(SAMPLE_COMMIT, LEGADO_REQUEST).replace(b'\r\n', b'\n')
    require(sha(source) == LEGADO_REQUEST_LF_SHA and b'class LegadoRequest' in source and
            b"options['method']" in source and b'webview' not in source.lower(),
            'historical request parser inspection differs')
    require(p['local_redacted_summary_sha256'] == LOCAL_SUMMARY_SHA and
            p['local_summary_assembled_at_utc'] == '2026-11-16T02:31:49.046766+00:00' and
            p['local_redacted_files_distributed'] is False and p['collector_distributed'] is False and
            p['local_capture_or_network_authenticity_offline_verifiable'] is False,
            'local evidence boundary differs')
    first = timestamp(OBSERVATIONS[0][5])
    last = timestamp(OBSERVATIONS[-1][5])
    sample_commit, summary_commit = git_commit_time(SAMPLE_COMMIT), git_commit_time(SUMMARY_COMMIT)
    require(sample_commit == timestamp(p['sampling_ledger']['matching_commit_at_utc']) and
            summary_commit == timestamp(p['summary_ledger']['matching_commit_at_utc']) and
            first < sample_commit < last < summary_commit <= timestamp(p['local_summary_assembled_at_utc']),
            'commit and observation chronology differs')


def check_sources(evidence, data):
    sources = evidence['sources']
    require(len(sources) == len(SOURCES), 'source count differs')
    require({item['record_index'] for item in sources} == set(SOURCES), 'source indices differ')
    for source in sources:
        require(set(source) == {'record_index','source_id','endpoint_host','name','kind','format',
                                'raw_record_canonical_sha256','sample_ledger_endpoint_sha256',
                                'sample_ledger_normalized_legado_sha256','prior_amsi'}, 'source schema differs')
        index = source['record_index']
        source_id, host = SOURCES[index]
        require(source['source_id'] == source_id and source['endpoint_host'] == host and
                data['selected'][source_id] == index, 'selected identity differs')
        old, new = data['old'][source_id], data['new'][source_id]
        for row in (old, new):
            require(row['selected_record_index'] == index and row['endpoint_host'] == host and
                    all(source[k] == row[k] for k in ('name','kind','format')) and
                    row['endpoint_sha256'] == source['sample_ledger_endpoint_sha256'] and
                    row['normalized_legado_canonical_sha256'] == source['sample_ledger_normalized_legado_sha256'] and
                    row['selected_raw_record_canonical_sha256'] == source['raw_record_canonical_sha256'],
                    'historical ledger source differs')
        record = data['records'][index]
        require(sha(canonical(record)) == source['raw_record_canonical_sha256'] and
                urlsplit(record['bookSourceUrl']).hostname == host, 'archived source differs')
        check_prior(source, data['amsi'])
    check_static_rules(data['records'])


def check_prior(source, amsi):
    prior = source['prior_amsi']
    if source['record_index'] == 4568:
        require(prior is None, 'unscanned historical evidence cannot be inferred')
        return
    record = amsi[source['endpoint_host']]
    inline = record['inline_scripts']['samples'][0]
    require(source['source_id'] in record['selected_source_ids'] and prior == {
        'evidence':AMSI,'observed_at_utc':record['sample_observed_at'],
        'root_classification':record['amsi']['classification'],
        'sample_bytes':record['sample_bytes'],'sample_sha256':record['sample_sha256'],
        'separate_inline_classification':inline['amsi']['classification']},
        'prior sample linkage differs')
    require(prior['root_classification'] == 'detected' and
            prior['separate_inline_classification'] == 'not_detected', 'AMSI attribution differs')


def check_static_rules(records):
    first, second, third, fourth = (records[i] for i in (36,1439,2098,4568))
    require('java.md5Encode' in first['searchUrl'] and 'tktime' in first['searchUrl'],
            'signed search description differs')
    require('java.md5Encode' in second['searchUrl'] and
            'book.fjwhcbsh.com' in second['ruleBookInfo']['tocUrl'] and
            'catalog.fjwhcbsh.com' in second['ruleBookInfo']['tocUrl'],
            'signed cross-host description differs')
    require('POST' in third['searchUrl'] and '/sort/1/{{page}}/' in third['exploreUrl'],
            'source 2098 historical entry differs')
    require('POST' in fourth['searchUrl'] and 'keyboard={{key}}' in fourth['searchUrl'] and
            fourth['ruleExplore']['bookList'] == 'tbody@tr' and
            fourth['ruleToc']['chapterList'] == '#booklist@li@a' and
            fourth['ruleContent']['content'] == '#content@html' and
            "'webView': true" in fourth['ruleToc']['chapterUrl'], 'source 4568 rules differ')


def check_method(evidence):
    require(evidence['method'] == {
        'observation_window_utc':[OBSERVATIONS[0][5], OBSERVATIONS[-1][5]],
        'http_requests':17,'counts_by_record_index':{'36':3,'1439':3,'2098':4,'4568':7},
        'all_resolved_dns_answers_checked_public':True,'connection_pinned_to_checked_address':True,
        'tls_hostname_verified':True,'redirects_followed':False,'cookies_or_credentials_sent':False,
        'source_or_page_scripts_executed':False,'subresources_fetched':False,
        'get_requests':16,'synthetic_search_post_requests':1,'max_sample_bytes':65536,
        'timeout_seconds_per_dns_connect_or_read':7,'overall_wall_deadline_enforced':False},
        'request method, counts or limitations differ')


def check_sample(sample, expected):
    if expected is None:
        require(sample is None, 'unsampled body cannot gain content')
        return
    require(isinstance(sample,dict) and set(sample) == {
        'bytes','sha256','truncated','visible_text_clues','title_clues','description_clues',
        'script_tags','external_script_tags','visible_characters'}, 'sample schema differs')
    require((sample['bytes'],sample['sha256'],sample['truncated']) == expected,
            'sample digest, size or truncation differs')
    for key in ('visible_text_clues','title_clues','description_clues'):
        clues = sample[key]
        require(isinstance(clues,dict) and set(clues) == CLUE_KEYS and
                all(type(value) is bool for value in clues.values()), 'sample clues differ')
    require(type(sample['script_tags']) is int and type(sample['external_script_tags']) is int and
            0 <= sample['external_script_tags'] <= sample['script_tags'] and
            (sample['visible_characters'] is None or
             type(sample['visible_characters']) is int and sample['visible_characters'] >= 0),
            'sample counts differ')


def check_observations(evidence):
    rows = evidence['observations']
    require(len(rows) == len(OBSERVATIONS), 'request count differs')
    require(Counter(str(row['record_index']) for row in rows) ==
            Counter({'36':3,'1439':3,'2098':4,'4568':7}), 'per-source request coverage differs')
    for row, expected in zip(rows, OBSERVATIONS, strict=True):
        require(set(row) == {'record_index','stage','path_role','started_at_utc','method',
                             'http_status','outcome','redirect','sample','structural_checks'},
                'observation schema differs')
        index, stage, role, method, status, at, sample = expected
        require((row['record_index'],row['stage'],row['path_role'],row['method'],row['http_status'],row['started_at_utc']) ==
                (index,stage,role,method,status,at), 'observation identity, time or status differs')
        key = (index,stage)
        expected_outcome = ('http_response_no_html_sample' if status == 302 and stage == 'initial_home'
                            else 'headers_received_only' if stage in ('repeat_home','old_category_headers')
                            else 'html_sampled')
        require(row['outcome'] == expected_outcome, 'observation outcome differs')
        check_sample(row['sample'], sample)
        if key in REDIRECTS:
            scheme, destination = REDIRECTS[key]
            require(row['redirect'] == {'followed':False,'same_host':False,
                                        'scheme':scheme,'destination_host':destination},
                    'redirect was followed or target attribution differs')
        else:
            require(row['redirect'] is None, 'unexpected redirect record')
        require(row['structural_checks'] == CHECKS.get(key), 'static selector result differs')
    times = [timestamp(row['started_at_utc']) for row in rows]
    require(all(a < b for a,b in zip(times,times[1:])), 'observation order differs')
    validate_clue_boundaries(rows)


def validate_clue_boundaries(rows):
    by_key = {(r['record_index'],r['stage']):r for r in rows}
    for key in ((36,'later_home_html'),(1439,'later_home_html')):
        sample = by_key[key]['sample']
        require(sample['script_tags'] == 1 and sample['external_script_tags'] == 0 and
                sample['visible_characters'] == 0, 'small homepage observation differs')
    category = by_key[(2098,'old_category_html')]['sample']
    require(category['script_tags'] == 1 and category['external_script_tags'] == 0 and
            category['visible_characters'] is None, 'category sample coverage differs')
    root = by_key[(4568,'initial_home')]['sample']
    clues = root['visible_text_clues']
    require(clues['adult_business'] and clues['ordinary_genres'] and not clues['age_gate'] and
            not clues['gambling_business'] and not clues['gambling_invitation'] and
            not root['title_clues']['adult_business'] and not root['description_clues']['adult_business'],
            'mixed content clues differ')


def check_interpretation(evidence):
    expected_true = {
        'historical_amsi_is_sample_only_not_site_malware_proof',
        'source36_and1439_signed_rules_or_other_hosts_not_tested',
        'source2098_old_post_search_and_reading_not_tested',
        'source4568_synthetic_search_zero_matches_not_permanent_failure',
        'source4568_mixed_keyword_clues_do_not_prove_sitewide_adult',
        'source4568_old_chapter_rule_declares_webview_true',
        'source4568_one_chapter_does_not_establish_full_reading',
    }
    expected_false = {'actual_legado_engine_or_webview_executed',
                      'automatic_sitewide_classification_or_quarantine_proposed',
                      'source4568_inspected_parser_implements_webview_option'}
    values = evidence['interpretation']
    require(set(values) == expected_true | expected_false and
            all(values[k] is True for k in expected_true) and
            all(values[k] is False for k in expected_false), 'interpretation exceeds evidence')


def verify(evidence, data=None, *, pinned=True):
    require(isinstance(evidence,dict) and set(evidence) == {
        'schema_version','scope','provenance','method','sources','observations','interpretation','limitations'},
        'evidence schema differs')
    if pinned:
        require(sha(canonical(evidence)) == CANONICAL_SHA, 'frozen evidence digest differs')
    require(evidence['schema_version'] == 1 and evidence['scope'] ==
            'Four bundled selected sources; bounded redacted static observations, not a safety or permanent-availability verdict.' and
            evidence['limitations'] == LIMITATIONS, 'scope or limitations differ')
    data = data if data is not None else load_inputs()
    check_provenance(evidence)
    check_sources(evidence, data)
    check_method(evidence)
    check_observations(evidence)
    check_interpretation(evidence)


def main():
    evidence = json.loads((ROOT / EVIDENCE).read_bytes())
    verify(evidence)
    print('Verified 4 bundled identities, two historical Git ledger objects and 17 redacted observations.')
    print('Offline validation cannot authenticate the original network responses or replay the collectors.')


if __name__ == '__main__':
    main()
