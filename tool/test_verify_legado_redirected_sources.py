import copy
import json
import unittest
from pathlib import Path

try:
    from .verify_legado_redirected_sources import verify
except ImportError:
    from verify_legado_redirected_sources import verify


class RedirectEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = json.loads(Path(
            'docs/implementation/legado-redirected-sources-20261116.json'
        ).read_text(encoding='utf-8'))

    def altered(self):
        return copy.deepcopy(self.original)

    def test_real_evidence_has_two_controlled_rounds(self):
        self.assertEqual(verify(self.original), {
            'sources': 2, 'rounds': 2, 'candidate_observations': 16,
        })

    def test_changed_source_cannot_be_attributed_to_another_record(self):
        data = self.altered()
        data['sources'][0]['selected_record_index'] += 1
        with self.assertRaises(ValueError):
            verify(data)

    def test_changed_rule_fingerprint_is_rejected(self):
        data = self.altered()
        data['sources'][0]['normalized_legado_canonical_sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            verify(data)

    def test_failed_control_cannot_authorize_candidates(self):
        data = self.altered()
        data['rounds'][0]['control']['status'] = 503
        with self.assertRaises(ValueError):
            verify(data)

    def test_response_cannot_be_relabelled_as_a_redirect(self):
        data = self.altered()
        data['rounds'][0]['observations'][0]['status'] = 200
        with self.assertRaises(ValueError):
            verify(data)

    def test_another_redirect_host_cannot_be_substituted(self):
        data = self.altered()
        data['rounds'][0]['observations'][0]['redirect_host'] = 'example.com'
        with self.assertRaises(ValueError):
            verify(data)

    def test_search_request_digest_cannot_be_changed(self):
        data = self.altered()
        data['rounds'][0]['observations'][1]['request_sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            verify(data)

    def test_missing_or_duplicate_query_cannot_replace_coverage(self):
        for duplicate in (False, True):
            data = self.altered()
            observations = data['rounds'][0]['observations']
            observations.pop()
            if duplicate:
                observations.append(copy.deepcopy(observations[0]))
            with self.subTest(duplicate=duplicate), self.assertRaises(ValueError):
                verify(data)

    def test_skipped_query_is_not_an_observation(self):
        data = self.altered()
        data['rounds'][0]['observations'][0] = {
            'host': 'm.newbiquge.org', 'purpose': 'root', 'method': 'HEAD',
            'skipped': 'control_failed',
        }
        with self.assertRaises(ValueError):
            verify(data)

    def test_out_of_order_observation_is_rejected(self):
        data = self.altered()
        data['rounds'][0]['observations'][0]['started_at'] = '2020-01-01T00:00:00+00:00'
        with self.assertRaises(ValueError):
            verify(data)

    def test_raw_page_or_extra_payload_is_rejected(self):
        for where in ('root', 'observation'):
            data = self.altered()
            target = data if where == 'root' else data['rounds'][0]['observations'][0]
            target['raw_body'] = 'unexpected'
            with self.subTest(where=where), self.assertRaises(ValueError):
                verify(data)

    def test_wrong_archive_digest_is_rejected(self):
        data = self.altered()
        data['archive_sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            verify(data)


if __name__ == '__main__':
    unittest.main()
