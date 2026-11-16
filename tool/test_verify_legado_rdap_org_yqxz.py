import copy
import json
import socket
import unittest
from pathlib import Path
from unittest.mock import patch

from tool import verify_legado_rdap_org_yqxz as audit


class OrgYqxzEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((audit.ROOT / audit.EVIDENCE).read_text(encoding='utf-8'))

    def changed(self):
        return copy.deepcopy(self.evidence)

    def verify_rejected(self, changed, message):
        with self.assertRaisesRegex(ValueError, message):
            audit.verify(changed, pinned=False)

    def test_offline_without_temporary_collector_or_network(self):
        original = Path.read_bytes
        def read_without_temporary_files(path):
            if 'build' in path.parts:
                raise AssertionError('temporary collector or draft was read')
            return original(path)
        with patch.object(Path, 'read_bytes', read_without_temporary_files), \
             patch.object(socket, 'create_connection', side_effect=AssertionError('network used')):
            result = audit.verify(self.evidence)
        self.assertEqual(result['rdap_matching_objects'], 2)
        self.assertEqual(result['old_host_nxdomain'], 7)
        self.assertEqual(result['old_host_timeout'], 1)
        self.assertFalse(result['raw_responses_reconstructed'])

    def test_immutable_evidence_digest(self):
        changed = self.changed()
        changed['rounds'][0]['observations'][0]['started_at'] = '2000-01-01T00:00:00+00:00'
        with self.assertRaisesRegex(ValueError, 'formal evidence digest'):
            audit.verify(changed)

    def test_source_index_and_rules_cannot_be_reassigned(self):
        for key, value in (('source_id', '0' * 64), ('selected_record_index', 1),
                           ('normalized_legado_sha256', '0' * 64), ('endpoint_sha256', '0' * 64)):
            changed = self.changed()
            changed['candidate']['selected_source'][key] = value
            self.verify_rejected(changed, 'historical selected source or rule')

    def test_archive_reference_is_fixed(self):
        changed = self.changed()
        changed['inputs']['archive']['sha256'] = '0' * 64
        self.verify_rejected(changed, 'input reference mismatch')

    def test_iana_cannot_be_reassigned_to_another_registry(self):
        changed = self.changed()
        changed['iana_bootstrap']['services']['org'] = ['https://other.example/']
        self.verify_rejected(changed, 'IANA observed bootstrap mapping')

    def test_old_timeout_is_not_changed_to_negative_dns(self):
        changed = self.changed()
        rows = changed['candidate']['historical_public_doh']
        rows[-1]['classification'] = 'nxdomain'
        self.verify_rejected(changed, 'historical DNS observations')
        changed = self.changed()
        row = next(r for r in changed['rounds'][1]['observations'] if r['classification'] == 'provider_timeout')
        row['classification'] = 'nxdomain'
        self.verify_rejected(changed, 'NXDOMAIN fields conflict')

    def test_current_unknown_dns_cannot_be_invented(self):
        changed = self.changed()
        row = next(r for r in changed['rounds'][1]['observations'] if r['classification'] == 'provider_timeout')
        row['dns_rcode'] = 3
        self.verify_rejected(changed, 'timeout was given a DNS result')

    def test_controls_cannot_be_forged(self):
        changed = self.changed()
        changed['rounds'][0]['control_status']['aliyun'] = False
        self.verify_rejected(changed, 'DoH control status mismatch')
        changed = self.changed()
        positive = next(r for r in changed['rounds'][0]['controls'] if r.get('domain') == 'google.org')
        positive['rdap_object_matches'] = False
        self.verify_rejected(changed, 'RDAP control status mismatch')

    def test_registered_domain_cannot_be_made_unregistered(self):
        changed = self.changed()
        row = next(r for r in changed['rounds'][0]['observations'] if r['mode'] == 'rdap')
        row['classification'] = 'http_404_json'
        row['http_status'] = 404
        self.verify_rejected(changed, 'RDAP matching object mismatch')

    def test_second_round_must_clear_observed_ttl(self):
        changed = self.changed()
        changed['cache_barrier']['minimum_wait_seconds'] = 30
        self.verify_rejected(changed, 'TTL barrier or round time')
        changed = self.changed()
        changed['rounds'][1]['started_at_utc'] = changed['rounds'][0]['completed_at_utc']
        self.verify_rejected(changed, 'TTL barrier or round time')

    def test_timeouts_must_not_be_silently_dropped(self):
        changed = self.changed()
        changed['rounds'][1]['observations'] = [
            row for row in changed['rounds'][1]['observations'] if row['classification'] != 'provider_timeout'
        ]
        self.verify_rejected(changed, 'candidate query coverage')

    def test_no_ip_query_or_credentials_in_artifact(self):
        for key, value, message in (('extra', '192.0.2.1', 'IP address retained'),
                                    ('extra', '2001:db8::1', 'IP address retained'),
                                    ('extra', 'https://example.invalid/?secret=x', 'query or page content'),
                                    ('cookie', 'not-a-cookie', 'raw private or network field')):
            changed = self.changed()
            changed[key] = value
            self.verify_rejected(changed, message)


if __name__ == '__main__':
    unittest.main()
