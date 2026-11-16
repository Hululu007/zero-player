"""Verify redacted category and search-path observations offline."""

import json
try:
    from .verify_legado_later_chain_common import ROOT, SOURCES, load_inputs, require, validate_basics
except ImportError:
    from verify_legado_later_chain_common import ROOT, SOURCES, load_inputs, require, validate_basics


EVIDENCE = ROOT / 'docs/implementation/legado-biquge7-category-recheck-20261116.json'
CANONICAL_SHA256 = 'f8c4cd6eac50fc47f8475545a0af23ecd99dff03d580e76dbe0d237e39915bfd'


def validate(evidence, archive, history):
    prior = validate_basics(evidence, CANONICAL_SHA256, {828, 3002, 2578}, archive, history)
    observations = evidence['observations']
    for work in ('record_828_work_a', 'record_828_work_b'):
        sample = observations[work]
        require(len(sample['requests']) == 3 and
                all(x['status'] == 200 and not x['truncated'] for x in sample['requests']),
                f'HTTP observations changed: {work}')
        results = sample['engine_results']
        details = next(x for x in results if x['stage'] == 'details')
        toc = next(x for x in results if x['stage'] == 'toc')
        content = next(x for x in results if x['stage'] == 'content')
        require(details['actual_title_rule_matches'] and details['author_matches'] and
                not details['category_present'] and toc['chapter_count'] == 120 and
                content['content_utf16_code_units'] > 0,
                f'engine result changed: {work}')
    category = observations['shared_category_check']
    require(len(category['requests']) == 2 and
            all(x['status'] == 200 and not x['truncated'] for x in category['requests']),
            'category sample HTTP changed')
    for index in (828, 3002):
        selected = [x for x in category['engine_results'] if x['id'] == SOURCES[index][0]]
        require(len(selected) == 8, f'category sample count changed: {index}')
        for item in selected:
            require(item['category_meta_count'] == 1 and
                    item['category_present'] == item['candidate'] and
                    item['category_matches_meta'] == item['candidate'],
                    f'category comparison changed: {index}')
        require({x['synthetic_label'] for x in selected if 'synthetic_label' in x} ==
                {'restricted_label_a', 'restricted_label_b', 'ordinary_label'},
                f'synthetic category controls changed: {index}')
    control = observations['record_2578_search']
    require(len(control['requests']) == 1 and control['requests'][0]['status'] == 404 and
            not control['engine_results'] and
            observations['record_2578_previous_search'] ==
            prior['prior_pilot']['observations']['record_2578']['search'] and
            observations['record_2578_previous_search']['status'] == 404,
            'single search-path control changed')
    return {'verified_sources': 3, 'sampled_works': 2, 'synthetic_labels': 3,
            'network_requests': 0, 'limitation': 'page bodies and collector not retained'}


def main():
    evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
    print(json.dumps(validate(evidence, *load_inputs()), ensure_ascii=False))


if __name__ == '__main__':
    main()
