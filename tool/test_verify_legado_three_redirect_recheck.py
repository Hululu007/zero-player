import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_three_redirect_recheck as audit


class ThreeRedirectEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))
        cls.archive, cls.ledger, cls.previous = audit.load_inputs(cls.evidence)

    def edited(self):
        return copy.deepcopy(self.evidence)

    def row(self, evidence, host, number, target):
        return next(row for row in evidence['get_observations']
                    if row['host'] == host and row['round'] == number and row['target'] == target)

    def test_archive_previous_head_and_actual_get_coverage(self):
        summary = audit.verify(self.evidence)
        self.assertEqual(summary['sources'], 3)
        self.assertEqual(summary['previous_head_redirects'], 3)
        self.assertEqual(summary['get_requests'], 22)
        self.assertEqual(summary['quge_previous_head'], 302)
        self.assertEqual(summary['quge_later_get_200'], 8)
        self.assertEqual(summary['truncated_rows'], 2)
        self.assertFalse(summary['liquge_post_submitted'])
        self.assertFalse(summary['sourcewide_invalidation_proven'])

    def test_no_temporary_collector_or_response_is_required(self):
        original = Path.read_bytes

        def no_build(path):
            if any(part.lower() == 'build' for part in path.parts):
                raise AssertionError('temporary collector must not be accessed')
            return original(path)

        with patch.object(Path, 'read_bytes', no_build):
            self.assertEqual(audit.verify(self.evidence)['get_requests'], 22)

    def test_historical_archive_and_head_evidence_are_fixed(self):
        for field in ('catalog_archive', 'source_ledger_historical_git', 'previous_head'):
            with self.subTest(field=field):
                evidence = self.edited()
                evidence['input_references'][field]['sha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    audit.load_inputs(evidence)

    def test_each_source_identity_and_rule_fingerprint_are_fixed(self):
        for index in range(3):
            for field in ('source_id', 'normalized_legado_sha256', 'search_sha256', 'explore_sha256'):
                with self.subTest(index=index, field=field):
                    evidence = self.edited()
                    evidence['sources'][index][field] = '0' * 64
                    with self.assertRaisesRegex(ValueError, 'source metadata, flags or rule hashes differ'):
                        audit.verify_sources(evidence, self.archive, self.ledger)

    def test_adult_source_snapshot_is_not_lost(self):
        evidence = self.edited()
        next(s for s in evidence['sources'] if s['host'] == 'm.liquge.com')['static_adult_source'] = False
        with self.assertRaisesRegex(ValueError, 'source metadata, flags or rule hashes differ'):
            audit.verify_sources(evidence, self.archive, self.ledger)

    def test_prior_head_user_agent_cannot_be_invented(self):
        evidence = self.edited()
        evidence['previous_head_observations'][0]['user_agent'] = 'generic'
        with self.assertRaisesRegex(ValueError, 'prior HEAD transcription differs'):
            audit.verify_previous(evidence, self.previous)

    def test_quge_get_200_is_not_rewritten_as_prior_head_redirect(self):
        evidence = self.edited()
        self.row(evidence, 'm.quge7.cc', 1, 'root')['http_status'] = 302
        with self.assertRaisesRegex(ValueError, 'quge GET observation differs'):
            audit.verify_get(evidence)

    def test_lost_liquge_status_cannot_be_filled_in(self):
        evidence = self.edited()
        self.row(evidence, 'm.liquge.com', 2, 'root')['http_status'] = 302
        with self.assertRaisesRegex(ValueError, 'truncated liquge status misreported'):
            audit.verify_get(evidence)

    def test_lost_37yq_redirect_target_cannot_be_filled_in(self):
        evidence = self.edited()
        self.row(evidence, 'www.37yq.com', 1, 'discovery_library')['redirect_host'] = 'ww17.37yq.com'
        with self.assertRaisesRegex(ValueError, 'truncated 37yq target misreported'):
            audit.verify_get(evidence)

    def test_post_or_untested_categories_cannot_be_claimed_as_checked(self):
        evidence = self.edited()
        evidence['method']['search_and_scope'] = 'All discovery paths and POST searches were tested.'
        with self.assertRaisesRegex(ValueError, 'request method, scope or user agents differ'):
            audit.verify(evidence)

    def test_user_agent_cannot_be_relabelled(self):
        evidence = self.edited()
        evidence['method']['current_user_agents']['bundled_mobile'] = 'generic'
        with self.assertRaisesRegex(ValueError, 'request method, scope or user agents differ'):
            audit.verify(evidence)

    def test_target_cannot_be_duplicated_or_removed(self):
        evidence = self.edited()
        evidence['get_observations'][-1] = copy.deepcopy(evidence['get_observations'][-2])
        with self.assertRaisesRegex(ValueError, 'GET target coverage differs'):
            audit.verify_get(evidence)

    def test_page_body_cannot_be_added(self):
        evidence = self.edited()
        evidence['get_observations'][0]['body'] = '<html>private</html>'
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_redirect_query_or_credentials_cannot_be_added(self):
        evidence = self.edited()
        evidence['get_observations'][0]['redirect_url'] = 'https://example.com/?token=private'
        with self.assertRaisesRegex(ValueError, 'URL query found'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
