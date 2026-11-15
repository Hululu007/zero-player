"""Verify the redacted source observations and their historical inputs offline.

No page body or collection script is archived; this checks provenance and the
integrity of recorded observations, not that the observations can be replayed.
"""

import bz2
import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/implementation/legado-sfwx-repair-20261116.json'
COMMIT = 'f7b5697d49fdc5113274e5add45a1108638957c5'
EVIDENCE_CANONICAL_SHA256 = (
    '5f3eb2de91596930a8c39ef1a51ee8e3f80778c0116731a0e03d97deb78219da'
)
ARCHIVE_SHA256 = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
LEDGER_SHA256 = 'fb6b8ace9e42eed5ab9756cb3a35d115a83466479b1946e968afe13306aee8c6'
HEAD_SHA256 = '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd'
EXPECTED = {
    4760: ('0723af128aa8adacd3e3a9efe03b622fa660d2f78a21b72cbe2bfe7d32ce8b75',
           'www.sfwx.com', 'b91ea60260f819a4d31198672593d844caaaee381918419a46888814190ad411'),
    3002: ('ad35798f5b42bac39ba862133be63224081484921a86a8e8e6b5570e65ca63a3',
           'www.biquge7.xyz', 'e0768b6f273fc63bb1f09fc7bfb2514b749a3d15f0eb934bf797c1f6cdfac7cf'),
    2578: ('926a302f72881a7c6488555dfd0779da9db89c7f1ae35fbb14fbaaa9846caa43',
           'www.b520.cc', 'fc3ddc6cb8e9c568200327d1d360ba7fad42e88a698abb18b57147f8c536b2f8'),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def require(condition, label):
    if not condition:
        raise ValueError(label)


def historical(path):
    return subprocess.check_output(['git', 'show', f'{COMMIT}:{path}'], cwd=ROOT)


def load_inputs():
    return (
        (ROOT / 'assets/catalogs/books/legado/catalog.json.bz2').read_bytes(),
        historical('docs/implementation/legado-source-ledger-20261115.json'),
        historical('docs/implementation/legado-unresolved-head-later-20261116.json'),
    )


def validate(evidence, archive, ledger_bytes, head_bytes):
    require(digest(canonical(evidence)) == EVIDENCE_CANONICAL_SHA256,
            'evidence observations or metadata changed')
    require(digest(archive) == ARCHIVE_SHA256, 'archive changed')
    require(digest(ledger_bytes) == LEDGER_SHA256, 'historical ledger changed')
    require(digest(head_bytes) == HEAD_SHA256, 'historical HEAD evidence changed')
    inputs = evidence['inputs']
    require(inputs['historical_git_commit'] == COMMIT and
            inputs['archive_sha256'] == ARCHIVE_SHA256 and
            inputs['historical_ledger_sha256'] == LEDGER_SHA256 and
            inputs['historical_head_sha256'] == HEAD_SHA256,
            'incorrect evidence input references')
    rows = json.loads(bz2.decompress(archive))['records']
    ledger = {entry['selected_record_index']: entry
              for entry in json.loads(ledger_bytes)['sources']}
    heads = {entry['host']: entry for entry in json.loads(head_bytes)['results']}
    observed = {item['record_index']: item for item in evidence['sources']}
    require(set(observed) == set(EXPECTED), 'incorrect source scope')
    for index, (source_id, host, legado_sha) in EXPECTED.items():
        item, old, raw = observed[index], ledger[index], rows[index]
        require(item['source_id'] == old['source_id'] == source_id and
                item['endpoint_host'] == old['endpoint_host'] == host and
                item['historical_legado_sha256'] ==
                old['normalized_legado_canonical_sha256'] == legado_sha,
                f'source identity mismatch: {index}')
        require(digest(canonical(raw)) == item['historical_raw_sha256'] ==
                old['selected_raw_record_canonical_sha256'],
                f'raw record mismatch: {index}')
        for field, expected in item['raw_field_sha256'].items():
            value = raw[field]
            data = value.encode('utf-8') if isinstance(value, str) else canonical(value)
            require(digest(data) == expected, f'raw field mismatch: {index}/{field}')
        prior = heads[host]['latest_head']
        require(prior['http_status'] == item['prior_recovery_head_status'] == 200 and
                prior['observed_at'] == item['prior_recovery_head_at_utc'],
                f'HEAD observation mismatch: {index}')
    obs = evidence['observations']['record_4760']
    for work in ('work_a', 'work_b'):
        result = obs[work]
        require(result['detail_and_toc']['old_details'].startswith('FormatException:') and
                result['detail_and_toc']['candidate_title_and_author_match'] and
                result['detail_and_toc']['candidate_toc_chapters'] == 100,
                f'detail or toc evidence changed: {work}')
        for chapter in result['chapters']:
            require(chapter['status'] == 200 and chapter['old_next_count'] == 2 and
                    chapter['without_next_same_content_sha256'] and
                    chapter['without_next_links'] == 0,
                    f'chapter evidence changed: {work}')
    category = obs['category_recheck']
    require(category['pipe_expression_output_length'] == 0 and
            category['explicit_selector_contains_category_meta'] and
            category['production_selector'] == '[property$=category]@content' and
            category['synthetic_exact_adult_label_preserved'] and
            category['synthetic_ordinary_label_preserved'],
            'category comparison changed')
    return {'verified_sources': len(observed), 'sampled_works': 2,
            'archive_sha256': ARCHIVE_SHA256, 'historical_commit': COMMIT,
            'network_requests': 0,
            'limitation': 'page bodies and collection script were not retained'}


def main():
    evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
    print(json.dumps(validate(evidence, *load_inputs()), ensure_ascii=False))


if __name__ == '__main__':
    main()
