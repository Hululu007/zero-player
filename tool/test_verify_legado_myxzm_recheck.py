import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_myxzm_recheck as audit


class MyxzmEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))
        cls.archive, cls.ledger = audit.load_inputs(cls.evidence)

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_archive_selection_rules_and_redacted_observations(self):
        result = audit.verify(self.evidence)
        self.assertEqual(result['selected_record_index'], 751)
        self.assertEqual(result['source_id'], audit.SOURCE_ID)
        self.assertEqual(result['two_class_candidate_nodes'], [1, 0])
        self.assertFalse(result['single_class_candidate_verified'])
        self.assertEqual(result['refetch_timeouts'], 2)

    def test_verification_does_not_depend_on_local_build_artifacts(self):
        original = Path.read_bytes

        def no_build(path):
            if any(part.lower() == 'build' for part in path.parts):
                raise AssertionError('temporary probe or sample should not be read')
            return original(path)

        with patch.object(Path, 'read_bytes', no_build):
            self.assertEqual(audit.verify(self.evidence)['source_id'], audit.SOURCE_ID)

    def test_archive_digest_reference_is_fixed(self):
        evidence = self.edited()
        evidence['input_references']['catalog_archive']['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'input references differ'):
            audit.load_inputs(evidence)

    def test_historical_ledger_revision_is_fixed(self):
        evidence = self.edited()
        evidence['input_references']['source_ledger_historical_git']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'input references differ'):
            audit.load_inputs(evidence)

    def test_selected_id_and_record_are_fixed(self):
        for field, value in [('source_id', '0' * 64), ('selected_record_index', 752)]:
            with self.subTest(field=field):
                evidence = self.edited()
                evidence['selection_snapshot'][field] = value
                with self.assertRaisesRegex(ValueError, 'selected source snapshot differs'):
                    audit.verify_selection(evidence, self.archive, self.ledger)

    def test_three_original_rule_digests_are_fixed(self):
        for field in audit.RULE_SHAS:
            with self.subTest(field=field):
                evidence = self.edited()
                evidence['recorded_observations']['source'][field] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'recorded source or rule digests differ'):
                    audit.verify_selection(evidence, self.archive, self.ledger)

    def test_archived_rule_content_cannot_change(self):
        for key, inner in [('searchUrl', None), ('ruleSearch', 'bookList'), ('ruleContent', 'content')]:
            with self.subTest(field=key):
                archive = dict(self.archive)
                archive['records'] = list(self.archive['records'])
                row = dict(archive['records'][751])
                if inner is None:
                    row[key] = 'changed'
                else:
                    row[key] = dict(row[key])
                    row[key][inner] = 'changed'
                archive['records'][751] = row
                with self.assertRaisesRegex(ValueError, 'archive record digest mismatch'):
                    audit.verify_selection(self.evidence, archive, self.ledger)

    def test_failed_novel_search_cannot_be_described_as_successful(self):
        evidence = self.edited()
        evidence['recorded_observations']['evidence']['search']['old_novel_search_rule_engine_books'] = 1
        with self.assertRaisesRegex(ValueError, 'search failure observation differs'):
            audit.verify_observations(evidence['recorded_observations'])

    def test_different_container_counterexample_cannot_be_erased(self):
        evidence = self.edited()
        evidence['recorded_observations']['evidence']['sample_b']['two_class_candidate_nodes'] = 1
        with self.assertRaisesRegex(ValueError, 'second sample counterexample differs'):
            audit.verify_observations(evidence['recorded_observations'])

    def test_single_class_candidate_cannot_be_claimed_as_verified(self):
        evidence = self.edited()
        evidence['recorded_observations']['evidence']['single_class_candidate']['actual_engine_tested_on_fetched_samples'] = True
        with self.assertRaisesRegex(ValueError, 'unverified single-class selector misreported'):
            audit.verify_observations(evidence['recorded_observations'])

    def test_timeout_cannot_be_relabelled_as_http_success(self):
        for label in ('sample_a_refetch', 'sample_b_refetch'):
            with self.subTest(label=label):
                evidence = self.edited()
                evidence['recorded_observations']['evidence']['single_class_candidate'][label]['status'] = 200
                with self.assertRaisesRegex(ValueError, 'timeout or unknown status misreported'):
                    audit.verify_observations(evidence['recorded_observations'])

    def test_advertisement_counterexample_cannot_be_removed(self):
        evidence = self.edited()
        evidence['recorded_observations']['evidence']['synthetic_advertisement_control']['candidate_kept_advertisement_text'] = False
        with self.assertRaisesRegex(ValueError, 'synthetic advertisement counterexample differs'):
            audit.verify_observations(evidence['recorded_observations'])

    def test_record_cannot_gain_an_unrelated_work_identity(self):
        evidence = self.edited()
        evidence['recorded_observations']['evidence']['sample_a']['work_title'] = 'not retained'
        with self.assertRaisesRegex(ValueError, 'redacted observation record changed'):
            audit.verify_observations(evidence['recorded_observations'])

    def test_raw_webpage_cannot_be_added(self):
        evidence = self.edited()
        evidence['recorded_observations']['evidence']['sample_a']['body'] = '<html>private</html>'
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_missing_reconstruction_limitations_are_rejected(self):
        evidence = self.edited()
        evidence['limitations'] = []
        with self.assertRaisesRegex(ValueError, 'historical reconstruction limitations missing'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
