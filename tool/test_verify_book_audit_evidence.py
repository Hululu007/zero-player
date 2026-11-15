import hashlib
import tempfile
import unittest
from pathlib import Path

from tool.verify_book_audit_evidence import EvidenceVerifier, ROOT


class EvidenceIntegrityTests(unittest.TestCase):
    def test_repository_evidence_links_are_consistent(self):
        self.assertGreater(EvidenceVerifier(ROOT).verify(), 40)

    def test_changed_or_missing_evidence_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'evidence.json'
            target.write_bytes(b'original')
            digest = hashlib.sha256(b'original').hexdigest()
            verifier = EvidenceVerifier(directory)
            verifier.check_digest(target, digest)
            target.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                EvidenceVerifier(directory).check_digest(target, digest)
            with self.assertRaises(FileNotFoundError):
                EvidenceVerifier(directory).check_digest(target.with_name('missing'), digest)

    def test_malformed_digest_is_rejected(self):
        with self.assertRaises(ValueError):
            EvidenceVerifier(ROOT).check_digest(ROOT / 'missing', 'not-a-hash')

    def test_ledger_paths_cannot_escape_the_workspace(self):
        verifier = EvidenceVerifier(ROOT)
        for path in ('../secret', 'lib/../../secret', 'lib\\secret', '/lib/secret'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                verifier.ledger_path(path, ('lib',))

    def test_source_snapshot_accepts_equivalent_windows_line_endings(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'source.dart'
            target.write_bytes(b'a\r\nb\r\n')
            digest = hashlib.sha256(b'a\nb\n').hexdigest()
            EvidenceVerifier(directory).check_digest(target, digest, normalize_lf=True)
            with self.assertRaises(ValueError):
                EvidenceVerifier(directory).check_digest(target, digest)


if __name__ == '__main__':
    unittest.main()
