import copy
import json
import unittest

try:
    from .verify_legado_recovered_amsi import ARCHIVE, EVIDENCE, HEAD, INVENTORY, verify
except ImportError:
    from verify_legado_recovered_amsi import ARCHIVE, EVIDENCE, HEAD, INVENTORY, verify


class RecoveredAmsiEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(EVIDENCE.read_bytes())
        cls.head_bytes = HEAD.read_bytes()
        cls.head = json.loads(cls.head_bytes)
        cls.inventory = INVENTORY.read_bytes()
        cls.archive = ARCHIVE.read_bytes()

    def check(self, data=None, head=None, head_bytes=None, inventory=None, archive=None):
        return verify(data if data is not None else self.data,
                      head if head is not None else self.head,
                      head_bytes if head_bytes is not None else self.head_bytes,
                      inventory if inventory is not None else self.inventory,
                      archive if archive is not None else self.archive)

    def test_recorded_results_and_controls(self):
        self.assertEqual(self.check(), {'hosts': 40, 'html_not_detected': 39,
                                        'connection_failure': 1, 'truncated_html': 20,
                                        'inline_not_detected': 85,
                                        'truncated_inline': 2, 'omitted_inline': 6})

    def test_different_head_evidence_is_rejected(self):
        with self.assertRaises(ValueError):
            self.check(head_bytes=self.head_bytes + b' ')

    def test_different_archive_and_inventory_are_rejected(self):
        for keyword in ('archive', 'inventory'):
            with self.subTest(input=keyword), self.assertRaises(ValueError):
                self.check(**{keyword: b'unrelated'})

    def test_changed_baseline_or_duplicate_host_is_rejected(self):
        for change in ('baseline', 'duplicate'):
            data = copy.deepcopy(self.data)
            if change == 'baseline':
                data['prior_audit_sha256'] = '0' * 64
            else:
                data['results'][-1] = copy.deepcopy(data['results'][0])
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check(data=data)

    def test_source_id_cannot_be_reassigned(self):
        data = copy.deepcopy(self.data)
        data['results'][0]['selected_source_ids'] = ['0' * 64]
        with self.assertRaises(ValueError):
            self.check(data=data)

    def test_error_cannot_be_relabelled_a_clean_scan(self):
        data = copy.deepcopy(self.data)
        failure = next(row for row in data['results'] if 'failure' in row)
        failure['failure'] = 'not_detected'
        with self.assertRaises(ValueError):
            self.check(data=data)

    def test_html_control_miss_cannot_be_claimed_detected(self):
        data = copy.deepcopy(self.data)
        data['controls']['html_wrapped_eicar']['classification'] = 'detected'
        with self.assertRaises(ValueError):
            self.check(data=data)

    def test_inconsistent_scanner_value_is_rejected(self):
        data = copy.deepcopy(self.data)
        row = next(row for row in data['results'] if 'amsi' in row)
        row['amsi']['classification'] = 'detected'
        with self.assertRaises(ValueError):
            self.check(data=data)

    def test_truncation_and_size_cannot_be_erased(self):
        data = copy.deepcopy(self.data)
        row = next(row for row in data['results'] if row.get('truncated'))
        row['truncated'] = False
        with self.assertRaises(ValueError):
            self.check(data=data)

    def test_script_omission_cannot_be_hidden(self):
        data = copy.deepcopy(self.data)
        row = next(row for row in data['results'] if row.get('inline_scripts', {}).get('samples'))
        row['inline_scripts']['samples'].pop()
        with self.assertRaises(ValueError):
            self.check(data=data)

    def test_raw_body_fields_are_rejected(self):
        for target in ('root', 'row'):
            data = copy.deepcopy(self.data)
            obj = data if target == 'root' else data['results'][0]
            obj['raw_body'] = 'unexpected'
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.check(data=data)

    def test_future_or_missing_observation_is_rejected(self):
        data = copy.deepcopy(self.data)
        data['results'][0]['sample_observed_at'] = '2020-01-01T00:00:00+00:00'
        with self.assertRaises(ValueError):
            self.check(data=data)


if __name__ == '__main__':
    unittest.main()
