import hashlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from verify_test_apks import ARCHITECTURES, CERTIFICATE, LIBRARIES, validate_apks


class TestApkValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.identity = {'avatarSha256': hashlib.sha256(b'avatar').hexdigest(),
                         'brandSha256': hashlib.sha256(b'brand').hexdigest()}
        self.badging_suffix = ''
        self.certificate = CERTIFICATE
        self.label = '红果TV（测试）'
        self.make_apks()

    def make_apks(self, wrong_elf=False, extra_abi=False):
        for abi, (_, elf_class, machine) in ARCHITECTURES.items():
            header = bytearray(20)
            header[:4] = b'\x7fELF'
            header[4] = elf_class
            header[5] = 1
            header[18:20] = struct.pack('<H', 62 if wrong_elf else machine)
            with zipfile.ZipFile(self.directory / f'HongguoTV-0.1.48-test.1-{abi}.apk', 'w') as archive:
                for library in LIBRARIES:
                    archive.writestr(f'lib/{abi}/{library}', header)
                if extra_abi:
                    archive.writestr('lib/x86_64/unexpected.so', header)
                archive.writestr('assets/flutter_assets/assets/app_identity/github-avatar.png', b'avatar')
                archive.writestr('assets/flutter_assets/assets/app_identity/app-icon.png', b'brand')

    def run_tool(self, *arguments):
        tool = Path(arguments[0]).name
        if tool == 'aapt':
            abi = 'arm64-v8a' if 'arm64-v8a' in arguments[-1] else 'armeabi-v7a'
            code = ARCHITECTURES[abi][0] + 73
            return (f"package: name='com.hongguo.tv' versionCode='{code}' versionName='0.1.48-test.1'\n"
                    f"sdkVersion:'26'\napplication-label:'{self.label}'\n" + self.badging_suffix)
        if tool == 'apksigner':
            return 'Number of signers: 1\nSigner #1 certificate SHA-256 digest: ' + self.certificate
        if tool == 'zipalign':
            self.assertEqual(arguments[1:6], ('-c', '-P', '16', '4', arguments[-1]))
            return ''
        raise AssertionError(arguments)

    def validate(self, version='0.1.48-test.1+73'):
        with patch('verify_test_apks.run', side_effect=self.run_tool):
            return validate_apks(self.directory, version, self.directory, self.identity)

    def test_two_arm_test_apks_keep_original_certificate_and_correct_upgrade_codes(self):
        results = self.validate()
        self.assertEqual([row['code'] for row in results], [2073, 1073])
        self.assertTrue(all(row['certificate'] == CERTIFICATE for row in results))
        for row in results:
            self.assertEqual(row['sha256'], hashlib.sha256((self.directory / row['name']).read_bytes()).hexdigest())

    def test_formal_version_and_unexpected_apks_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'test versions'):
            self.validate('0.1.48+73')
        (self.directory / 'stale.apk').write_bytes(b'stale')
        with self.assertRaisesRegex(ValueError, 'exactly the selected'):
            self.validate()

    def test_arm64_only_selection_validates_one_package(self):
        for apk in self.directory.glob('*-armeabi-v7a.apk'):
            apk.unlink()
        with patch('verify_test_apks.run', side_effect=self.run_tool):
            results = validate_apks(self.directory, '0.1.48-test.1+73', self.directory, self.identity, ['arm64-v8a'])
        self.assertEqual([row['abi'] for row in results], ['arm64-v8a'])
        self.assertEqual(results[0]['code'], 2073)

    def test_arm64_only_rejects_an_extra_armv7_package(self):
        with self.assertRaisesRegex(ValueError, 'exactly the selected'):
            validate_apks(self.directory, '0.1.48-test.1+73', self.directory, self.identity, ['arm64-v8a'])

    def test_wrong_signer_is_rejected(self):
        self.certificate = '0' * 64
        with self.assertRaisesRegex(ValueError, 'certificate'):
            self.validate()

    def test_missing_test_label_and_debug_or_test_only_installation_are_rejected(self):
        self.label = '红果TV'
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.validate()
        self.label = '红果TV（测试）'
        for flag in ['application-debuggable', 'application-testOnly']:
            self.badging_suffix = flag
            with self.assertRaisesRegex(ValueError, 'identity'):
                self.validate()

    def test_mislabeled_native_machine_and_extra_abi_are_rejected(self):
        self.make_apks(wrong_elf=True)
        with self.assertRaisesRegex(ValueError, 'architecture mismatch'):
            self.validate()
        self.make_apks(extra_abi=True)
        with self.assertRaisesRegex(ValueError, 'unexpected architectures'):
            self.validate()

    def test_modified_identity_asset_is_rejected(self):
        self.identity['brandSha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'Identity asset'):
            self.validate()


if __name__ == '__main__':
    unittest.main()
