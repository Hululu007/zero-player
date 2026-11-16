"""Offline integrity, provenance and privacy regressions for four sources."""
from copy import deepcopy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_four_risk_revisit as review


def observed(evidence, index, stage):
    return next(row for row in evidence['observations']
                if row['record_index'] == index and row['stage'] == stage)


class FourSourceEvidenceTest(unittest.TestCase):
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
            with self.assertRaises((ValueError, KeyError, TypeError, StopIteration)):
                review.verify(candidate, self.data)

    def test_offline_validation_does_not_use_build_or_network(self):
        read_bytes = Path.read_bytes
        def guarded_read(path):
            if 'build' in path.parts:
                raise AssertionError('build is not an offline input')
            return read_bytes(path)
        review.load_inputs.cache_clear()
        with patch.object(Path, 'read_bytes', guarded_read), \
                patch('socket.socket', side_effect=AssertionError('network is forbidden')):
            review.verify(self.original)

    def test_frozen_evidence_digest_rejects_modification(self):
        self.reject(lambda e: observed(e, 4568, 'initial_home')['sample'].update(
            script_tags=123), repin=False)

    def test_source_id_and_host_are_bound_to_selected_record(self):
        self.reject(lambda e: e['sources'][0].update(source_id='0' * 64))
        self.reject(lambda e: e['sources'][0].update(endpoint_host='other.example'))

    def test_archive_rule_fingerprint_cannot_be_reassigned(self):
        self.reject(lambda e: e['sources'][1].update(raw_record_canonical_sha256='0' * 64))
        self.reject(lambda e: e['sources'][1].update(sample_ledger_normalized_legado_sha256='0' * 64))

    def test_ledger_commit_is_not_backdated_or_runtime_proof(self):
        self.reject(lambda e: e['provenance']['sampling_ledger'].update(
            matching_object_identified_after_initial_observations=False))
        self.reject(lambda e: e['provenance']['sampling_ledger'].update(
            matching_commit_at_utc='2026-11-16T02:18:00+00:00'))
        self.reject(lambda e: e['provenance']['summary_ledger'].update(
            sha256=review.SAMPLE_LEDGER_SHA))

    def test_parser_source_is_not_claimed_as_full_sample_runtime(self):
        self.reject(lambda e: e['provenance']['legado_request_static_source'].update(
            scope='complete source runtime'))
        self.reject(lambda e: e['interpretation'].update(
            source4568_inspected_parser_implements_webview_option=True))

    def test_request_count_and_timing_are_exact(self):
        self.reject(lambda e: e['observations'].pop())
        self.reject(lambda e: e['observations'][0].update(
            started_at_utc='2026-11-16T03:00:00+00:00'))
        self.reject(lambda e: e['method'].update(overall_wall_deadline_enforced=True))

    def test_302_is_not_a_success_and_redirects_are_never_followed(self):
        self.reject(lambda e: observed(e, 2098, 'repeat_home').update(http_status=200))
        self.reject(lambda e: observed(e, 2098, 'repeat_home')['redirect'].update(followed=True))
        self.reject(lambda e: observed(e, 2098, 'repeat_home')['redirect'].update(same_host=True))

    def test_unknown_redirect_host_cannot_be_fabricated(self):
        self.reject(lambda e: observed(e, 36, 'initial_home')['redirect'].update(
            destination_host='zairuc.com'))

    def test_sample_bytes_hashes_and_truncation_are_fixed(self):
        self.reject(lambda e: observed(e, 4568, 'detail_1')['sample'].update(truncated=False))
        self.reject(lambda e: observed(e, 4568, 'chapter_1')['sample'].update(sha256='0' * 64))
        self.reject(lambda e: observed(e, 2098, 'old_category_html')['sample'].update(visible_characters=0))

    def test_prior_amsi_root_and_inline_results_remain_separate(self):
        self.reject(lambda e: e['sources'][0]['prior_amsi'].update(root_classification='not_detected'))
        self.reject(lambda e: e['sources'][0]['prior_amsi'].update(separate_inline_classification='detected'))
        self.reject(lambda e: e['sources'][3].update(prior_amsi={'root_classification':'not_detected'}))

    def test_mixed_content_cannot_be_recast_as_sitewide_adult_or_safe(self):
        self.reject(lambda e: observed(e, 4568, 'initial_home')['sample']['visible_text_clues'].update(
            adult_business=False))
        self.reject(lambda e: e['interpretation'].update(
            source4568_mixed_keyword_clues_do_not_prove_sitewide_adult=False))
        self.reject(lambda e: e['interpretation'].update(sitewide_adult=True))

    def test_unknown_search_and_single_chapter_cannot_become_full_success(self):
        self.reject(lambda e: observed(e, 4568, 'synthetic_search')['structural_checks'].update(usable_links=1))
        self.reject(lambda e: e['interpretation'].update(
            source4568_synthetic_search_zero_matches_not_permanent_failure=False))
        self.reject(lambda e: e['interpretation'].update(
            source4568_one_chapter_does_not_establish_full_reading=False))

    def test_script_execution_and_automatic_quarantine_cannot_be_claimed(self):
        self.reject(lambda e: e['method'].update(source_or_page_scripts_executed=True))
        self.reject(lambda e: e['interpretation'].update(actual_legado_engine_or_webview_executed=True))
        self.reject(lambda e: e['interpretation'].update(automatic_sitewide_classification_or_quarantine_proposed=True))

    def test_private_page_content_query_work_and_ip_cannot_be_added(self):
        for key, value in [('body','raw page'), ('work_title','private title'),
                           ('work_path','/book/1.html'), ('query','a'), ('ip','192.0.2.1'),
                           ('cookie','session=x')]:
            with self.subTest(key=key):
                self.reject(lambda e: observed(e, 4568, 'chapter_1').update({key:value}))
        self.reject(lambda e: observed(e, 2098, 'repeat_home')['redirect'].update(
            destination_host='192.0.2.1'))

    def test_recorded_limitations_cannot_be_removed(self):
        self.reject(lambda e: e['limitations'].pop())
        self.reject(lambda e: e['provenance'].update(
            local_capture_or_network_authenticity_offline_verifiable=True))


if __name__ == '__main__':
    unittest.main()
