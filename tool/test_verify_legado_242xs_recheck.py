import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_242xs_recheck as audit


class Legacy242EvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))
        cls.archive, cls.ledger = audit.inputs.load_inputs(cls.evidence)

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_archive_selected_identity_and_two_observation_rounds(self):
        result = audit.verify(self.evidence)
        self.assertEqual(result['selected_record_index'], 2940)
        self.assertEqual(result['source_id'], audit.SOURCE_ID)
        self.assertEqual(result['root_http_200'], 2)
        self.assertEqual(result['old_search_http_404'], 2)
        self.assertEqual(result['old_category_http_404'], 2)
        self.assertFalse(result['host_wide'])
        self.assertFalse(result['orphan_history_id'])

    def test_no_local_build_artifacts_are_required(self):
        original = Path.read_bytes

        def no_build(path):
            if any(part.lower() == 'build' for part in path.parts):
                raise AssertionError('temporary sample or collector must not be read')
            return original(path)

        with patch.object(Path, 'read_bytes', no_build):
            self.assertEqual(audit.verify(self.evidence)['source_id'], audit.SOURCE_ID)

    def test_source_identity_endpoint_and_fingerprint_are_fixed(self):
        for field, value in [('source_id', '0' * 64), ('selected_record_index', 2941),
                             ('endpoint_host', '242xs.info'), ('normalized_legado_sha256', '0' * 64)]:
            with self.subTest(field=field):
                evidence = self.edited()
                evidence['source'][field] = value
                with self.assertRaisesRegex(ValueError, 'selected source or rule digest metadata differs'):
                    audit.verify_source(evidence, self.archive, self.ledger)

    def test_archive_and_historical_ledger_are_fixed(self):
        for key in ('catalog_archive', 'source_ledger_historical_git'):
            with self.subTest(key=key):
                evidence = self.edited()
                evidence['input_references'][key]['sha256'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'input references differ'):
                    audit.inputs.load_inputs(evidence)

    def test_old_rule_fields_cannot_be_rewritten(self):
        for field in ('raw_search_sha256', 'raw_explore_sha256', 'raw_search_list_sha256', 'raw_explore_list_sha256'):
            with self.subTest(field=field):
                evidence = self.edited()
                evidence['source'][field] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'selected source or rule digest metadata differs'):
                    audit.verify_source(evidence, self.archive, self.ledger)

    def test_archived_search_or_category_record_cannot_be_substituted(self):
        for field in ('searchUrl', 'exploreUrl'):
            with self.subTest(field=field):
                archive = dict(self.archive)
                archive['records'] = list(self.archive['records'])
                row = dict(archive['records'][2940])
                row[field] = 'changed'
                archive['records'][2940] = row
                with self.assertRaisesRegex(ValueError, 'archive record digest mismatch'):
                    audit.verify_source(self.evidence, archive, self.ledger)

    def test_root_cannot_be_relabelled_as_novel_home(self):
        evidence = self.edited()
        evidence['observations'][0]['title'] = '小说'
        with self.assertRaisesRegex(ValueError, 'root observation differs'):
            audit.verify_observations(evidence)

    def test_old_search_and_category_404_cannot_be_relabelled(self):
        for index in (1, 2, 4, 5):
            with self.subTest(index=index):
                evidence = self.edited()
                evidence['observations'][index]['http_status'] = 200
                with self.assertRaisesRegex(ValueError, 'old (search|category) observation differs'):
                    audit.verify_observations(evidence)

    def test_round_cannot_duplicate_or_drop_a_request(self):
        evidence = self.edited()
        evidence['observations'][5] = copy.deepcopy(evidence['observations'][4])
        with self.assertRaisesRegex(ValueError, 'round or target sequence differs'):
            audit.verify_observations(evidence)

    def test_real_user_query_cannot_replace_the_synthetic_marker(self):
        evidence = self.edited()
        evidence['observations'][1]['synthetic_query'] = False
        with self.assertRaisesRegex(ValueError, 'old search observation differs'):
            audit.verify_observations(evidence)

    def test_host_wide_or_orphan_quarantine_cannot_be_claimed(self):
        for field in ('host_wide', 'orphan_history_id', 'claims_malware', 'claims_permanent_failure'):
            with self.subTest(field=field):
                evidence = self.edited()
                evidence['policy_scope'][field] = True
                with self.assertRaisesRegex(ValueError, 'policy scope differs'):
                    audit.verify(evidence)

    def test_page_body_cannot_be_added(self):
        evidence = self.edited()
        evidence['observations'][0]['body'] = '<html>private</html>'
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_recorded_response_cannot_be_changed_silently(self):
        evidence = self.edited()
        evidence['observations'][0]['sample_bytes'] = 1508
        with self.assertRaisesRegex(ValueError, 'root observation differs'):
            audit.verify_observations(evidence)


if __name__ == '__main__':
    unittest.main()
