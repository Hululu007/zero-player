"""Regression tests for the offline HEAD/GET evidence join."""

import copy
import unittest

from tool import compare_legado_head_get as audit


def fixture():
    first_at, second_at = '2026-11-15T01:00:00+00:00', '2026-11-15T02:00:00+00:00'
    get_at, get_end = '2026-11-15T03:00:00+00:00', '2026-11-15T03:00:01+00:00'
    first = {'archive_sha256': 'catalog', 'results': [
        {'host': 'a.test', 'observed_at': first_at, 'record_indices': [0]},
        {'host': 'b.test', 'observed_at': first_at, 'record_indices': [1]},
        {'host': 'c.test', 'observed_at': first_at, 'record_indices': [2], 'status': 200}]}
    def head(host, index, ident):
        return {'host': host, 'record_indices': [index], 'selected_source_ids': [ident],
                'previous': {'observed_at': first_at, 'classification': 'timeout'},
                'recheck': {'observed_at': second_at, 'classification': 'tls_error'}}
    second = {'archive_sha256': 'catalog', 'first_audit_sha256': 'first',
              'import_inventory_sha256': 'inventory',
              'results': [head('a.test', 0, 'a'), head('b.test', 1, 'b')]}
    inventory = {'archive_sha256': 'catalog', 'generated_at': first_at, 'import_code_sha256': {},
                 'selected_sources': [{'host': 'a.test', 'id': 'a'}, {'host': 'b.test', 'id': 'b'}]}
    def get(host, index, ids):
        return {'host': host, 'record_indices': [index], 'selected_source_ids': ids,
                'started_at': get_at, 'sample_observed_at': get_end}
    a = {**get('a.test', 0, ['a']), 'http_status': 200, 'sample_bytes': 10,
         'amsi': {'hresult': '0x00000000', 'amsi_result': 1, 'classification': 'not_detected'}}
    b = {**get('b.test', 1, ['b']), 'failure': 'timeout'}
    c = {**get('c.test', 2, []), 'http_status': 403}
    stages = [{'archive_sha256': 'catalog', 'prior_audit_sha256': 'first',
               'import_inventory_sha256': 'inventory', 'completed_at': get_end,
               'requested_hosts': 3, 'results': [a, b, c]}]
    return first, second, inventory, stages


class HeadGetTests(unittest.TestCase):
    def test_only_later_get_status_counts_as_response(self):
        first, second, inventory, stages = fixture()
        result = audit.compare(first, 'first', second, inventory, 'inventory', stages)
        self.assertEqual(result['both_heads_no_status']['hosts'], 2)
        self.assertEqual(result['later_get_status']['hosts'], 1)
        self.assertEqual(result['later_get_no_status']['hosts'], 1)
        self.assertEqual(result['later_get_status']['by_category']['nonempty_html_scanned']['selected_ids'], 1)
        self.assertEqual(result['responded_hosts'][0]['host'], 'a.test')

    def test_scan_error_is_not_a_successful_html_scan(self):
        sample = {'http_status': 200, 'sample_bytes': 10,
                  'amsi': {'hresult': '0x80004005', 'amsi_result': None, 'classification': 'scan_error'}}
        self.assertEqual(audit.get_category(sample), 'nonempty_html_scan_unavailable')

    def test_duplicate_hosts_bad_status_and_time_order_are_rejected(self):
        first, second, inventory, stages = fixture()
        duplicate = copy.deepcopy(stages)
        duplicate[0]['results'].append(duplicate[0]['results'][0])
        duplicate[0]['requested_hosts'] += 1
        with self.assertRaises(ValueError):
            audit.compare(first, 'first', second, inventory, 'inventory', duplicate)
        bad_status = copy.deepcopy(stages)
        bad_status[0]['results'][0]['http_status'] = None
        with self.assertRaises(ValueError):
            audit.compare(first, 'first', second, inventory, 'inventory', bad_status)
        bad_time = copy.deepcopy(stages)
        bad_time[0]['results'][0]['started_at'] = '2026-11-15T01:30:00+00:00'
        with self.assertRaises(ValueError):
            audit.compare(first, 'first', second, inventory, 'inventory', bad_time)


if __name__ == '__main__':
    unittest.main()
