"""Offline safety and accounting checks for the bounded DoH audit."""

import json
import struct
import unittest
from unittest.mock import patch

from tool import audit_legado_doh_full as full
from tool import audit_legado_doh_pilot as pilot
from tool import classify_legado_doh as classify
from tool import verify_legado_doh as verify


class DohTests(unittest.TestCase):
    def test_dns_answer_is_classified_without_persisting_an_address(self):
        host, ident, qtype = 'example.test', 1234, 1
        question = pilot.name_wire(host) + struct.pack('!HH', qtype, 1)
        header = struct.pack('!HHHHHH', ident, 0x8180, 1, 1, 0, 0)
        record = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + b'\0' * 4
        result = pilot.parse_dns(header + question + record, ident, host, qtype)
        self.assertEqual(result['classification'], 'noerror_addresses')
        self.assertEqual(result['address_categories'], {'unspecified': 1})
        self.assertEqual(result['address_ttls_seconds'], [60])
        self.assertNotIn('0.0.0.0', json.dumps(result))
        with self.assertRaises(ValueError):
            pilot.parse_dns(header + question + record, ident + 1, host, qtype)

    def test_bad_dns_compression_and_invalid_host_are_rejected(self):
        with self.assertRaises(ValueError):
            pilot.read_name(b'\xc0\x00', 0)
        for name in ('localhost', 'user@example.test', 'example.test/path'):
            with self.assertRaises(ValueError):
                pilot.name_wire(name)

    def test_provider_controls_require_a_valid_public_a_answer(self):
        values = {(provider, typ): {'http_status': 200, 'dns_rcode': 0,
                                    'address_categories': {'public': 1} if typ == 'A' else {}}
                  for provider in pilot.PROVIDERS for typ in pilot.TYPES}
        self.assertTrue(full.control_ok(values))
        values[('aliyun', 'A')]['address_categories'] = {'unspecified': 1}
        self.assertFalse(full.control_ok(values))

    def test_metrics_keep_errors_and_resolver_disagreement_distinct(self):
        hosts = {'a.example': {'host': 'a.example', 'baseline': 'repeated_nxdomain',
                               'selected_source_ids': ['id-a']},
                 'b.example': {'host': 'b.example', 'baseline': 'repeated_unspecified',
                               'selected_source_ids': ['id-b']}}
        observations = {}
        for host in hosts:
            for provider in pilot.PROVIDERS:
                for typ in pilot.TYPES:
                    classification = 'nxdomain' if host == 'a.example' else 'noerror_no_address'
                    observations[(host, provider, typ)] = {'provider': provider, 'query_type': typ,
                                                            'classification': classification}
        observations[('a.example', 'tencent', 'A')]['classification'] = 'provider_timeout'
        observations[('b.example', 'aliyun', 'A')].update(
            classification='noerror_addresses', address_categories={'public': 1})
        result = full.metrics(hosts, observations)
        nx = result['repeated_nxdomain']['host_observations']
        self.assertEqual(nx['one_or_more_dns_or_transport_errors'], 1)
        self.assertNotIn('both_providers_nxdomain_for_a_and_aaaa', nx)
        other = result['repeated_unspecified']['host_observations']
        self.assertEqual(other['at_least_one_provider_public_address'], 1)
        self.assertEqual(other['provider_disagreement_at_least_one_type'], 1)
        refined = classify.summarize(hosts, observations)
        nx_refined = refined['repeated_nxdomain']['host_observations']
        self.assertEqual(nx_refined['one_or_more_dns_or_transport_errors'], 1)
        self.assertNotIn('valid_provider_category_disagreement', nx_refined)
        other_refined = refined['repeated_unspecified']['host_observations']
        self.assertEqual(other_refined['valid_provider_category_disagreement'], 1)

    def test_offline_verifier_recomputes_and_rejects_raw_answer_fields(self):
        hosts = {'a.example': {'host': 'a.example', 'baseline': 'repeated_nxdomain',
                               'record_indices': [1], 'selected_source_ids': ['id-a']}}
        observations = {(host, provider, typ): {'host': host, 'baseline': 'repeated_nxdomain',
                                                'provider': provider, 'query_type': typ,
                                                'classification': 'nxdomain', 'http_status': 200,
                                                'dns_rcode': 3, 'response_sha256': 'a' * 64}
                        for host in hosts for provider in pilot.PROVIDERS for typ in pilot.TYPES}
        controls = [{'host': 'example.com', 'baseline': 'control', 'provider': provider,
                     'query_type': typ, 'http_status': 200, 'dns_rcode': 0,
                     'classification': 'noerror_addresses' if typ == 'A' else 'noerror_no_address',
                     'response_sha256': 'b' * 64,
                     'address_categories': {'public': 1} if typ == 'A' else {}}
                    for provider in pilot.PROVIDERS for typ in pilot.TYPES]
        evidence = {'completed_at': 'time', 'head_recheck_sha256': 'head',
                    'address_recheck_sha256': 'address', 'pilot_sha256': 'pilot',
                    'archive_sha256': 'archive', 'providers': pilot.PROVIDERS,
                    'control_queries': controls, 'completed_queries': 4, 'pilot_hosts_reused': 0,
                    'results': [{**hosts['a.example'], 'observations': [
                        full.compact_observation(row) for row in observations.values()]}],
                    'summary': full.metrics(hosts, observations)}
        head = {'archive_sha256': 'archive'}
        addresses = {'archive_sha256': 'archive', 'parent_recheck_sha256': 'head'}
        with patch.object(audit := verify.audit, 'groups', return_value=hosts), \
             patch.object(audit, 'validated_pilot', return_value=({}, set())), \
             patch.object(pilot, 'choose', return_value=([], 0, 0)):
            self.assertEqual(verify.verify(evidence, head, 'head', addresses, 'address', {}, 'pilot'),
                             evidence['summary'])
            evidence['results'][0]['observations'][0]['data'] = 'redacted'
            with self.assertRaises(ValueError):
                verify.verify(evidence, head, 'head', addresses, 'address', {}, 'pilot')


if __name__ == '__main__':
    unittest.main()
