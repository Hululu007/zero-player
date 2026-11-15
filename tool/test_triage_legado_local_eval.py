import copy
import json
from pathlib import Path
import unittest

from tool.audit_legado_catalog import CATALOG, inventory
from tool.triage_legado_local_eval import (
    REVIEWED,
    assert_local_eval,
    checked_fields,
    reviewed_profiles,
    unpack_constant,
)


class LocalEvalReviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows, _, _, _, _ = inventory(CATALOG)
        cls.imported = json.loads(Path(
            'docs/implementation/legado-import-inventory-20261115.json'
        ).read_text(encoding='utf-8'))

    def test_all_recorded_snapshots_are_still_selected(self):
        self.assertEqual(len(reviewed_profiles(self.rows, self.imported)), 19)

    def test_changed_reviewed_field_is_not_accepted(self):
        row = copy.deepcopy(self.rows[27])
        row['bookSourceComment'] += '\nchanged'
        _, field_digest, extras = REVIEWED[27]
        with self.assertRaises(ValueError):
            checked_fields(row, 27, field_digest, extras)

    def test_remote_eval_or_malformed_packer_is_not_classed_local(self):
        with self.assertRaises(ValueError):
            assert_local_eval('eval(result)', 27, 'ruleContent.content')
        with self.assertRaises(ValueError):
            unpack_constant('eval(function() { return result; })')


if __name__ == '__main__':
    unittest.main()
