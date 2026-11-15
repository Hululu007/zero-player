"""Reproduce the manual per-ID triage of the 2026-11-15 Legado eval candidates.

The assertions tie the human-curated data-flow summaries to exact original
record indices and field hashes. No source rule is interpreted or executed.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .audit_legado_catalog import CATALOG, inventory
    from .audit_legado_rule_patterns import strings
else:
    from audit_legado_catalog import CATALOG, inventory
    from audit_legado_rule_patterns import strings


# Each tuple names original snapshot records, a rule field, a category, a
# faithful short code excerpt, and textual markers checked before reporting.
EVIDENCE = [
    ([12, 1794, 4813], 'bookSourceComment', 'remote_script_fragment',
     'str=java.ajax(origin+u2).match(...)[0]; eval(str)', ('java.ajax', 'eval(str)')),
    ([17, 231, 232, 233, 234, 393, 1184, 3105], 'ruleContent.content', 'remote_data_expression',
     "r=String(java.ajax(url).match(...)[1]); eval('(' + r + ')')", ('java.ajax', 'eval(')),
    ([190, 192], 'ruleContent.content', 'remote_script_fragment',
     'eval(String(java.ajax(...))); eval(result.match(...)[1])', ('java.ajax', 'eval(')),
    ([337, 619, 604], 'ruleContent.content', 'remote_data_expression',
     'json=java.ajax(...); json=eval("("+json.replace(...)+")")', ('java.ajax', 'eval(')),
    ([475, 1030, 2884, 3077], 'bookSourceComment', 'remote_field_in_code',
     "callback=src.match(...)[1]; eval('d'+callback+'=(data)=>data.content;')", ('src.match', 'eval(')),
    ([475, 1030, 2884, 3077], 'ruleContent.content', 'remote_data_expression',
     'index_html=java.get(index_url,...); eval(String(index_html.body()))', ('index_html', 'eval(')),
    ([475, 1030, 2884, 3077], 'ruleToc.chapterList', 'remote_data_expression',
     'index_html=java.get(index_url,...); eval(String(index_html.body()))', ('index_html', 'eval(')),
    ([535, 2088, 2504], 'ruleSearch.bookList', 'third_party_base64_script',
     'global.wesrc=...newCall(request).execute().body().string(); eval(...Base64.decode(global.wesrc,0))',
     ('global.wesrc', 'newCall(request)', 'Base64.decode', 'eval(')),
    ([535, 2088, 2504], 'ruleContent.content', 'third_party_base64_script',
     'global.wesrc=...newCall(request).execute().body().string(); eval(...Base64.decode(global.wesrc,0))',
     ('global.wesrc', 'newCall(request)', 'Base64.decode', 'eval(')),
    ([1066], 'ruleSearch.bookList', 'remote_script_fragment',
     'j=java.ajax(...); eval(String(j.match(reg)[0]))', ('java.ajax', 'j.match(reg)', 'eval(')),
    ([1066], 'ruleContent.content', 'remote_script_fragment',
     'j=java.ajax(...); eval(String(j.match(reg)[0]))', ('java.ajax', 'j.match(reg)', 'eval(')),
    ([1227], 'ruleContent.content', 'remote_script_fragment',
     'eval(result.match(/(eval...)/)[1])', ('result.match', 'eval(')),
    ([1396, 3225, 1502, 3462, 4136], 'exploreUrl', 'remote_field_in_code',
     "JSON.parse(java.ajax(...)).data.map(...); freetype=$.freetype; eval('sort'+type2+'.push(json)')",
     ('JSON.parse(java.ajax', '$.freetype', "eval('sort'")),
    ([2176, 3322, 2172, 2388], 'ruleContent.content', 'remote_script_fragment',
     'eval(...result.match(/(eval...)/)[1]...)', ('result.match', 'eval(')),
    ([3067, 3649], 'ruleContent.content', 'remote_script_fragment',
     'eval(String(java.ajax(...).match(...)[1]))', ('java.ajax', 'eval(')),
    ([3482, 4083], 'bookSourceComment', 'remote_data_expression',
     'eval(src.match(/decodeURIComponent.../g).shift())', ('src.match', 'eval(')),
    ([3926, 4824], 'ruleContent.content', 'remote_script_fragment',
     'tokenHtml=java.ajax(url); eval(String(tokenHtml))', ('java.ajax(url)', 'eval(String(tokenHtml))')),
    ([3926, 4824], 'ruleBookInfo.wordCount', 'remote_script_fragment',
     'size=result?.match(...); eval(size || ...)', ('result?', 'eval(')),
    ([3926, 4824], 'ruleSearch.wordCount', 'remote_script_fragment',
     '//script/text()@js: if(result){ eval(result) }', ('script/text()', 'eval(result)')),
    ([3973], 'ruleContent.content', 'page_attribute_eval',
     "pic=java.getString('img!0:1:-1@data-src'); eval(pic)", ('java.getString', 'eval(pic)')),
    ([4817], 'ruleContent.content', 'remote_data_expression',
     'arrStr=src.match(...)[1]; try JSON.parse(arrStr...) catch eval(arrStr)', ('src.match', 'JSON.parse', 'eval(arrStr)')),
    ([4826], 'ruleContent.content', 'remote_script_fragment',
     'html=java.ajax(...); eval(html.match(/Ark.../)[1])', ('java.ajax', 'eval(html.match')),
    ([3220], 'ruleContent.content', 'remote_script_fragment',
     'eval(result.match(/chapterImages.../)[0]); eval(result.match(/chapterPath.../)[0])', ('result.match', 'eval(')),
]

# These are observations, not endorsements of an entire source as safe.
LOCAL = {
    1: ('ruleContent.content', 'eval(String(source.loginUrl)) executes a bundled source field; the separate ajax result is not the eval argument.'),
    219: ('ruleSearch.bookList', 'eval(String(source...bookSourceComment)) executes bundled metadata; the referenced field defines request helpers.'),
    924: ('exploreUrl', 'eval selects statically declared local category arrays; the URL and arrays coexist in the same field.'),
    943: ('ruleContent.content', 'eval(String(source.bookSourceComment)) builds a request URL from bundled metadata; the later ajax result is not its eval argument.'),
    3958: ('exploreUrl', 'eval(String(source.bookSourceComment)) runs bundled code that makes a request; no response-to-eval flow was identified.'),
    4373: ('ruleContent.content', 'eval(String(source.bookSourceComment)) loads bundled decoder functions; no response-to-eval flow was identified.'),
}
UNKNOWN = {
    3927: ('ruleBookInfo.init', 'objParse(String(java.get("util"))) revives function strings with eval; loginCheckJs stores a serialized util object. Remote-data provenance was not established.'),
    4040: ('ruleBookInfo.init', 'objParse(String(java.get("util"))) revives function strings with eval; loginCheckJs stores a serialized util object. Remote-data provenance was not established.'),
    4151: ('loginUrl', 'eval(String(Reload(...))) depends on a function from a referenced library; its definition was not fetched or inspected.'),
}


def version(row):
    value = str(row.get('lastUpdateTime', ''))
    return int(value) if re.fullmatch(r'[+-]?\d+', value) else 0


def selected_indices(rows, imported):
    parsed = {r['index']: r for r in imported['raw_parseable']}
    selected, versions = {}, {}
    for refs in imported['pack_references'].values():
        for index in refs:
            source = parsed.get(index)
            if not source:
                continue
            ident, stamp = source['id'], version(rows[index])
            if ident not in versions or stamp > versions[ident]:
                selected[ident], versions[ident] = index, stamp
    for chosen in imported['selected_sources']:
        actual = parsed[selected[chosen['id']]]
        if any(actual[k] != chosen[k] for k in ('id', 'name', 'group', 'host', 'kind')):
            raise ValueError(f"reconstructed selection disagrees for {chosen['id']}")
    return parsed, selected


def evidence_records(rows):
    evidence = {}
    for indices, path, category, excerpt, required in EVIDENCE:
        for index in indices:
            fields = dict(strings(rows[index]))
            value = fields[path]
            if not all(token in value for token in required):
                raise ValueError(f'expected evidence missing: {index} {path}')
            evidence.setdefault(index, []).append({
                'field': path, 'field_sha256': hashlib.sha256(value.encode()).hexdigest(),
                'category': category, 'data_flow_excerpt': excerpt,
            })
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidates', type=Path)
    parser.add_argument('imported', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rows, _, _, _, manifest = inventory(CATALOG)
    candidates = json.loads(args.candidates.read_text(encoding='utf-8'))
    imported = json.loads(args.imported.read_text(encoding='utf-8'))
    if any(data['archive_sha256'] != manifest['archiveSha256'] for data in (candidates, imported)):
        raise ValueError('evidence and import inventory must refer to the bundled archive')
    parsed, selected = selected_indices(rows, imported)
    evidence = evidence_records(rows)
    profiles = {}
    for row in candidates['candidates']:
        ident = row['source_id']
        if ident:
            profiles.setdefault(ident, []).append(row['index'])
    classifications = {}
    for index in evidence:
        if index in parsed:
            classifications[parsed[index]['id']] = ('network_data_to_eval', None)
    for label, entries in (('local_code_only_observed', LOCAL), ('data_provenance_unconfirmed', UNKNOWN)):
        for index, (path, summary) in entries.items():
            value = dict(strings(rows[index]))[path]
            if 'eval(' not in value and 'eval (' not in value:
                raise ValueError(f'missing eval field: {index} {path}')
            classifications[parsed[index]['id']] = (label, {'index': index, 'field': path,
                'field_sha256': hashlib.sha256(value.encode()).hexdigest(), 'summary': summary})
    if set(profiles) != set(classifications):
        raise ValueError('manual triage does not account for every candidate source ID')
    selected_rows = {r['id']: r for r in imported['selected_sources']}
    result = []
    for ident, indices in profiles.items():
        category, note = classifications[ident]
        chosen = selected[ident]
        result.append({'source_id': ident,
                       **{k: v for k, v in selected_rows[ident].items() if k != 'id'},
                       'classification': category,
                       'candidate_record_indices': indices, 'selected_record_index': chosen,
                       'selected_record_has_evidence': chosen in evidence,
                       'selected_eval_fields': [path for path, value in strings(rows[chosen])
                                                if re.search(r'\beval\s*\(|\b(?:new\s+)?Function\s*\(', value)],
                       'evidence': [{'record_index': i, **item} for i in indices for item in evidence.get(i, [])],
                       'assessment': note})
    unimportable = [{'record_index': row['index'], 'name': row['name'],
                     'evidence': evidence.get(row['index'], []),
                     'assessment': ('local source comment eval observed' if row['index'] in (617, 3488) else None)}
                    for row in candidates['candidates'] if row['source_id'] is None]
    output = {'archive_sha256': manifest['archiveSha256'],
              'baseline_import_code_sha256': imported.get('import_code_sha256', {}),
              'scope': 'manual static data-flow triage of same-field eval/network candidates; no source code executed',
              'function_scan': 'No Function( or new Function( in any candidate record; zero same-field Function/network matches across all raw records.',
              'source_profiles': result, 'unimportable_records': unimportable}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'{len(result)} unique IDs; '
          f'{sum(r["classification"] == "network_data_to_eval" for r in result)} with data-flow evidence; '
          f'{sum(r["selected_record_has_evidence"] for r in result)} selected records contain evidence')


if __name__ == '__main__':
    main()
