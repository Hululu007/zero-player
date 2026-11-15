"""Verify redacted mixed-category homepage evidence offline, without network access."""
import argparse
import bz2
from collections import Counter
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess

if __package__:
    from . import verify_legado_rdap_com_eighteen as shared
else:
    import verify_legado_rdap_com_eighteen as shared

common = shared.common
ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-adult-mixed-home-recheck-20261116.json'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
COMMIT = 'a6c7d9986a64a2c7328c5f74c06415a116ef27a9'
FILES = {'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
         'catalog_manifest': 'assets/catalogs/books/legado/manifest.json'}
SOURCE_IDS = {
    '04bcb61b79595729a59083d8137d536c9aea56a8b5023a601cbccb9c8e7bd204': ('i.12bz.net', 4729, False),
    '25209b2554ef51f2360edd02c813a63fd799ad8d9674b091fb68bd4c8c66509f': ('i.12bz.net', 4740, False),
    'df954ffc66302d0b7d931af18f0c850a51b72baa03054f3ad59196e2c60f1a5f': ('i.12bz.net', 1236, True),
    '63ae1d87e428bc772aed26b531b073f05ec2b07ae32ca1b89e1a466bbad66fc1': ('m.zhanvxs.cc', 4485, False),
    'e9a26ffe1152c5087487e223a1b328969f5ad54778240052f34daca3b2664804': ('m.zhanvxs.cc', 4494, False),
}
MIXED_IDS = ('63ae1d87e428bc772aed26b531b073f05ec2b07ae32ca1b89e1a466bbad66fc1',
             'e9a26ffe1152c5087487e223a1b328969f5ad54778240052f34daca3b2664804')
FIRST_ID = '04bcb61b79595729a59083d8137d536c9aea56a8b5023a601cbccb9c8e7bd204'
SECOND_ID = '25209b2554ef51f2360edd02c813a63fd799ad8d9674b091fb68bd4c8c66509f'
ADULT_ID = 'df954ffc66302d0b7d931af18f0c850a51b72baa03054f3ad59196e2c60f1a5f'
OBSERVATION_SHA256 = 'b5ff26ee25873ca053340cf6140033289ef04d1163a8d78d9891141b278bddfb'
REDACTED_DRAFT_SHA256 = '79b2a5c1a39a2ee7f27b934c11fa41d2de87d1ae0e221502a9cd4285a691c211'
require, sha, timestamp = common.require, common.sha, common.timestamp

# These are generic category indicators, not source page text or work identifiers.
STRONG = re.compile(r'(\u8272\u60c5|\u60c5\u8272|\u6210\u4eba|\u8089\u6587|\u60c5\u617e|\u60c5\u6b32|\u4e71\u4f26|\u4e82\u502b|\u5f3a\u5978|\u5f37\u59e6|\bH\s*\u6587|\u9ad8\s*H|\u5341\u516b\u7981|18\u7981)', re.I)
WEAK = re.compile(r'(\u6fc0\u60c5|\u6682\u6627|\u66d6\u6627|\u502b\u7406|\u4f26\u7406|\u6027\u611f|\u79c1\u5bc6)', re.I)
ORIENTATION = re.compile(r'(\u803d\u7f8e|\u767e\u5408|\bBL\b|\u540c\u6027)', re.I)
ORDINARY = re.compile(r'(\u7384\u5e7b|\u5947\u5e7b|\u6b66\u4fa0|\u6b66\u4fe0|\u4ed9\u4fa0|\u4ed9\u4fe0|\u4fee\u771f|\u79d1\u5e7b|\u79d1\u5e7b|\u90fd\u5e02|\u8a00\u60c5|\u7231\u60c5|\u611b\u60c5|\u6821\u56ed|\u6821\u5712|\u5386\u53f2|\u6b77\u53f2|\u519b\u4e8b|\u519b\u4e8b|\u60ac\u7591|\u61f8\u7591|\u63a8\u7406|\u6050\u6016|\u7a7f\u8d8a|\u7f51\u6e38|\u7db2\u6e38|\u5168\u672c|\u5b8c\u672c|\u5168\u90e8|\u539f\u521b|\u539f\u5275|\u73b0\u4ee3|\u73fe\u4ee3|\u53e4\u4ee3)', re.I)

METHOD = {
    'requests': 'Exactly two anonymous HTTPS GET / per fixed host; 8-second deadlines; verified TLS and vetted public destination; no redirects, credentials, cookies, origin, script execution, or linked-resource requests.',
    'sample': 'Only up to 65536 bytes of HTML in memory; scripts, style, templates and comments are not analyzed; raw response, page title, work names, source category text and URLs are not retained.',
    'signals': 'Fixed lexical indicators and counts only; adult-category matches and age gates require interpretation, and ordinary/BL labels do not imply adult content.',
    'source': 'Selected IDs and saved discovery rules from the bundled catalog and historical ledger; this is not a user-installation audit.',
}
LIMITATIONS = [
    'The two observations per host are seconds apart on one network path and may share caches; they are not independent long-term observations.',
    'Only a bounded homepage sample and fixed lexical indicators were examined. No match does not establish the absence of adult content or any site safety conclusion.',
    'A mixed discovery rule with an adult category does not by itself establish that the entire source or site is adult-only.',
    'Orientation labels do not establish adult content. Unclassified category labels remain unknown rather than being counted as general or adult categories.',
    'An existing adult source classification belongs to that source identity at the historical snapshot; it is not a verdict on another source sharing a host.',
    'The adult policy values are historical ledger values from the pinned Git commit; they are not current user settings, runtime state, or proof of the current working tree.',
    'Source code hashes use CRLF-to-LF normalization and refer to the pinned Git snapshot. Offline verification needs Git and the historical object; shallow clones may omit it.',
    'Raw page responses were not retained. Offline verification checks redacted records and static catalog facts, not the authenticity or completeness of the omitted responses.',
]
DECISIONS = {
    'm.zhanvxs.cc': {'site_adult_status_from_sample': 'undetermined',
                     'new_source_classification': 'not_supported',
                     'mixed_discovery_source_ids': list(MIXED_IDS)},
    'i.12bz.net': {'site_adult_status_from_sample': 'undetermined',
                   'new_source_classification': 'not_supported',
                   'historical_adult_source_id': ADULT_ID,
                   'other_historical_source_ids': [FIRST_ID, SECOND_ID],
                   'infer_adult_for_same_host_siblings': False},
}


def canonical_sha(value):
    return sha(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8'))


@lru_cache(maxsize=None)
def git_blob(path):
    try:
        result = subprocess.run(['git', '-C', str(ROOT), 'show', COMMIT + ':' + path],
                                capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or the historical snapshot is unavailable') from None
    require(result.returncode == 0, 'historical snapshot unavailable; shallow clones may omit it')
    return result.stdout


def load_inputs(evidence):
    refs = evidence['input_references']
    require(set(refs) == set(FILES) | {'source_ledger_historical_git'}, 'input reference set mismatch')
    raw = {}
    for key, path in FILES.items():
        ref = refs[key]
        require(ref == {'path': path, 'sha256': ref.get('sha256')}, 'unexpected input path or fields')
        raw[key] = (ROOT / path).read_bytes()
        require(sha(raw[key]) == ref['sha256'], 'input digest mismatch: ' + key)
    ref = refs['source_ledger_historical_git']
    require(ref == {'commit': COMMIT, 'path': LEDGER, 'sha256': ref.get('sha256')},
            'historical ledger reference mismatch')
    ledger_raw = git_blob(LEDGER)
    require(sha(ledger_raw) == ref['sha256'], 'historical ledger digest mismatch')
    ledger = json.loads(ledger_raw)
    archive = json.loads(bz2.decompress(raw['catalog_archive']))
    manifest = json.loads(raw['catalog_manifest'])
    require(manifest['archiveSha256'] == sha(raw['catalog_archive']) and
            manifest['records'] == len(archive['records']), 'catalog archive or manifest mismatch')
    for key, path in FILES.items():
        require(ledger['input_sha256'].get(path) == sha(raw[key]), 'historical ledger input differs: ' + key)
    source = evidence['source_code_snapshot']
    require(source == {'commit': COMMIT, 'digest_convention': 'sha256_crlf_to_lf',
                       'normalized_sha256': ledger['normalized_source_code_sha256']},
            'historical source-code snapshot differs')
    for path, expected in source['normalized_sha256'].items():
        require(sha(git_blob(path).replace(b'\r\n', b'\n')) == expected,
                'historical normalized source digest differs')
    return archive, ledger


def static_category_counts(text):
    require(isinstance(text, str) and not any(marker in text.lower()
            for marker in ('@js:', '<js>', '{{java.', 'eval(')), 'unsupported dynamic discovery rule')
    parts = [part for line in text.split('\n') for part in line.split('&&') if '::' in part]
    labels = [part.split('::', 1)[0] for part in parts if part.split('::', 1)[1].strip()]
    counts = Counter()
    for label in labels:
        if STRONG.search(label):
            kind = 'explicit_adult_category'
        elif WEAK.search(label):
            kind = 'suggestive_category_only'
        elif ORIENTATION.search(label):
            kind = 'orientation_category_only'
        elif ORDINARY.search(label):
            kind = 'general_genre_category'
        else:
            kind = 'unclassified_label'
        counts[kind] += 1
    return {'category_count': len(labels), 'semantic_class_counts': dict(counts)}


def verify_sources(evidence, archive, ledger):
    rows = evidence['source_snapshot']
    require(len(rows) == len(SOURCE_IDS) and {row['source_id'] for row in rows} == set(SOURCE_IDS),
            'selected source identities differ')
    byid = {row['source_id']: row for row in ledger['sources']}
    for source in rows:
        verify_source(source, byid, archive)
    by_source = {row['source_id']: row for row in rows}
    first, second = (by_source[ident] for ident in MIXED_IDS)
    require(first['endpoint_sha256'] == second['endpoint_sha256'] and
            first['discovery_sha256'] == second['discovery_sha256'] and
            first['normalized_legado_sha256'] != second['normalized_legado_sha256'],
            'mixed same-host identity boundary differs')
    counts = first['static_discovery_signal_counts']
    require(counts == {'category_count': 8, 'semantic_class_counts': {'explicit_adult_category': 1,
            'general_genre_category': 2, 'orientation_category_only': 3, 'unclassified_label': 2}},
            'mixed category evidence differs')
    siblings = [by_source[ident] for ident in (FIRST_ID, SECOND_ID, ADULT_ID)]
    require(siblings[0]['discovery_sha256'] == siblings[1]['discovery_sha256'] and
            siblings[0]['endpoint_sha256'] == siblings[2]['endpoint_sha256'] and
            len({row['normalized_legado_sha256'] for row in siblings}) == 3,
            'same-host sibling identity boundary differs')
    require(all(row['static_discovery_signal_counts'] == {'category_count': 19,
                'semantic_class_counts': {'general_genre_category': 5, 'unclassified_label': 14}}
                for row in siblings), 'sibling category evidence differs')


def verify_source(source, byid, archive):
    fields = {'host', 'source_id', 'selected_record_index', 'kind', 'format', 'static_adult_policy_snapshot',
              'normalized_legado_sha256', 'endpoint_sha256', 'selected_raw_record_canonical_sha256',
              'discovery_sha256', 'static_discovery_signal_counts'}
    require(set(source) == fields, 'unexpected source snapshot fields')
    ident = source['source_id']
    host, index, adult = SOURCE_IDS[ident]
    historic = byid[ident]
    require(source['host'] == host and source['selected_record_index'] == index and
            source['static_adult_policy_snapshot'] is adult and
            historic['static_policy']['adult_source_classified'] is adult and
            source['format'] == historic['format'] == 'html', 'historical source policy or identity differs')
    shared.verify_source({'source_id': ident, 'name': historic['name'], 'kind': source['kind'],
                          'selected_record_index': index,
                          'normalized_legado_sha256': source['normalized_legado_sha256'],
                          'endpoint_sha256': source['endpoint_sha256'],
                          'selected_raw_record_canonical_sha256': source['selected_raw_record_canonical_sha256']},
                         host, byid, archive)
    discovery = archive['records'][index].get('exploreUrl', '')
    require(source['discovery_sha256'] == sha(discovery.encode('utf-8')) and
            source['static_discovery_signal_counts'] == static_category_counts(discovery),
            'static discovery signals or digest differ')


def verify_observations(evidence):
    rows = evidence['observations']
    require(len(rows) == 4 and {(r['host'], r['round']) for r in rows} ==
            {(host, n) for host in ('m.zhanvxs.cc', 'i.12bz.net') for n in (1, 2)},
            'homepage observation coverage differs')
    expected_fields = {'host', 'round', 'started_at', 'observed_at', 'http_status', 'sample_bytes', 'truncated',
                       'classification', 'charset', 'decoding_replacement_count', 'signals'}
    expected_signals = {'title_present', 'description_present', 'title_explicit_adult_business_phrase',
                        'description_explicit_adult_business_phrase', 'title_suggestive_word',
                        'description_suggestive_word', 'minor_gate_signal', 'nav_or_category_link_count',
                        'all_link_count', 'nav_category_signal_counts'}
    bools = expected_signals - {'nav_or_category_link_count', 'all_link_count', 'nav_category_signal_counts'}
    last = None
    for row in rows:
        require(set(row) == expected_fields and row['classification'] == 'html_sample' and
                row['http_status'] == 200 and row['truncated'] is False and
                type(row['sample_bytes']) is int and 0 < row['sample_bytes'] <= 65536 and
                row['charset'] in ('utf-8', 'gb18030') and row['decoding_replacement_count'] == 0,
                'unexpected or incomplete homepage observation')
        start, end = timestamp(row['started_at']), timestamp(row['observed_at'])
        require(start <= end and (last is None or start >= last), 'invalid observation timing or order')
        last = end
        signals = row['signals']
        require(set(signals) == expected_signals and all(type(signals[k]) is bool for k in bools),
                'unexpected homepage signal fields')
        nav, all_links = signals['nav_or_category_link_count'], signals['all_link_count']
        counts = signals['nav_category_signal_counts']
        allowed = {'explicit_adult_category', 'general_genre_category', 'orientation_category_only',
                   'suggestive_category_only'}
        require(type(nav) is int and type(all_links) is int and 0 <= nav <= all_links and
                isinstance(counts, dict) and set(counts) <= allowed and
                all(type(v) is int and 0 < v <= nav for v in counts.values()), 'invalid homepage category counts')
    require(canonical_sha(rows) == OBSERVATION_SHA256, 'frozen homepage observation digest differs')


def verify(evidence):
    fields = {'schema', 'generated_at', 'method', 'limitations', 'input_references', 'source_code_snapshot',
              'collection_provenance', 'source_snapshot', 'observations', 'decisions'}
    require(set(evidence) == fields and evidence['schema'] == 1, 'unexpected evidence fields or schema')
    common.reject_sensitive(evidence)
    shared.reject_url_queries(evidence)
    require(evidence['method'] == METHOD and evidence['limitations'] == LIMITATIONS,
            'method or limitations differ')
    require(evidence['decisions'] == DECISIONS, 'conservative interpretation or sibling boundary differs')
    require(evidence['collection_provenance'] == {'redacted_build_summary_sha256': REDACTED_DRAFT_SHA256,
            'redacted_summary_generated_at_utc': '2026-11-15T21:07:36.638342+00:00',
            'raw_html_retained': False, 'page_titles_retained': False, 'work_identifiers_retained': False},
            'redacted collection provenance differs')
    archive, ledger = load_inputs(evidence)
    verify_sources(evidence, archive, ledger)
    verify_observations(evidence)
    require(timestamp(evidence['generated_at']) >= timestamp(evidence['observations'][-1]['observed_at']),
            'evidence generated before last observation')
    return {'hosts': 2, 'selected_source_ids': len(SOURCE_IDS), 'homepage_observations': 4,
            'historical_adult_source_ids': 1, 'new_whole_source_classifications_supported': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': verify(json.loads(raw)),
                      'historical_response_bodies_recomputed': False, 'historical_git_commit': COMMIT},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
