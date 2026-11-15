"""Regression tests for offline CERT Polska domain comparison."""

import hashlib
import unittest
from unittest.mock import patch

from tool import audit_certpl_legado as audit


class CertPolskaAuditTests(unittest.TestCase):
    def test_exact_parent_and_shared_host_boundaries(self):
        indicators = {'a.example.com': [1], 'xn--bcher-kva.example': [2]}
        self.assertEqual(list(audit.domain_matches('a.example.com', indicators)),
                         [('a.example.com', 'exact')])
        self.assertEqual(list(audit.domain_matches('b.a.example.com', indicators)),
                         [('a.example.com', 'listed_parent')])
        for host in ('example.com', 'b.example.com', 'xa.example.com',
                     'a.example.com.evil.test'):
            self.assertEqual(list(audit.domain_matches(host, indicators)), [])
        self.assertEqual(audit.host_name('BÜCHER.Example.'), 'xn--bcher-kva.example')
        self.assertIsNone(audit.host_name('127.0.0.1'))

    def test_only_literal_valid_uncredentialed_hosts_are_extracted(self):
        row = {'bookSourceUrl': 'https://Example.COM/path?secret=never-output',
               'bookSourceComment': 'mentions https://sub.example.com/a',
               'rule': 'https://person:secret@example.com/a https://{{dynamic}}/x'}
        self.assertEqual(list(audit.literal_hosts(row)),
                         [('example.com', 'bookSourceUrl'),
                          ('sub.example.com', 'bookSourceComment')])

    def test_active_removed_and_future_statuses_stay_distinct(self):
        observed = audit.timestamp('2026-11-15T05:22:22Z')
        added = '2026-11-01T00:00:00Z'
        self.assertEqual(audit.entry_status(added, '', observed), 'active_in_snapshot')
        self.assertEqual(audit.entry_status(added, '2026-11-14T00:00:00Z', observed),
                         'withdrawn')
        self.assertEqual(audit.entry_status(added, '2026-11-16T00:00:00Z', observed),
                         'future_withdrawal')
        self.assertEqual(audit.entry_status('2026-11-16T00:00:00Z', '', observed),
                         'future_addition')
        with self.assertRaises(ValueError):
            audit.timestamp('2026-11-15T05:22:22')

    def test_feed_hash_header_and_result_evidence(self):
        content = ('PozycjaRejestru\tAdresDomeny\tDataWpisu\tDataWykreslenia\n'
                   '12\tparent.example\t2026-11-01T00:00:00Z\t\n'
                   '13\tretired.example\t2026-11-01T00:00:00Z\t2026-11-10T00:00:00Z\n').encode()
        metadata = {'endpoint': audit.FEED_URL, 'status': 200,
                    'observed_at': '2026-11-15T05:22:22Z', 'bytes': len(content),
                    'sha256': hashlib.sha256(content).hexdigest()}
        observed = audit.verify_metadata(content, metadata)
        entries, statuses, _ = audit.parse_feed(content, observed)
        self.assertEqual(statuses, {'active_in_snapshot': 1, 'withdrawn': 1})
        rows = [{'bookSourceUrl': 'https://child.parent.example/'}]
        parsed = {0: {'id': 'source-0', 'host': 'child.parent.example'}}
        with patch.object(audit, 'selected_indices', return_value=(parsed, {'source-0': 0})):
            refs, parsed, selected, _, selected_hosts, missing = audit.catalog_references(rows, {}, {})
        self.assertEqual(selected_hosts, {'child.parent.example'})
        self.assertEqual(missing, 0)
        self.assertIn((0, 'selected_imported_host'), refs['child.parent.example'])
        evidence = audit.matching_evidence(refs, parsed, selected, entries)
        self.assertEqual(len(evidence), 1)
        self.assertEqual(evidence[0]['relation'], 'listed_parent')
        self.assertEqual(evidence[0]['provider_entries'][0]['entry_id'], '12')
        self.assertEqual(evidence[0]['catalog_references'][0]['source_id'], 'source-0')
        self.assertTrue(evidence[0]['catalog_references'][0]['selected_version'])
        with self.assertRaises(ValueError):
            audit.verify_metadata(content + b'x', metadata)
        with self.assertRaises(ValueError):
            audit.parse_feed(b'wrong\theader\n', observed)


if __name__ == '__main__':
    unittest.main()
