import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import publish_windows_preview as publish


class WindowsPublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'dist/windows'
        self.output.mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 0.1.13-preview.1+37\n', encoding='utf-8')
        self.package = self.output / 'HongguoTV-0.1.13-preview.1-windows-x64.zip'
        self.package.write_bytes(b'synthetic package')
        self.smoke = {name: True for name in [
            'ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux',
            'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'playbackPower',
            'fullscreen', 'mediaKitPlayback', 'cleanPath', 'nonAsciiPath', 'differentWorkingDirectory', 'javaEnvironmentRemoved']}
        self.smoke.update(processExitCode=0, version='0.1.13-preview.1', build=37)
        self.write('Windows-smoke.json', self.smoke)
        self.write('Windows-validation.json', {
            'ok': True, 'architecture': 'x64', 'build': 37, 'version': '0.1.13-preview.1',
            'sha256': hashlib.sha256(self.package.read_bytes()).hexdigest()})
        self.write('Windows-signature.json', {'status': 'NotSigned', 'signed': False})
        self.android = {'id': 1, 'tag': 'app-v0.1.12-36', 'assets': [{'id': 2, 'digest': 'old'}]}
        self.write('Android-isolation.json', {'before': self.android, 'androidParserUnchanged': True})
        self.update = {'ok': True, 'windowsTag': 'windows-v0.1.13-preview.1-37', 'androidLatest': self.android['tag']}
        self.write('Windows-update-check.json', self.update)
        for patch in [mock.patch.object(publish, 'root', self.root),
                      mock.patch.object(publish, 'output', self.output),
                      mock.patch.object(publish.os, 'chdir')]:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, name, value):
        (self.output / name).write_text(json.dumps(value), encoding='utf-8')

    def run_command(self, command):
        with mock.patch('sys.argv', ['publish_windows_preview.py', command]):
            publish.main()

    def test_incomplete_smoke_and_invalid_signing_block_release_before_github(self):
        with mock.patch.object(publish.subprocess, 'run') as github:
            for field in ['videoFrameRendered', 'nativeCore', 'cleanPath', 'playbackPower']:
                self.write('Windows-smoke.json', {**self.smoke, field: False})
                with self.subTest(field=field), self.assertRaises(ValueError):
                    self.run_command('stage')
            self.write('Windows-smoke.json', self.smoke)
            self.write('Windows-signature.json', {'status': 'UnknownError', 'signed': False})
            with self.assertRaises(ValueError):
                self.run_command('stage')
            github.assert_not_called()

    def test_existing_release_is_never_overwritten(self):
        with mock.patch.object(publish.subprocess, 'run', return_value=mock.Mock(returncode=0)) as github:
            with self.assertRaisesRegex(ValueError, 'never replace'):
                self.run_command('stage')
            self.assertEqual(github.call_count, 1)
            self.assertEqual(github.call_args.args[0][:3], ['gh', 'release', 'view'])

    def test_finalization_requires_same_android_assets_and_live_download_success(self):
        with mock.patch.object(publish.subprocess, 'run') as github:
            with mock.patch.object(publish, 'metadata', return_value={**self.android, 'assets': []}):
                with self.assertRaises(ValueError):
                    self.run_command('finalize')
            self.write('Windows-update-check.json', {**self.update, 'ok': False})
            with mock.patch.object(publish, 'metadata', return_value=self.android):
                with self.assertRaises(ValueError):
                    self.run_command('finalize')
            github.assert_not_called()

    def test_successful_finalization_hashes_assets_and_uploads_only_windows_evidence(self):
        with mock.patch.object(publish, 'metadata', return_value=self.android), \
                mock.patch.object(publish.subprocess, 'run') as github:
            self.run_command('finalize')
        arguments = github.call_args.args[0]
        self.assertEqual(arguments[:4], ['gh', 'release', 'upload', 'windows-v0.1.13-preview.1-37'])
        self.assertNotIn('--clobber', arguments)
        self.assertEqual({Path(value).name for value in arguments[4:]},
                         {'Android-isolation.json', 'Windows-update-check.json', 'SHA256SUMS.txt'})
        self.assertIn(hashlib.sha256(self.package.read_bytes()).hexdigest(),
                      (self.output / 'SHA256SUMS.txt').read_text())
        self.assertTrue(json.loads((self.output / 'Android-isolation.json').read_text())['ok'])

    def test_stable_version_cannot_enter_windows_preview_publisher(self):
        (self.root / 'pubspec.yaml').write_text('version: 0.1.13+37\n')
        with mock.patch.object(publish.subprocess, 'run') as github:
            with self.assertRaises(ValueError):
                self.run_command('stage')
            github.assert_not_called()


if __name__ == '__main__':
    unittest.main()
