import copy
import json
import unittest
from pathlib import Path

from tool import verify_legado_rdap_com_six as audit


class RdapComSixEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_repository_evidence_and_historical_sources(self):
        summary = audit.verify(self.evidence)
        self.assertEqual(summary['selected_source_ids'], 8)
        self.assertEqual(summary['doh_timeouts'], 5)
        self.assertEqual(summary['http_404_empty_body'], 2)

    def test_historical_ledger_revision_is_fixed(self):
        evidence = self.edited()
        evidence['input_references']['source_ledger_historical_git']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'historical ledger reference mismatch'):
            audit.verify(evidence)

    def test_selected_source_record_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['selected_record_index'] = 123
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_registered_response_cannot_be_relabelled(self):
        evidence = self.edited()
        row = next(row for row in evidence['rounds'][0]['observations']
                   if row.get('classification') == 'matching_domain_object')
        row['http_status'] = 404
        with self.assertRaisesRegex(ValueError, 'invalid RDAP matching object'):
            audit.verify(evidence)

    def test_timeout_is_not_a_dns_negative_answer(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['classification'] == 'provider_timeout')
        row['classification'] = 'nxdomain'
        with self.assertRaisesRegex(ValueError, 'DNS classification and status disagree'):
            audit.verify(evidence)

    def test_duplicate_observation_does_not_count_as_two_queries(self):
        evidence = self.edited()
        rows = evidence['rounds'][0]['observations']
        rows[-1] = copy.deepcopy(rows[0])
        with self.assertRaisesRegex(ValueError, 'duplicate candidate observation'):
            audit.verify(evidence)

    def test_unexpected_rdap_personal_data_is_rejected(self):
        evidence = self.edited()
        evidence['rounds'][0]['observations'][0]['entities'] = [{'handle': 'private'}]
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_literal_ip_hidden_in_text_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('unexpected address: 1.2.3.4')
        with self.assertRaisesRegex(ValueError, 'literal IP address'):
            audit.verify(evidence)

    def test_candidate_summary_must_match_observations(self):
        evidence = self.edited()
        evidence['candidates'][0]['current_summary']['dns_classification_counts'] = {}
        with self.assertRaisesRegex(ValueError, 'candidate summary differs'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
