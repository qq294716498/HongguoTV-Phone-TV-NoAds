import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from check_android_signing import availability, SIGNING_NAMES
import publish_android_stable as publish
from publish_android_stable import certificate, offsets, validate_apks


class AndroidStablePublishTests(unittest.TestCase):
    def test_published_windows_baseline_is_verified_and_preserved_without_republishing(self):
        assets = [{'id': n, 'name': name, 'size': 1, 'digest': 'sha256:synthetic'}
                  for n, name in enumerate(['Windows-update-check.json', 'Windows-update-channel.json',
                                           'Android-isolation.json', 'SHA256SUMS.txt'])]
        old = dict(id=1, tag_name='windows-v0.1.15-40', target_commitish='old', draft=False, prerelease=False, assets=[])
        current = dict(id=2, tag_name=publish.windows_tag, target_commitish='current', draft=False, prerelease=False, assets=assets)
        def releases(tag):
            return current if tag == publish.windows_tag else old
        with mock.patch.object(publish, 'release', side_effect=releases):
            self.assertEqual(set(publish.validated_windows_snapshots('current')), set(publish.windows_tags))
            with self.assertRaisesRegex(ValueError, 'Windows baseline'):
                publish.validated_windows_snapshots('different')
            for field, value in [('assets', assets[:-1]), ('draft', True), ('prerelease', True)]:
                previous = current[field]
                current[field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    publish.validated_windows_snapshots('current')
                current[field] = previous

    def test_release_scope_rejects_windows_runtime_and_other_unapproved_changes(self):
        with mock.patch.object(publish.subprocess, 'check_output', side_effect=[publish.tv_source, 'README.md\n.github/workflows/android-stable.yml\n']):
            publish.validate_release_source('candidate')
        for changed in ['lib/windows_desktop.dart', 'lib/player_screen.dart', 'pubspec.yaml']:
            with mock.patch.object(publish.subprocess, 'check_output', side_effect=[publish.tv_source, changed]), self.subTest(changed=changed), self.assertRaisesRegex(ValueError, 'Runtime source changed'):
                publish.validate_release_source('candidate')
        with mock.patch.object(publish.subprocess, 'check_output', return_value='other'), self.assertRaisesRegex(ValueError, 'approved TV source'):
            publish.validate_release_source('candidate')

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
