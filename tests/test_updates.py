"""Reject release metadata mistakes before an archive can be published."""
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('appcast', ROOT / 'scripts/make-appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'Diktation-1.2.0.zip'
        self.feed = self.root / 'appcast.xml'
        self.config = dict(repository='Senooy/Diktation', public_ed_key='public-key',
                           feed_url='https://github.com/Senooy/Diktation/releases/latest/download/appcast.xml')
        self.info = dict(CFBundleIdentifier='dev.local.diktation', CFBundleVersion='1.2.0',
                         SUPublicEDKey=self.config['public_ed_key'], SUFeedURL=self.config['feed_url'],
                         SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
        self.write_archive()
        self.xml = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                    '<sparkle:version>1.2.0</sparkle:version><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>'
                    '<enclosure url="https://github.com/Senooy/Diktation/releases/download/v1.2.0/Diktation-1.2.0.zip" '
                    f'length="{self.archive.stat().st_size}" sparkle:edSignature="signature"/>'
                    '</item></channel></rss>')

    def write_archive(self):
        with zipfile.ZipFile(self.archive, 'w') as package:
            package.writestr('Diktation.app/Contents/Info.plist', plistlib.dumps(self.info))

    def verify(self, xml=None):
        self.feed.write_text(xml or self.xml)
        appcast.verify(self.feed, self.archive, '1.2.0', self.config)

    @patch.object(appcast.subprocess, 'run')
    def test_valid_metadata_requires_cryptographic_verification(self, run):
        self.verify()
        run.assert_called_once_with(['swift', str(ROOT / 'scripts/verify-update.swift'),
                                    str(self.archive), 'public-key', 'signature'], check=True)

    @patch.object(appcast.subprocess, 'run')
    def test_rejects_wrong_feed_metadata_before_verification(self, run):
        for old, new in [('v1.2.0/', 'v1.1.0/'), ('>1.2.0<', '>1.1.0<'),
                         ('>14.0<', '>13.0<'), ('Senooy/Diktation', 'other/repository'),
                         ('sparkle:edSignature="signature"', ''),
                         (f'length="{self.archive.stat().st_size}"', 'length="0"'),
                         ('</item>', '</item><item/>')]:
            with self.subTest(change=new), self.assertRaises(ValueError):
                self.verify(self.xml.replace(old, new))
        run.assert_not_called()

    @patch.object(appcast.subprocess, 'run')
    def test_rejects_wrong_archive_identity_or_security(self, run):
        for key in self.info.copy():
            original = self.info[key]
            self.info[key] = False if isinstance(original, bool) else 'wrong-value'
            self.write_archive()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify()
            self.info[key] = original
        run.assert_not_called()

    @patch.object(appcast.subprocess, 'run', side_effect=appcast.subprocess.CalledProcessError(1, 'swift'))
    def test_invalid_signature_prevents_success(self, run):
        with self.assertRaises(appcast.subprocess.CalledProcessError):
            self.verify()


if __name__ == '__main__':
    unittest.main()
