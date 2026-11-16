"""Check stored book-audit evidence links without a network request.

This checks internal byte-level consistency, not the authenticity of the
evidence or the safety of any source. The current ledger source snapshot and
explicitly retained collector digests are checked; unsaved historical tools
and raw network responses cannot be reconstructed.
"""

import hashlib
import json
import re
import subprocess
from pathlib import Path, PurePosixPath


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
    ('legado-amsi-source-classification-before-fanfanu', 'amsi_summary_sha256', 'legado-amsi-summary'),
    ('legado-amsi-source-classification-before-fanfanu', 'amsi_clusters_sha256', 'legado-amsi-template-clusters'),
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

    def check_digest(self, path, expected, *, normalize_lf=False):
        if not isinstance(expected, str) or len(expected) != 64:
            raise ValueError(f'invalid SHA-256 in reference to {path}')
        content = self.read(path)
        if normalize_lf:
            content = content.replace(b'\r\n', b'\n')
        actual = hashlib.sha256(content).hexdigest()
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

    def ledger_path(self, name, prefixes):
        if not isinstance(name, str) or '\\' in name:
            raise ValueError('invalid ledger reference')
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or not any(
            name == prefix or name.startswith(prefix + '/') for prefix in prefixes
        ):
            raise ValueError(f'unexpected ledger reference: {name}')
        return self.root.joinpath(*path.parts)

    def verify_ledger(self):
        ledger = self.report('legado-source-ledger')
        inputs = ledger['input_sha256']
        if not {'pubspec.lock', 'assets/catalogs/books/legado/catalog.json.bz2'} <= inputs.keys():
            raise ValueError('ledger omits required inputs')
        for name, digest in inputs.items():
            path = self.ledger_path(name, (
                'pubspec.lock', 'assets/catalogs/books/legado', 'docs/implementation',
            ))
            self.check_digest(path, digest, normalize_lf=name == 'pubspec.lock')
        code = ledger['normalized_source_code_sha256']
        if 'tool/audit_book_source_ledger.dart' not in code:
            raise ValueError('ledger omits its generator')
        for name, digest in code.items():
            path = self.ledger_path(name, ('lib', 'tool', 'test/books'))
            self.check_digest(path, digest, normalize_lf=True)
        for name, digest in ledger['runtime_policy_reference_only_normalized_sha256'].items():
            path = self.ledger_path(name, ('lib',))
            self.check_digest(path, digest, normalize_lf=True)

    def git_snapshot(self, commit, path, digest, expected_path):
        if path != expected_path or not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError('invalid historical Git reference')
        content = subprocess.run(
            ['git', 'show', f'{commit}:{path}'], cwd=self.root, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout
        if hashlib.sha256(content).hexdigest() != digest:
            raise ValueError('historical Git object SHA-256 mismatch')
        self.checked += 1
        return content

    def verify_historical_ledger(self, inputs):
        path = 'docs/implementation/' + filename('legado-source-ledger')
        content = self.git_snapshot(
            inputs['source_ledger_git_commit'], inputs['source_ledger_path'],
            inputs['source_ledger_sha256'], path,
        )
        if json.loads(content)['normalized_source_code_sha256'] != inputs['ledger_source_code_sha256']:
            raise ValueError('historical ledger source snapshot mismatch')

    def verify_static_adult_review(self, name, tool, archive):
        report = json.loads(self.read(self.docs / name))
        self.check_digest(archive, report['catalog_archive_sha256'])
        self.check_digest(self.root / 'tool' / tool, report['verification_tool_sha256_lf'], normalize_lf=True)
        reference = report['historical_ledger']
        path = 'docs/implementation/' + filename('legado-source-ledger')
        ledger = json.loads(self.git_snapshot(
            reference['git_commit'], reference['path'], reference['sha256'], path,
        ))
        historical_code = ledger['normalized_source_code_sha256']
        for source, digest in report['historical_normalized_source_code_sha256'].items():
            if historical_code.get(source) != digest:
                raise ValueError('historical adult review source snapshot mismatch')
        if 'historical_label_evidence' in report:
            reference = report['historical_label_evidence']
            path = 'docs/implementation/' + filename('legado-adult-label-evidence')
            self.git_snapshot(reference['git_commit'], reference['path'], reference['sha256'], path)

    def verify_recent_evidence(self, archive):
        redirect = self.report('legado-amsi-redirect-recheck')['inputs']
        names = (
            'legado-amsi-source-classification-before-fanfanu',
            'legado-amsi-template-clusters',
            'legado-host-audit',
        )
        expected = {'docs/implementation/' + filename(name) for name in names}
        if set(redirect) != expected:
            raise ValueError('unexpected redirect evidence inputs')
        for path, digest in redirect.items():
            self.check_digest(self.root / path, digest)
        rdap = self.report('legado-rdap-net-sample')
        self.check_digest(archive, rdap['catalog_archive_sha256'])
        names = ('legado-doh-reviewed', 'legado-host-recheck', 'legado-import-inventory')
        inputs = rdap['input_evidence_sha256']
        if set(inputs) != {filename(name) for name in names}:
            raise ValueError('unexpected .net RDAP evidence inputs')
        for name, digest in inputs.items():
            self.check_digest(self.docs / name, digest)
        adult = self.report('legado-adult-category-recheck')['inputs']
        self.check_digest(archive, adult['catalog_archive_sha256'])
        host_audit = 'docs/implementation/' + filename('legado-host-audit')
        if adult['first_host_audit_path'] != host_audit:
            raise ValueError('unexpected adult category host evidence')
        self.check_digest(self.root / host_audit, adult['first_host_audit_sha256'])
        self.verify_historical_ledger(adult)
        for name, tool in (
            ('legado-uaa-adult-id-review-20261116.json', 'audit_uaa_adult_id.py'),
            ('legado-equivalent-adult-ids-20261116.json', 'audit_equivalent_adult_ids.py'),
        ):
            self.verify_static_adult_review(name, tool, archive)
        chain = json.loads(self.read(self.docs / 'legado-two-chain-pilot-20261116.json'))
        archive_key = 'assets/catalogs/books/legado/catalog.json.bz2'
        manifest_key = 'assets/catalogs/books/legado/manifest.json'
        for snapshot in ('source_file_sha256_at_initial', 'source_file_sha256_at_followup'):
            self.check_digest(archive, chain[snapshot][archive_key])
            self.check_digest(self.root / manifest_key, chain[snapshot][manifest_key])
        com_rdap = json.loads(self.read(self.docs / 'legado-rdap-com-six-20261116.json'))
        references = com_rdap['input_references']
        expected = {
            'catalog_archive': archive_key,
            'catalog_manifest': manifest_key,
            'host_recheck': 'docs/implementation/' + filename('legado-host-recheck'),
            'doh_reviewed': 'docs/implementation/' + filename('legado-doh-reviewed'),
            'previous_rdap': 'docs/implementation/' + filename('legado-rdap-sample'),
        }
        if set(references) != set(expected) | {'source_ledger_historical_git'}:
            raise ValueError('unexpected .com RDAP evidence inputs')
        for name, path in expected.items():
            reference = references[name]
            if reference['path'] != path:
                raise ValueError(f'unexpected .com RDAP {name} path')
            self.check_digest(self.root / path, reference['sha256'])
        reference = references['source_ledger_historical_git']
        path = 'docs/implementation/' + filename('legado-source-ledger')
        self.git_snapshot(reference['commit'], reference['path'], reference['sha256'], path)
        nine = json.loads(self.read(self.docs / 'legado-rdap-nine-20261116.json'))
        references = nine['input_references']
        expected = {
            'catalog_archive': archive_key,
            'catalog_manifest': manifest_key,
            'host_recheck': 'docs/implementation/' + filename('legado-host-recheck'),
            'doh_reviewed': 'docs/implementation/' + filename('legado-doh-reviewed'),
            'previous_rdap_com': 'docs/implementation/' + filename('legado-rdap-sample'),
            'previous_rdap_net': 'docs/implementation/' + filename('legado-rdap-net-sample'),
            'previous_rdap_com_six': 'docs/implementation/legado-rdap-com-six-20261116.json',
            'previous_rdap_com_eighteen': 'docs/implementation/legado-rdap-com-eighteen-20261116.json',
            'host_audit': 'docs/implementation/' + filename('legado-host-audit'),
        }
        if set(references) != set(expected) | {'source_ledger_historical_git'}:
            raise ValueError('unexpected nine-domain RDAP evidence inputs')
        for name, path in expected.items():
            reference = references[name]
            if reference['path'] != path:
                raise ValueError(f'unexpected nine-domain RDAP {name} path')
            self.check_digest(self.root / path, reference['sha256'])
        reference = references['source_ledger_historical_git']
        path = 'docs/implementation/' + filename('legado-source-ledger')
        self.git_snapshot(reference['commit'], reference['path'], reference['sha256'], path)
        eighteen = json.loads(self.read(self.docs / 'legado-rdap-com-eighteen-20261116.json'))
        references = eighteen['input_references']
        expected = {
            'catalog_archive': archive_key,
            'catalog_manifest': manifest_key,
            'host_recheck': 'docs/implementation/' + filename('legado-host-recheck'),
            'doh_reviewed': 'docs/implementation/' + filename('legado-doh-reviewed'),
            'previous_rdap_com': 'docs/implementation/' + filename('legado-rdap-sample'),
            'previous_rdap_net': 'docs/implementation/' + filename('legado-rdap-net-sample'),
            'previous_rdap_com_six': 'docs/implementation/legado-rdap-com-six-20261116.json',
            'dns_address_recheck': 'docs/implementation/' + filename('legado-dns-address-recheck'),
            'host_audit': 'docs/implementation/' + filename('legado-host-audit'),
            'amsi_other': 'docs/implementation/' + filename('legado-amsi-other-hosts'),
        }
        if set(references) != set(expected) | {'source_ledger_historical_git'}:
            raise ValueError('unexpected eighteen-domain RDAP evidence inputs')
        for name, path in expected.items():
            reference = references[name]
            if reference['path'] != path:
                raise ValueError(f'unexpected eighteen-domain RDAP {name} path')
            self.check_digest(self.root / path, reference['sha256'])
        reference = references['source_ledger_historical_git']
        path = 'docs/implementation/' + filename('legado-source-ledger')
        self.git_snapshot(reference['commit'], reference['path'], reference['sha256'], path)

    def verify_later_sources(self, archive):
        ledger_path = 'docs/implementation/' + filename('legado-source-ledger')
        later = json.loads(self.read(self.docs / 'legado-unresolved-head-later-20261116.json'))
        allowed_inputs = {
            'docs/implementation/' + filename(name) for name in (
                'legado-host-audit', 'legado-host-recheck', 'legado-import-inventory', *STAGES,
            )
        } | {
            'assets/catalogs/books/legado/catalog.json.bz2',
            'assets/catalogs/books/legado/manifest.json',
        }
        if set(later['input_sha256']) != allowed_inputs:
            raise ValueError('unexpected later HEAD evidence inputs')
        for path, digest in later['input_sha256'].items():
            self.check_digest(self.root / path, digest)
        self.check_digest(archive, later['archive_sha256'])

        latest = json.loads(self.read(self.docs / 'legado-unresolved-943-recheck-20261116.json'))
        refs = latest['input_references']
        expected = {'archive': 'assets/catalogs/books/legado/catalog.json.bz2',
                    'previous_head': 'docs/implementation/legado-unresolved-head-later-20261116.json',
                    'import_inventory': 'docs/implementation/legado-import-inventory-20261115.json'}
        if set(refs) != set(expected) | {'historical_ledger'}:
            raise ValueError('unexpected latest host recheck references')
        for key, path in expected.items():
            if refs[key]['path'] != path:
                raise ValueError('unexpected latest host recheck input path')
            self.check_digest(self.root / path, refs[key]['sha256'])
        history = refs['historical_ledger']
        self.git_snapshot(history['git_commit'], history['path'], history['sha256'], ledger_path)

        four = json.loads(self.read(self.docs / 'legado-recovered-four-amsi-20261116.json'))
        refs = four['input_references']
        expected = {'archive': 'assets/catalogs/books/legado/catalog.json.bz2',
                    'head': 'docs/implementation/legado-unresolved-943-recheck-20261116.json',
                    'import_inventory': 'docs/implementation/legado-import-inventory-20261115.json',
                    'prior_amsi': 'docs/implementation/legado-recovered-amsi-20261116.json'}
        if set(refs) != set(expected):
            raise ValueError('unexpected four-host AMSI references')
        for key, path in expected.items():
            if refs[key]['path'] != path:
                raise ValueError('unexpected four-host AMSI input path')
            self.check_digest(self.root / path, refs[key]['sha256'])

        amsi = json.loads(self.read(self.docs / 'legado-recovered-amsi-20261116.json'))
        self.check_digest(archive, amsi['archive_sha256'])
        self.check_digest(self.docs / filename('legado-import-inventory'), amsi['import_inventory_sha256'])
        rows = [{'host': row['host'], 'record_indices': row['record_indices']}
                for row in later['results'] if row['latest_head'].get('http_status') == 200]
        if len(rows) != 40:
            raise ValueError('unexpected later AMSI candidate count')
        baseline = {'archive_sha256': later['archive_sha256'],
                    'source_recheck_sha256': later['local_collector_sha256']['recheck'],
                    'results': rows}
        wire = json.dumps(baseline, ensure_ascii=False, separators=(',', ':')).encode() + b'\r\n'
        if hashlib.sha256(wire).hexdigest() != amsi['prior_audit_sha256']:
            raise ValueError('later AMSI candidate baseline mismatch')
        self.checked += 1

        top = json.loads(self.read(self.docs / 'legado-rdap-top-cc-20261116.json'))
        refs = top['input_references']
        expected = {
            'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
            'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
            'host_recheck': 'docs/implementation/' + filename('legado-host-recheck'),
            'doh_reviewed': 'docs/implementation/' + filename('legado-doh-reviewed'),
        }
        if set(refs) != set(expected) | {'source_ledger_historical_git'}:
            raise ValueError('unexpected top/cc evidence inputs')
        for key, path in expected.items():
            if refs[key]['path'] != path:
                raise ValueError('unexpected top/cc evidence path')
            self.check_digest(self.root / path, refs[key]['sha256'])
        ref = refs['source_ledger_historical_git']
        self.git_snapshot(ref['commit'], ref['path'], ref['sha256'], ledger_path)
        collector = top['collection_script']
        if collector['path'] != 'tool/collect_legado_rdap_top_cc.py':
            raise ValueError('unexpected top/cc collector')
        self.check_digest(self.root / collector['path'], collector['sha256'], normalize_lf=True)

        three = json.loads(self.read(self.docs / 'legado-three-redirect-recheck-20261116.json'))
        refs = three['input_references']
        expected = {
            'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
            'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
            'previous_head': 'docs/implementation/legado-unresolved-head-later-20261116.json',
        }
        if set(refs) != set(expected) | {'source_ledger_historical_git'}:
            raise ValueError('unexpected three-source redirect inputs')
        for key, path in expected.items():
            if refs[key]['path'] != path:
                raise ValueError('unexpected three-source redirect path')
            self.check_digest(self.root / path, refs[key]['sha256'])
        ref = refs['source_ledger_historical_git']
        self.git_snapshot(ref['commit'], ref['path'], ref['sha256'], ledger_path)

        redirect = json.loads(self.read(self.docs / 'legado-redirected-sources-20261116.json'))
        self.check_digest(archive, redirect['archive_sha256'])
        ref = redirect['historical_ledger']
        self.git_snapshot(ref['commit'], ref['path'], ref['sha256'], ledger_path)
        self.check_digest(self.root / 'tool/recheck_redirected_book_sources.py',
                          redirect['collector_source_sha256'], normalize_lf=True)
        self.check_digest(self.root / 'tool/audit_legado_catalog.py',
                          redirect['transport_source_sha256'], normalize_lf=True)

        myxzm = json.loads(self.read(self.docs / 'legado-myxzm-recheck-20261116.json'))
        refs = myxzm['input_references']
        if set(refs) != {'catalog_archive', 'catalog_manifest', 'source_ledger_historical_git'}:
            raise ValueError('unexpected novel-source evidence inputs')
        for key, path in (('catalog_archive', 'assets/catalogs/books/legado/catalog.json.bz2'),
                          ('catalog_manifest', 'assets/catalogs/books/legado/manifest.json')):
            if refs[key]['path'] != path:
                raise ValueError('unexpected novel-source evidence path')
            self.check_digest(self.root / path, refs[key]['sha256'])
        ref = refs['source_ledger_historical_git']
        self.git_snapshot(ref['commit'], ref['path'], ref['sha256'], ledger_path)

        woo = json.loads(self.read(self.docs / 'legado-woo15-home-review-20261116.json'))
        self.check_digest(archive, woo['catalog_archive_sha256'])
        self.git_snapshot('a6c7d9986a64a2c7328c5f74c06415a116ef27a9', ledger_path,
                          woo['historical_ledger_sha256'], ledger_path)

        mixed = json.loads(self.read(self.docs / 'legado-adult-mixed-home-recheck-20261116.json'))
        refs = mixed['input_references']
        if set(refs) != {'catalog_archive', 'catalog_manifest', 'source_ledger_historical_git'}:
            raise ValueError('unexpected mixed-source evidence inputs')
        for key, path in (('catalog_archive', 'assets/catalogs/books/legado/catalog.json.bz2'),
                          ('catalog_manifest', 'assets/catalogs/books/legado/manifest.json')):
            if refs[key]['path'] != path:
                raise ValueError('unexpected mixed-source evidence path')
            self.check_digest(self.root / path, refs[key]['sha256'])
        ref = refs['source_ledger_historical_git']
        history = json.loads(self.git_snapshot(ref['commit'], ref['path'], ref['sha256'], ledger_path))
        snapshot = mixed['source_code_snapshot']
        if (snapshot['commit'] != ref['commit'] or
                snapshot['normalized_sha256'] != history['normalized_source_code_sha256']):
            raise ValueError('mixed-source historical code snapshot mismatch')

        novel_242 = json.loads(self.read(self.docs / 'legado-242xs-recheck-20261116.json'))
        refs = novel_242['input_references']
        if set(refs) != {'catalog_archive', 'catalog_manifest', 'source_ledger_historical_git'}:
            raise ValueError('unexpected 242 source evidence inputs')
        for key, path in (('catalog_archive', 'assets/catalogs/books/legado/catalog.json.bz2'),
                          ('catalog_manifest', 'assets/catalogs/books/legado/manifest.json')):
            if refs[key]['path'] != path:
                raise ValueError('unexpected 242 source evidence path')
            self.check_digest(self.root / path, refs[key]['sha256'])
        ref = refs['source_ledger_historical_git']
        self.git_snapshot(ref['commit'], ref['path'], ref['sha256'], ledger_path)

        sfwx = json.loads(self.read(self.docs / 'legado-sfwx-repair-20261116.json'))
        inputs = sfwx['inputs']
        if inputs['archive_path'] != 'assets/catalogs/books/legado/catalog.json.bz2':
            raise ValueError('unexpected source-repair archive path')
        self.check_digest(archive, inputs['archive_sha256'])
        commit = inputs['historical_git_commit']
        self.git_snapshot(commit, inputs['historical_ledger_path'],
                          inputs['historical_ledger_sha256'], ledger_path)
        head_path = 'docs/implementation/legado-unresolved-head-later-20261116.json'
        self.git_snapshot(commit, inputs['historical_head_path'],
                          inputs['historical_head_sha256'], head_path)
        if inputs['probe_helper_path'] != 'tool/audit_legado_catalog.py':
            raise ValueError('unexpected source-repair probe helper path')
        self.check_digest(self.root / inputs['probe_helper_path'],
                          inputs['probe_helper_sha256'], normalize_lf=True)

        later_history = {
            'ledger': ledger_path,
            'head': 'docs/implementation/legado-unresolved-head-later-20261116.json',
            'prior_pilot': 'docs/implementation/legado-sfwx-repair-20261116.json',
        }
        for name in ('legado-sfwx-3984-recheck-20261116.json',
                     'legado-biquge7-category-recheck-20261116.json'):
            report = json.loads(self.read(self.docs / name))
            inputs = report['inputs']
            if (inputs['archive_path'] != 'assets/catalogs/books/legado/catalog.json.bz2' or
                    set(inputs['historical_files']) != set(later_history)):
                raise ValueError('unexpected later reading review references')
            self.check_digest(archive, inputs['archive_sha256'])
            for key, path in later_history.items():
                ref = inputs['historical_files'][key]
                self.git_snapshot(inputs['historical_commit'], ref['path'], ref['sha256'], path)

        jhsssd = json.loads(self.read(self.docs / 'legado-jhsssd-category-recheck-20261116.json'))
        inputs = jhsssd['inputs']
        if inputs['archive_path'] != 'assets/catalogs/books/legado/catalog.json.bz2':
            raise ValueError('unexpected jhsssd reading-review archive path')
        self.check_digest(archive, inputs['archive_sha256'])
        self.git_snapshot(inputs['historical_commit'], inputs['historical_ledger_path'],
                          inputs['historical_ledger_sha256'], ledger_path)

        lengmen = json.loads(self.read(self.docs / 'legado-lengmen-amsi-recheck-20261116.json'))
        inputs = lengmen['inputs']
        if inputs['archive_path'] != 'assets/catalogs/books/legado/catalog.json.bz2':
            raise ValueError('unexpected AMSI follow-up archive path')
        self.check_digest(archive, inputs['archive_sha256'])
        expected_history = {
            'ledger': ledger_path,
            'summary': 'docs/implementation/legado-amsi-summary-20261115.json',
            'initial': 'docs/implementation/legado-amsi-other-hosts-20261115.json',
            'clusters': 'docs/implementation/legado-amsi-template-clusters-20261115.json',
            'classification': 'docs/implementation/legado-amsi-source-classification-20261115.json',
        }
        if set(inputs['historical_files']) != set(expected_history):
            raise ValueError('unexpected AMSI follow-up historical references')
        for key, path in expected_history.items():
            ref = inputs['historical_files'][key]
            self.git_snapshot(inputs['historical_git_commit'], ref['path'], ref['sha256'], path)

        five = json.loads(self.read(self.docs / 'legado-rdap-five-20261116.json'))
        refs = five['input_references']
        expected = {
            'catalog_archive': 'assets/catalogs/books/legado/catalog.json.bz2',
            'catalog_manifest': 'assets/catalogs/books/legado/manifest.json',
            'later_host_recheck': 'docs/implementation/legado-unresolved-head-later-20261116.json',
            'prior_public_doh': 'docs/implementation/legado-doh-reviewed-20261115.json',
            'older_host_recheck': 'docs/implementation/legado-host-recheck-20261115.json',
        }
        if set(refs) != set(expected) | {'source_ledger_historical_git', 'previous_rdap_historical_git'}:
            raise ValueError('unexpected five-domain RDAP inputs')
        ref = refs['source_ledger_historical_git']
        commit = ref['commit']
        history = json.loads(self.git_snapshot(commit, ref['path'], ref['sha256'], ledger_path))
        for key, path in expected.items():
            if refs[key]['path'] != path:
                raise ValueError('unexpected five-domain RDAP path')
            self.check_digest(self.root / path, refs[key]['sha256'])
            self.git_snapshot(commit, path, refs[key]['sha256'], path)
        previous = refs['previous_rdap_historical_git']
        expected_previous = {
            'docs/implementation/legado-rdap-sample-20261115.json',
            'docs/implementation/legado-rdap-net-sample-20261115.json',
            'docs/implementation/legado-rdap-com-six-20261116.json',
            'docs/implementation/legado-rdap-com-eighteen-20261116.json',
            'docs/implementation/legado-rdap-nine-20261116.json',
            'docs/implementation/legado-rdap-top-cc-20261116.json',
        }
        if set(previous) != expected_previous:
            raise ValueError('unexpected historical RDAP reference set')
        for path, item in previous.items():
            if item['commit'] != commit:
                raise ValueError('historical RDAP commit mismatch')
            self.git_snapshot(commit, path, item['sha256'], path)
        snapshot = five['source_code_snapshot']
        if (snapshot['commit'] != commit or snapshot['digest_convention'] != 'sha256_crlf_to_lf' or
                snapshot['normalized_sha256'] != history['normalized_source_code_sha256']):
            raise ValueError('five-domain historical code snapshot mismatch')
        expected_tools = {
            'tool/collect_legado_rdap_five.py', 'tool/collect_legado_rdap_top_cc.py',
            'tool/audit_legado_doh_pilot.py', 'tool/audit_legado_catalog.py',
            'tool/verify_legado_rdap_com_eighteen.py', 'tool/verify_legado_rdap_com_six.py',
        }
        for name, expected_set in (('collection_scripts', expected_tools),
                                   ('verification_support', {'tool/verify_legado_rdap_top_cc.py'})):
            group = five[name]
            if group['digest_convention'] != 'sha256_crlf_to_lf' or set(group['sha256']) != expected_set:
                raise ValueError('unexpected five-domain tool reference set')
            for path, digest in group['sha256'].items():
                self.check_digest(self.root / path, digest, normalize_lf=True)

    def verify_qishuzw_post_probe(self, archive):
        probe = json.loads(self.read(self.docs / 'legado-qishuzw-post-probe-20261116.json'))
        self.check_digest(archive, probe['catalog_archive_sha256'])
        if probe['host'] != 'https://www.qishuzw.com':
            raise ValueError('unexpected qishuzw probe host')
        rows = probe['rows']
        if [row.get('method') for row in rows] != ['GET', 'POST', 'POST']:
            raise ValueError('unexpected qishuzw probe methods')
        for row in rows:
            if row.get('status') != 200 or '西甲直播' not in row.get('title', ''):
                raise ValueError('unexpected qishuzw probe response')
            if row.get('sitebox_marker') or row.get('book_link_count') != 0:
                raise ValueError('qishuzw probe unexpectedly contained a book list')
            if len(row.get('sha256') or '') != 64:
                raise ValueError('qishuzw probe sample digest missing')

    def _canonical_digest(self, payload):
        return hashlib.sha256(json.dumps(
            payload, ensure_ascii=False, sort_keys=True, separators=(',', ':')
        ).encode('utf8')).hexdigest()

    def verify_unresolved_rounds(self, archive):
        third = json.loads(self.read(self.docs / 'legado-unresolved-third-round-20261116.json'))
        if (self._canonical_digest(third) != 'c87962a4ba28fb01b0146b0b5dafc21b9b3461dd05f225384175d4b5ec0aebde' or
                third['input_references']['archive']['sha256'] !=
                hashlib.sha256(self.read(archive)).hexdigest() or
                third['input_references']['previous_round']['sha256'] !=
                '9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0'):
            raise ValueError('third unresolved round provenance changed')
        rows = third['results']
        if len(rows) != 939 or third['summary']['hosts'] != 939:
            raise ValueError('third unresolved round population changed')
        recorded = sum(row['latest_head']['http_status'] is not None for row in rows)
        if recorded != 4 or third['summary']['http_status_recorded'] != 4:
            raise ValueError('third unresolved round status count changed')
        unresolved = {row['host'] for row in rows if row['latest_head']['http_status'] is None}
        if len(unresolved) != 935:
            raise ValueError('third unresolved round no-status count changed')

        get_round = json.loads(self.read(self.docs / 'legado-unresolved-get-round-20261116.json'))
        if (self._canonical_digest(get_round) != '5cf86bf7f24536815cf7fc4e9c63cc3c62dba26d8106e439ac0d273c8aa5fa7d' or
                get_round['input_references']['round_three']['sha256'] !=
                hashlib.sha256(self.read(self.docs / 'legado-unresolved-third-round-20261116.json')).hexdigest()):
            raise ValueError('GET unresolved round provenance changed')
        if len(get_round['results']) != 935 or get_round['summary']['hosts'] != 935:
            raise ValueError('GET unresolved round population changed')
        if get_round['summary']['http_status_recorded'] != 1 or get_round['summary']['http_200'] != 0:
            raise ValueError('GET unresolved round status count changed')
        if {row['host'] for row in get_round['results']} != unresolved:
            raise ValueError('GET unresolved round host set changed')

        responders = json.loads(self.read(self.docs / 'legado-third-round-responders-20261116.json'))
        if (self._canonical_digest(responders) !=
                '988e10ee3964f39bbbbbc173b86f4dd36050b97ca4fe9f21133e57d85ca5ce49' or
                responders['input_references']['round_three']['sha256'] !=
                hashlib.sha256(self.read(self.docs / 'legado-unresolved-third-round-20261116.json')).hexdigest()):
            raise ValueError('responder evidence provenance changed')
        if sorted(row['host'] for row in responders['results']) != [
                'hao8.net', 'm.aixdzs.com', 'm.xyyuedu.com', 'www.00xs.net']:
            raise ValueError('responder host set changed')
        if responders['summary']['requests'] != 8 or responders['summary']['statuses'] != [200, 301]:
            raise ValueError('responder sample summary changed')
        self.checked += 3

    def verify_hao8_parking(self):
        parking = json.loads(self.read(self.docs / 'legado-hao8-parking-20261116.json'))
        if self._canonical_digest(parking) != 'a7ce77fb96cb94752f9dea33b7318a91a31a7d6423b9b04f96f8de456bb3e14b':
            raise ValueError('hao8 parking evidence changed')
        if parking['host'] != 'hao8.net' or len(parking['results']) != 2:
            raise ValueError('hao8 parking population changed')
        for row in parking['results']:
            if row.get('status') != 200 or row.get('book_link_count') != 0:
                raise ValueError('hao8 parking response changed')
            if not all(row['markers'].get(name) for name in (
                    'domain_can_transfer', 'domain_for_sale_en', 'fixed_price_sale', 'price_cny')):
                raise ValueError('hao8 parking markers changed')
            if row['markers'].get('book_search_form') or '域名可以转让' not in row.get('quote', ''):
                raise ValueError('hao8 parking quote changed')
        self.checked += 1

    def verify_phishing_army(self, archive):
        report = json.loads(self.read(self.docs / 'legado-phishing-army-20261116.json'))
        catalog = report['catalog']
        self.check_digest(archive, catalog['archive_sha256'])
        inventory = 'docs/implementation/' + filename('legado-import-inventory')
        if catalog['import_inventory_path'] != inventory:
            raise ValueError('unexpected Phishing Army import inventory path')
        self.check_digest(self.root / inventory, catalog['import_inventory_sha256'])
        tools = report['normalized_tool_sha256']
        expected = {
            'tool/audit_phishing_army_legado.py', 'tool/audit_certpl_legado.py',
            'tool/audit_legado_catalog.py', 'tool/audit_legado_rule_patterns.py',
            'tool/triage_legado_eval_candidates.py',
        }
        if set(tools) != expected:
            raise ValueError('unexpected Phishing Army tool reference set')
        for path, digest in tools.items():
            self.check_digest(self.root / path, digest, normalize_lf=True)
        matches = report['comparison']['matches']
        if (len(matches) != report['comparison']['matching_host_indicator_pairs'] or
                len({entry['catalog_host'] for entry in matches}) != report['comparison']['matching_hosts']):
            raise ValueError('inconsistent Phishing Army match counts')

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
        iqiyi = self.report('legado-iqiyi-manhua-recheck')['inputs']
        inventory = 'docs/implementation/' + filename('legado-import-inventory')
        if iqiyi['import_inventory_path'] != inventory:
            raise ValueError('unexpected iQIYI import inventory path')
        self.check_digest(self.root / inventory, iqiyi['import_inventory_sha256'])
        self.check_digest(archive, iqiyi['catalog_archive_sha256'])
        rdap = self.report('legado-rdap-sample')['inputs']
        for field, stem in (
            ('import_inventory', 'legado-import-inventory'),
            ('head_recheck', 'legado-host-recheck'),
            ('public_doh_review', 'legado-doh-reviewed'),
        ):
            path = 'docs/implementation/' + filename(stem)
            if rdap[field + '_path'] != path:
                raise ValueError(f'unexpected {field} path')
            self.check_digest(self.root / path, rdap[field + '_sha256'])
        self.check_digest(archive, rdap['archive_sha256'])
        pilot = self.report('legado-static-search-pilot')['inputs']
        self.check_digest(archive, pilot['catalog_archive_sha256'])
        recheck_560 = self.report('legado-560xs-recheck')['inputs']
        pilot_path = 'docs/implementation/' + filename('legado-static-search-pilot')
        if recheck_560['initial_pilot_evidence_path'] != pilot_path:
            raise ValueError('unexpected 560 search pilot path')
        self.check_digest(self.root / pilot_path, recheck_560['initial_pilot_evidence_sha256'])
        self.check_digest(archive, recheck_560['catalog_archive_sha256'])
        self.verify_recent_evidence(archive)
        self.verify_later_sources(archive)
        self.verify_qishuzw_post_probe(archive)
        self.verify_unresolved_rounds(archive)
        self.verify_hao8_parking()
        self.verify_phishing_army(archive)
        self.verify_ledger()
        return self.checked


if __name__ == '__main__':
    verifier = EvidenceVerifier(ROOT)
    count = verifier.verify()
    print(f'{count} stored evidence links and archive digests match.')
    print('Consistency does not establish source safety or evidence authenticity.')
