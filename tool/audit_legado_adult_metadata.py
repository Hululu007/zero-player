"""Extract explicit per-record adult labels, grouped by actual source ID.

This is metadata evidence, not a claim about a site's current contents. Its
purpose is to show which labels are lost when import chooses a newer variant.
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re


LABEL = re.compile(r'🔞|十八禁|18禁|色情|成人小说|成人漫画|成人文学|情色|黄文|黃文|肉文|裸聊', re.I)


def has_explicit_label(row):
    return bool(LABEL.search(row['name'] + ' ' + row['group']))


def summarize(inventory):
    evidence = defaultdict(list)
    for row in inventory['raw_parseable']:
        if has_explicit_label(row):
            evidence[row['id']].append({key: row[key] for key in ('index', 'host', 'name', 'group')})
    sources = []
    for source in inventory['selected_sources']:
        if source['id'] in evidence:
            sources.append({**source, 'selected_has_label': has_explicit_label(source),
                            'raw_label_evidence': evidence[source['id']]})
    return {'archive_sha256': inventory['archive_sha256'],
            'import_code_sha256': inventory.get('import_code_sha256', {}),
            'label_pattern': LABEL.pattern,
            'labelled_id_count': len(sources),
            'selected_label_absent_count': sum(not x['selected_has_label'] for x in sources),
            'sources': sources}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = summarize(json.loads(args.inventory.read_text(encoding='utf-8')))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"{result['labelled_id_count']} IDs with explicit adult metadata; "
          f"{result['selected_label_absent_count']} selected variants omit these labels")


if __name__ == '__main__':
    main()
