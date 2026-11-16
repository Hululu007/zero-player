"""Check feed integrity, snapshot identity and domain matching boundaries."""

import hashlib
import json
import unittest

from tool import audit_phishing_army_legado as audit


def sha(content):
    return hashlib.sha256(content).hexdigest()


class PhishingArmyAuditTests(unittest.TestCase):
    def setUp(self):
        self.feed = b'parent.example\nother.example\n'
        self.manifest = json.dumps({
            'schema_version': 1,
            'generated_at': '2026-11-15T23:00:00Z',
            'entries': 2,
            'files': {audit.FEED_NAME: {'bytes': len(self.feed), 'sha256': sha(self.feed)}},
        }).encode()
        self.feed_meta = self.meta(self.feed, audit.FEED_URL)
        self.manifest_meta = self.meta(self.manifest, audit.MANIFEST_URL)

    def meta(self, content, endpoint):
        return {'endpoint': endpoint, 'status': 200, 'bytes': len(content),
                'sha256': sha(content), 'observed_at': '2026-11-16T00:00:00Z'}

    def parse(self, feed=None, manifest=None, feed_meta=None, manifest_meta=None):
        return audit.parse_snapshot(
            feed if feed is not None else self.feed,
            manifest if manifest is not None else self.manifest,
            manifest_meta if manifest_meta is not None else self.manifest_meta,
            feed_meta if feed_meta is not None else self.feed_meta,
        )

    def test_only_exact_and_listed_parent_relations_match(self):
        indicators, _ = self.parse()
        refs = {'child.parent.example': {(0, 'declared_endpoint')},
                'parent.example': {(1, 'bookSourceComment')},
                'sibling.example': {(2, 'declared_endpoint')},
                'parent.example.evil': {(3, 'declared_endpoint')}}
        parsed = {0: {'id': 'selected'}, 1: {'id': 'older'}}
        matches = audit.compare(refs, parsed, {'selected': 0, 'older': 9}, indicators)
        self.assertEqual([(m['catalog_host'], m['relation']) for m in matches], [
            ('child.parent.example', 'listed_parent'), ('parent.example', 'exact')])
        self.assertTrue(matches[0]['catalog_references'][0]['selected_version'])
        self.assertFalse(matches[1]['catalog_references'][0]['selected_version'])

    def test_rejects_changed_bytes_and_wrong_download_origin(self):
        with self.assertRaises(ValueError):
            self.parse(feed=self.feed + b'x')
        wrong = dict(self.feed_meta, endpoint='https://elsewhere.example/list')
        with self.assertRaises(ValueError):
            self.parse(feed_meta=wrong)

    def test_rejects_manifest_for_different_feed(self):
        changed = self.feed.replace(b'other', b'third')
        with self.assertRaises(ValueError):
            self.parse(feed=changed, feed_meta=self.meta(changed, audit.FEED_URL))

    def test_rejects_invalid_domains_and_duplicate_entries(self):
        for feed in (b'parent.example\nhttps://bad.example/\n',
                     b'parent.example\nparent.example\n'):
            info = json.loads(self.manifest)
            info['files'][audit.FEED_NAME] = {'bytes': len(feed), 'sha256': sha(feed)}
            manifest = json.dumps(info).encode()
            with self.assertRaises(ValueError):
                self.parse(feed=feed, feed_meta=self.meta(feed, audit.FEED_URL),
                           manifest=manifest, manifest_meta=self.meta(manifest, audit.MANIFEST_URL))


if __name__ == '__main__':
    unittest.main()
