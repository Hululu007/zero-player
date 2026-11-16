import copy
import json
import socket
import unittest
from pathlib import Path
from unittest.mock import patch

from tool import verify_legado_sanyou_sale_recheck as audit


class SanyouSaleEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def changed(self):
        return copy.deepcopy(self.evidence)

    def rejected(self, changed, reason):
        with self.assertRaisesRegex(ValueError, reason):
            audit.verify(changed, pinned=False)

    def test_offline_without_temporary_files_or_network(self):
        original = Path.read_bytes
        def read_without_build(path):
            if 'build' in path.parts: raise AssertionError('temporary collection was read')
            return original(path)
        with patch.object(Path, 'read_bytes', read_without_build), \
             patch.object(socket, 'create_connection', side_effect=AssertionError('network used')):
            result = audit.verify(self.evidence)
        self.assertEqual(result['selected_record_indices'], [3134, 918])
        self.assertEqual(result['observations'], 16)
        self.assertFalse(result['historical_pages_reconstructed'])

    def test_evidence_digest_is_pinned(self):
        changed = self.changed(); changed['observations'][0]['sample_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'formal evidence digest'):
            audit.verify(changed)

    def test_either_source_identity_and_rule_cannot_be_reassigned(self):
        for key in ('source', 'second_source'):
            for field, value in (('source_id', '0' * 64), ('selected_record_index', 0),
                                 ('normalized_legado_sha256', '0' * 64), ('source_key', 'other')):
                changed = self.changed(); changed[key][field] = value
                self.rejected(changed, 'source identity or rules|second selected source')

    def test_observed_paths_and_counts_are_frozen(self):
        for field in ('observations', 'second_observations'):
            changed = self.changed(); changed[field][1]['status'] = 404
            self.rejected(changed, 'observation digest mismatch')
            changed = self.changed(); changed[field][1]['old_list_selector_nodes'] = 1
            with patch.object(audit, 'SECOND_OBSERVATIONS_SHA' if field == 'second_observations' else 'OBSERVATIONS_SHA',
                              audit.sha(audit.canonical(changed[field]))):
                self.rejected(changed, 'bounded observation mismatch')

    def test_two_sources_not_promoted_to_host_wide_or_orphan_ban(self):
        for field in ('host_wide', 'orphan_history_id', 'claims_malware', 'claims_permanent_failure'):
            changed = self.changed(); changed['policy_scope'][field] = True
            self.rejected(changed, 'policy scope mismatch')

    def test_prior_zero_results_cannot_become_a_sale_heading(self):
        changed = self.changed(); changed['prior_pilot_search_observations'][0]['domain_sale_h1_count'] = 2
        self.rejected(changed, 'prior pilot observations mismatch')

    def test_sample_hashes_and_short_spacing_are_not_overstated(self):
        changed = self.changed()
        changed['second_observations'][0]['sample_sha256'] = changed['observations'][0]['sample_sha256']
        with patch.object(audit, 'SECOND_OBSERVATIONS_SHA', audit.sha(audit.canonical(changed['second_observations']))):
            self.rejected(changed, 'separate sample hashes lost')
        changed = self.changed(); changed['method']['whole_request_deadline_strict'] = True
        self.rejected(changed, 'method mismatch')
        changed = self.changed(); changed['method']['complete_nonpublic_and_multicast_exclusion_verified'] = True
        self.rejected(changed, 'method mismatch')

    def test_original_collectors_are_not_claimed_as_retained(self):
        changed = self.changed(); changed['collection_artifacts']['raw_pages_or_collectors_in_repository'] = True
        self.rejected(changed, 'collection provenance mismatch')

    def test_no_ip_url_query_or_raw_body(self):
        for value in ('192.0.2.1', '2001:db8::1'):
            changed = self.changed(); changed['extra'] = value
            self.rejected(changed, 'IP address retained')
        changed = self.changed(); changed['extra'] = 'https://example.invalid/?token=x'
        self.rejected(changed, 'query or page content retained')
        changed = self.changed(); changed['body'] = 'test'
        self.rejected(changed, 'raw payload or private field')


if __name__ == '__main__':
    unittest.main()
