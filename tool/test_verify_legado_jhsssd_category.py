import copy
import json
import unittest

from tool import verify_legado_jhsssd_category as verifier


class VerifyJhsssdEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive, cls.ledger = verifier.load_inputs()
        cls.evidence = json.loads(verifier.EVIDENCE.read_text(encoding='utf-8'))

    def test_original(self):
        result = verifier.validate(self.evidence, self.archive, self.ledger)
        self.assertEqual(result['sampled_works'], 2)
        self.assertEqual(result['other_search_probes'], 6)

    def test_changed_category_or_network_observation_is_rejected(self):
        changed = copy.deepcopy(self.evidence)
        changed['observations']['candidate_two_works']['works'][0]['detail']['analysis']['category_diag']['engine_matches_og'] = False
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            verifier.validate(changed, self.archive, self.ledger)
        changed = copy.deepcopy(self.evidence)
        changed['other_search_probes'][0]['steps'][0]['observation']['http_status'] = 200
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            verifier.validate(changed, self.archive, self.ledger)

    def test_changed_identity_or_fixture_is_rejected(self):
        changed = copy.deepcopy(self.evidence)
        changed['source']['old_legado_canonical_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            verifier.validate(changed, self.archive, self.ledger)
        changed = copy.deepcopy(self.evidence)
        changed['synthetic_fixture']['policy_expected']['高H'] = True
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            verifier.validate(changed, self.archive, self.ledger)

    def test_changed_historical_inputs_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'archive changed'):
            verifier.validate(self.evidence, self.archive + b' ', self.ledger)
        with self.assertRaisesRegex(ValueError, 'historical ledger changed'):
            verifier.validate(self.evidence, self.archive, self.ledger + b' ')


if __name__ == '__main__':
    unittest.main()
