"""Verify redacted AMSI observations and pinned archive inputs offline.

The new observations cannot be reproduced from retained evidence: the page,
script, query and temporary collector were deliberately not saved.
"""

import bz2
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/implementation/legado-lengmen-amsi-recheck-20261116.json'
COMMIT = 'f7b5697d49fdc5113274e5add45a1108638957c5'
EVIDENCE_CANONICAL_SHA256 = (
    '188613f00ab2f91b097dd8d3038a36130dc972ce0bff9232485be9e2157d6819'
)
ARCHIVE_SHA256 = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
HISTORICAL = {
    'ledger': ('docs/implementation/legado-source-ledger-20261115.json',
               'fb6b8ace9e42eed5ab9756cb3a35d115a83466479b1946e968afe13306aee8c6'),
    'summary': ('docs/implementation/legado-amsi-summary-20261115.json',
                'b8a93e7b8fb78ca3bcf57f5748a7b50f67e32e14c8298776726f7779f81ecf67'),
    'initial': ('docs/implementation/legado-amsi-other-hosts-20261115.json',
                '25180e804c1df15165af8bb20ae58c5b4dd6b2e24f6a0a092d50281ca5e25750'),
    'clusters': ('docs/implementation/legado-amsi-template-clusters-20261115.json',
                 '0aaff7d86529327f67ea09f741d62a00a0cf47a03a90175b982619beeed9de3e'),
    'classification': ('docs/implementation/legado-amsi-source-classification-20261115.json',
                       'd8a40945fa3875f65085d9fd210808aa8038f5d8a012495e8bf2bd68fe061180'),
}
EXPECTED = {
    450: ('5c5cc84bbd5019fd7fc40a5effcdf9adfddca60a2f4f6885b1eb034ad4da0a93',
          '98d3c34181b05187296b73cedf44c117088709673fc7d8bf4307fbfdcdcbd5dd'),
    1921: ('47e709728d21b76a1156fd1a080dd45d8dc82c1a95f8e66359533ac4d336847e',
           '264c75aab9098fa2d643b6ef1db6174d91ca55a8d00c8b216fb5837decde112e'),
}
HOST = 'www.lengmen.org'
SHAPE = '05e7d863aefa066d521304faf1ecf18b31791a0f55502474dc1d646e4a8bf6b6'


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def require(condition, label):
    if not condition:
        raise ValueError(label)


def load_inputs():
    archive = (ROOT / 'assets/catalogs/books/legado/catalog.json.bz2').read_bytes()
    history = {key: subprocess.check_output(['git', 'show', f'{COMMIT}:{path}'], cwd=ROOT)
               for key, (path, _) in HISTORICAL.items()}
    return archive, history


def validate(evidence, archive, history):
    require(digest(canonical(evidence)) == EVIDENCE_CANONICAL_SHA256,
            'redacted observations or metadata changed')
    require(digest(archive) == ARCHIVE_SHA256, 'catalog archive changed')
    require(set(history) == set(HISTORICAL), 'historical input set changed')
    for key, (_, expected) in HISTORICAL.items():
        require(digest(history[key]) == expected, f'historical input changed: {key}')
    refs = evidence['inputs']
    require(refs['historical_git_commit'] == COMMIT and
            refs['archive_sha256'] == ARCHIVE_SHA256,
            'archive or commit reference changed')
    for key, (path, expected) in HISTORICAL.items():
        require(refs['historical_files'][key] == {'path': path, 'sha256': expected},
                f'historical reference changed: {key}')

    old = {key: json.loads(value) for key, value in history.items()}
    rows = json.loads(bz2.decompress(archive))['records']
    ledger = {x['selected_record_index']: x for x in old['ledger']['sources']
              if x['endpoint_host'] == HOST}
    classified = {x['id']: x for x in old['classification']['sources']
                  if x['endpoint_host'] == HOST}
    observed = {x['selected_record_index']: x for x in evidence['source_fingerprints']}
    require(set(ledger) == set(observed) == set(EXPECTED), 'source scope changed')
    for index, (source_id, legado_sha) in EXPECTED.items():
        item, saved, raw = observed[index], ledger[index], rows[index]
        require(item['source_id'] == saved['source_id'] == source_id and
                item['normalized_legado_canonical_sha256'] ==
                saved['normalized_legado_canonical_sha256'] == legado_sha,
                f'selected source identity changed: {index}')
        require(item['raw_record_canonical_sha256'] ==
                saved['selected_raw_record_canonical_sha256'] == digest(canonical(raw)) and
                item['historical_same_id_record_indices'] ==
                saved['related_same_id_and_endpoint_host_record_indices'] and
                item['endpoint_sha256'] == saved['endpoint_sha256'] and
                item['historical_static_policy'] == saved['static_policy'],
                f'archived source evidence changed: {index}')
        require(item['earlier_amsi_classification_legado_sha256_unsorted_json'] ==
                classified[source_id]['rule']['normalized_legado_sha256'],
                f'earlier fingerprint mismatch: {index}')
        for field, expected in item['raw_field_sha256'].items():
            value = raw.get(field)
            encoded = value.encode('utf-8') if isinstance(value, str) else canonical(value)
            require(digest(encoded) == expected, f'raw rule mismatch: {index}/{field}')

    summary = next(x for x in old['summary']['detection_observations'] if x['host'] == HOST)
    initial = next(x for x in old['initial']['results'] if x['host'] == HOST)
    cluster = next(x for x in old['clusters']['results'] if x['host'] == HOST)
    group = next(x for x in old['clusters']['shape_groups'] if HOST in x['hosts'])
    ids = {value[0] for value in EXPECTED.values()}
    require(set(summary['selected_source_ids']) == set(initial['selected_source_ids']) ==
            set(cluster['selected_source_ids']) == ids and
            initial['record_indices'] == cluster['record_indices'] == [450, 1921, 2318],
            'historical host association changed')
    prev = evidence['prior']['initial']
    require(prev['observed_at_utc'] == initial['sample_observed_at'] and
            prev['sample_sha256'] == initial['sample_sha256'] == summary['sample_sha256'] and
            prev['html_amsi'] == initial['amsi'] and
            prev['inline_sample_sha256'] ==
            initial['inline_scripts']['samples'][0]['sample_sha256'] and
            prev['inline_amsi'] == initial['inline_scripts']['samples'][0]['amsi'],
            'initial AMSI observation changed')
    prev = evidence['prior']['cluster_recheck']
    target = cluster['literal_navigation']['direct_constant_targets'][0]
    require(prev['observed_at_utc'] == cluster['sample_observed_at'] and
            prev['sample_sha256'] == cluster['sample_sha256'] and
            prev['html_amsi'] == cluster['amsi'] and
            prev['inline_sample_sha256'] ==
            cluster['inline_scripts']['samples'][0]['sample_sha256'] and
            prev['inline_amsi'] == cluster['inline_scripts']['samples'][0]['amsi'] and
            prev['shape_sha256'] == cluster['shape_sha256'] == group['shape_sha256'] == SHAPE and
            prev['shape_group_size'] == len(group['hosts']) == 14 and
            target['target_host_is_source'] and target['has_query'],
            'historical template observation changed')

    observations = evidence['observations']
    require(len(observations) == evidence['method']['requests'] == 6 and
            observations[0]['http_status'] == 302 and
            observations[0]['redirect_target'] == 'unknown_not_captured',
            'request count or unobserved redirect changed')
    segment = observations[4]
    require(segment['kind'] == 'segment_and_synthetic_controls' and
            segment['html_amsi']['amsi_result'] == segment['inline_amsi']['amsi_result'] == 32768 and
            len(segment['segment_scans']) == 4 and
            all(x['amsi']['amsi_result'] == 1 for x in segment['segment_scans']) and
            all(x['amsi']['amsi_result'] == 1 for x in segment['ordinary_synthetic_navigation_controls']),
            'segment or synthetic control observations changed')
    variants = observations[5]['comparisons']
    require(observations[5]['same_byte_length_for_all_variants'] and
            variants[1]['kind'] == 'hostname_literal_replaced_within_url' and
            [x['amsi']['amsi_result'] for x in variants] == [32768, 32768, 1, 1],
            'equal-length comparison changed')
    serialized = canonical(evidence).decode('utf-8')
    require('?' not in serialized and not re.search(r'https?://|<script', serialized, re.I),
            'unexpected URL, query or page code in evidence')
    return {'verified_sources': 2, 'recorded_requests': 6, 'template_hosts': 14,
            'historical_commit': COMMIT, 'network_requests': 0,
            'limitation': 'new page, script, query and collector were not retained'}


def main():
    evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
    print(json.dumps(validate(evidence, *load_inputs()), ensure_ascii=False))


if __name__ == '__main__':
    main()
