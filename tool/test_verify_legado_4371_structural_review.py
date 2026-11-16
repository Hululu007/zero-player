"""Offline integrity, identity, sampling and privacy regressions for #4371."""
from copy import deepcopy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_4371_structural_review as review


class StructuralReview4371Test(unittest.TestCase):
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

    def test_verification_never_reads_build_or_uses_network(self):
        original = Path.read_bytes
        def guarded(path):
            if 'build' in path.parts:
                raise AssertionError('build is not an evidence input')
            return original(path)
        review.load_inputs.cache_clear()
        with patch.object(Path, 'read_bytes', guarded), \
                patch('socket.socket', side_effect=AssertionError('network forbidden')):
            review.verify(self.original)

    def test_frozen_evidence_digest(self):
        self.reject(lambda e: e['source'].update(source_id='0' * 64), repin=False)

    def test_selected_source_identity_and_older_rule_are_bound(self):
        for key, value in [('source_id', '0' * 64), ('endpoint_host', 'other.example'),
                           ('selected_record_index', 4370), ('endpoint_sha256', '0' * 64),
                           ('raw_record_canonical_sha256', '0' * 64),
                           ('normalized_legado_sha256', '0' * 64)]:
            with self.subTest(key=key):
                self.reject(lambda e: e['source'].update({key: value}))
        altered = deepcopy(self.data)
        altered['records'][4371] = {**altered['records'][4371], 'bookSourceName': 'changed'}
        with self.assertRaises(ValueError):
            review.verify(self.original, altered)

    def test_historical_ledger_and_capture_digest_remain_bound(self):
        self.reject(lambda e: e['provenance']['historical_ledger'].update(git_commit='0' * 40))
        self.reject(lambda e: e['provenance']['historical_ledger'].update(sha256='0' * 64))
        self.reject(lambda e: e['provenance'].update(local_redacted_capture_sha256='0' * 64))
        self.reject(lambda e: e['provenance'].update(network_authenticity_verifiable_offline=True))
        self.reject(lambda e: e['provenance'].update(collector_or_dependencies_distributed=True))

    def test_two_search_placeholders_are_not_successes(self):
        for index in (0, 1):
            self.reject(lambda e: e['observations'][index].update(no_results_placeholder_count=0))
            self.reject(lambda e: e['observations'][index].update(items_with_anchor_and_bold=1))
        self.reject(lambda e: e['method'].update(synthetic_searches=1))
        self.reject(lambda e: e['interpretation'].update(search_placeholder_does_not_prove_permanent_failure=False))

    def test_category_toc_and_single_chapter_counts_stay_limited(self):
        self.reject(lambda e: e['observations'][2].update(old_table_rows=51))
        self.reject(lambda e: e['observations'][4].update(same_host_safe_chapter_candidates=20))
        self.reject(lambda e: e['observations'][5].update(visible_characters=2057))
        self.reject(lambda e: e['method'].update(chapters=2))
        self.reject(lambda e: e['interpretation'].update(one_chapter_does_not_prove_full_reading=False))
        self.reject(lambda e: e['interpretation'].update(safe_candidates_are_collector_path_predicate_only=False))

    def test_no_unverified_sitewide_conclusions(self):
        for key in ('site_security_verified', 'site_malware_verified', 'sitewide_adult_verified',
                    'whole_source_unavailable_verified', 'whole_source_readability_verified'):
            with self.subTest(key=key):
                self.reject(lambda e: e['interpretation'].update({key: True}))
        self.reject(lambda e: e['interpretation'].update(automatic_quarantine_proposed=True))

    def test_capture_does_not_claim_application_or_script_execution(self):
        self.reject(lambda e: e['method'].update(page_or_source_scripts_executed=True))
        self.reject(lambda e: e['interpretation'].update(application_parser_executed=True))
        self.reject(lambda e: e['method'].update(capture_requests_fetched_subresources=True))

    def test_dns_and_timeout_limitations_not_strengthened(self):
        self.reject(lambda e: e['method'].update(dns_validator='all answers public'))
        self.reject(lambda e: e['method'].update(overall_wall_deadline_enforced=True))
        self.reject(lambda e: e['method'].update(redirects_followed=True))
        self.reject(lambda e: e['limitations'].pop())

    def test_prior_separate_script_request_scope_not_erased(self):
        self.reject(lambda e: e['limitations'].__setitem__(2, 'No prior script requests.'))
        self.reject(lambda e: e['method'].update(never_requested_any_script=True))

    def test_http_status_and_samples_not_invented(self):
        self.reject(lambda e: e['observations'][0]['http'].update(status=404))
        self.reject(lambda e: e['observations'][2]['http'].update(sample_bytes=65537))
        self.reject(lambda e: e['observations'][3]['http'].update(truncated=True))
        self.reject(lambda e: e['observations'].pop())

    def test_raw_text_work_path_query_or_address_cannot_be_added(self):
        for key in ('body', 'html', 'work_title', 'path', 'query', 'ip', 'cookie', 'script'):
            with self.subTest(key=key):
                self.reject(lambda e: e['observations'][5].update({key: 'private data'}))

    def test_duplicate_or_reordered_observations_are_rejected(self):
        self.reject(lambda e: e['observations'].reverse())
        self.reject(lambda e: e['observations'].__setitem__(1, deepcopy(e['observations'][0])))


if __name__ == '__main__':
    unittest.main()
