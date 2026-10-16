import hashlib
from pathlib import Path
import tempfile
import unittest

from check_android_signing import availability, SIGNING_NAMES
from publish_android_stable import certificate, offsets, validate_apks


class AndroidStablePublishTests(unittest.TestCase):
    def test_signing_preflight_reports_presence_without_secret_values(self):
        env = {name: 'synthetic-secret-value' for name in SIGNING_NAMES}
        result = availability(env)
        self.assertTrue(result['ok'])
        self.assertNotIn('synthetic-secret-value', str(result))
        for name in SIGNING_NAMES:
            self.assertFalse(availability({k: v for k, v in env.items() if k != name})['ok'])

    def test_validation_blocks_wrong_certificate_code_abi_assets_or_tampered_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            rows = []
            for abi, offset in offsets.items():
                name = f'HongguoTV-0.1.16-{abi}.apk'
                (directory / name).write_bytes(b'synthetic signed package')
                rows.append(dict(name=name, package='com.hongguo.tv', abi=abi, version='0.1.16', code=offset + 41,
                    certificate=certificate, bytes=24, sha256=hashlib.sha256(b'synthetic signed package').hexdigest(),
                    crcVerified=True, zipAlignmentVerified=True, identityAssetsVerified=True))
            validate_apks(rows, '0.1.16', 41, directory)
            for field, value in [('certificate', 'wrong'), ('code', 2036), ('identityAssetsVerified', False)]:
                altered = [{**row} for row in rows];altered[0][field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    validate_apks(altered, '0.1.16', 41, directory)
            with self.assertRaises(ValueError):validate_apks(rows[:2], '0.1.16', 41, directory)
            (directory / rows[0]['name']).write_bytes(b'tampered')
            with self.assertRaises(ValueError):validate_apks(rows, '0.1.16', 41, directory)


if __name__ == '__main__':
    unittest.main()
