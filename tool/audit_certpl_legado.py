"""Compare a local CERT Polska TSV snapshot with the bundled Legado catalog.

This is an offline audit: it never fetches the feed, opens catalog URLs, runs
rules or sends the user's data anywhere. Feed metadata must be captured when
the official URL is downloaded and must include its SHA-256 and byte length.
The provider's list concerns phishing, not a general-purpose malware scan.
"""

import argparse
from collections import Counter, defaultdict
import csv
from datetime import datetime
import hashlib
import io
import ipaddress
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

if __package__:
    from .audit_legado_catalog import CATALOG, inventory
    from .audit_legado_rule_patterns import strings
    from .triage_legado_eval_candidates import selected_indices
else:
    from audit_legado_catalog import CATALOG, inventory
    from audit_legado_rule_patterns import strings
    from triage_legado_eval_candidates import selected_indices


FEED_URL = 'https://hole.cert.pl/domains/v2/domains.csv'
TERMS_URL = 'https://cert.pl/en/warning-list/'
FIELDS = ['PozycjaRejestru', 'AdresDomeny', 'DataWpisu', 'DataWykreslenia']
URL_TOKEN = re.compile(r'https?://[^\s"\'`<>]+', re.I)
LABEL = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')


def host_name(value):
    """Return a DNS domain in ASCII or None; do not resolve the name."""
    try:
        name = value.strip().rstrip('.').encode('idna').decode('ascii').lower()
        labels = name.split('.')
        if len(name) > 253 or len(labels) < 2 or not all(LABEL.fullmatch(x) for x in labels):
            return None
        try:
            ipaddress.ip_address(name)
            return None
        except ValueError:
            return name
    except (AttributeError, UnicodeError):
        return None


def literal_hosts(row):
    """Yield syntactically valid literal URL hosts and source-field paths."""
    for path, value in strings(row):
        for match in URL_TOKEN.finditer(value):
            try:
                parts = urlsplit(match.group())
                if parts.username is None and parts.password is None:
                    host = host_name(parts.hostname or '')
                    if host:
                        yield host, path
            except ValueError:
                continue


def domain_matches(host, indicators):
    """Find exact and enclosing listed DNS domains; never match siblings."""
    labels = host.split('.')
    for offset in range(len(labels) - 1):
        domain = '.'.join(labels[offset:])
        if domain in indicators:
            yield domain, 'exact' if offset == 0 else 'listed_parent'


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.utcoffset() is None:
        raise ValueError('timestamp must include a timezone')
    return parsed


def entry_status(added, removed, observed):
    if timestamp(added) > observed:
        return 'future_addition'
    if not removed:
        return 'active_in_snapshot'
    return 'withdrawn' if timestamp(removed) <= observed else 'future_withdrawal'


def verify_metadata(content, metadata):
    if metadata.get('endpoint') != FEED_URL or metadata.get('status') != 200:
        raise ValueError('metadata must identify a successful official v2 TSV download')
    if len(content) != metadata.get('bytes') or hashlib.sha256(content).hexdigest() != metadata.get('sha256'):
        raise ValueError('feed snapshot does not match its download size and SHA-256')
    return timestamp(metadata['observed_at'])


def parse_feed(content, observed):
    reader = csv.DictReader(io.StringIO(content.decode('utf-8-sig'), newline=''), delimiter='\t')
    if reader.fieldnames != FIELDS:
        raise ValueError('unexpected CERT Polska TSV header')
    entries, statuses, added_times, removed_times = defaultdict(list), Counter(), [], []
    for row in reader:
        domain = host_name(row['AdresDomeny'])
        if not domain:
            raise ValueError('feed contains an invalid domain; review format before continuing')
        added, removed = row['DataWpisu'], row['DataWykreslenia']
        status = entry_status(added, removed, observed)
        statuses[status] += 1
        added_times.append(timestamp(added))
        if removed:
            removed_times.append(timestamp(removed))
        entries[domain].append({'entry_id': row['PozycjaRejestru'], 'added_at': added,
                                'removed_at': removed or None, 'status': status})
    ranges = {'first_added_at': min(added_times).isoformat() if added_times else None,
              'last_added_at': max(added_times).isoformat() if added_times else None,
              'last_removed_at': max(removed_times).isoformat() if removed_times else None}
    return entries, dict(statuses), ranges


def catalog_references(rows, endpoint_hosts, imported):
    parsed, selected = selected_indices(rows, imported)
    refs, literal_count = defaultdict(set), 0
    for host, indices in endpoint_hosts.items():
        for index in indices:
            refs[host].add((index, 'declared_endpoint'))
    for index, row in enumerate(rows):
        for host, path in literal_hosts(row):
            literal_count += 1
            refs[host].add((index, path))
    selected_hosts, missing_selected = set(), 0
    for index in selected.values():
        host = host_name(parsed[index].get('host', ''))
        if host:
            selected_hosts.add(host)
            refs[host].add((index, 'selected_imported_host'))
        else:
            missing_selected += 1
    return refs, parsed, selected, literal_count, selected_hosts, missing_selected


def matching_evidence(refs, parsed, selected, entries):
    matches = []
    for host in sorted(refs):
        for domain, relation in domain_matches(host, entries):
            references = []
            for index, field in sorted(refs[host]):
                source = parsed.get(index)
                ident = source['id'] if source else None
                references.append({'record_index': index, 'field': field, 'source_id': ident,
                                   'selected_version': bool(ident and selected.get(ident) == index)})
            matches.append({'catalog_host': host, 'indicator_domain': domain,
                            'relation': relation, 'provider_entries': entries[domain],
                            'catalog_references': references})
    return matches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feed', type=Path, required=True, help='local official v2 TSV snapshot')
    parser.add_argument('--metadata', type=Path, required=True,
                        help='download metadata object/array, or a previous evidence JSON')
    parser.add_argument('--import-inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    metadata = json.loads(args.metadata.read_text(encoding='utf-8'))
    if isinstance(metadata, dict) and 'source' in metadata:
        metadata = metadata['source']
    if isinstance(metadata, list):
        candidates = [x for x in metadata if x.get('endpoint') == FEED_URL]
        if len(candidates) != 1:
            raise ValueError('metadata array must contain exactly one official feed download')
        metadata = candidates[0]
    content = args.feed.read_bytes()
    observed = verify_metadata(content, metadata)
    entries, statuses, ranges = parse_feed(content, observed)
    rows, hosts, unresolved, _, manifest = inventory(CATALOG)
    import_bytes = args.import_inventory.read_bytes()
    imported = json.loads(import_bytes)
    if imported['archive_sha256'] != manifest['archiveSha256']:
        raise ValueError('import inventory and bundled archive differ')
    refs, parsed, selected, literal_count, selected_hosts, missing_selected = catalog_references(rows, hosts, imported)
    matches = matching_evidence(refs, parsed, selected, entries)
    out = {
        'method': 'Offline local comparison only; no catalog URLs requested and no source rules executed.',
        'source': {'endpoint': FEED_URL, 'description_and_terms_url': TERMS_URL,
                   'usage_terms': 'Provider permits any purpose including commercial use; no provider endorsement or warranty.',
                   'scope': 'Domains used for phishing targeting Polish users; not a comprehensive malware feed.',
                   'observed_at': metadata['observed_at'], 'status': metadata['status'],
                   'content_type': metadata.get('content_type'), 'last_modified': metadata.get('last_modified'),
                   'etag': metadata.get('etag'), 'bytes': metadata['bytes'], 'sha256': metadata['sha256'],
                   'records_by_status': statuses, 'time_ranges': ranges,
                   'retention_and_withdrawal': 'Provider v2 is limited to the last six months; an entry with a past removal timestamp is withdrawn. An absent or removed entry is not grounds for blocking. Active here means present without removal at observation, not presently valid.'},
        'catalog': {'archive_sha256': manifest['archiveSha256'], 'raw_records': len(rows),
                    'endpoint_hosts': len(hosts), 'unresolved_endpoint_records': len(unresolved),
                    'import_inventory_sha256': hashlib.sha256(import_bytes).hexdigest(),
                    'import_inventory_generated_at': imported['generated_at'],
                    'importer_code_sha256': imported['import_code_sha256'],
                    'selected_source_ids': len(selected),
                    'selected_source_hosts': len(selected_hosts),
                    'selected_sources_without_valid_host': missing_selected,
                    'scope': 'All catalog records: statically extracted endpoint hosts, normalized hosts of the selected imported sources and syntactically valid literal HTTP(S) URL hosts from every string field, including comments and scripts. Literal mentions are not proof of execution. Dynamic, nonliteral, malformed or credential-bearing URLs are not fully covered.',
                    'literal_url_occurrences': literal_count, 'unique_compared_hosts': len(refs)},
        'comparison': {'rule': 'Case-insensitive IDNA DNS-label equality or a listed parent domain of the catalog host; no parent, sibling, substring, URL-path or shared-IP inference.',
                       'matching_host_indicator_pairs': len(matches),
                       'matching_hosts': len({x['catalog_host'] for x in matches}),
                       'matches': matches},
        'reproduction': 'Pass this evidence file as --metadata along with the original local TSV and pinned import inventory. The TSV is intentionally not committed: recovering identical bytes requires a separately retained snapshot; a new download may have changed and needs new metadata.',
        'limitations': ['No match does not establish safety, absence of malware, or current/future availability.',
                        'This domain-only feed cannot establish an exact URL match or identify malicious paths on shared hosts.',
                        'Snapshot and importer evidence are historical; they do not describe subsequent feed or code changes.']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(out, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"{len(rows)} records, {len(refs)} hosts, {len(matches)} matching host/indicator pairs")


if __name__ == '__main__':
    main()
