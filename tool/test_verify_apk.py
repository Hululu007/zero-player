"""Protect the approved handwriting/system font distribution policy."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


class FontDistributionTests(unittest.TestCase):
    def verify(self, fonts):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'font-policy.apk'
            with ZipFile(apk, 'w', compression=ZIP_DEFLATED) as archive:
                for library in ['libflutter.so', 'libmpv.so', 'libffmpegkit.so',
                                'libsqlite3.so', 'libapp.so']:
                    archive.writestr('lib/arm64-v8a/' + library, b'fixture')
                for font in fonts:
                    archive.writestr('assets/flutter_assets/assets/fonts/' + font,
                                     b'fixture')
            return subprocess.run(
                [sys.executable, str(Path(__file__).with_name('verify_apk.py')),
                 str(apk), '--abis', 'arm64-v8a', '--compressed-native'],
                text=True, capture_output=True, check=False)

    def test_handwriting_with_device_fonts_is_accepted(self):
        result = self.verify(['Xiaolai-Regular.ttf'])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_handwriting_cannot_be_omitted(self):
        result = self.verify([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing user-selectable font', result.stderr)

    def test_removed_bundled_faces_are_rejected(self):
        for font in ['NotoSansSC.ttf', 'NotoSerifSC.ttf']:
            with self.subTest(font=font):
                result = self.verify(['Xiaolai-Regular.ttf', font])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Removed bundled font', result.stderr)


if __name__ == '__main__':
    unittest.main()
