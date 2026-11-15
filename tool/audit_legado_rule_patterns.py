"""Statically flag bundled source fields containing eval and network indicators.

Co-occurrence is a candidate only, not proof that evaluated data was fetched.
The exact wesrc template is reported separately; no source scripts are run.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

if __package__:
    from .audit_legado_catalog import CATALOG, hostname, inventory
else:
    from audit_legado_catalog import CATALOG, hostname, inventory


EVAL = re.compile(r'\beval\s*\(', re.I)
NETWORK = re.compile(r'\bokhttp(?:3)?\b|\bjava\.(?:ajax|get|post|connect)\s*\('
                     r'|\bfetch\s*\(|\bXMLHttpRequest\b|\bjava\.net\b|https?://', re.I)
URL = re.compile(r'https?://[^\s"\'<>]+', re.I)
WESRC = (re.compile(r'global\.wesrc\s*=\s*\[global\.okhttp\.client\.newCall'
                    r'\(request\)\.execute\(\)\.body\(\)\.string\(\)\]', re.I),
         re.compile(r'eval\s*\(\s*\[new\s+global\.okhttp\.JString\('
                    r'android\.util\.Base64\.decode\(global\.wesrc\s*,\s*0\)', re.I))


def strings(value, path=''):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from strings(child, f'{path}.{key}' if path else key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from strings(child, f'{path}[{index}]')


def candidates(row):
    fields = []
    for path, value in strings(row):
        if not EVAL.search(value) or not NETWORK.search(value):
            continue
        hosts = set()
        for match in URL.findall(value):
            try:
                host = urlsplit(match).hostname
                if host:
                    hosts.add(host.lower())
            except ValueError:
                pass
        fields.append({'path': path, 'sha256': hashlib.sha256(value.encode()).hexdigest(),
                       'literal_url_hosts': sorted(hosts),
                       'wesrc_template': all(marker.search(value) for marker in WESRC)})
    return fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path, help='output of inventory_legado_import.dart')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rows, _, _, _, manifest = inventory(CATALOG)
    imported = json.loads(args.inventory.read_text(encoding='utf-8'))
    if imported['archive_sha256'] != manifest['archiveSha256']:
        raise ValueError('import inventory refers to a different catalog')
    ids = {row['index']: row for row in imported['raw_parseable']}
    result = []
    for index, row in enumerate(rows):
        fields = candidates(row)
        if fields:
            source = ids.get(index)
            result.append({'index': index, 'name': row.get('bookSourceName', ''),
                           'host': source['host'] if source else hostname(row.get('bookSourceUrl', ''), allow_alias=True),
                           'source_id': source['id'] if source else None, 'fields': fields})
    output = {'archive_sha256': manifest['archiveSha256'],
              'method': 'same string contains eval( and a network marker; no code executed',
              'candidates': result}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(f'{len(result)} candidate records, '
          f'{sum(any(f["wesrc_template"] for f in r["fields"]) for r in result)} exact wesrc templates')


if __name__ == '__main__':
    main()
