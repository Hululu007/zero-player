"""Inventory selected Legado fields that mention eval and page-like variables.

This is a recall-oriented text scan, not data-flow analysis. In particular,
metadata, local eval and a page variable in the same field can be unrelated.
Source rules are never executed and no network connections are made.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .audit_legado_catalog import CATALOG, inventory
    from .audit_legado_rule_patterns import strings
    from .triage_legado_eval_candidates import selected_indices
else:
    from audit_legado_catalog import CATALOG, inventory
    from audit_legado_rule_patterns import strings
    from triage_legado_eval_candidates import selected_indices


EVAL = re.compile(r'\beval\s*\(', re.I)
PAGE_VARIABLE = re.compile(
    r'\b(?:result|input|body|html|src)\b|\bjava\s*\.\s*getString\s*\(',
    re.I,
)


def candidate_fields(record):
    return [
        {
            'field': path,
            'sha256': hashlib.sha256(value.encode()).hexdigest(),
            'metadata': path in ('bookSourceComment', 'variableComment'),
        }
        for path, value in strings(record)
        if EVAL.search(value) and PAGE_VARIABLE.search(value)
    ]


def audit(rows, imported, previous):
    parsed, selected = selected_indices(rows, imported)
    previous_ids = {entry['source_id'] for entry in previous['source_profiles']}
    profiles = []
    for ident, index in selected.items():
        fields = candidate_fields(rows[index])
        if fields:
            profiles.append({
                'source_id': ident,
                'selected_record_index': index,
                'name': parsed[index]['name'],
                'kind': parsed[index]['kind'],
                'host': parsed[index]['host'],
                'previous_same_field_network_candidate': ident in previous_ids,
                'candidate_fields': fields,
            })
    return profiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('imported', type=Path)
    parser.add_argument('previous', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rows, _, _, _, manifest = inventory(CATALOG)
    imported = json.loads(args.imported.read_text(encoding='utf-8'))
    previous = json.loads(args.previous.read_text(encoding='utf-8'))
    if any(data['archive_sha256'] != manifest['archiveSha256']
           for data in (imported, previous)):
        raise ValueError('inventory and previous triage must use the bundled archive')
    profiles = audit(rows, imported, previous)
    output = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'archive_sha256': manifest['archiveSha256'],
        'import_code_sha256': imported.get('import_code_sha256', {}),
        'scope': ('heuristic selected raw fields mentioning eval and page-like '
                  'variables or java.getString; not proof of data flow; no execution'),
        'profiles': profiles,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    additional = sum(not row['previous_same_field_network_candidate'] for row in profiles)
    print(f'{len(profiles)} selected IDs match heuristic; '
          f'{additional} outside previous same-field network candidates')


if __name__ == '__main__':
    main()
