import copy
from collections import Counter
import json
import unittest

from tool import verify_legado_rdap_nine as audit


class RdapNineEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_historical_archive_sources_and_observation_coverage(self):
        result = audit.verify(self.evidence)
        self.assertEqual(result['candidate_domains'], 9)
        self.assertEqual(result['selected_source_ids'], 12)
        self.assertEqual(result['total_requests_attempted'], 170)
        self.assertEqual(result['candidate_requests_skipped_due_to_control'], 32)
        self.assertEqual(result['candidate_doh_timeouts'], 4)
        self.assertEqual(result['control_doh_timeouts'], 2)
        self.assertEqual(result['domains_with_two_404'], 3)
        self.assertEqual(result['domains_with_two_matching_objects'], 6)

    def test_historical_ledger_revision_is_fixed(self):
        evidence = self.edited()
        evidence['input_references']['source_ledger_historical_git']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'historical ledger reference mismatch'):
            audit.verify(evidence)

    def test_source_record_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['selected_record_index'] = 123
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_static_policy_cannot_be_misattributed(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['static_policy_snapshot']['fixed_endpoint_host_quarantine'] = True
        with self.assertRaisesRegex(ValueError, 'static policy snapshot differs'):
            audit.verify(evidence)

    def test_old_servfail_cannot_be_relabelled_as_nxdomain(self):
        evidence = self.edited()
        row = next(row for candidate in evidence['candidates'] for row in candidate['previous_public_doh']
                   if row['classification'] == 'servfail')
        row['classification'], row['dns_rcode'] = 'nxdomain', 3
        with self.assertRaisesRegex(ValueError, 'old public DNS evidence differs'):
            audit.verify(evidence)

    def test_failed_tld_control_cannot_be_changed_to_passed(self):
        evidence = self.edited()
        evidence['rounds'][0]['control_status']['com']['tencent'] = True
        with self.assertRaisesRegex(ValueError, 'control status differs'):
            audit.verify_rounds(evidence)

    def test_passing_net_control_cannot_authorize_skipped_com_query(self):
        evidence = self.edited()
        first = evidence['rounds'][0]
        row = copy.deepcopy(next(row for row in first['observations'] if row.get('host') == 'uu234.net'
                                 and row.get('provider') == 'tencent' and row.get('query_type') == 'A'))
        row['host'] = 'aoyekanshu.com'
        first['observations'].append(row)
        first['skipped'] = [s for s in first['skipped'] if not
                            (s['host'] == 'aoyekanshu.com' and s['provider'] == 'tencent' and s['query_type'] == 'A')]
        first['scheduled'] += 1
        first['classification_counts'] = dict(Counter(item['classification'] for item in first['observations']))
        with self.assertRaisesRegex(ValueError, 'candidate query coverage or skipped controls differ'):
            audit.verify_rounds(evidence)

    def test_candidate_timeout_cannot_be_relabelled_as_nxdomain(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['classification'] == 'provider_timeout')
        row['classification'] = 'nxdomain'
        with self.assertRaisesRegex(ValueError, 'DNS classification and status disagree'):
            audit.verify_rounds(evidence)

    def test_control_timeout_cannot_contain_a_synthetic_dns_response(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['controls']
                   if row['classification'] == 'provider_timeout')
        row['dns_rcode'] = 3
        with self.assertRaisesRegex(ValueError, 'timeout treated as DNS response'):
            audit.verify_rounds(evidence)

    def test_registered_domain_cannot_be_replaced_with_another_404(self):
        evidence = self.edited()
        rows = evidence['rounds'][0]['observations']
        dst = next(i for i, row in enumerate(rows) if row.get('domain') == 'bulasw.com')
        replacement = copy.deepcopy(next(row for row in rows if row.get('domain') == 'hanmandq.com'))
        replacement['domain'] = 'bulasw.com'
        rows[dst] = replacement
        evidence['rounds'][0]['classification_counts'] = dict(Counter(row['classification'] for row in rows))
        with self.assertRaisesRegex(ValueError, 'domain RDAP classification differs'):
            audit.verify_rounds(evidence)

    def test_duplicate_observation_cannot_replace_another_query(self):
        evidence = self.edited()
        rows = evidence['rounds'][0]['observations']
        rows[-1] = copy.deepcopy(rows[0])
        with self.assertRaisesRegex(ValueError, 'duplicate candidate observation'):
            audit.verify_rounds(evidence)

    def test_same_domain_301_cannot_be_rewritten(self):
        evidence = self.edited()
        evidence['known_sibling_counterexamples'][0]['http_status'] = 200
        with self.assertRaisesRegex(ValueError, 'same-domain counterexample differs'):
            audit.verify(evidence)

    def test_candidate_summary_must_match_observations(self):
        evidence = self.edited()
        evidence['candidates'][0]['current_summary']['skipped_due_to_control'] = 0
        rdap, dns = audit.verify_rounds(evidence)
        with self.assertRaisesRegex(ValueError, 'candidate summary differs'):
            audit.verify_summaries(evidence, rdap, dns)

    def test_registration_data_is_rejected(self):
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
