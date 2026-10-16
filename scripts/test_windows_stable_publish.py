import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import publish_windows_stable as publish


class WindowsStablePublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'dist/windows'
        self.output.mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 0.1.14+39\n')
        self.package = self.output / 'HongguoTV-0.1.14-windows-x64.zip'
        self.package.write_bytes(b'synthetic package')
        self.smoke = {name: True for name in [
            'ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux',
            'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'playbackPower',
            'fullscreen', 'miniReuseResizeRestore', 'nativeTrayHidden', 'trayKeepsPlaying',
            'nativeTrayRestored', 'nativeTrayQuit', 'mediaKitPlayback', 'cleanPath',
            'nonAsciiPath', 'differentWorkingDirectory', 'javaEnvironmentRemoved', 'normalAppStartup', 'remoteImagesDisabled']}
        self.smoke.update(processExitCode=0, version='0.1.14', build=39, nativeTrayToggles=2)
        self.write('Windows-smoke.json', self.smoke)
        self.write('Windows-validation.json', {'ok': True, 'architecture': 'x64', 'build': 39,
                   'version': '0.1.14', 'sha256': hashlib.sha256(self.package.read_bytes()).hexdigest()})
        self.write('Windows-signature.json', {'status': 'NotSigned', 'signed': False})
        self.transactions = {'ok': True, 'version': '0.1.14', 'build': 39, 'cases': [{'case': name, 'ok': True, 'build': 39, 'oldBuild': 38, 'startupAcknowledged': True} for name in [
            'success', 'crash', 'hang', 'busy', 'tamper', 'version', 'semantic', 'architecture',
            'unowned', 'junction', 'second-instance', 'real-client-startup-ack']]}
        self.write('Windows-update-transaction.json', self.transactions)
        for patch in [mock.patch.object(publish, 'root', self.root), mock.patch.object(publish, 'output', self.output),
                      mock.patch.object(publish, 'github', return_value=json.dumps({'object': {'sha': 'current'}})),
                      mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current'}),
                      mock.patch.object(publish.os, 'chdir')]:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, name, data):
        (self.output / name).write_text(json.dumps(data))

    def stage(self):
        with mock.patch('sys.argv', ['publish_windows_stable.py', 'stage']):
            publish.main()

    def test_native_tray_mini_or_transaction_failure_blocks_all_release_actions(self):
        with mock.patch.object(publish.subprocess, 'run') as github:
            for name in ['miniReuseResizeRestore', 'trayKeepsPlaying', 'nativeTrayRestored', 'nativeTrayQuit']:
                self.write('Windows-smoke.json', {**self.smoke, name: False})
                with self.subTest(name=name), self.assertRaises(ValueError):
                    self.stage()
            self.write('Windows-smoke.json', self.smoke)
            self.write('Windows-update-transaction.json', {**self.transactions, 'cases': self.transactions['cases'][:-1]})
            with self.assertRaises(ValueError):
                self.stage()
            github.assert_not_called()

    def test_existing_stable_release_is_never_overwritten(self):
        with mock.patch.object(publish.subprocess, 'run', return_value=mock.Mock(returncode=0)) as github:
            with self.assertRaisesRegex(ValueError, 'never replace'):
                self.stage()
            self.assertEqual(github.call_count, 1)

    def test_preview_cannot_be_published_as_stable(self):
        (self.root / 'pubspec.yaml').write_text('version: 0.1.14-preview.1+39\n')
        with mock.patch.object(publish.subprocess, 'run') as github:
            with self.assertRaises(ValueError):
                self.stage()
            github.assert_not_called()

    def test_changed_package_bytes_block_publication(self):
        self.package.write_bytes(b'tampered')
        with mock.patch.object(publish.subprocess, 'run') as github:
            with self.assertRaises(ValueError):
                self.stage()
            github.assert_not_called()

    def test_superseded_commit_cannot_publish(self):
        with mock.patch.object(publish, 'github', return_value=json.dumps({'object': {'sha': 'newer'}})), \
                mock.patch.object(publish.subprocess, 'run') as writes:
            with self.assertRaisesRegex(ValueError, 'superseded'):
                self.stage()
            writes.assert_not_called()


if __name__ == '__main__':
    unittest.main()
