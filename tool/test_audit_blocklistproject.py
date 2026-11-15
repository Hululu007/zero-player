"""Regression tests for the bounded snapshot and offline catalog comparison."""

import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tool import audit_blocklistproject_legado as audit
from tool.audit_legado_catalog import CATALOG, inventory
from tool import fetch_blocklistproject_snapshot as fetch


class _Response:
    def __init__(self, url, data, *, length=None):
        self.url = url
        self.data = io.BytesIO(data)
        self.status = 200
        self.headers = {'Content-Length': str(len(data) if length is None else length),
                        'Content-Type': 'text/plain'}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.data.close()

    def geturl(self):
        return self.url

    def read(self, size):
        return self.data.read(size)


class _Opener:
    def __init__(self, data, *, length=None):
        self.data, self.length, self.request = data, length, None

    def open(self, request, timeout):
        self.request = request
        if timeout != 20:
            raise AssertionError('network read timeout changed')
        return _Response(request.full_url, self.data, length=self.length)


def _blob(content):
    return hashlib.sha1(f'blob {len(content)}\0'.encode() + content).hexdigest()


class SnapshotTests(unittest.TestCase):
    def test_bounded_download_validates_git_blob_and_uses_no_credentials(self):
        content = b'# Title: Malware\n# License: MIT\n0.0.0.0 bad.example\n'
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(fetch.FILES, {'malware.txt': (len(content), _blob(content))}):
            opener = _Opener(content)
            info = fetch.download_file(opener, Path(directory), 'malware.txt',
                                       len(content), _blob(content))
            self.assertEqual((Path(directory) / 'malware.txt').read_bytes(), content)
            self.assertEqual(info['sha256'], hashlib.sha256(content).hexdigest())
            self.assertEqual(info['file_header']['license'], 'MIT')
            self.assertEqual(opener.request.get_method(), 'GET')
            self.assertTrue(opener.request.full_url.startswith(fetch.RAW_BASE + '/'))
            headers = {k.lower(): v for k, v in opener.request.header_items()}
            self.assertNotIn('authorization', headers)
            self.assertNotIn('cookie', headers)
            self.assertNotIn('referer', headers)
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(fetch.FILES, {'malware.txt': (len(content), _blob(content))}):
            opener = _Opener(content, length=len(content)+1)
            with self.assertRaises(ValueError):
                fetch.download_file(opener, Path(directory), 'malware.txt', len(content), _blob(content))
            self.assertFalse((Path(directory) / 'malware.txt').exists())
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(fetch.FILES, {'malware.txt': (len(content), '0'*40)}):
            with self.assertRaises(ValueError):
                fetch.download_file(_Opener(content), Path(directory), 'malware.txt',
                                    len(content), '0'*40)
            self.assertFalse((Path(directory) / 'malware.txt').exists())
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(fetch.FILES, {'malware.txt': (len(content), _blob(content))}):
            with self.assertRaises(ValueError):
                fetch.download_file(_Opener(content + b'x', length=len(content)),
                                    Path(directory), 'malware.txt', len(content), _blob(content))
            self.assertFalse((Path(directory) / 'malware.txt').exists())
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                fetch.download_file(_Opener(content), Path(directory), '../other.txt',
                                    len(content), _blob(content))

    def test_redirect_is_rejected(self):
        with self.assertRaises(ValueError):
            fetch.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example/')


class OfflineAuditTests(unittest.TestCase):
    def test_uaa_review_evidence_is_tied_to_both_real_catalog_records(self):
        imported = json.loads(Path('docs/implementation/legado-import-inventory-20261115.json')
                              .read_text(encoding='utf-8'))
        rows, hosts, _, _, _ = inventory(CATALOG)
        _, parsed, selected, _, _, _ = audit.catalog_references(rows, hosts, imported)
        evidence = audit.uaa_metadata_evidence(rows, parsed, selected)
        self.assertEqual(evidence['historical_selected_record_index'], 989)
        self.assertEqual([entry['record_index'] for entry in evidence['records']], [989, 3116])
        self.assertTrue(all(entry['category_count'] == 49 for entry in evidence['records']))
        altered = list(rows)
        altered[989] = {**altered[989], 'exploreUrl': altered[989]['exploreUrl'] + ' '}
        with self.assertRaises(ValueError):
            audit.uaa_metadata_evidence(altered, parsed, selected)

    def test_only_sinkhole_mappings_or_valid_bare_domains_are_accepted(self):
        self.assertEqual(audit.extract_domains(b'# comment\n'), ((), 'empty_or_comment', 0))
        self.assertEqual(audit.extract_domains(b'0.0.0.0 EXAMPLE.COM. sub.example.com # note\n'),
                         (('example.com', 'sub.example.com'), 'sinkhole_mapping', 0))
        self.assertEqual(audit.extract_domains(b'127.0.0.1 example.com\n')[0], ('example.com',))
        self.assertEqual(audit.extract_domains(b'B\xc3\x9cCHER.example\n')[0], ('xn--bcher-kva.example',))
        self.assertEqual(audit.extract_domains(b'0.0.0.0 *.example.com bad_name.example\n'),
                         ((), 'sinkhole_mapping', 2))
        self.assertEqual(audit.extract_domains(b'1.2.3.4 example.com\n')[1], 'unsupported')
        self.assertEqual(audit.extract_domains(b'https://example.com/x\n')[2], 1)

    def test_exact_and_parent_matching_never_covers_siblings_or_reverse_parents(self):
        refs = {'one.example.com': {(0, 'declared_endpoint')},
                'sibling.example.net': {(1, 'declared_endpoint')}}
        candidates = audit.candidate_domains(refs)
        self.assertIn(('one.example.com', 'exact'), candidates['one.example.com'])
        self.assertIn(('one.example.com', 'listed_parent'), candidates['example.com'])
        for candidate in ('ne.example.com', 'another.example.com', 'one.example.com.evil.test'):
            self.assertNotIn(candidate, candidates)
        self.assertEqual(list(audit.domain_matches('example.com', {'one.example.com'})), [])

    def test_snapshot_integrity_and_header_checked_during_streamed_match(self):
        data = b'# Title: Malware\n# License: MIT\n0.0.0.0 bad.example\n0.0.0.0 other.test\n'
        blob = _blob(data)
        meta = {'url': f'{audit.RAW_BASE}/malware.txt', 'status': 200,
                'bytes': len(data), 'git_blob_sha1': blob,
                'sha256': hashlib.sha256(data).hexdigest(),
                'observed_at': '2026-11-15T08:00:00+00:00',
                'completed_at': '2026-11-15T08:00:01+00:00',
                'file_header': fetch.feed_header(data)}
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(audit.FILES, {'malware.txt': (len(data), blob)}):
            file = Path(directory) / 'malware.txt'
            file.write_bytes(data)
            found, counts = audit.verify_file(file, 'malware.txt', meta, {'bad.example'})
            self.assertEqual(found, {'bad.example'})
            self.assertEqual(counts['sinkhole_mapping'], 2)
            file.write_bytes(data.replace(b'bad.example', b'mad.example'))
            with self.assertRaises(ValueError):
                audit.verify_file(file, 'malware.txt', meta, {'mad.example'})
            file.write_bytes(data + b'x')
            with self.assertRaises(ValueError):
                audit.verify_file(file, 'malware.txt', meta, {'bad.example'})
            file.write_bytes(data)
            with self.assertRaises(ValueError):
                audit.verify_file(file, 'malware.txt', {**meta, 'file_header': {}}, set())

    def test_selected_sources_are_separated_by_endpoint_relation_and_index(self):
        parsed = {
            0: {'id': 'a', 'name': 'A', 'kind': 'text', 'host': 'a.example'},
            1: {'id': 'b', 'name': 'B', 'kind': 'comic', 'host': 'b.example'},
            2: {'id': 'c', 'name': 'C', 'kind': 'text', 'host': 'c.example'},
            3: {'id': 'a', 'name': 'old A', 'kind': 'text', 'host': 'a.example'},
        }
        selected = {'a': 0, 'b': 1, 'c': 2}
        matches = [
            {'catalog_host': 'a.example', 'listed_domain': 'a.example', 'relation': 'exact',
             'catalog_references': [{'record_index': 0, 'field': 'selected_imported_host', 'source_id': 'a', 'selected_version': True}]},
            {'catalog_host': 'b.example', 'listed_domain': 'example', 'relation': 'listed_parent',
             'catalog_references': [{'record_index': 1, 'field': 'selected_imported_host', 'source_id': 'b', 'selected_version': True}]},
            {'catalog_host': 'cdn.example', 'listed_domain': 'cdn.example', 'relation': 'exact',
             'catalog_references': [{'record_index': 2, 'field': 'ruleSearch.coverUrl', 'source_id': 'c', 'selected_version': True},
                                    {'record_index': 3, 'field': 'bookSourceUrl', 'source_id': 'a', 'selected_version': False}]},
        ]
        groups = audit.group_selected_sources(matches, parsed, selected)
        self.assertEqual([x['source_id'] for x in groups['exact_endpoint']], ['a'])
        self.assertEqual([x['source_id'] for x in groups['listed_parent_endpoint']], ['b'])
        self.assertEqual([x['source_id'] for x in groups['other_fields_only']], ['c'])
        self.assertEqual(groups['other_fields_only'][0]['signals'][0]['fields'], ['ruleSearch.coverUrl'])


if __name__ == '__main__':
    unittest.main()
