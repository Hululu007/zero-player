"""Verify redacted record 3984 observations; no network is used."""

import json
try:
    from .verify_legado_later_chain_common import ROOT, load_inputs, require, validate_basics
except ImportError:
    from verify_legado_later_chain_common import ROOT, load_inputs, require, validate_basics


EVIDENCE = ROOT / 'docs/implementation/legado-sfwx-3984-recheck-20261116.json'
CANONICAL_SHA256 = 'cf3519094656c7485ba91cc7b04efafde6af46ad462e2544f83ce954358413ff'


def validate(evidence, archive, history):
    validate_basics(evidence, CANONICAL_SHA256, {3984}, archive, history)
    observations = evidence['observations']
    for work in ('work_a', 'work_b'):
        sample = observations[work]
        require(len(sample['requests']) == 3 and
                all(x['status'] == 200 and not x['truncated'] for x in sample['requests']),
                f'HTTP observations changed: {work}')
        results = sample['engine_results']
        old = next(x for x in results if x['stage'] == 'details' and not x['candidate'])
        new = next(x for x in results if x['stage'] == 'details' and x['candidate'])
        toc = next(x for x in results if x['stage'] == 'toc')
        old_content = next(x for x in results if x['stage'] == 'content' and not x['candidate'])
        new_content = next(x for x in results if x['stage'] == 'content' and x['candidate'])
        require(old['known_error'] == 'selector_depth_limit' and
                new['actual_title_rule_matches'] and new['author_matches'] and
                new['category_present'] and toc['chapter_count'] == 100 and
                old_content['next_content_count'] == 2 and
                new_content['next_content_count'] == 0 and
                old_content['content_sha256'] == new_content['content_sha256'],
                f'engine comparison changed: {work}')
    extra = observations['additional_chapter_samples']
    require(len(extra['requests']) == 5 and len(extra['engine_results']) == 6,
            'additional chapter sampling changed')
    for ordinal in (10, 50, 90):
        pair = [x for x in extra['engine_results'] if x['sampled_ordinal'] == ordinal]
        require(len(pair) == 2 and pair[0]['next_matches_next_toc_chapter'] and
                pair[0]['content_sha256'] == pair[1]['content_sha256'] and
                pair[1]['next_content_count'] == 0 and
                pair[0]['next_page_anchor_count'] == 0,
                f'additional chapter changed: {ordinal}')
    return {'verified_sources': 1, 'sampled_works': 2, 'additional_chapters': 3,
            'network_requests': 0, 'limitation': 'page bodies and collector not retained'}


def main():
    evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
    print(json.dumps(validate(evidence, *load_inputs()), ensure_ascii=False))


if __name__ == '__main__':
    main()
