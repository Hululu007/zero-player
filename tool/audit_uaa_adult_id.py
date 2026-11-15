"""Reproduce a static UAA-source comparison without executing source rules.

The comparison uses the archived source pack and an immutable historical ledger
Git object. It makes no requests and does not read any user data or page body.
"""
import argparse
import bz2
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parent.parent
COMMIT = '6c18b625ee81176c130aef6c33bd6dd3ee5159f1'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA = '81ceb0f074c5abe38f45d67148ddee195a9878ec533c8124ec9ab5bbf3aa121b'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
TARGETS = {
    989: '08b828adf2d0154db83894b6b77db3defa9dfae30de8a832fc26a5f7c72cbe07',
    3903: 'f55889c694e46c91b0cb834eb5a36c861eb49963e8f86c042f164732dbdb6f06',
    1860: 'f44c7e7d83ca20312dd48786f9bb53448cbbf8bfd737f5bff7108798d7c97ddd',
    3352: 'e7830aff2d331cabbbe123bd8d94cfe614181793ee4f8fbe0e02327effb376db',
}
CODE_PATHS = [
    'lib/features/books/data/book_import.dart',
    'lib/features/books/data/legado/legado_import.dart',
    'lib/features/books/domain/book.dart',
    'lib/features/books/domain/legado_source.dart',
    'lib/features/books/domain/book_source_risk.dart',
]
TITLE_URL = re.compile(
    r'''\{\s*["']title["']\s*:\s*(["'])(.*?)\1\s*,\s*["']url["']\s*:\s*(["'])(.*?)\3''',
    re.S,
)
ADULT_CATEGORIES = ['家庭乱伦', '调教虐待', '群体换伴', '强奸轮奸']
INTENSITY = {'少肉': '1', '中肉': '2', '多肉': '3', '超多': '4'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git_blob(path):
    result = subprocess.run(
        ['git', 'show', f'{COMMIT}:{path}'], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    )
    return result.stdout


def selected_sources():
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
    found = {entry['selected_record_index']: entry for entry in ledger['sources']
             if entry['selected_record_index'] in TARGETS}
    if set(found) != set(TARGETS):
        raise ValueError('selected record indices are incomplete')
    for index, source in found.items():
        if source['source_id'] != TARGETS[index] or source['endpoint_host'] != 'api.uaa.com':
            raise ValueError(f'selected source identity mismatch: {index}')
    hashes = {}
    for path in CODE_PATHS:
        digest = sha(git_blob(path).replace(b'\r\n', b'\n'))
        if ledger['normalized_source_code_sha256'][path] != digest:
            raise ValueError(f'historical source digest mismatch: {path}')
        hashes[path] = digest
    return rows, found, hashes, sha(archive)


def literal_pairs(text):
    return [(match.group(2), match.group(4)) for match in TITLE_URL.finditer(text)]


def endpoint(url):
    parsed = urlsplit(url.split(',', 1)[0])
    return parsed.hostname, parsed.path


def validate_intensity(pairs):
    urls = {title: url for title, url in pairs}
    for title, value in INTENSITY.items():
        if parse_qs(urlsplit(urls[title]).query).get('porn') != [value]:
            raise ValueError(f'global intensity option changed: {title}')


def identity(index, rows, ledger):
    source = ledger[index]
    row = rows[index]
    return {
        'selected_record_index': index,
        'source_id': source['source_id'],
        'name': source['name'],
        'kind': source['kind'],
        'endpoint_host': source['endpoint_host'],
        'normalized_legado_canonical_sha256': source['normalized_legado_canonical_sha256'],
        'raw_explore_sha256_utf8': sha(row['exploreUrl'].encode('utf8')),
        'raw_search_sha256_utf8': sha(row['searchUrl'].encode('utf8')),
        'adult_source_classified_at_historical_snapshot':
            source['static_policy']['adult_source_classified'],
    }


def derive():
    rows, sources, source_hashes, archive_hash = selected_sources()
    pairs_989 = literal_pairs(rows[989]['exploreUrl'])
    pairs_3903 = literal_pairs(rows[3903]['exploreUrl'])
    if (len(pairs_989), len(pairs_3903)) != (50, 50):
        raise ValueError('unexpected static menu length')
    if len(set(pairs_989)) != 50 or len(set(pairs_3903)) != 50:
        raise ValueError('unexpected duplicate static menu pair')
    common = len(set(pairs_989) & set(pairs_3903))
    if common != 49:
        raise ValueError('unexpected common static menu count')
    for index, pairs in [(989, pairs_989), (3903, pairs_3903)]:
        if endpoint(rows[index]['searchUrl']) != ('api.uaa.com', '/novel/app/novel/search'):
            raise ValueError(f'novel search endpoint mismatch: {index}')
        nonempty = [(title, url) for title, url in pairs if url]
        if (index == 989 and len(nonempty) != 49) or (index == 3903 and len(nonempty) != 50):
            raise ValueError(f'unexpected empty discovery addresses: {index}')
        if any(endpoint(url) != ('api.uaa.com', '/novel/app/novel/search') for _, url in nonempty):
            raise ValueError(f'novel discovery endpoint mismatch: {index}')
        labels = {title for title, _ in pairs}
        if not set(ADULT_CATEGORIES).issubset(labels) or '肉量·全部' not in labels:
            raise ValueError(f'explicit categories or global intensity missing: {index}')
        validate_intensity(pairs)
    dynamic = rows[1860]['exploreUrl']
    dynamic_pairs = literal_pairs(dynamic)
    if (not dynamic.lstrip().startswith('@js:') or
            "java.ajax('https://api.uaa.com/novel/app/novel/categories')" not in dynamic):
        raise ValueError('dynamic category source changed')
    if endpoint(rows[1860]['searchUrl']) != ('api.uaa.com', '/novel/app/novel/search'):
        raise ValueError('dynamic novel search endpoint changed')
    validate_intensity(dynamic_pairs)
    if endpoint(rows[3352]['searchUrl']) != ('api.uaa.com', '/comic/app/comic/search'):
        raise ValueError('same-host comic counterexample changed')
    return {
        'schema_version': 1,
        'scope': 'Offline static comparison of exact bundled source records and a historical import snapshot; no source rule, webpage script, network request, or user data is executed or accessed.',
        'catalog_archive_sha256': archive_hash,
        'historical_ledger': {'git_commit': COMMIT, 'path': LEDGER, 'sha256': LEDGER_SHA,
                              'note': 'Historical pre-change snapshot, not the current regenerated ledger.'},
        'historical_normalized_source_code_sha256': source_hashes,
        'verification_tool_sha256_lf': sha(Path(__file__).read_bytes().replace(b'\r\n', b'\n')),
        'candidate': {**identity(3903, rows, sources),
            'search_host': 'api.uaa.com', 'search_path': '/novel/app/novel/search',
            'literal_discovery_title_url_pairs': len(pairs_3903),
            'all_literal_discovery_pairs_use_search_endpoint': True,
            'explicit_adult_category_labels': ADULT_CATEGORIES,
            'global_intensity_label': '肉量·全部', 'global_intensity_porn_values': INTENSITY,
            'common_unique_title_url_pairs_with_989': common},
        'already_classified_comparison': {**identity(989, rows, sources),
            'literal_discovery_title_url_pairs': len(pairs_989),
            'empty_address_pairs_ignored_by_importer': 1,
            'global_intensity_label': '肉量·全部', 'global_intensity_porn_values': INTENSITY},
        'separate_dynamic_candidate': {**identity(1860, rows, sources),
            'search_host': 'api.uaa.com', 'search_path': '/novel/app/novel/search',
            'dynamic_category_endpoint_path': '/novel/app/novel/categories',
            'global_intensity_porn_values': INTENSITY,
            'dynamic_category_response_observed': False,
            'whole_source_adult_classification_proven': None,
            'recommendation': 'Review separately; dynamic category response and complete source content were not observed.'},
        'same_host_comic_counterexample': {**identity(3352, rows, sources),
            'search_path': '/comic/app/comic/search',
            'note': 'Different source ID and comic endpoint; no host-wide classification follows.'},
        'limitations': [
            'Historical catalog metadata and shared search targets do not verify current webpages, current responses, safety, or the content of every work.',
            'Dynamic JavaScript and remote category data were inspected as text only and were neither executed nor fetched.',
            'The exact historical source policy snapshot requires local Git and the cited commit; missing Git history causes verification to fail.',
        ],
        'reproduction': 'python tool/audit_uaa_adult_id.py --verify docs/implementation/legado-uaa-adult-id-review-20261116.json',
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
        print('UAA source evidence matches the archived pack and historical Git snapshot')


if __name__ == '__main__':
    main()
