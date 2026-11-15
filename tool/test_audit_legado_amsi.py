"""Security and interpretation regressions for the local AMSI sampler."""

import json
import base64
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from tool import audit_legado_amsi as audit
from tool import audit_legado_amsi_clusters as clusters
from tool import recheck_legado_amsi as recheck
from tool import summarize_legado_amsi as summary
from tool.test_audit_legado_catalog import ConnectedSocket


class AmsiAuditTests(unittest.TestCase):
    def test_results_do_not_conflate_policy_errors_and_detections(self):
        self.assertEqual(audit.classify_scan(0, 1), 'not_detected')
        self.assertEqual(audit.classify_scan(0, 2), 'provider_risk_score')
        self.assertEqual(audit.classify_scan(0, 0x4000), 'blocked_by_admin')
        self.assertEqual(audit.classify_scan(0, 0x4fff), 'blocked_by_admin')
        self.assertEqual(audit.classify_scan(0, 0x5000), 'provider_risk_score')
        self.assertEqual(audit.classify_scan(0, 0x8000), 'detected')
        self.assertEqual(audit.classify_scan(0x80004005, 0), 'scan_error')
        self.assertEqual(audit.classify_scan(0, None), 'scan_error')

    def test_inline_scripts_are_bounded_and_incomplete_script_is_marked(self):
        markup = (b'<script src="https://do-not-fetch.example/x.js">' + b'x' * 9000
                  + b'</script><script></script><script>unfinished')
        stats, scripts = audit.extract_inline_scripts(markup)
        self.assertEqual(stats['script_tags_observed'], 3)
        self.assertEqual(stats['nonempty_inline_scripts_observed'], 2)
        self.assertEqual(len(scripts), 2)
        self.assertEqual(len(scripts[0][1]), 8192)
        self.assertTrue(scripts[0][0]['truncated'])
        self.assertTrue(scripts[0][0]['has_src_attribute'])
        self.assertTrue(scripts[1][0]['truncated'])
        self.assertFalse(scripts[1][0]['closing_tag_observed'])
        self.assertNotIn('unfinished', json.dumps(stats))
        markup = b''.join(b'<script>x</script>' for _ in range(audit.MAX_SCRIPTS + 2))
        stats, scripts = audit.extract_inline_scripts(markup)
        self.assertEqual(len(scripts), audit.MAX_SCRIPTS)
        self.assertEqual(stats['inline_scripts_omitted'], 2)

    def test_redirect_is_not_followed_or_read_and_payload_is_bounded(self):
        response = Mock(status=302)
        connection = Mock()
        limit = Mock()
        with patch.object(audit.http.client, 'HTTPResponse', return_value=response):
            result, payload = audit.sample_response(connection, 'example.com', limit)
        self.assertEqual(result['failure'], 'redirect_not_followed')
        self.assertIsNone(payload)
        response.read.assert_not_called()
        self.assertEqual(connection.sendall.call_count, 1)
        request = connection.sendall.call_args.args[0]
        self.assertTrue(request.startswith(b'GET / HTTP/1.1\r\n'))
        self.assertNotIn(b'Cookie:', request)
        response = Mock(status=200)
        response.getheader.side_effect = lambda name, default='': {'Content-Type': 'text/html',
                                                                    'Content-Encoding': ''}.get(name, default)
        response.read.return_value = b'a' * (audit.MAX_SAMPLE + 1)
        with patch.object(audit.http.client, 'HTTPResponse', return_value=response):
            result, payload = audit.sample_response(Mock(), 'example.com', limit)
        self.assertEqual(len(payload), audit.MAX_SAMPLE)
        self.assertTrue(result['truncated'])
        response.read.assert_called_once_with(audit.MAX_SAMPLE + 1)
        self.assertNotIn('a' * 32, json.dumps(result))

    def test_invalid_hosts_fail_before_dns_or_socket_use(self):
        with patch.object(audit, 'public_addresses') as dns:
            for host in ('localhost', 'example.local', 'user:pass@example.com', 'example.com/path'):
                with self.assertRaises(ValueError):
                    audit.fetch_root(host, 2)
        dns.assert_not_called()

    def test_rate_limiter_spaces_request_starts(self):
        fake = [10.0]
        def clock():
            return fake[0]
        def sleep(delay):
            fake[0] += delay
        limiter = audit.RateLimiter(0.25, clock, sleep)
        times = []
        for _ in range(3):
            limiter.wait()
            times.append(clock())
        self.assertEqual(times, [10.0, 10.25, 10.5])

    def test_slow_stream_obeys_overall_deadline(self):
        client, peer = socket.socketpair()
        connected, stop = ConnectedSocket(client), threading.Event()
        def server():
            try:
                peer.recv(4096)
                peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1000\r\n\r\n')
                while not stop.wait(0.02):
                    peer.sendall(b'a')
            except OSError:
                pass
            finally:
                peer.close()
        worker = threading.Thread(target=server, daemon=True)
        worker.start()
        try:
            with patch.object(audit, 'public_addresses', return_value=[(socket.AF_INET, '8.8.8.8')]), \
                 patch.object(audit.socket, 'socket', return_value=connected), \
                 patch('tool.audit_legado_catalog.TLS') as tls:
                tls.wrap_socket.side_effect = lambda sock, **kwargs: sock
                start = time.monotonic()
                with self.assertRaises(TimeoutError):
                    audit.fetch_root('example.com', 0.25)
                self.assertLess(time.monotonic() - start, 1.5)
        finally:
            stop.set()
            connected.close()
            worker.join(timeout=2)

    def test_scan_error_and_html_body_do_not_become_clean_or_persist(self):
        failed = Mock(returncode=1)
        with patch.object(audit.subprocess, 'run', return_value=failed):
            self.assertEqual(audit.scan_many_in_worker([b'abc'])[0]['classification'], 'scan_error')
        scan = {'phase': 'scan', 'hresult': '0x00000000', 'amsi_result': 1,
                'classification': 'not_detected'}
        entry = {'host': 'example.com', 'record_indices': [2], 'selected_source_ids': ['id']}
        with patch.object(audit, 'fetch_root', return_value=({'http_status': 200}, b'<script>secret</script>')):
            with patch.object(audit, 'scan_many_in_worker', return_value=[scan, scan]):
                result = audit.inspect(entry, Mock(), 2)
        self.assertEqual(len(result['inline_scripts']['samples']), 1)
        self.assertNotIn('secret', json.dumps(result))

    def test_static_atob_literal_decoding_does_not_evaluate_or_follow_links(self):
        url = b'https://example.test/path'
        script = b'atob("' + base64.b64encode(url) + b'"); atob(runtime_variable);'
        stats, samples = recheck.decode_atob_literals([({'ordinal': 1}, script)])
        self.assertEqual(stats['literal_calls_observed'], 1)
        self.assertEqual(samples[0][1], url)
        self.assertEqual(samples[0][0]['category'], 'http_url_text')
        self.assertTrue(samples[0][0]['contains_http_url'])
        self.assertNotIn('example.test', json.dumps(stats))
        self.assertNotIn('example.test', json.dumps(samples[0][0]))

    def test_static_navigation_requires_a_complete_direct_literal(self):
        script = (b'location.href="https://target.example/a";'
                  b'location="https://wrong.example/"+suffix;'
                  b'location.replace("/local");')
        data = recheck.literal_navigation([({'ordinal': 1}, script)], 'source.example')
        hosts = [x['target_host_defanged'] for x in data['direct_constant_targets']]
        self.assertEqual(hosts, ['target[.]example', 'source[.]example'])
        self.assertNotIn('wrong[.]example', hosts)
        self.assertEqual(data['location_mentions'], 3)

    def test_script_shape_ignores_literal_values_without_leaking_them(self):
        first = b'location.href="https://one.example/abc";var n=123;'
        second = b'location.href="https://two.example/def";var n=456;'
        self.assertEqual(recheck.shape_digest(first, 'one.example'),
                         recheck.shape_digest(second, 'two.example'))

    def test_cluster_selection_rechecks_only_detected_hosts(self):
        sample = {'archive_sha256': 'catalog', 'results': [
            {'host': 'clean.example', 'amsi': {'classification': 'not_detected'}},
            {'host': 'blocked.example', 'amsi': {'classification': 'blocked_by_admin'}},
            {'host': 'root.example', 'amsi': {'classification': 'detected'}},
            {'host': 'script.example', 'amsi': {'classification': 'not_detected'},
             'inline_scripts': {'samples': [{'amsi': {'classification': 'detected'}}]}}]}
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'input.json'
            path.write_text(json.dumps(sample), encoding='utf-8')
            _, selected = clusters.select_detections([path])
            self.assertEqual(set(selected), {'root.example', 'script.example'})
            with self.assertRaises(ValueError):
                clusters.select_detections([path, path])

    def test_summary_requires_exact_coverage_and_distinguishes_empty_pages(self):
        clean = {'phase': 'scan', 'hresult': '0x00000000', 'amsi_result': 1,
                 'classification': 'not_detected'}
        prior = {'archive_sha256': 'catalog', 'results': [{'host': 'a.example'}, {'host': 'b.example'}]}
        scan = {'archive_sha256': 'catalog', 'completed_at': 'end', 'started_at': 'start',
                'offset': 0, 'requested_hosts': 2, 'workers': 1,
                'minimum_request_start_interval_seconds': 0.5, 'network_deadline_seconds': 4,
                'results': [{'host': 'a.example', 'sample_bytes': 1, 'amsi': clean,
                             'selected_source_ids': ['id-1'], 'truncated': False},
                            {'host': 'b.example', 'sample_bytes': 0, 'failure': 'empty_html',
                             'selected_source_ids': ['id-2']}]}
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'input.json'
            path.write_text(json.dumps(scan), encoding='utf-8')
            result = summary.summarize(prior, [path])
            self.assertEqual(result['html_scanned_with_successful_hresult'], 1)
            self.assertEqual(result['hosts_without_successful_html_scan'], 1)
            self.assertEqual(result['selected_source_ids_with_successful_html_scan'], 1)
            with self.assertRaises(ValueError):
                summary.summarize(prior, [path, path])
            scan['results'][1]['amsi'] = clean
            path.write_text(json.dumps(scan), encoding='utf-8')
            with self.assertRaises(ValueError):
                summary.summarize(prior, [path])


if __name__ == '__main__':
    unittest.main()
