import copy
from datetime import timedelta
import json
import unittest

from tool import verify_legado_rdap_top_cc as audit


class TopCcEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_evidence_and_archive_sources(self):
        summary = audit.verify(self.evidence)
        self.assertEqual(summary['candidate_domains'], 7)
        self.assertEqual(summary['selected_source_ids'], 7)
        self.assertEqual(summary['control_requests_attempted'], 32)
        self.assertEqual(summary['candidate_requests_attempted'] +
                         summary['candidate_requests_skipped_due_to_control'], 110)
        self.assertGreaterEqual(summary['domains_with_two_matching_objects'], 1)

    def test_reference_commit_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['input_references']['source_ledger_historical_git']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'historical ledger reference mismatch'):
            audit.verify(evidence)

    def test_source_record_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['selected_record_index'] = 123
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_source_id_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['source_id'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'selected source association differs'):
            audit.verify(evidence)

    def test_source_endpoint_cannot_be_rewritten(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['normalized_endpoint'] = 'https://example.com/'
        with self.assertRaisesRegex(ValueError, 'normalized endpoint differs'):
            audit.verify(evidence)

    def test_collector_digest_normalizes_line_endings(self):
        raw = (audit.ROOT / 'tool/collect_legado_rdap_top_cc.py').read_bytes()
        normalized = raw.replace(b'\r\n', b'\n')
        self.assertEqual(audit.sha(normalized), audit.COLLECTOR_SHA256)
        self.assertEqual(audit.sha(normalized.replace(b'\n', b'\r\n').replace(b'\r\n', b'\n')),
                         audit.COLLECTOR_SHA256)

    def test_old_timeout_cannot_be_relabelled_nxdomain(self):
        evidence = self.edited()
        row = next(row for candidate in evidence['candidates'] for row in candidate['previous_public_doh']
                   if row['classification'] == 'provider_timeout')
        row.update(classification='nxdomain', dns_rcode=3, http_status=200)
        with self.assertRaisesRegex(ValueError, 'historical public DNS mismatch'):
            audit.verify(evidence)

    def test_failed_control_cannot_be_changed_to_passed(self):
        evidence = self.edited()
        evidence['rounds'][0]['control_status']['top']['tencent'] = True
        with self.assertRaisesRegex(ValueError, 'control status differs'):
            audit.verify_rounds(evidence)

    def test_failed_control_cannot_authorize_skipped_candidate(self):
        evidence = self.edited()
        first = evidence['rounds'][0]
        skipped = next(row for row in first['skipped'] if row.get('mode') == 'doh')
        replacement = copy.deepcopy(next(row for row in first['observations'] if row.get('mode') == 'doh'
                                         and row['classification'] == 'nxdomain'))
        replacement.update(host=skipped['host'], provider=skipped['provider'], query_type=skipped['query_type'])
        first['observations'].append(replacement)
        first['skipped'].remove(skipped)
        with self.assertRaisesRegex(ValueError, 'request start interval|candidate coverage'):
            audit.verify_rounds(evidence)

    def test_control_timeout_cannot_contain_dns_response(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['controls']
                   if row['classification'] == 'provider_timeout')
        row['dns_rcode'] = 3
        with self.assertRaisesRegex(ValueError, 'failed DNS query contains fabricated response'):
            audit.verify_rounds(evidence)

    def test_nxdomain_cannot_have_success_rcode(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['classification'] == 'nxdomain')
        row['dns_rcode'] = 0
        with self.assertRaisesRegex(ValueError, 'DNS classification and status disagree'):
            audit.verify_rounds(evidence)

    def test_duplicate_query_cannot_replace_another(self):
        evidence = self.edited()
        rows = evidence['rounds'][0]['observations']
        duplicate = copy.deepcopy(rows[0])
        duplicate['started_at'], duplicate['observed_at'] = rows[-1]['started_at'], rows[-1]['observed_at']
        rows[-1] = duplicate
        with self.assertRaisesRegex(ValueError, 'candidate coverage'):
            audit.verify_rounds(evidence)

    def test_json_404_requires_matching_error_code(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['classification'] == 'http_404_json')
        row['rdap_error_code_is_404'] = False
        with self.assertRaisesRegex(ValueError, 'invalid RDAP 404 object'):
            audit.verify_rounds(evidence)

    def test_registered_parent_and_missing_old_subdomain_remain_separate(self):
        rows = self.evidence['rounds'][0]['observations']
        self.assertEqual(next(row for row in rows if row.get('domain') == 'wxc.cc')['classification'],
                         'matching_domain_object')
        self.assertTrue(any(row.get('host') == 'm.wxc.cc' and row['classification'] == 'nxdomain'
                            for row in rows))
        self.assertTrue(any(row.get('host') == 'wxc.cc' and row['classification'] == 'noerror_addresses'
                            for row in rows))

    def test_cache_wait_cannot_be_shortened(self):
        evidence = self.edited()
        evidence['cache_barrier']['minimum_wait_seconds'] -= 1
        with self.assertRaisesRegex(ValueError, 'cache barrier differs'):
            audit.verify_rounds(evidence)

    def test_second_round_cannot_start_before_cache_barrier(self):
        evidence = self.edited()
        barrier = audit.timestamp(evidence['cache_barrier']['not_before_utc'])
        evidence['rounds'][1]['started_at'] = (barrier - timedelta(seconds=1)).isoformat()
        with self.assertRaisesRegex(ValueError, 'before cache barrier'):
            audit.verify_rounds(evidence)

    def test_candidate_summary_cannot_reclassify_skip(self):
        evidence = self.edited()
        candidate = next(c for c in evidence['candidates']
                         if c['current_summary']['registry_domain_dns']['skipped_due_to_control'])
        candidate['current_summary']['registry_domain_dns']['skipped_due_to_control'] = 0
        with self.assertRaisesRegex(ValueError, 'candidate summary differs'):
            audit.summarize(evidence)

    def test_iana_bootstrap_mapping_cannot_be_changed(self):
        evidence = self.edited()
        evidence['iana_bootstrap']['services']['top'] = ['https://example.com/']
        with self.assertRaisesRegex(ValueError, 'IANA bootstrap observation differs'):
            audit.verify(evidence)

    def test_personal_registration_data_is_rejected(self):
        evidence = self.edited()
        evidence['rounds'][0]['observations'][0]['entities'] = [{'handle': 'private'}]
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_raw_response_is_rejected(self):
        evidence = self.edited()
        evidence['rounds'][0]['observations'][0]['body'] = '{}'
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_literal_ip_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('unexpected address: ' + '.'.join(map(str, (1, 2, 3, 4))))
        with self.assertRaisesRegex(ValueError, 'literal IP address'):
            audit.verify(evidence)

    def test_query_string_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('https://example.com/?token=private')
        with self.assertRaisesRegex(ValueError, 'URL query found'):
            audit.verify(evidence)

    def test_unchanged_schema_still_rejects_forged_observation(self):
        evidence = self.edited()
        row = next(row for run in evidence['rounds'] for row in run['observations']
                   if row['mode'] == 'rdap' and row['classification'] == 'matching_domain_object')
        row['body_bytes'] += 1
        with self.assertRaisesRegex(ValueError, 'frozen observation digest differs'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
