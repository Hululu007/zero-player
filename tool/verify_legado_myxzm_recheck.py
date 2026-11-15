"""Verify the redacted myxzm audit evidence offline without opening webpages."""
import argparse
import bz2
import json
from pathlib import Path
import subprocess

if __package__:
    from . import verify_legado_rdap_com_eighteen as shared
else:
    import verify_legado_rdap_com_eighteen as shared

ROOT = shared.ROOT
EVIDENCE = 'docs/implementation/legado-myxzm-recheck-20261116.json'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
MANIFEST = 'assets/catalogs/books/legado/manifest.json'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
MANIFEST_SHA = '59bb9e3551b5a01406c1d720d2b5d5d5f21518eccbb52cd93f8d752c19f7cf66'
LEDGER_SHA = '7e53cfcd42523e3dd173708ffc0ce99ec42b9de4fbeae63969765690d2068070'
SOURCE_ID = '483d7c92f8871bb1e84d45883d9a6ea0705afe1265615146ece1b2c9fbef90ad'
SUMMARY_SHA = '81154ea9eeb16cbf408865b4058c2a0762bc2c39436401a19eaa2b0e9296f78d'
SUMMARY_CANONICAL_SHA = 'd381de0a9086ff79bd1b2102be4841cddbe3bc7f30fdadfc220737b3cf83888c'
RULE_SHAS = {
    'old_search_rule_sha256': '5b94eb307b1c1daa58f4e7fad72d030991dfc833f6676a2a0c06bcd50da20f52',
    'old_search_list_sha256': '59f3362b7d20c3ea20af7896d647669d7ade264e71f0c0251f3d10e8d9ec632b',
    'old_content_rule_sha256': 'd48c8db1549d45364ef71ecffa2d46d2ce36efe924b9fe697075ccc9b6114db3',
}
SELECTION = {
    'source_id': SOURCE_ID, 'selected_record_index': 751, 'kind': 'text', 'format': 'html',
    'endpoint_host': 'm.myxzm.com',
    'endpoint_sha256': 'b01a233d6cdbd310ffee8a8f6da1a594d3c7bc756fff629530327c1f92e67e90',
    'selected_raw_record_canonical_sha256': 'de253991cccd80e1086477f2ba4b98198baaba15d38ae221510f234c5af9fa95',
    'normalized_legado_sha256': '9caa213ccc167eb20ca20d95731af27dd6b260494932d7727dc0505747e46d92',
}
require = shared.require
sha = shared.sha


def load_inputs(evidence):
    expected = {
        'catalog_archive': {'path': ARCHIVE, 'sha256': ARCHIVE_SHA},
        'catalog_manifest': {'path': MANIFEST, 'sha256': MANIFEST_SHA},
        'source_ledger_historical_git': {'commit': shared.COMMIT, 'path': shared.LEDGER, 'sha256': LEDGER_SHA},
    }
    require(evidence['input_references'] == expected, 'input references differ')
    archive_raw = (ROOT / ARCHIVE).read_bytes()
    manifest_raw = (ROOT / MANIFEST).read_bytes()
    require(sha(archive_raw) == ARCHIVE_SHA and sha(manifest_raw) == MANIFEST_SHA, 'archive or manifest digest differs')
    manifest = json.loads(manifest_raw)
    archive = json.loads(bz2.decompress(archive_raw))
    require(manifest['archiveSha256'] == ARCHIVE_SHA and len(archive['records']) == manifest['records'],
            'archive manifest association differs')
    try:
        proc = subprocess.run(['git', '-C', str(ROOT), 'show', shared.COMMIT + ':' + shared.LEDGER],
                              capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git or historical ledger object is unavailable') from None
    require(proc.returncode == 0, 'historical ledger object unavailable; shallow clones may omit it')
    require(sha(proc.stdout) == LEDGER_SHA, 'historical ledger digest differs')
    ledger = json.loads(proc.stdout)
    require(ledger['input_sha256'].get(ARCHIVE) == ARCHIVE_SHA and
            ledger['input_sha256'].get(MANIFEST) == MANIFEST_SHA, 'historical archive reference differs')
    return archive, ledger


def verify_selection(evidence, archive, ledger):
    require(evidence['selection_snapshot'] == SELECTION, 'selected source snapshot differs')
    sources = {row['source_id']: row for row in ledger['sources']}
    source = sources.get(SOURCE_ID)
    require(source is not None and source['selected_record_index'] == 751 and source['format'] == 'html',
            'historical selected source differs')
    selected = {'source_id': SOURCE_ID, 'name': source['name'], 'kind': SELECTION['kind'],
                'selected_record_index': 751, 'normalized_legado_sha256': SELECTION['normalized_legado_sha256'],
                'endpoint_sha256': SELECTION['endpoint_sha256'],
                'selected_raw_record_canonical_sha256': SELECTION['selected_raw_record_canonical_sha256']}
    shared.verify_source(selected, SELECTION['endpoint_host'], sources, archive)
    raw = archive['records'][751]
    rules = {'old_search_rule_sha256': raw['searchUrl'],
             'old_search_list_sha256': raw['ruleSearch']['bookList'],
             'old_content_rule_sha256': raw['ruleContent']['content']}
    for field, value in rules.items():
        require(isinstance(value, str) and sha(value.encode('utf-8')) == RULE_SHAS[field],
                'archived rule digest differs: ' + field)
    source_record = evidence['recorded_observations']['source']
    require(source_record == {'source_id': SOURCE_ID, 'selected_record_index': 751,
                              'host': SELECTION['endpoint_host'], **RULE_SHAS}, 'recorded source or rule digests differ')


def verify_observations(recorded):
    obs = recorded['evidence']
    require(set(obs) == {'discovery', 'search', 'sample_a', 'sample_b', 'single_class_candidate',
                         'synthetic_advertisement_control'}, 'observation set differs')
    discovery, search = obs['discovery'], obs['search']
    require(discovery['status'] == 200 and discovery['old_rule_engine_books'] == 20 and
            discovery['static_search_form'] == {'method': 'GET', 'path': '/search/',
                                                  'named_inputs': ['q'], 'event_handler': False},
            'discovery observation differs')
    require(search['status'] == 200 and search['returned_service_type'] == 'comic' and
            search['old_novel_search_rule_engine_books'] == 0 and search['novel_search_endpoint_verified'] is False,
            'search failure observation differs')
    a, b = obs['sample_a'], obs['sample_b']
    require(a['detail_status'] == 200 and a['content_status'] == 200 and a['old_toc_engine_chapters'] == 2 and
            a['old_content_characters'] == 0 and a['two_class_candidate'] == 'class.mrx-cot gtfvws@html' and
            a['candidate_nodes'] == 1 and a['candidate_characters'] == 1892 and a['container_paragraphs'] == 74,
            'first sample observation differs')
    require(b['detail_status'] == 200 and b['content_status'] == 200 and b['old_toc_engine_chapters'] == 10 and
            b['old_content_characters'] == 0 and b['two_class_candidate_nodes'] == 0 and
            b['two_class_candidate_characters'] == 0 and b['subsequent_status'] == 200 and
            b['substantial_container_class'] == 'mrx-cot ahpuzh' and b['substantial_container_paragraphs'] == 141,
            'second sample counterexample differs')
    single = obs['single_class_candidate']
    require(single['rule'] == 'class.mrx-cot@html' and single['actual_engine_tested_on_fetched_samples'] is False,
            'unverified single-class selector misreported')
    for label in ('sample_a_refetch', 'sample_b_refetch'):
        row = single[label]
        require(row.get('failure') == 'overall_timeout' and row.get('status', 'missing') is None,
                'timeout or unknown status misreported')
        require(shared.timestamp(row['started_at_utc']) < shared.timestamp(row['observed_at_utc']),
                'invalid timeout interval')
    control = obs['synthetic_advertisement_control']
    require(control['candidate_kept_advertisement_text'] is True and control['synthetic_script_executed'] is False,
            'synthetic advertisement counterexample differs')
    canonical = json.dumps(recorded, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
    require(sha(canonical) == SUMMARY_CANONICAL_SHA, 'redacted observation record changed')


def verify(evidence):
    require(set(evidence) == {'schema_version', 'scope', 'input_references', 'selection_snapshot',
                              'recorded_observations', 'provenance', 'limitations'} and
            evidence['schema_version'] == 1, 'unexpected evidence schema')
    provenance = evidence['provenance']
    require(provenance == {'redacted_local_summary_sha256': SUMMARY_SHA,
                           'redacted_observations_canonical_sha256': SUMMARY_CANONICAL_SHA,
                           'raw_webpages_in_this_evidence': False, 'work_or_chapter_identities_in_this_evidence': False,
                           'original_collector_in_repository': False, 'temporary_engine_scripts_in_repository': False},
            'redaction or provenance differs')
    require(any('does not independently authenticate' in text for text in evidence['limitations']) and
            any('without that object' in text for text in evidence['limitations']),
            'historical reconstruction limitations missing')
    shared.common.reject_sensitive(evidence)
    shared.reject_url_queries(evidence)
    archive, ledger = load_inputs(evidence)
    verify_selection(evidence, archive, ledger)
    verify_observations(evidence['recorded_observations'])
    return {'selected_record_index': 751, 'source_id': SOURCE_ID, 'archive_sha256': ARCHIVE_SHA,
            'discovery_books': 20, 'search_books': 0, 'old_toc_chapters': [2, 10],
            'two_class_candidate_nodes': [1, 0], 'single_class_candidate_verified': False,
            'refetch_timeouts': 2, 'synthetic_advertisement_retained': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / EVIDENCE)
    args = parser.parse_args()
    raw = args.evidence.read_bytes()
    summary = verify(json.loads(raw))
    print(json.dumps({'evidence_sha256': sha(raw), 'verified_summary': summary,
                      'historical_webpages_reconstructed': False,
                      'historical_collector_reconstructed': False,
                      'network_observations_independently_verified': False}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
