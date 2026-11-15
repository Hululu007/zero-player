"""Record reviewed response-to-code flows among the broad eval candidates.

All assertions are against bundled source text. The script does not execute a
source rule or fetch any of the sites, and the evidence is not a malware claim.
"""

import argparse
import hashlib
import json
from pathlib import Path

if __package__:
    from .audit_legado_catalog import CATALOG, inventory
    from .audit_legado_rule_patterns import strings
    from .triage_legado_eval_candidates import selected_indices
else:
    from audit_legado_catalog import CATALOG, inventory
    from audit_legado_rule_patterns import strings
    from triage_legado_eval_candidates import selected_indices


# Each tuple identifies selected records, an executable rule field, expected
# text markers, and a short static description of the observed data flow.
REVIEWED = [
    ([3836], 'ruleContent.content', ('eval(String(result))',),
     'evaluates the complete result supplied to the content rule'),
    ([1228], 'ruleContent.content', ('eval(result.match', 'var qTcms_Cur'),
     'evaluates a script fragment matched from the result'),
    ([3219], 'ruleContent.content', ('var html=result', 'eval(html.match'),
     'evaluates a script fragment matched from the result'),
    ([2128, 3760, 4156, 4159], 'ruleToc.chapterList',
     ('eval(result.match', '__NUXT__[^<]*'),
     'evaluates page text from the NUXT marker through the next tag'),
    *[([2128, 3760, 4156, 4159], field,
       ('eval(result.match', '__NUXT__[^<]*'),
       'evaluates page text from the NUXT marker through the next tag')
      for field in ('ruleBookInfo.name', 'ruleBookInfo.author',
                    'ruleBookInfo.intro', 'ruleBookInfo.coverUrl',
                    'ruleBookInfo.kind', 'ruleBookInfo.lastChapter')],
    ([2136, 4052, 4161], 'ruleContent.content', ('eval(result.match',),
     'extracts and evaluates an eval expression from the result'),
    ([4046], 'ruleContent.content', ('//script', 'eval(result)'),
     'selects script text and evaluates the result'),
    ([3995, 4019], 'ruleContent.nextContentUrl', ('src.match', 'eval(next'),
     'extracts and evaluates a function from the page, then evaluates its result'),
    ([662, 1432], 'ruleContent.nextContentUrl', ('result.match', 'eval(code)'),
     'extracts an eval function from the result and evaluates it'),
    *[([3460], field, ('eval(result.match', 'text=new Array'),
       'evaluates an Array expression matched from the page result')
      for field in ('ruleContent.content', 'ruleBookInfo.init',
                    'ruleSearch.bookList', 'ruleToc.chapterList')],
    ([189, 627, 2247, 4840], 'ruleContent.content',
     ('eval(result.match',),
     'evaluates an expression matched from the page result'),
    ([4840], 'ruleToc.chapterList', ('eval(src.match', 'originalOrder'),
     'evaluates a page expression intended to describe chapter order'),
    ([4090], 'ruleContent.content', ('eval(String(java.getString', 'photoLinks'),
     'evaluates a photoLinks field selected from the page result'),
    ([4152, 4153, 4157, 4158], 'ruleContent.content',
     ('nonce=eval(nonce)', 'result.match'),
     'evaluates a nonce expression extracted from the page'),
    ([4221, 4559, 4579, 4665], 'ruleSearch.bookList',
     ('eval(result)', 'baseUrl.match'),
     'conditionally evaluates the complete search result'),
    ([4712, 4762], 'ruleContent.content', ('match=src.match', 'eval(match[1])'),
     'evaluates an expression extracted from page content'),
    ([4271, 4278, 4317], 'ruleContent.content',
     ('java.getString', 'eval(`"${data}"`)'),
     'inserts a selected response field into a JavaScript expression and evaluates it'),
]


def reviewed_profiles(rows, imported):
    parsed, selected = selected_indices(rows, imported)
    profiles = {}
    for indices, field, required, summary in REVIEWED:
        for index in indices:
            source = parsed[index]
            if selected[source['id']] != index:
                raise ValueError(f'record {index} is no longer selected')
            value = dict(strings(rows[index]))[field]
            if not all(token in value for token in required):
                raise ValueError(f'evidence changed for record {index}: {field}')
            profile = profiles.setdefault(index, {
                'source_id': source['id'], 'name': source['name'],
                'kind': source['kind'], 'host': source['host'],
                'classification': 'network_data_to_eval',
                'selected_record_index': index, 'evidence': [],
            })
            profile['evidence'].append({
                'record_index': index,
                'field': field,
                'field_sha256': hashlib.sha256(value.encode()).hexdigest(),
                'category': 'response_or_script_to_eval',
                'data_flow_excerpt': summary,
            })
    return list(profiles.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('imported', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rows, _, _, _, manifest = inventory(CATALOG)
    imported = json.loads(args.imported.read_text(encoding='utf-8'))
    if imported['archive_sha256'] != manifest['archiveSha256']:
        raise ValueError('import inventory must use the bundled archive')
    profiles = reviewed_profiles(rows, imported)
    output = {
        'archive_sha256': manifest['archiveSha256'],
        'scope': 'selected source text inspected statically; no rule executed',
        'source_profiles': profiles,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'{len(profiles)} selected IDs have reviewed response-to-code evidence')


if __name__ == '__main__':
    main()
