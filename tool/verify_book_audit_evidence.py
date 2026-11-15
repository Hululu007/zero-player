"""Check stored book-audit evidence links without a network request.

This checks internal byte-level consistency, not the authenticity of the
evidence or the safety of any source. Historical tool hashes are deliberately
not compared to today's tools, which may have changed since collection.
"""

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIRECT_LINKS = (
    ('legado-host-recheck', 'first_audit_sha256', 'legado-host-audit'),
    ('legado-host-recheck', 'import_inventory_sha256', 'legado-import-inventory'),
    ('legado-dns-address-recheck', 'parent_recheck_sha256', 'legado-host-recheck'),
    ('legado-doh-sample', 'head_recheck_sha256', 'legado-host-recheck'),
    ('legado-doh-sample', 'address_recheck_sha256', 'legado-dns-address-recheck'),
    ('legado-doh-full', 'head_recheck_sha256', 'legado-host-recheck'),
    ('legado-doh-full', 'address_recheck_sha256', 'legado-dns-address-recheck'),
    ('legado-doh-full', 'pilot_sha256', 'legado-doh-sample'),
    ('legado-doh-reviewed', 'head_recheck_sha256', 'legado-host-recheck'),
    ('legado-doh-reviewed', 'address_recheck_sha256', 'legado-dns-address-recheck'),
    ('legado-doh-reviewed', 'pilot_sha256', 'legado-doh-sample'),
    ('legado-doh-reviewed', 'collection_evidence_sha256', 'legado-doh-full'),
    ('legado-amsi-recheck-4qo', 'prior_result_file_sha256', 'legado-amsi-prior-html'),
    ('legado-amsi-recheck-4qo-decoded', 'prior_result_file_sha256', 'legado-amsi-prior-html'),
    ('legado-amsi-source-classification', 'amsi_summary_sha256', 'legado-amsi-summary'),
    ('legado-amsi-source-classification', 'amsi_clusters_sha256', 'legado-amsi-template-clusters'),
    ('legado-blocklistproject-policy', 'grouped_evidence_sha256', 'legado-blocklistproject-evidence'),
)
STAGES = ('legado-amsi-pilot', 'legado-amsi-prior-html', 'legado-amsi-other-hosts')
ARRAY_LINKS = (
    ('legado-amsi-summary', 'stages', STAGES),
    ('legado-amsi-template-clusters', 'source_scans', STAGES),
    ('legado-head-get-comparison', 'inputs', (
        'legado-host-audit', 'legado-host-recheck', 'legado-import-inventory', *STAGES,
    )),
)


def filename(stem):
    return f'{stem}-20261115.json'


class EvidenceVerifier:
    def __init__(self, root):
        self.root = Path(root)
        self.docs = self.root / 'docs' / 'implementation'
        self.checked = 0
        self._bytes = {}

    def read(self, path):
        path = Path(path)
        if path not in self._bytes:
            self._bytes[path] = path.read_bytes()
        return self._bytes[path]

    def report(self, stem):
        return json.loads(self.read(self.docs / filename(stem)))

    def check_digest(self, path, expected):
        if not isinstance(expected, str) or len(expected) != 64:
            raise ValueError(f'invalid SHA-256 in reference to {path}')
        actual = hashlib.sha256(self.read(path)).hexdigest()
        if actual != expected:
            raise ValueError(f'SHA-256 mismatch: {path}')
        self.checked += 1

    def verify_array(self, source, field, stems):
        entries = self.report(source)[field]
        expected_names = {filename(stem) for stem in stems}
        names = [entry['file'] for entry in entries]
        if len(names) != len(expected_names) or set(names) != expected_names:
            raise ValueError(f'unexpected {field} in {filename(source)}')
        for entry in entries:
            self.check_digest(self.docs / entry['file'], entry['sha256'])

    def verify(self):
        for source, key, target in DIRECT_LINKS:
            self.check_digest(self.docs / filename(target), self.report(source)[key])
        for source, field, stems in ARRAY_LINKS:
            self.verify_array(source, field, stems)
        for source in STAGES:
            report = self.report(source)
            self.check_digest(self.docs / filename('legado-host-audit'), report['prior_audit_sha256'])
            self.check_digest(self.docs / filename('legado-import-inventory'), report['import_inventory_sha256'])
        recheck = self.report('legado-blocklist-malware-recheck')['list_evidence']
        expected_path = 'docs/implementation/' + filename('legado-blocklistproject-evidence')
        if recheck['path'] != expected_path:
            raise ValueError('unexpected blocklist recheck evidence path')
        self.check_digest(self.root / expected_path, recheck['sha256'])
        archive = self.root / 'assets' / 'catalogs' / 'books' / 'legado' / 'catalog.json.bz2'
        for path, payload in tuple(self._bytes.items()):
            if path.parent != self.docs:
                continue
            report = json.loads(payload)
            if 'archive_sha256' in report:
                self.check_digest(archive, report['archive_sha256'])
        self.check_digest(
            archive,
            self.report('legado-blocklistproject-evidence')['catalog']['archive_sha256'],
        )
        self.check_digest(archive, recheck['catalog_archive_sha256'])
        return self.checked


if __name__ == '__main__':
    verifier = EvidenceVerifier(ROOT)
    count = verifier.verify()
    print(f'{count} stored evidence links and archive digests match.')
    print('Consistency does not establish source safety or evidence authenticity.')
