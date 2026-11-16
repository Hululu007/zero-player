"""Integrity, identity, privacy and coverage regressions without network."""
from copy import deepcopy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_two_selected_amsi_static as review


class TwoSelectedAmsiEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = json.loads((review.ROOT / review.EVIDENCE).read_bytes())
        cls.data = review.load_inputs()
        review.verify(cls.original, cls.data)

    def reject(self, change, *, repin=True):
        candidate = deepcopy(self.original)
        change(candidate)
        digest = review.sha(review.canonical(candidate)) if repin else review.CANONICAL_SHA
        with patch.object(review, 'CANONICAL_SHA', digest):
            with self.assertRaises((ValueError, KeyError, TypeError, IndexError)):
                review.verify(candidate, self.data)

    def test_verification_does_not_touch_build_or_network(self):
        original_read = Path.read_bytes
        def guarded(path):
            if 'build' in path.parts:
                raise AssertionError('build is not an input')
            return original_read(path)
        review.load_inputs.cache_clear()
        with patch.object(Path, 'read_bytes', guarded), \
                patch('socket.socket', side_effect=AssertionError('network forbidden')):
            review.verify(self.original)

    def test_frozen_canonical_digest(self):
        self.reject(lambda e: e['sources'][0].update(source_id='0' * 64), repin=False)

    def test_selected_id_host_and_index_are_independent_constraints(self):
        self.reject(lambda e: e['sources'][0].update(source_id='0' * 64))
        self.reject(lambda e: e['sources'][0].update(host='other.example'))
        self.reject(lambda e: e['sources'][1].update(selected_record_index=3012))

    def test_old_endpoint_and_rule_fingerprints_cannot_be_reassigned(self):
        self.reject(lambda e: e['sources'][0].update(endpoint_sha256='0' * 64))
        self.reject(lambda e: e['sources'][1].update(raw_record_sha256='0' * 64))
        self.reject(lambda e: e['sources'][1].update(normalized_legado_sha256='0' * 64))
        altered = deepcopy(self.data)
        altered['records'][4838] = {**altered['records'][4838], 'bookSourceName': 'changed'}
        with self.assertRaises(ValueError):
            review.verify(self.original, altered)

    def test_ledger_and_prior_observations_are_bound(self):
        self.reject(lambda e: e.update(ledger_git_commit='0' * 40))
        self.reject(lambda e: e.update(ledger_sha256='0' * 64))
        self.reject(lambda e: e['prior_evidence_sha256'].update(
            {'legado-amsi-other-hosts-20261115.json': '0' * 64}))
        altered = deepcopy(self.data)
        altered['later']['kuronavi.blog']['amsi']['classification'] = 'not_detected'
        with self.assertRaises(ValueError):
            review.verify(self.original, altered)

    def test_redirect_not_followed_and_destination_remains_unknown(self):
        self.reject(lambda e: e['observations'][0].update(http_status=200))
        self.reject(lambda e: e['observations'][0].update(location='https://example.com/'))
        self.reject(lambda e: e['method_details'].update(http_redirects_followed=True))

    def test_tls_failures_remain_unknown_http_outcomes(self):
        self.reject(lambda e: e['observations'][1].update(http_status=404))
        self.reject(lambda e: e['observations'][3].update(failure='dns_error'))
        self.reject(lambda e: e['interpretation'].update(tls_errors_prove_permanent_failure=True))

    def test_root_detection_and_inline_non_detection_remain_distinct(self):
        self.reject(lambda e: e['observations'][2]['amsi'].update(classification='not_detected'))
        self.reject(lambda e: e['observations'][2]['inline_scans'][0]['amsi'].update(
            classification='detected'))
        self.reject(lambda e: e['observations'][2].update(sample_bytes=32769))
        self.reject(lambda e: e['observations'][2].update(truncated=True))

    def test_wrapped_control_misses_and_cloud_boundary_are_preserved(self):
        self.reject(lambda e: e['control']['html_wrapped_eicar'].update(classification='detected'))
        self.reject(lambda e: e['control']['inline_script_with_eicar'].update(classification='detected'))
        self.reject(lambda e: e['method_details'].update(antimalware_provider_may_upload_samples=False))

    def test_no_sitewide_safety_malware_or_adult_conclusion(self):
        for key in ('current_host_security_verified', 'current_host_malware_confirmed',
                    'sitewide_adult_classification', 'full_source_readability_verified',
                    'permanent_unavailability_verified'):
            with self.subTest(key=key):
                self.reject(lambda e: e['interpretation'].update({key: True}))
        self.reject(lambda e: e['interpretation'].update(same_template_does_not_prove_independent_threats=False))

    def test_script_execution_and_network_authenticity_cannot_be_claimed(self):
        self.reject(lambda e: e['method_details'].update(page_or_source_scripts_executed=True))
        self.reject(lambda e: e['method_details'].update(page_or_source_scripts_executed=0))
        self.reject(lambda e: e['method_details'].update(dns_all_answers_checked_public=1))
        self.reject(lambda e: e['provenance_limits'].update(offline_can_authenticate_network_response=True))
        self.reject(lambda e: e['provenance_limits'].update(ledger_object_identifies_entire_runtime=True))
        self.reject(lambda e: e.update(method='Scripts were executed'))
        self.reject(lambda e: e.update(limitations='Site is safe'))

    def test_raw_content_ip_or_redirect_target_cannot_be_added(self):
        for key in ('body', 'html', 'script', 'ip', 'cookie', 'location'):
            with self.subTest(key=key):
                self.reject(lambda e: e['observations'][2].update({key: 'private data'}))

    def test_request_count_and_chronology_are_fixed(self):
        self.reject(lambda e: e['observations'].pop())
        self.reject(lambda e: e['observations'][3].update(started_at='2026-11-15T00:00:00+00:00'))
        self.reject(lambda e: e['method_details'].update(max_requests_per_host=3))


if __name__ == '__main__':
    unittest.main()
