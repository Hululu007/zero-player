import copy
from collections import Counter
import json
import unittest

from tool import verify_legado_rdap_com_eighteen as audit


class RdapComEighteenEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_historical_archive_sources_and_request_coverage(self):
        summary = audit.verify(self.evidence)
        self.assertEqual(summary['candidate_domains'], 18)
        self.assertEqual(summary['selected_source_ids'], 22)
        self.assertEqual(summary['candidate_requests_attempted'], 252)
        self.assertEqual(summary['candidate_requests_skipped_due_to_control'], 72)
        self.assertEqual(summary['domains_with_two_404'], 7)
        self.assertEqual(summary['domains_with_two_matching_objects'], 11)
        self.assertEqual(summary['candidate_doh_timeouts'], 6)

    def test_historical_ledger_revision_is_fixed(self):
        evidence = self.edited()
        evidence['input_references']['source_ledger_historical_git']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'historical ledger reference mismatch'):
            audit.verify(evidence)

    def test_source_cannot_be_reassigned_to_another_archive_record(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['selected_record_index'] = 123
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_failed_control_cannot_be_changed_to_passed(self):
        evidence = self.edited()
        evidence['rounds'][0]['control_status']['com']['tencent'] = True
        with self.assertRaisesRegex(ValueError, 'control status differs'):
            audit.verify_rounds(evidence)

    def test_skipped_query_cannot_be_added_as_an_observation(self):
        evidence = self.edited()
        first, second = evidence['rounds']
        row = copy.deepcopy(next(row for row in second['observations']
                                 if row.get('host') == '778buy.com' and row.get('provider') == 'tencent'
                                 and row.get('query_type') == 'A'))
        row['started_at'] = first['started_at']
        row['observed_at'] = first['started_at']
        first['observations'].append(row)
        first['skipped'] = [skip for skip in first['skipped']
                            if not (skip['host'] == '778buy.com' and skip['provider'] == 'tencent'
                                    and skip['query_type'] == 'A')]
        first['scheduled'] += 1
        first['classification_counts'] = dict(Counter(item['classification'] for item in first['observations']))
        with self.assertRaisesRegex(ValueError, 'candidate query coverage or skipped controls differ'):
            audit.verify_rounds(evidence)

    def test_timeout_cannot_be_relabelled_as_nxdomain(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['classification'] == 'provider_timeout')
        row['classification'] = 'nxdomain'
        with self.assertRaisesRegex(ValueError, 'DNS classification and status disagree'):
            audit.verify_rounds(evidence)

    def test_timeout_cannot_contain_a_synthetic_dns_answer(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['classification'] == 'provider_timeout')
        row['dns_rcode'] = 3
        with self.assertRaisesRegex(ValueError, 'timeout treated as DNS response'):
            audit.verify_rounds(evidence)

    def test_registered_object_cannot_be_reported_as_404(self):
        evidence = self.edited()
        row = next(row for row in evidence['rounds'][0]['observations']
                   if row['classification'] == 'matching_domain_object')
        row['http_status'] = 404
        with self.assertRaisesRegex(ValueError, 'invalid RDAP matching object'):
            audit.verify_rounds(evidence)

    def test_duplicate_observation_cannot_replace_a_query(self):
        evidence = self.edited()
        rows = evidence['rounds'][0]['observations']
        rows[-1] = copy.deepcopy(rows[0])
        with self.assertRaisesRegex(ValueError, 'duplicate candidate observation'):
            audit.verify_rounds(evidence)

    def test_same_domain_counterexample_must_match_recorded_evidence(self):
        evidence = self.edited()
        evidence['known_sibling_counterexamples'][1]['observations'][0]['http_status'] = 200
        with self.assertRaisesRegex(ValueError, 'same-domain counterexamples differ'):
            audit.verify(evidence)

    def test_candidate_summary_must_match_observations(self):
        evidence = self.edited()
        evidence['candidates'][0]['current_summary']['skipped_due_to_control'] = 0
        rdap, dns = audit.verify_rounds(evidence)
        with self.assertRaisesRegex(ValueError, 'candidate summary differs'):
            audit.verify_summaries(evidence, rdap, dns)

    def test_unexpected_registration_details_are_rejected(self):
        evidence = self.edited()
        evidence['rounds'][0]['observations'][0]['entities'] = [{'handle': 'private'}]
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_literal_address_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('unexpected address: 1.2.3.4')
        with self.assertRaisesRegex(ValueError, 'literal IP address'):
            audit.verify(evidence)

    def test_url_query_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('https://example.com/search?token=private')
        with self.assertRaisesRegex(ValueError, 'URL query found'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
