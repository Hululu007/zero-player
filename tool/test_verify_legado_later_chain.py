import copy
import json
import unittest

from tool import verify_legado_biquge7_category as category
from tool import verify_legado_sfwx_3984 as sfwx
from tool.verify_legado_later_chain_common import load_inputs


class VerifyLaterChainEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive, cls.history = load_inputs()
        cls.sfwx = json.loads(sfwx.EVIDENCE.read_text(encoding='utf-8'))
        cls.category = json.loads(category.EVIDENCE.read_text(encoding='utf-8'))

    def test_both_originals(self):
        self.assertEqual(sfwx.validate(self.sfwx, self.archive, self.history)['sampled_works'], 2)
        self.assertEqual(category.validate(self.category, self.archive, self.history)['verified_sources'], 3)

    def test_changed_chapter_or_fingerprint_is_rejected(self):
        changed = copy.deepcopy(self.sfwx)
        changed['observations']['work_b']['engine_results'][-1]['next_content_count'] = 2
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            sfwx.validate(changed, self.archive, self.history)
        changed = copy.deepcopy(self.category)
        changed['sources'][0]['old_legado_canonical_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            category.validate(changed, self.archive, self.history)

    def test_changed_category_or_http_result_is_rejected(self):
        changed = copy.deepcopy(self.category)
        changed['observations']['shared_category_check']['engine_results'][0]['category_meta_count'] = 0
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            category.validate(changed, self.archive, self.history)
        changed = copy.deepcopy(self.category)
        changed['observations']['record_2578_search']['requests'][0]['status'] = 200
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            category.validate(changed, self.archive, self.history)

    def test_changed_historical_input_or_archive_is_rejected(self):
        history = dict(self.history)
        history['head'] += b' '
        with self.assertRaisesRegex(ValueError, 'historical input changed: head'):
            sfwx.validate(self.sfwx, self.archive, history)
        with self.assertRaisesRegex(ValueError, 'archive changed'):
            category.validate(self.category, self.archive + b' ', self.history)


if __name__ == '__main__':
    unittest.main()
