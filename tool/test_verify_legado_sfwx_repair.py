import copy
import json
import unittest

from tool.verify_legado_sfwx_repair import EVIDENCE, load_inputs, validate


class VerifySfwxEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads(EVIDENCE.read_text(encoding='utf-8'))
        cls.archive, cls.ledger, cls.head = load_inputs()

    def test_real_inputs(self):
        result = validate(self.evidence, self.archive, self.ledger, self.head)
        self.assertEqual(result['verified_sources'], 3)
        self.assertEqual(result['sampled_works'], 2)
        self.assertEqual(result['network_requests'], 0)

    def test_changed_observation_is_rejected(self):
        changed = copy.deepcopy(self.evidence)
        changed['observations']['record_4760']['work_b']['chapters'][0][
            'without_next_same_content_sha256'] = False
        with self.assertRaisesRegex(ValueError, 'evidence observations'):
            validate(changed, self.archive, self.ledger, self.head)

    def test_changed_identity_is_rejected(self):
        changed = copy.deepcopy(self.evidence)
        changed['sources'][0]['record_index'] = 3984
        with self.assertRaisesRegex(ValueError, 'evidence observations'):
            validate(changed, self.archive, self.ledger, self.head)

    def test_changed_historical_input_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'historical ledger'):
            validate(self.evidence, self.archive, self.ledger + b' ', self.head)
        with self.assertRaisesRegex(ValueError, 'archive'):
            validate(self.evidence, self.archive + b' ', self.ledger, self.head)


if __name__ == '__main__':
    unittest.main()
