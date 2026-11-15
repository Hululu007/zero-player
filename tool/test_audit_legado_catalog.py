"""Safety and interpretation regression tests for the catalog probe."""

import socket
import threading
import time
import unittest
from unittest.mock import patch

from tool import audit_legado_catalog as audit
from tool import audit_legado_adult_metadata as metadata
from tool import audit_legado_rule_patterns as patterns


class ConnectedSocket:
    """Use a local socket pair to exercise HTTP reads without real TLS/network."""

    def __init__(self, connection):
        self.connection = connection

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def connect(self, address):
        pass

    def settimeout(self, timeout):
        self.connection.settimeout(timeout)

    def do_handshake(self):
        pass

    def sendall(self, data):
        self.connection.sendall(data)

    def makefile(self, *args, **kwargs):
        return self.connection.makefile(*args, **kwargs)

    def shutdown(self, how):
        self.connection.shutdown(how)

    def close(self):
        self.connection.close()


class CatalogAuditTest(unittest.TestCase):
    def test_target_validation_and_legacy_upgrade(self):
        self.assertEqual(audit.hostname('http://example.com/path,{"method":"POST"}'), 'example.com')
        self.assertEqual(audit.hostname('www.example.com', allow_alias=True), 'www.example.com')
        self.assertEqual(audit.hostname('https://example.com#identity label'), 'example.com')
        for value in ('https://127.0.0.1/', 'https://user@example.com/',
                      'https://example.com:8443/', 'http://example.com:443/',
                      'https://host.internal/', 'https://example.com\\@evil.com/',
                      'https://example.com/\r\nHeader:x'):
            with self.subTest(value=value):
                self.assertIsNone(audit.hostname(value))

    @patch('tool.audit_legado_catalog.socket.getaddrinfo')
    def test_mixed_public_and_private_dns_is_never_connected(self, lookup):
        lookup.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('8.8.8.8', 443)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('127.0.0.1', 443)),
        ]
        with patch('tool.audit_legado_catalog.socket.socket') as connection:
            result = audit.probe('example.com', 3, False)
        self.assertIn('non-public', result['error'])
        connection.assert_not_called()

    def test_redirect_is_observed_not_followed(self):
        self.assertEqual(audit.destination('old.example', 'https://www.hugedomains.com/domain_profile.cfm?secret=x'),
                         {'redirect_host': 'www.hugedomains.com', 'redirect_scheme': 'https', 'redirect': 'parking'})
        self.assertEqual(audit.destination('old.example', '/new')['redirect'], 'same_host')
        self.assertEqual(audit.destination('old.example', 'javascript:alert(1)')['redirect'], 'invalid')
        self.assertEqual(audit.destination('old.example', '')['redirect'], 'invalid')
        with patch('tool.audit_legado_catalog.fetch', return_value={'status': 302, 'redirect': 'other_host'}) as fetch:
            audit.probe('old.example', 3, True)
        fetch.assert_called_once()

    def test_get_failure_preserves_successful_head(self):
        with patch('tool.audit_legado_catalog.fetch', side_effect=[{'status': 200}, TimeoutError('GET timed out')]):
            result = audit.probe('example.com', 3, True)
        self.assertEqual(result['status'], 200)
        self.assertNotIn('error', result)
        self.assertIn('TimeoutError', result['sample']['error'])

    def test_resolver_deadline_bounds_wait(self):
        release = threading.Event()
        try:
            with patch('tool.audit_legado_catalog.socket.getaddrinfo', side_effect=lambda *a, **k: release.wait(2)):
                with self.assertRaises(TimeoutError):
                    audit._bounded_lookup('example.com', 0.02)
        finally:
            release.set()

    def test_trickling_headers_and_body_obey_overall_deadline(self):
        for phase in ('headers', 'body'):
            with self.subTest(phase=phase):
                client, peer = socket.socketpair()
                connected = ConnectedSocket(client)
                stop = threading.Event()

                def server():
                    try:
                        peer.recv(4096)
                        initial = (b'HTTP/1.1 200 OK\r\nX-Slow: ' if phase == 'headers' else
                                   b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n'
                                   b'Content-Length: 1000\r\n\r\n')
                        peer.sendall(initial)
                        end = time.monotonic() + 2
                        while time.monotonic() < end and not stop.wait(0.02):
                            peer.sendall(b'a')
                    except OSError:
                        pass
                    finally:
                        peer.close()

                worker = threading.Thread(target=server, daemon=True)
                worker.start()
                try:
                    with patch('tool.audit_legado_catalog.public_addresses',
                               return_value=[(socket.AF_INET, '8.8.8.8')]), \
                         patch('tool.audit_legado_catalog.socket.socket', return_value=connected), \
                         patch('tool.audit_legado_catalog.TLS') as tls:
                        tls.wrap_socket.side_effect = lambda sock, **kwargs: sock
                        started = time.monotonic()
                        with self.assertRaisesRegex(TimeoutError, 'deadline'):
                            audit.fetch('example.com', 'GET', 0.25)
                        elapsed = time.monotonic() - started
                    self.assertLess(elapsed, 1.5, 'progress must not reset the overall deadline')
                finally:
                    stop.set()
                    connected.close()
                    worker.join(timeout=2.5)

    def test_only_visible_sample_contributes_to_signals(self):
        sample = ('<title>网上赌场</title><script>成人小说</script>'
                  '<div>内容正常</div>').encode()
        result = audit.signals(sample, 'utf-8')
        self.assertEqual(result['title'], '网上赌场')
        self.assertEqual(result['betting_signals'], ['网上赌场'])
        self.assertEqual(result['adult_signals'], [])
        encoded = '<meta charset="gb2312"><title>成人小说</title>'.encode('gb18030')
        self.assertEqual(audit.signals(encoded, None)['adult_signals'], ['成人小说'])

    def test_adult_evidence_survives_variant_deduplication(self):
        inventory = {'archive_sha256': 'digest',
                     'raw_parseable': [{'index': 4, 'id': 'same-id', 'host': 'example.com',
                                        'name': '旧标签🔞', 'group': ''},
                                       {'index': 5, 'id': 'same-id', 'host': 'example.com',
                                        'name': '新标签', 'group': ''}],
                     'selected_sources': [{'id': 'same-id', 'name': '新标签', 'group': '',
                                           'kind': 'text', 'host': 'example.com'}]}
        result = metadata.summarize(inventory)
        self.assertEqual(result['labelled_id_count'], 1)
        self.assertEqual(result['selected_label_absent_count'], 1)
        self.assertEqual(result['sources'][0]['raw_label_evidence'][0]['index'], 4)

    def test_rule_scan_keeps_cooccurrence_separate_from_exact_template(self):
        fixture = {'ruleContent': {'content': "eval('local'); fetch('https://example.com/');"},
                   'ruleSearch': {'bookList': 'global.wesrc = [global.okhttp.client.newCall(request)'
                                  '.execute().body().string()]; eval([new global.okhttp.JString('
                                  'android.util.Base64.decode(global.wesrc, 0))])'},
                   'noncandidate': 'eval(1)'}
        fields = {field['path']: field for field in patterns.candidates(fixture)}
        self.assertEqual(set(fields), {'ruleContent.content', 'ruleSearch.bookList'})
        self.assertFalse(fields['ruleContent.content']['wesrc_template'])
        self.assertEqual(fields['ruleContent.content']['literal_url_hosts'], ['example.com'])
        self.assertTrue(fields['ruleSearch.bookList']['wesrc_template'])


if __name__ == '__main__':
    unittest.main()
