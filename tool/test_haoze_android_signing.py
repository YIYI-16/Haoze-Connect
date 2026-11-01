import base64
import hashlib
import os
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import patch

import haoze_android_signing as signing


class SigningPreparationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {'HAOZE_ANDROID_KEYSTORE_BASE64': base64.b64encode(b'test-store' * 100).decode(),
                    'HAOZE_ANDROID_STORE_PASSWORD': 'unit-secret', 'HAOZE_ANDROID_KEY_ALIAS': 'unit',
                    'HAOZE_ANDROID_KEY_PASSWORD': 'unit-secret'}
        self.pem = ssl.DER_cert_to_PEM_cert(b'unit-public-certificate')
        self.fingerprint = hashlib.sha256(b'unit-public-certificate').hexdigest()

    def prepare(self, fingerprint=None):
        def run(arguments):
            self.assertNotIn('unit-secret', arguments)
            return self.pem if '-exportcert' in arguments else ''
        with patch.dict(os.environ, self.env, clear=True), patch.object(signing, 'run_checked', side_effect=run), patch.object(signing, 'pinned_certificate', return_value=fingerprint or self.fingerprint):
            return signing.prepare(self.root / 'signing', self.root / 'github-env')

    def test_missing_credentials_fail_before_writing(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                signing.prepare(self.root / 'signing')
        self.assertFalse((self.root / 'signing').exists())

    def test_pinned_identity_and_private_permissions(self):
        key = self.prepare()
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(key.parent.stat().st_mode & 0o777, 0o700)
        exported = (self.root / 'github-env').read_text()
        self.assertEqual(exported, f'HAOZE_ANDROID_KEYSTORE_PATH={key.resolve()}\n')
        self.assertNotIn('unit-secret', exported)

    def test_unexpected_identity_is_removed(self):
        with self.assertRaises(ValueError):
            self.prepare('b' * 64)
        self.assertFalse((self.root / 'signing/release.p12').exists())
        self.assertFalse((self.root / 'github-env').exists())

    def test_existing_key_is_not_overwritten(self):
        key = self.prepare()
        before = key.read_bytes()
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(key.read_bytes(), before)

    def test_signing_directory_link_is_rejected(self):
        (self.root / 'other').mkdir()
        (self.root / 'signing').symlink_to(self.root / 'other', target_is_directory=True)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_manifest_requires_real_verification_metadata(self):
        import haoze_release_manifest as manifest
        apk = self.root / 'release.apk';apk.write_bytes(b'unit-artifact')
        exe = self.root / 'release.exe';exe.write_bytes(b'MZ-unit-installer')
        proof = self.root / 'proof.json';proof.write_text('{}')
        with self.assertRaises(KeyError):
            manifest.build_manifest(apk, exe, proof, 'a' * 40)

    def test_numbered_and_sdk_ranged_certificate_output(self):
        pin = signing.pinned_certificate()
        prefix = 'Number of signers: 1\nVerified using v2 scheme (APK Signature Scheme v2): true\n'
        signing.verify_signature_output(prefix + f'Signer #1 certificate SHA-256 digest: {pin}\n')
        ranges = ''.join(f'Signer (minSdkVersion={start}, maxSdkVersion={end}) certificate SHA-256 digest: {pin}\n'
                         for start, end in [(33, 2147483647), (24, 32)])
        signing.verify_signature_output(prefix + ranges)
        for invalid in [prefix + ranges.replace(pin, 'b' * 64, 1),
                        prefix.replace('signers: 1', 'signers: 2') + ranges,
                        prefix + ranges + f'Signer #2 certificate SHA-256 digest: {pin}\n',
                        prefix, ranges]:
            with self.assertRaises(ValueError):
                signing.verify_signature_output(invalid)


if __name__ == '__main__':
    unittest.main()
