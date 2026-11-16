"""Offline tamper regressions for the later .top review."""
from copy import deepcopy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tool import verify_legado_rdap_top_later as review


class LaterTopEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((review.ROOT / review.EVIDENCE).read_text(encoding='utf-8'))
        review.verify(cls.evidence)

    def reject(self, change, *, refresh_capture_hash=False):
        candidate = deepcopy(self.evidence)
        change(candidate)
        digest = review.prior.canonical_sha(candidate['later_capture'])
        with patch.object(review, 'CAPTURE_CANONICAL_SHA', digest if refresh_capture_hash else review.CAPTURE_CANONICAL_SHA):
            with self.assertRaises((ValueError, KeyError, TypeError, StopIteration)):
                review.verify(candidate)

    def test_frozen_observation_is_not_editable(self):
        self.reject(lambda e: e['later_capture']['round']['observations'].pop())

    def test_candidate_identity_and_version_cannot_change(self):
        self.reject(lambda e: e['historical_candidates'][2]['selected_sources'][0].update(
            {'normalized_legado_sha256': '0' * 64}))

    def test_timeout_candidate_cannot_be_added_to_review(self):
        self.reject(lambda e: e['reviewed_unavailable_source_ids'].append(
            'c0cef4c7811afb1da938df500c893459d9e78075e25ce471bfb17b6c52cc9f12'))

    def test_false_registry_control_is_not_usable(self):
        def change(e):
            row = e['later_capture']['round']['controls'][0]
            row['rdap_object_matches'] = False
        self.reject(change, refresh_capture_hash=True)

    def test_candidate_registry_404_cannot_become_200(self):
        def change(e):
            rows = e['later_capture']['round']['observations']
            next(row for row in rows if row.get('domain') == 'stxt.top')['http_status'] = 200
        self.reject(change, refresh_capture_hash=True)

    def test_timeout_is_not_an_nxdomain(self):
        def change(e):
            rows = e['later_capture']['round']['observations']
            next(row for row in rows if row.get('host') == 'stxt.top')['classification'] = 'provider_timeout'
        self.reject(change, refresh_capture_hash=True)

    def test_failed_control_cannot_be_skipped_silently(self):
        def change(e):
            round_ = e['later_capture']['round']
            round_['skipped'].append({'mode': 'rdap', 'domain': 'stxt.top', 'reason': 'control_failed'})
        self.reject(change, refresh_capture_hash=True)

    def test_round_cannot_precede_the_prior_cache_barrier(self):
        def change(e):
            e['later_capture']['round']['started_at'] = '2026-11-15T20:55:06+00:00'
        self.reject(change, refresh_capture_hash=True)

    def test_negative_controls_cannot_be_reused(self):
        def change(e):
            e['later_capture']['round']['negative_controls'] = deepcopy(
                review.validated_prior()['rounds'][0]['negative_controls'])
        self.reject(change, refresh_capture_hash=True)

    def test_raw_dns_addresses_cannot_be_added(self):
        self.reject(lambda e: e['later_capture']['round']['observations'][0].update({'ip_address': '192.0.2.1'}),
                    refresh_capture_hash=True)

    def test_limitations_are_not_silently_removed(self):
        self.reject(lambda e: e['limitations'].pop())

    def test_recent_head_evidence_cannot_be_repointed(self):
        self.reject(lambda e: e['latest_head_evidence'].update({'sha256': '0' * 64}))


if __name__ == '__main__':
    unittest.main()
