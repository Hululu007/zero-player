"""Compare a pinned local Block List Project snapshot to the bundled catalog.

The audit is offline: it does not request any catalog or listed site, execute
rules, or inspect user data. A match is a third-party clue, not a verdict.
"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .audit_certpl_legado import catalog_references, domain_matches, host_name
    from .audit_legado_catalog import CATALOG, inventory
    from .fetch_blocklistproject_snapshot import COMMIT, COMMIT_DATE, FILES, RAW_BASE, REPOSITORY, TREE, feed_header
else:
    from audit_certpl_legado import catalog_references, domain_matches, host_name
    from audit_legado_catalog import CATALOG, inventory
    from fetch_blocklistproject_snapshot import COMMIT, COMMIT_DATE, FILES, RAW_BASE, REPOSITORY, TREE, feed_header


CATEGORIES = ('malware', 'gambling', 'porn', 'phishing')
ARCHIVE_SHA256 = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
INVENTORY_SHA256 = 'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
AUDIT_FILES = ('tool/audit_blocklistproject_legado.py',
               'tool/fetch_blocklistproject_snapshot.py',
               'tool/audit_certpl_legado.py', 'tool/audit_legado_catalog.py',
               'tool/audit_legado_rule_patterns.py', 'tool/triage_legado_eval_candidates.py')
DNS = re.compile(rb'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+'
                 rb'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z')
SINKS = {b'0.0.0.0', b'127.0.0.1', b'::', b'::1'}
UAA_ID = '08b828adf2d0154db83894b6b77db3defa9dfae30de8a832fc26a5f7c72cbe07'
UAA_DISCOVERY_SHA256 = '7c8dfc898783d6067314d0e89f98742ef4383c48ea22fa4da9d005a58698ded1'


def candidate_domains(refs):
    """Map each legal exact/parent indicator to the catalog hosts it covers."""
    out = defaultdict(list)
    for host in sorted(refs):
        labels = host.split('.')
        for offset in range(len(labels) - 1):
            indicator = '.'.join(labels[offset:])
            out[indicator].append((host, 'exact' if offset == 0 else 'listed_parent'))
    return dict(out)


def extract_domains(line):
    """Accept hosts-file sinkhole mappings or bare domains; never parse URLs."""
    content = line.split(b'#', 1)[0].strip()
    if not content:
        return (), 'empty_or_comment', 0
    parts = content.split()
    if parts[0] in SINKS and len(parts) >= 2:
        tokens, kind = parts[1:], 'sinkhole_mapping'
    elif len(parts) == 1:
        tokens, kind = parts, 'bare_domain'
    else:
        return (), 'unsupported', 0
    result, invalid = [], 0
    for token in tokens:
        raw = token.lower().rstrip(b'.')
        if raw.isascii():
            valid = len(raw) <= 253 and DNS.fullmatch(raw) is not None
            domain = raw.decode('ascii') if valid else None
        else:
            try:
                domain = host_name(raw.decode('utf-8'))
            except UnicodeError:
                domain = None
        if domain is None:
            invalid += 1
        else:
            result.append(domain)
    return tuple(result), kind, invalid


def verify_file(path, name, metadata, candidates=None):
    """Hash while parsing, retaining only listed indicators in the candidate set."""
    size, blob = FILES[name]
    if (metadata.get('url') != f'{RAW_BASE}/{name}' or metadata.get('status') != 200
            or metadata.get('bytes') != size or metadata.get('git_blob_sha1') != blob):
        raise ValueError(f'unexpected pinned metadata for {name}')
    for key in ('observed_at', 'completed_at'):
        stamp = datetime.fromisoformat(metadata[key].replace('Z', '+00:00'))
        if stamp.utcoffset() is None:
            raise ValueError(f'undated snapshot metadata for {name}')
    digest = hashlib.sha256()
    git = hashlib.sha1(f'blob {size}\0'.encode('ascii'))
    count, prefix = 0, bytearray()
    stats, found = Counter(), set()
    with path.open('rb') as source:
        if candidates is None:
            iterator = iter(lambda: source.read(256 * 1024), b'')
        else:
            iterator = source
        for block in iterator:
            count += len(block)
            if count > size:
                raise ValueError(f'snapshot file exceeds pinned size: {name}')
            digest.update(block)
            git.update(block)
            if len(prefix) < 8192:
                prefix.extend(block[:8192-len(prefix)])
            if candidates is not None:
                domains, kind, invalid = extract_domains(block)
                stats[kind] += 1
                stats['invalid_domain_tokens'] += invalid
                if invalid:
                    tokens = block.split(b'#', 1)[0].split()
                    if tokens and tokens[0] in SINKS:
                        tokens = tokens[1:]
                    stats['invalid_tokens_with_underscore'] += sum(b'_' in token for token in tokens)
                stats['domain_tokens'] += len(domains)
                found.update(domain for domain in domains if domain in candidates)
    if count != size or git.hexdigest() != blob or digest.hexdigest() != metadata.get('sha256'):
        raise ValueError(f'snapshot does not match its pinned blob and SHA-256: {name}')
    if name.endswith('.txt') and feed_header(prefix) != metadata.get('file_header'):
        raise ValueError(f'file header differs from recorded metadata: {name}')
    return found, dict(stats)


def build_matches(refs, parsed, selected, indicators, category):
    matches = []
    for host in sorted(refs):
        for domain, relation in domain_matches(host, indicators):
            references = []
            for index, field in sorted(refs[host]):
                source = parsed.get(index)
                ident = source['id'] if source else None
                references.append({'record_index': index, 'field': field,
                                   'source_id': ident,
                                   'selected_version': bool(ident and selected.get(ident) == index)})
            matches.append({'catalog_host': host, 'listed_domain': domain,
                            'relation': relation, 'category': category,
                            'catalog_references': references})
    return matches


def group_selected_sources(matches, parsed, selected):
    """Separate selected endpoint matches from other static field mentions."""
    grouped = defaultdict(dict)
    for match in matches:
        for reference in match['catalog_references']:
            ident = reference['source_id']
            if not reference['selected_version'] or selected.get(ident) != reference['record_index']:
                continue
            key = (match['catalog_host'], match['listed_domain'], match['relation'])
            fields = grouped[ident].setdefault(key, set())
            fields.add(reference['field'])
    result = {'exact_endpoint': [], 'listed_parent_endpoint': [], 'other_fields_only': []}
    for ident, signals in sorted(grouped.items()):
        index = selected[ident]
        source = parsed[index]
        endpoint = [key for key, fields in signals.items() if 'selected_imported_host' in fields]
        if any(key[2] == 'exact' for key in endpoint):
            group = 'exact_endpoint'
        elif endpoint:
            group = 'listed_parent_endpoint'
        else:
            group = 'other_fields_only'
        result[group].append({
            'source_id': ident, 'name': source['name'], 'kind': source['kind'],
            'source_endpoint_host': source['host'], 'selected_record_index': index,
            'signals': [{'catalog_host': host, 'listed_domain': domain, 'relation': relation,
                         'fields': sorted(fields)}
                        for (host, domain, relation), fields in sorted(signals.items())],
        })
    return result


def uaa_metadata_evidence(rows, parsed, selected):
    """Recheck the explicit catalog labels of one manually reviewed source ID."""
    indices = sorted(index for index, source in parsed.items() if source['id'] == UAA_ID)
    if indices != [989, 3116] or selected.get(UAA_ID) != 989:
        raise ValueError('UAA selected source identity or duplicate indices changed')
    evidence = []
    for index in indices:
        row = rows[index]
        discovery = row.get('exploreUrl')
        if not isinstance(discovery, str):
            raise ValueError('UAA discovery metadata is missing')
        digest = hashlib.sha256(discovery.encode('utf-8')).hexdigest()
        titles = re.findall(r"['\"]title['\"]\s*:\s*['\"]([^'\"]+)['\"]", discovery)
        expected = ['肉量·全部', '少肉', '中肉', '多肉', '超多']
        if (digest != UAA_DISCOVERY_SHA256 or len(titles) != 49
                or not {'家庭乱伦', '调教虐待'}.issubset(titles)
                or not any(titles[pos:pos + len(expected)] == expected for pos in range(len(titles)))):
            raise ValueError('UAA explicit category evidence differs from the reviewed record')
        evidence.append({'record_index': index, 'last_update_time': row.get('lastUpdateTime'),
                         'discovery_field_sha256': digest, 'category_count': len(titles),
                         'explicit_category_examples': ['家庭乱伦', '调教虐待'],
                         'adult_level_filter_sequence': expected})
    return {'source_id': UAA_ID, 'historical_selected_record_index': 989,
            'basis': 'These are bundled source category labels, not a fresh website observation.',
            'records': evidence}


def analyze(snapshot_dir, imported_path):
    code_hashes = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest()
                   for name in AUDIT_FILES}
    manifest_bytes = (snapshot_dir / 'snapshot.json').read_bytes()
    snapshot = json.loads(manifest_bytes)
    if (snapshot.get('repository') != REPOSITORY or snapshot.get('revision') != COMMIT
            or snapshot.get('tree') != TREE or snapshot.get('commit_date') != COMMIT_DATE
            or snapshot.get('tree_metadata_url') != f'https://api.github.com/repos/blocklistproject/Lists/git/trees/{TREE}'
            or snapshot.get('repository_license') != 'Unlicense (repository LICENSE and README)'
            or set(snapshot.get('files', {})) != set(FILES)):
        raise ValueError('snapshot is not the expected pinned repository tree')
    for name in ('LICENSE', 'README.md'):
        verify_file(snapshot_dir / name, name, snapshot['files'][name])
    license_text = (snapshot_dir / 'LICENSE').read_text(encoding='utf-8')
    readme_text = (snapshot_dir / 'README.md').read_text(encoding='utf-8')
    if 'unencumbered software released into the public domain' not in license_text.lower():
        raise ValueError('repository LICENSE content differs from the reviewed version')
    if 'licensed under the [unlicense]' not in readme_text.lower():
        raise ValueError('repository README license declaration is missing')

    import_bytes = imported_path.read_bytes()
    if hashlib.sha256(import_bytes).hexdigest() != INVENTORY_SHA256:
        raise ValueError('import inventory differs from the audited 2139-ID baseline')
    imported = json.loads(import_bytes)
    rows, hosts, unresolved, _, archive = inventory(CATALOG)
    if archive['archiveSha256'] != ARCHIVE_SHA256 or imported['archive_sha256'] != ARCHIVE_SHA256:
        raise ValueError('catalog archive is not the audited snapshot')
    refs, parsed, selected, literals, selected_hosts, missing = catalog_references(rows, hosts, imported)
    if (len(rows), len(refs), len(selected), len(selected_hosts), missing) != (4845, 2720, 2139, 1541, 0):
        raise ValueError('catalog host/ID scope differs from the reviewed baseline')
    candidates = candidate_domains(refs)
    categories = {}
    all_matches = []
    for category in CATEGORIES:
        name = category + '.txt'
        indicators, stats = verify_file(snapshot_dir / name, name,
                                        snapshot['files'][name], candidates)
        expected_license = None if category == 'gambling' else 'MIT'
        if snapshot['files'][name]['file_header'].get('license') != expected_license:
            raise ValueError(f'unexpected license header for {name}')
        matches = build_matches(refs, parsed, selected, indicators, category)
        selected_ids = sorted({ref['source_id'] for match in matches
                               for ref in match['catalog_references'] if ref['selected_version']})
        categories[category] = {
            'source': snapshot['files'][name],
            'parse_stats': stats,
            'matching_hosts': len({match['catalog_host'] for match in matches}),
            'matching_host_indicator_pairs': len(matches),
            'selected_source_ids_with_matching_reference': len(selected_ids),
            'selected_sources_by_relation': group_selected_sources(matches, parsed, selected),
            'matches': matches,
        }
        all_matches.extend(matches)
    if any(hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest
           for name, digest in code_hashes.items()):
        raise ValueError('audit code changed during the offline comparison')
    return {
        'method': 'Offline-only match of exact DNS names or explicitly listed parent domains. No websites visited, rules executed, or user data read or uploaded.',
        'source': {'repository': REPOSITORY, 'revision': COMMIT, 'commit_date': COMMIT_DATE,
                   'tree': TREE, 'tree_metadata_url': snapshot['tree_metadata_url'],
                   'repository_license_declaration': snapshot['repository_license'],
                   'license_file': snapshot['files']['LICENSE'],
                   'readme_file': snapshot['files']['README.md'],
                   'license_caveat': 'The repository declares Unlicense; malware, phishing and porn file headers say MIT, while gambling has no license field in its leading header. Upstream data rights and redistribution terms have not been determined.',
                   'snapshot_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest()},
        'catalog': {'archive_sha256': archive['archiveSha256'], 'raw_records': len(rows),
                    'unresolved_endpoint_records': len(unresolved),
                    'import_inventory_sha256': hashlib.sha256(import_bytes).hexdigest(),
                    'import_inventory_generated_at': imported['generated_at'],
                    'importer_code_sha256': imported['import_code_sha256'],
                    'selected_source_ids': len(selected), 'selected_source_hosts': len(selected_hosts),
                    'literal_url_occurrences': literals, 'unique_compared_hosts': len(refs),
                    'scope': 'Original 4845 bundled records: declared endpoints and literal HTTP(S) hosts in all fields, plus the 2139 selected imported IDs. Field references can be comments or script text and do not prove that a host was contacted.'},
        'audit_script_sha256': code_hashes,
        'manual_review_metadata': {'uaa_novel': uaa_metadata_evidence(rows, parsed, selected)},
        'comparison': {'rule': 'Match case-insensitive IDNA DNS labels exactly or a listed parent of the catalog host; never reverse the relation or match siblings, substrings, paths, shared IPs, or dynamic domains.',
                       'total_distinct_matching_hosts': len({match['catalog_host'] for match in all_matches}),
                       'categories': categories},
        'limitations': ['Each category represents a third-party list entry, not proof of current malware, gambling, adult content, phishing, availability, or wrongdoing.',
                        'A listed parent can contain unrelated subdomains, and shared services or static comments can cause false associations; check each reference and actual site before any classification.',
                        'No match does not establish safety; dynamic domains, malformed URLs, private addresses and content behind paths may be outside coverage.',
                        'The repository is archived and the pinned source is historical; host ownership, website behavior and rules may change.',
                        'The import inventory is the historical 2139-ID baseline and does not represent current installation, enablement or later rule repairs.'],
        'reproduction': 'Run this offline script with the retained pinned build snapshot and the hashed import inventory; raw upstream lists are not committed.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', type=Path, required=True)
    parser.add_argument('--import-inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = analyze(args.snapshot, args.import_inventory)
    if args.output.exists():
        raise ValueError('output already exists; refusing to overwrite')
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"{report['catalog']['unique_compared_hosts']} hosts, {report['catalog']['selected_source_ids']} selected IDs")
    for category, item in report['comparison']['categories'].items():
        print(f"{category}: {item['matching_hosts']} matching hosts, {item['selected_source_ids_with_matching_reference']} selected IDs")


if __name__ == '__main__':
    main()
