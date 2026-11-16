"""Compare a locally retained Phishing Army domains snapshot with Legado.

This tool makes no network requests and never runs source rules. The feed and
the provider's manifest are intentionally kept outside the repository. A
domain-list match is a clue, not proof of a malicious source or exact URL.
"""

import argparse
import hashlib
import json
from pathlib import Path

if __package__:
    from .audit_certpl_legado import catalog_references, domain_matches, host_name, timestamp
    from .audit_legado_catalog import CATALOG, inventory
else:
    from audit_certpl_legado import catalog_references, domain_matches, host_name, timestamp
    from audit_legado_catalog import CATALOG, inventory


ROOT = 'https://phishing.army/download/'
MANIFEST_URL = ROOT + 'phishing-army-manifest.json'
FEED_NAME = 'phishing-army-domains.txt'
FEED_URL = ROOT + FEED_NAME


def digest(content):
    return hashlib.sha256(content).hexdigest()


def verify_download(content, metadata, endpoint):
    if metadata.get('endpoint') != endpoint or metadata.get('status') != 200:
        raise ValueError('download metadata does not identify the official successful response')
    if metadata.get('bytes') != len(content) or metadata.get('sha256') != digest(content):
        raise ValueError('download bytes do not match metadata')
    return timestamp(metadata['observed_at'])


def parse_snapshot(feed, manifest, manifest_metadata, feed_metadata):
    manifest_observed = verify_download(manifest, manifest_metadata, MANIFEST_URL)
    feed_observed = verify_download(feed, feed_metadata, FEED_URL)
    info = json.loads(manifest)
    if info.get('schema_version') != 1:
        raise ValueError('unexpected provider manifest schema')
    if timestamp(info['generated_at']) > min(manifest_observed, feed_observed):
        raise ValueError('manifest generation time is later than download')
    expected = info['files'][FEED_NAME]
    if expected.get('bytes') != len(feed) or expected.get('sha256') != digest(feed):
        raise ValueError('manifest does not describe this feed snapshot')
    entries = set()
    count = 0
    for line in feed.decode('utf-8-sig').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        domain = host_name(line)
        if not domain or domain != line.lower().rstrip('.'):
            raise ValueError('invalid domain in feed')
        entries.add(domain)
        count += 1
    if count != len(entries) or count != info['entries']:
        raise ValueError('feed domain count does not match the manifest')
    return entries, info


def compare(refs, parsed, selected, indicators):
    matches = []
    for host in sorted(refs):
        for domain, relation in domain_matches(host, indicators):
            references = []
            for index, field in sorted(refs[host]):
                source = parsed.get(index)
                source_id = source['id'] if source else None
                references.append({
                    'record_index': index,
                    'field': field,
                    'source_id': source_id,
                    'selected_version': bool(source_id and selected.get(source_id) == index),
                })
            matches.append({'catalog_host': host, 'indicator_domain': domain,
                            'relation': relation, 'catalog_references': references})
    return matches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feed', type=Path, required=True)
    parser.add_argument('--feed-metadata', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-metadata', type=Path, required=True)
    parser.add_argument('--import-inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    feed = args.feed.read_bytes()
    provider_manifest = args.manifest.read_bytes()
    feed_meta = json.loads(args.feed_metadata.read_text(encoding='utf-8'))
    manifest_meta = json.loads(args.manifest_metadata.read_text(encoding='utf-8'))
    indicators, provider = parse_snapshot(feed, provider_manifest, manifest_meta, feed_meta)
    rows, hosts, unresolved, _, catalog_manifest = inventory(CATALOG)
    imported_bytes = args.import_inventory.read_bytes()
    imported = json.loads(imported_bytes)
    if imported['archive_sha256'] != catalog_manifest['archiveSha256']:
        raise ValueError('import inventory and bundled archive differ')
    refs, parsed, selected, literal_count, selected_hosts, missing = catalog_references(
        rows, hosts, imported)
    matches = compare(refs, parsed, selected, indicators)
    dependencies = ('tool/audit_phishing_army_legado.py', 'tool/audit_certpl_legado.py',
                    'tool/audit_legado_catalog.py', 'tool/audit_legado_rule_patterns.py',
                    'tool/triage_legado_eval_candidates.py')
    report = {
        'method': 'Offline local domain comparison; no catalog URLs requested and no source rules executed.',
        'provider': {
            'project_url': 'https://phishing.army/downloads/',
            'usage_and_licensing_url': 'https://phishing.army/license/',
            'feed_download': feed_meta,
            'manifest_download': manifest_meta,
            'manifest_generated_at': provider['generated_at'],
            'manifest_entries': provider['entries'],
            'upstream_sources': [{'name': entry['name'], 'status': entry['status']}
                                 for entry in provider['sources']],
            'scope': 'Aggregated community phishing domains; not a malware or gambling feed. Some upstream providers overlap previously checked data.',
        },
        'catalog': {
            'archive_sha256': catalog_manifest['archiveSha256'],
            'raw_records': len(rows),
            'endpoint_hosts': len(hosts),
            'unresolved_endpoint_records': len(unresolved),
            'import_inventory_path': args.import_inventory.as_posix(),
            'import_inventory_sha256': digest(imported_bytes),
            'import_inventory_generated_at': imported['generated_at'],
            'selected_source_ids': len(selected),
            'selected_source_hosts': len(selected_hosts),
            'selected_sources_without_valid_host': missing,
            'literal_url_occurrences': literal_count,
            'unique_compared_hosts': len(refs),
            'scope': 'Declared endpoint and selected imported hosts plus literal HTTP(S) hosts in all string fields. A mention is not proof of execution; dynamic and malformed URLs may be omitted.',
        },
        'comparison': {
            'rule': 'DNS-label equality or a listed parent of the catalog host; no parent, sibling, substring, shared-IP or exact-URL inference.',
            'matching_host_indicator_pairs': len(matches),
            'matching_hosts': len({match['catalog_host'] for match in matches}),
            'matches': matches,
        },
        'normalized_tool_sha256': {
            path: digest(Path(path).read_bytes().replace(b'\r\n', b'\n')) for path in dependencies
        },
        'reproduction': 'Pass the separately retained feed, provider manifest and their download metadata along with the pinned import inventory. The provider files are not committed; a later snapshot may differ.',
        'limitations': [
            'No match does not establish safety, availability, or absence of malware, phishing or gambling.',
            'A domain match does not establish an exact URL match, current maliciousness, or which tenant or path was involved.',
            'This historical snapshot and importer inventory do not represent later changes.',
            'Public feed access does not grant rights over its independent upstream data providers.',
        ],
    }
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'{len(rows)} records, {len(refs)} hosts, {len(matches)} matching host/indicator pairs')


if __name__ == '__main__':
    main()
