"""Classification regressions for the second-pass source audit."""

import unittest
import ctypes

from tool import recheck_legado_failures as audit
from tool import recheck_legado_dns_answers as dns


class RecheckClassificationTest(unittest.TestCase):
    def test_http_response_does_not_claim_readability(self):
        self.assertEqual(audit.classification({'status': 200}), 'http_200')
        self.assertEqual(audit.classification({'status': 302}), 'http_redirect')
        self.assertEqual(audit.classification({'status': 403}), 'http_restricted')
        self.assertEqual(audit.classification({'status': 404}), 'http_other')

    def test_dns_timeout_tls_and_connection_errors_remain_distinct(self):
        for error, expected in [
            ('dns: [Errno 11001] getaddrinfo failed', 'dns_host_not_found'),
            ('dns: [Errno 11004] getaddrinfo failed', 'dns_no_data'),
            ('TimeoutError: DNS deadline exceeded', 'dns_timeout'),
            ('TimeoutError: overall request deadline exceeded', 'connection_or_read_timeout'),
            ('SSLCertVerificationError: expired', 'tls_error'),
            ('ConnectionRefusedError: refused', 'connection_error'),
            ('ValueError: DNS includes a non-public address', 'non_public_dns_rejected'),
        ]:
            with self.subTest(error=error):
                self.assertEqual(audit.classification({'error': error}), expected)

    def test_nxdomain_requires_two_consistent_dns_observations(self):
        missing = {'a': 9003, 'aaaa': 9501}
        self.assertEqual(audit.dns_verdict([missing]), 'unconfirmed')
        self.assertEqual(audit.dns_verdict([missing, missing]), 'repeated_nxdomain')
        self.assertEqual(audit.dns_verdict([missing, {'a': 0, 'aaaa': 9003}]), 'dns_reply_seen')
        self.assertEqual(audit.dns_verdict([{'a': 0, 'aaaa': 9501}]), 'dns_reply_seen')
        self.assertEqual(audit.dns_verdict([missing, {'error': 'deadline'}]), 'unconfirmed')
        empty = {'a': 9501, 'aaaa': 9501}
        self.assertEqual(audit.dns_verdict([empty, empty]), 'repeated_no_records')
        self.assertEqual(audit.dns_verdict([missing, empty]), 'inconclusive')

    def test_ids_are_associated_by_actual_selected_host(self):
        sources = {'selected_sources': [
            {'id': '1', 'host': 'example.com'},
            {'id': '2', 'host': 'example.com'},
            {'id': '3', 'host': 'other.example.com'},
        ]}
        self.assertEqual(audit.source_index(sources), {
            'example.com': ['1', '2'], 'other.example.com': ['3'],
        })

    def test_address_categories_do_not_report_unspecified_as_public(self):
        record = audit.DnsRecord()
        record.record_type = 1
        record.data[:4] = (0, 0, 0, 0)
        self.assertEqual(audit._address_kinds(ctypes.addressof(record)), {'unspecified': 1})
        record.data[:4] = (8, 8, 8, 8)
        self.assertEqual(audit._address_kinds(ctypes.addressof(record)), {'public': 1})
        record.data[:4] = (127, 0, 0, 1)
        self.assertEqual(audit._address_kinds(ctypes.addressof(record)), {'other_non_public': 1})

    def test_repeated_unspecified_and_mixed_dns_stay_distinct(self):
        unspecified = {'a_address_kinds': {'unspecified': 1}, 'aaaa_address_kinds': {}}
        public = {'a_address_kinds': {'public': 1}, 'aaaa_address_kinds': {}}
        private = {'a_address_kinds': {'other_non_public': 1}, 'aaaa_address_kinds': {}}
        self.assertEqual(dns.address_verdict([unspecified, unspecified]), 'repeated_unspecified_address')
        self.assertEqual(dns.address_verdict([unspecified, public]), 'public_address_observed')
        self.assertEqual(dns.address_verdict([unspecified, private]), 'other_non_public_address_observed')
        self.assertEqual(dns.address_verdict([unspecified, {'error': 'deadline'}]), 'dns_query_timeout_or_error')


if __name__ == '__main__':
    unittest.main()
