"""Reproduce two bundled adult-source equivalence findings without network access.

The historical ledger contains the actual importer's canonical endpoint and
Legado rule hashes. This script binds them back to the bundled archive, its
explicit historical labels, and the immutable Git snapshot that produced them.
It never executes a source rule or accesses the current websites.
"""

import argparse
import bz2
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent.parent
COMMIT = '6c18b625ee81176c130aef6c33bd6dd3ee5159f1'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA = '81ceb0f074c5abe38f45d67148ddee195a9878ec533c8124ec9ab5bbf3aa121b'
LABELS = 'docs/implementation/legado-adult-label-evidence-20261115.json'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
CODE_PATHS = [
    'lib/features/books/data/book_import.dart',
    'lib/features/books/data/legado/legado_import.dart',
    'lib/features/books/domain/book.dart',
    'lib/features/books/domain/legado_source.dart',
    'lib/features/books/domain/book_source_risk.dart',
]
PAIRS = [
    {
        'labelled': (4715, 'fd43c18e3b6b2020f3f7823c48ae7691362f156e2c3b3a1523d5a7fb5c1bbfbf'),
        'candidate': (4730, '5c917c26905991075f4d33ffdc650a6f525e5e80f10837da497af751686cab1a'),
        'counterexample': (4704, 'b62b1166d3a5c9736ff5c4ca16427a9485f9de33dc401bfed8d144595b00fc9f'),
        'label_index': 484,
        'host': 'm.roushuwu.com',
        'endpoint_sha256': '1f520341cef553f53929aa39563a6d62fb97e30a97c9dfe1f6190334032c1ff6',
        'legado_sha256': '3362f0d0995def1ce468318bff5d6e9427b53005878fe251bee1b442366779ac',
    },
    {
        'labelled': (788, 'db5de6085b56eafa7738c7515a7c18a4111f1cf9f46c76df6640e46b681e48fa'),
        'candidate': (4564, 'f13fda5de688afbafbe3ac0e5f3d0b6cbeb858fc022c42b44f25a734e0e51374'),
        'counterexample': (4583, '3bded8f2ed0492577d9726fda2151acc6146a65bf410bd7eab6f637b6898e831'),
        'label_index': 788,
        'host': 'www.blshuge.com',
        'endpoint_sha256': 'b893fc7f28cdd04fe581450dc0bce683c1f2602c6778b558620b5370111f35e2',
        'legado_sha256': '9a895fce740a4da47c3077073cf9bf59fb80ace3fc11d3623152a982c990e522',
    },
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git_blob(path):
    return subprocess.run(
        ['git', 'show', f'{COMMIT}:{path}'], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout


def inputs():
    archive = (ROOT / ARCHIVE).read_bytes()
    manifest = json.loads((ROOT / 'assets/catalogs/books/legado/manifest.json').read_text(encoding='utf8'))
    if sha(archive) != manifest['archiveSha256']:
        raise ValueError('catalog archive SHA-256 mismatch')
    rows = json.loads(bz2.decompress(archive))['records']
    snapshot = git_blob(LEDGER)
    if sha(snapshot) != LEDGER_SHA:
        raise ValueError('historical ledger Git object SHA-256 mismatch')
    ledger = json.loads(snapshot)
    if ledger['input_sha256'][ARCHIVE] != sha(archive):
        raise ValueError('historical ledger refers to a different archive')
    label_blob = git_blob(LABELS)
    labels = json.loads(label_blob)
    if labels['archive_sha256'] != sha(archive):
        raise ValueError('historical label evidence refers to a different archive')
    hashes = {}
    for path in CODE_PATHS:
        digest = sha(git_blob(path).replace(b'\r\n', b'\n'))
        if ledger['normalized_source_code_sha256'][path] != digest:
            raise ValueError(f'historical source digest mismatch: {path}')
        hashes[path] = digest
    return rows, ledger, labels, hashes, sha(archive), sha(label_blob)


def identity(source):
    return {
        'selected_record_index': source['selected_record_index'],
        'source_id': source['source_id'],
        'name': source['name'],
        'kind': source['kind'],
        'format': source['format'],
        'endpoint_host': source['endpoint_host'],
        'endpoint_sha256': source['endpoint_sha256'],
        'normalized_legado_canonical_sha256': source['normalized_legado_canonical_sha256'],
        'adult_source_classified_at_historical_snapshot': source['static_policy']['adult_source_classified'],
    }


def compare(pair, rows, ledger, labels):
    def selected(role):
        index, source_id = pair[role]
        matches = [source for source in ledger['sources'] if source['selected_record_index'] == index]
        if len(matches) != 1 or matches[0]['source_id'] != source_id:
            raise ValueError(f'{role}: selected record or source ID changed')
        return matches[0]

    labelled, candidate, other = (selected(role) for role in ('labelled', 'candidate', 'counterexample'))
    if len({item['source_id'] for item in (labelled, candidate, other)}) != 3:
        raise ValueError('the three identities are not independent')
    for item in (labelled, candidate):
        if (item['kind'], item['format'], item['endpoint_host']) != ('text', 'html', pair['host']):
            raise ValueError('source kind, format or endpoint host mismatch')
        if item['endpoint_sha256'] != pair['endpoint_sha256']:
            raise ValueError('complete normalized endpoint digest mismatch')
        if item['normalized_legado_canonical_sha256'] != pair['legado_sha256']:
            raise ValueError('complete normalized Legado digest mismatch')
    if not labelled['static_policy']['adult_source_classified']:
        raise ValueError('labelled source not classified in historical snapshot')
    if candidate['static_policy']['adult_source_classified'] or other['static_policy']['adult_source_classified']:
        raise ValueError('historical candidate or counterexample already classified')
    if other['endpoint_host'] != pair['host'] or other['normalized_legado_canonical_sha256'] == pair['legado_sha256']:
        raise ValueError('same-host distinct-rule counterexample mismatch')
    raw_label = rows[pair['label_index']]
    if '🔞' not in raw_label['bookSourceName']:
        raise ValueError('explicit historical label missing')
    if pair['label_index'] not in labelled['related_same_id_and_endpoint_host_record_indices']:
        raise ValueError('historical ledger does not associate the label with this exact source ID')
    label_entries = [entry for entry in labels['sources'] if entry['id'] == labelled['source_id']]
    if len(label_entries) != 1 or not any(
        item['index'] == pair['label_index'] and item['host'] == pair['host']
        and item['name'] == raw_label['bookSourceName']
        for item in label_entries[0]['raw_label_evidence']
    ):
        raise ValueError('independent historical label evidence mismatch')
    return {
        'labelled_source': identity(labelled),
        'candidate_source': identity(candidate),
        'matched_fields': ['kind', 'format', 'complete normalized endpoint SHA-256',
                           'complete normalized Legado rule SHA-256'],
        'explicit_label': {'record_index': pair['label_index'],
                           'name': raw_label['bookSourceName']},
        'same_host_different_rule_counterexample': identity(other),
    }


def derive():
    rows, ledger, labels, source_hashes, archive_hash, label_hash = inputs()
    return {
        'schema_version': 1,
        'scope': 'Offline comparison of selected bundled records and historical importer results; no source rule, webpage script, network request, or user data is executed or accessed.',
        'catalog_archive_sha256': archive_hash,
        'historical_ledger': {'git_commit': COMMIT, 'path': LEDGER, 'sha256': LEDGER_SHA,
                              'note': 'Historical pre-change snapshot, not the current regenerated ledger.'},
        'historical_label_evidence': {'git_commit': COMMIT, 'path': LABELS, 'sha256': label_hash},
        'historical_normalized_source_code_sha256': source_hashes,
        'verification_tool_sha256_lf': sha(Path(__file__).read_bytes().replace(b'\r\n', b'\n')),
        'pairs': [compare(pair, rows, ledger, labels) for pair in PAIRS],
        'limitations': [
            'The rule equivalence concerns only the selected historical versions; no current webpage, response, complete content, or safety was verified.',
            'The two newly classified source IDs follow the existing persistent ID policy, including later rule revisions and historical books; other IDs and whole domains are not automatically classified.',
            'The cited historical ledger and label evidence require local Git and the specified commit; missing Git history causes verification to fail.',
        ],
        'reproduction': 'python tool/audit_equivalent_adult_ids.py --verify docs/implementation/legado-equivalent-adult-ids-20261116.json',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', type=Path, metavar='OUTPUT')
    mode.add_argument('--verify', type=Path, metavar='INPUT')
    args = parser.parse_args()
    evidence = derive()
    if args.write is not None:
        evidence['generated_at'] = datetime.now(timezone(timedelta(hours=8))).isoformat()
        evidence['time_zone'] = 'Asia/Shanghai (UTC+08:00)'
        with args.write.open('x', encoding='utf8', newline='\n') as output:
            json.dump(evidence, output, ensure_ascii=False, indent=2)
            output.write('\n')
        print(f'wrote {args.write}')
    else:
        saved = json.loads(args.verify.read_text(encoding='utf8'))
        saved.pop('generated_at')
        if saved.pop('time_zone') != 'Asia/Shanghai (UTC+08:00)' or saved != evidence:
            raise ValueError('evidence does not match offline recomputation')
        print('equivalent source evidence matches the archived pack and historical Git snapshot')


if __name__ == '__main__':
    main()
