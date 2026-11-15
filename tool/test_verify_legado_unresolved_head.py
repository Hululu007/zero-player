"""Offline regression and tamper checks for the 1023-host observation set."""
import copy
import json
from datetime import datetime, timedelta
import unittest

from tool import verify_legado_unresolved_head as audit


class UnresolvedHeadEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.context = audit.inputs()
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_bytes())

    def test_reconstructed_population_and_summary(self):
        summary = audit.verify(self.evidence, self.context)
        self.assertEqual(summary['hosts'], 1023)
        self.assertEqual(summary['selected_source_ids'], 990)
        self.assertEqual(summary['http_status_recorded'], 80)
        self.assertEqual(summary['http_status_unrecorded'], 943)
        self.assertEqual(summary['http_200'], 40)
        self.assertEqual(summary['dns_verdicts']['not_checked'], 758)

    def test_collector_transcription_when_local_originals_exist(self):
        baseline = audit.ROOT / 'build/legado-unresolved-head-baseline-v4-20261116.json'
        raw = audit.ROOT / 'build/legado-unresolved-head-recheck-v4-20261116.json'
        if not baseline.exists() or not raw.exists():
            self.skipTest('collector originals are optional local build artifacts')
        self.assertEqual(audit.build(baseline.read_bytes(), raw.read_bytes(), self.context), self.evidence)

    def test_missing_duplicate_or_unrelated_host_is_rejected(self):
        for operation in ('missing', 'duplicate', 'other_host'):
            value = copy.deepcopy(self.evidence)
            if operation == 'missing':
                value['results'].pop()
            elif operation == 'duplicate':
                value['results'][1] = copy.deepcopy(value['results'][0])
            else:
                value['results'][0]['host'] = '127.0.0.1'
            with self.subTest(operation=operation), self.assertRaises(ValueError):
                audit.verify(value, self.context)

    def test_selected_id_and_version_cannot_be_reassigned(self):
        value = copy.deepcopy(self.evidence)
        row = next(r for r in value['results'] if r['selected_sources'])
        row['selected_sources'][0]['record_index'] += 1
        with self.assertRaises(ValueError):
            audit.verify(value, self.context)

    def test_valid_looking_changed_observation_breaks_pinned_digest(self):
        value = copy.deepcopy(self.evidence)
        row = next(r for r in value['results'] if r['latest_head']['http_status'] == 200)
        # Still a valid timestamp and same outcome/summary, but not the observation.
        stamp = row['latest_head']['observed_at']
        row['latest_head']['observed_at'] = (
            datetime.fromisoformat(stamp) - timedelta(microseconds=1)).isoformat()
        self.assertNotEqual(row['latest_head']['observed_at'], stamp)
        with self.assertRaises(ValueError):
            audit.verify(value, self.context)

    def test_unexpected_sensitive_fields_and_dns_tampering_are_rejected(self):
        for field in ('ip_address', 'body', 'redirect_url'):
            value = copy.deepcopy(self.evidence)
            value['results'][0][field] = 'redacted'
            with self.subTest(field=field), self.assertRaises(ValueError):
                audit.verify(value, self.context)
        value = copy.deepcopy(self.evidence)
        row = next(r for r in value['results'] if r['dns']['observations'])
        row['dns']['verdict'] = 'not_checked'
        with self.assertRaises(ValueError):
            audit.verify(value, self.context)

    def test_modified_input_reference_and_scope_are_rejected(self):
        for field in ('input', 'scope'):
            value = copy.deepcopy(self.evidence)
            if field == 'input':
                value['input_sha256'][audit.FIRST] = '0' * 64
            else:
                value['limitations'] = []
            with self.subTest(field=field), self.assertRaises(ValueError):
                audit.verify(value, self.context)


if __name__ == '__main__':
    unittest.main()
