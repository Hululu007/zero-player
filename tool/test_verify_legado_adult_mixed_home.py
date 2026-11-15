import copy
import json
import unittest
from unittest import mock

from tool import verify_legado_adult_mixed_home as audit


class AdultMixedHomeEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_selected_records_and_observations_verify_offline(self):
        with mock.patch('socket.create_connection', side_effect=AssertionError('network used')):
            summary = audit.verify(self.evidence)
        self.assertEqual(summary, {'hosts': 2, 'selected_source_ids': 5, 'homepage_observations': 4,
                                   'historical_adult_source_ids': 1,
                                   'new_whole_source_classifications_supported': 0})

    def test_orientation_and_general_labels_do_not_become_adult(self):
        text = '\u803d\u7f8e::/a&&\u8a00\u60c5::/b'
        self.assertEqual(audit.static_category_counts(text), {'category_count': 2,
            'semantic_class_counts': {'orientation_category_only': 1, 'general_genre_category': 1}})

    def test_unknown_label_is_not_counted_as_general(self):
        self.assertEqual(audit.static_category_counts('zzz::/a'), {'category_count': 1,
                         'semantic_class_counts': {'unclassified_label': 1}})

    def test_renamed_source_id_is_rejected(self):
        evidence = self.edited()
        evidence['source_snapshot'][0]['source_id'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'selected source identities differ'):
            audit.verify(evidence)

    def test_reassigned_record_index_is_rejected(self):
        evidence = self.edited()
        evidence['source_snapshot'][0]['selected_record_index'] = 123
        with self.assertRaisesRegex(ValueError, 'historical source policy or identity differs'):
            audit.verify(evidence)

    def test_static_source_digest_is_checked(self):
        evidence = self.edited()
        evidence['source_snapshot'][0]['normalized_legado_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_discovery_digest_is_checked(self):
        evidence = self.edited()
        evidence['source_snapshot'][0]['discovery_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'static discovery signals or digest differ'):
            audit.verify(evidence)

    def test_unclassified_categories_cannot_become_general(self):
        evidence = self.edited()
        counts = evidence['source_snapshot'][0]['static_discovery_signal_counts']['semantic_class_counts']
        counts['unclassified_label'] -= 1
        counts['general_genre_category'] += 1
        with self.assertRaisesRegex(ValueError, 'static discovery signals or digest differ'):
            audit.verify(evidence)

    def test_orientation_cannot_be_relabelled_adult(self):
        evidence = self.edited()
        source = next(s for s in evidence['source_snapshot'] if s['source_id'] == audit.MIXED_IDS[0])
        counts = source['static_discovery_signal_counts']['semantic_class_counts']
        counts['orientation_category_only'] -= 1
        counts['explicit_adult_category'] += 1
        with self.assertRaisesRegex(ValueError, 'static discovery signals or digest differ'):
            audit.verify(evidence)

    def test_historical_sibling_adult_label_cannot_be_copied(self):
        evidence = self.edited()
        source = next(s for s in evidence['source_snapshot'] if s['source_id'] == audit.FIRST_ID)
        source['static_adult_policy_snapshot'] = True
        with self.assertRaisesRegex(ValueError, 'historical source policy or identity differs'):
            audit.verify(evidence)

    def test_adult_source_snapshot_cannot_be_deleted(self):
        evidence = self.edited()
        source = next(s for s in evidence['source_snapshot'] if s['source_id'] == audit.ADULT_ID)
        source['static_adult_policy_snapshot'] = False
        with self.assertRaisesRegex(ValueError, 'historical source policy or identity differs'):
            audit.verify(evidence)

    def test_same_host_sibling_inference_is_rejected(self):
        evidence = self.edited()
        evidence['decisions']['i.12bz.net']['infer_adult_for_same_host_siblings'] = True
        with self.assertRaisesRegex(ValueError, 'conservative interpretation or sibling boundary differs'):
            audit.verify(evidence)

    def test_mixed_category_cannot_become_site_wide_verdict(self):
        evidence = self.edited()
        evidence['decisions']['m.zhanvxs.cc']['site_adult_status_from_sample'] = 'adult'
        with self.assertRaisesRegex(ValueError, 'conservative interpretation or sibling boundary differs'):
            audit.verify(evidence)

    def test_missing_or_duplicate_observation_is_rejected(self):
        evidence = self.edited()
        evidence['observations'][-1] = copy.deepcopy(evidence['observations'][0])
        with self.assertRaisesRegex(ValueError, 'homepage observation coverage differs'):
            audit.verify(evidence)

    def test_truncation_cannot_be_hidden(self):
        evidence = self.edited()
        evidence['observations'][0]['truncated'] = True
        with self.assertRaisesRegex(ValueError, 'unexpected or incomplete homepage observation'):
            audit.verify(evidence)

    def test_homepage_signal_cannot_be_forged(self):
        evidence = self.edited()
        evidence['observations'][0]['signals']['title_explicit_adult_business_phrase'] = True
        with self.assertRaisesRegex(ValueError, 'frozen homepage observation digest differs'):
            audit.verify(evidence)

    def test_raw_response_cannot_be_added(self):
        evidence = self.edited()
        evidence['observations'][0]['body'] = 'redacted-placeholder'
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_page_title_cannot_be_added(self):
        evidence = self.edited()
        evidence['observations'][0]['title'] = 'redacted-placeholder'
        with self.assertRaisesRegex(ValueError, 'unexpected or incomplete homepage observation'):
            audit.verify(evidence)

    def test_work_identifier_cannot_be_added(self):
        evidence = self.edited()
        evidence['observations'][0]['work_id'] = 'redacted-placeholder'
        with self.assertRaisesRegex(ValueError, 'unexpected or incomplete homepage observation'):
            audit.verify(evidence)

    def test_source_code_snapshot_cannot_be_rewritten(self):
        evidence = self.edited()
        key = next(iter(evidence['source_code_snapshot']['normalized_sha256']))
        evidence['source_code_snapshot']['normalized_sha256'][key] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'historical source-code snapshot differs'):
            audit.verify(evidence)

    def test_historical_commit_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['input_references']['source_ledger_historical_git']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'historical ledger reference mismatch'):
            audit.verify(evidence)

    def test_query_string_cannot_be_added(self):
        evidence = self.edited()
        evidence['limitations'].append('https://example.com/?token=private')
        with self.assertRaisesRegex(ValueError, 'URL query found'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
