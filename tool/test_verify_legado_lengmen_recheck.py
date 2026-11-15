import copy
import json
import unittest

from tool.verify_legado_lengmen_recheck import EVIDENCE, load_inputs, validate


class VerifyLengmenEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
        cls.archive, cls.history = load_inputs()

    def test_original_evidence_and_historical_inputs(self):
        result = validate(self.evidence, self.archive, self.history)
        self.assertEqual(result['verified_sources'], 2)
        self.assertEqual(result['recorded_requests'], 6)
        self.assertEqual(result['network_requests'], 0)

    def test_changed_new_result_is_rejected(self):
        changed = copy.deepcopy(self.evidence)
        changed['observations'][5]['comparisons'][1]['amsi']['amsi_result'] = 1
        with self.assertRaisesRegex(ValueError, 'redacted observations'):
            validate(changed, self.archive, self.history)

    def test_changed_redirect_or_fingerprint_is_rejected(self):
        for mutate in ('redirect', 'fingerprint'):
            changed = copy.deepcopy(self.evidence)
            if mutate == 'redirect':
                changed['observations'][0]['redirect_target'] = 'same_host'
            else:
                changed['source_fingerprints'][0]['normalized_legado_canonical_sha256'] = '0' * 64
            with self.subTest(mutate=mutate), self.assertRaisesRegex(ValueError, 'redacted observations'):
                validate(changed, self.archive, self.history)

    def test_changed_historical_input_and_archive_are_rejected(self):
        changed = dict(self.history)
        changed['clusters'] += b' '
        with self.assertRaisesRegex(ValueError, 'historical input changed: clusters'):
            validate(self.evidence, self.archive, changed)
        with self.assertRaisesRegex(ValueError, 'catalog archive changed'):
            validate(self.evidence, self.archive + b' ', self.history)


if __name__ == '__main__':
    unittest.main()
