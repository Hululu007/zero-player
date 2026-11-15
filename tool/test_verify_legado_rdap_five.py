import copy
from datetime import timedelta
import json
import unittest
from unittest import mock

from tool import verify_legado_rdap_five as audit


class FiveDomainEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def edited(self):
        return copy.deepcopy(self.evidence)

    def test_evidence_verifies_offline_with_complete_coverage(self):
        with mock.patch('socket.create_connection', side_effect=AssertionError('network used')):
            summary = audit.verify(self.evidence)
        self.assertEqual(summary['candidate_domains'], 5)
        self.assertEqual(summary['selected_source_ids'], 10)
        self.assertEqual(summary['control_requests_attempted'], 68)
        self.assertEqual(summary['candidate_requests_attempted'] +
                         summary['candidate_requests_skipped_due_to_control'], 90)

    def test_source_record_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['selected_record_index'] = 123
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_exact_endpoint_digest_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['endpoint_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_normalized_complete_endpoint_cannot_be_rewritten(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['normalized_endpoint'] += '/other'
        with self.assertRaisesRegex(ValueError, 'normalized complete endpoint differs'):
            audit.verify(evidence)

    def test_complete_rule_digest_cannot_be_reassigned(self):
        evidence = self.edited()
        evidence['candidates'][0]['selected_sources'][0]['normalized_legado_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'historical selected version'):
            audit.verify(evidence)

    def test_absent_prior_public_dns_cannot_become_a_negative(self):
        evidence = self.edited()
        candidate = next(c for c in evidence['candidates'] if c['previous_public_doh'] is None)
        candidate['previous_public_doh'] = []
        with self.assertRaisesRegex(ValueError, 'prior public DNS evidence differs'):
            audit.verify(evidence)

    def test_historical_native_timeout_cannot_be_relabelled(self):
        evidence = self.edited()
        evidence['candidates'][0]['latest_native_dns']['observations'][0]['query_failed'] = True
        with self.assertRaisesRegex(ValueError, 'latest native DNS evidence differs'):
            audit.verify(evidence)

    def test_registered_parent_and_old_subdomain_are_distinct(self):
        rows = self.evidence['rounds'][0]['observations']
        self.assertEqual(next(r for r in rows if r.get('domain') == '7wav.com')['classification'],
                         'matching_domain_object')
        self.assertTrue(any(r.get('host') == '7wav.com' and r['classification'] == 'noerror_addresses'
                            for r in rows))
        self.assertTrue(any(r.get('host') == 'm.7wav.com' and r['classification'] == 'nxdomain'
                            for r in rows))

    def test_registered_domain_can_have_negative_dns(self):
        rows = self.evidence['rounds'][0]['observations']
        self.assertEqual(next(r for r in rows if r.get('domain') == 'fxsw.top')['classification'],
                         'matching_domain_object')
        self.assertTrue(any(r.get('host') == 'fxsw.top' and r['classification'] == 'nxdomain' for r in rows))

    def test_missing_first_round_control_never_satisfies_strict_eligibility(self):
        for domain in ('zri.moe', 'cwj18.org'):
            candidate = next(c for c in self.evidence['candidates'] if c['registry_domain'] == domain)
            self.assertFalse(audit.strict_eligibility(candidate, self.evidence['rounds']))

    def test_cross_period_review_uses_historical_tencent_without_inventing_current_queries(self):
        candidate = next(c for c in self.evidence['candidates'] if c['registry_domain'] == 'zri.moe')
        historical = candidate['previous_public_doh']
        self.assertEqual({(r['provider'], r['query_type']) for r in historical},
                         {(p, q) for p in ('aliyun', 'tencent') for q in ('A', 'AAAA')})
        self.assertEqual(audit.cross_period_zri_sources(self.evidence),
                         sorted(s['source_id'] for s in candidate['selected_sources']))
        for row in self.evidence['rounds']:
            self.assertFalse(row['control_status']['moe']['tencent'])
            self.assertFalse(any(r.get('provider') == 'tencent' and
                                 r.get('host') in ('zri.moe', 'book.zri.moe')
                                 for r in row['observations']))

    def test_cross_period_review_requires_historical_tencent_results(self):
        evidence = self.edited()
        candidate = next(c for c in evidence['candidates'] if c['registry_domain'] == 'zri.moe')
        candidate['previous_public_doh'] = [r for r in candidate['previous_public_doh']
                                            if r['provider'] != 'tencent']
        self.assertEqual(audit.cross_period_zri_sources(evidence), [])
        with self.assertRaisesRegex(ValueError, 'prior public DNS evidence differs'):
            audit.verify(evidence)

    def test_cross_period_review_requires_prior_ttl_metadata(self):
        evidence = self.edited()
        candidate = next(c for c in evidence['candidates'] if c['registry_domain'] == 'zri.moe')
        candidate['previous_public_doh'][0]['negative_ttls_seconds'] = []
        self.assertEqual(audit.cross_period_zri_sources(evidence), [])

    def test_historical_positive_control_cannot_be_forged(self):
        evidence = self.edited()
        evidence['historical_public_doh_controls'][0]['classification'] = 'nxdomain'
        self.assertEqual(audit.cross_period_zri_sources(evidence), [])
        with self.assertRaisesRegex(ValueError, 'historical public DNS controls differ'):
            audit.verify(evidence)

    def test_cross_period_review_requires_both_latest_aliyun_rounds(self):
        evidence = self.edited()
        row = evidence['rounds'][1]
        row['observations'] = [r for r in row['observations'] if not
                               (r.get('host') == 'book.zri.moe' and r.get('provider') == 'aliyun'
                                and r.get('query_type') == 'A')]
        self.assertEqual(audit.cross_period_zri_sources(evidence), [])

    def test_control_failure_cannot_be_changed_to_pass(self):
        evidence = self.edited()
        evidence['rounds'][0]['control_status']['moe']['tencent'] = True
        with self.assertRaisesRegex(ValueError, 'control status differs'):
            audit.verify_rounds(evidence)

    def test_skipped_candidate_cannot_be_fabricated(self):
        evidence = self.edited()
        row = evidence['rounds'][0]
        skipped = next(item for item in row['skipped'] if item['mode'] == 'doh')
        fake = copy.deepcopy(next(item for item in row['observations'] if item.get('mode') == 'doh'
                                  and item['classification'] == 'nxdomain'))
        fake.update(host=skipped['host'], provider=skipped['provider'], query_type=skipped['query_type'])
        row['observations'].append(fake)
        row['skipped'].remove(skipped)
        with self.assertRaisesRegex(ValueError, 'request start interval|candidate coverage'):
            audit.verify_rounds(evidence)

    def test_timeout_cannot_contain_fabricated_dns_result(self):
        evidence = self.edited()
        row = next(item for run in evidence['rounds'] for item in run['controls']
                   if item['classification'] == 'provider_timeout')
        row['dns_rcode'] = 3
        with self.assertRaisesRegex(ValueError, 'failed DNS query contains fabricated response'):
            audit.verify_rounds(evidence)

    def test_nxdomain_requires_matching_rcode(self):
        evidence = self.edited()
        row = next(item for run in evidence['rounds'] for item in run['observations']
                   if item['classification'] == 'nxdomain')
        row['dns_rcode'] = 0
        with self.assertRaisesRegex(ValueError, 'DNS classification and status disagree'):
            audit.verify_rounds(evidence)

    def test_json_404_requires_matching_error_code(self):
        evidence = self.edited()
        row = next(item for run in evidence['rounds'] for item in run['observations']
                   if item['classification'] == 'http_404_json')
        row['rdap_error_code_is_404'] = False
        with self.assertRaisesRegex(ValueError, 'invalid RDAP 404 object'):
            audit.verify_rounds(evidence)

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

    def test_duplicate_observation_cannot_replace_a_query(self):
        evidence = self.edited()
        rows = evidence['rounds'][0]['observations']
        duplicate = copy.deepcopy(rows[0])
        duplicate['started_at'], duplicate['observed_at'] = rows[-1]['started_at'], rows[-1]['observed_at']
        rows[-1] = duplicate
        with self.assertRaisesRegex(ValueError, 'candidate coverage'):
            audit.verify_rounds(evidence)

    def test_public_suffix_boundary_cannot_be_rewritten(self):
        evidence = self.edited()
        evidence['public_suffix_observation']['source_host_to_registrable_domain_icann_and_including_private']['book.zri.moe'] = 'moe'
        with self.assertRaisesRegex(ValueError, 'public suffix boundary observation differs'):
            audit.verify(evidence)

    def test_unrecorded_suffix_observation_time_cannot_be_invented(self):
        evidence = self.edited()
        evidence['public_suffix_observation']['exact_observation_time_recorded'] = True
        with self.assertRaisesRegex(ValueError, 'public suffix boundary observation differs'):
            audit.verify(evidence)

    def test_iana_mapping_cannot_be_rewritten(self):
        evidence = self.edited()
        evidence['iana_bootstrap']['services']['moe'] = ['https://example.com/']
        with self.assertRaisesRegex(ValueError, 'IANA bootstrap observation differs'):
            audit.verify(evidence)

    def test_previous_registry_evidence_cannot_be_removed(self):
        evidence = self.edited()
        evidence['input_references']['previous_rdap_historical_git'].pop(audit.PREVIOUS_RDAP[0])
        with self.assertRaisesRegex(ValueError, 'prior RDAP evidence set differs'):
            audit.verify(evidence)

    def test_source_code_snapshot_cannot_be_rewritten(self):
        evidence = self.edited()
        key = next(iter(evidence['source_code_snapshot']['normalized_sha256']))
        evidence['source_code_snapshot']['normalized_sha256'][key] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'historical source-code snapshot differs'):
            audit.verify(evidence)

    def test_verification_support_digest_cannot_be_rewritten(self):
        evidence = self.edited()
        key = next(iter(evidence['verification_support']['sha256']))
        evidence['verification_support']['sha256'][key] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'verification support references differ'):
            audit.verify(evidence)

    def test_registry_personal_data_is_rejected(self):
        evidence = self.edited()
        evidence['rounds'][0]['observations'][0]['entities'] = [{'handle': 'private'}]
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_raw_registry_response_is_rejected(self):
        evidence = self.edited()
        evidence['rounds'][0]['observations'][0]['body'] = 'redacted-placeholder'
        with self.assertRaisesRegex(ValueError, 'sensitive response field'):
            audit.verify(evidence)

    def test_literal_address_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('unexpected address: ' + '.'.join(map(str, (1, 2, 3, 4))))
        with self.assertRaisesRegex(ValueError, 'literal IP address'):
            audit.verify(evidence)

    def test_query_string_is_rejected(self):
        evidence = self.edited()
        evidence['limitations'].append('https://example.com/?token=private')
        with self.assertRaisesRegex(ValueError, 'URL query found'):
            audit.verify(evidence)

    def test_plausible_but_forged_observation_is_rejected(self):
        evidence = self.edited()
        row = next(item for run in evidence['rounds'] for item in run['observations']
                   if item['mode'] == 'rdap' and item['classification'] == 'matching_domain_object')
        row['body_bytes'] += 1
        with self.assertRaisesRegex(ValueError, 'frozen observation digest differs'):
            audit.verify(evidence)


if __name__ == '__main__':
    unittest.main()
