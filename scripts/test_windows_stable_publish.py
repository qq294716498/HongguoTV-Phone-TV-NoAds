import hashlib
import base64
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import publish_windows_stable as publish


class WindowsReleaseNotesTests(unittest.TestCase):
    def test_fallback_manifest_never_caches_pending_or_premature_verified_notes(self):
        tag = 'windows-v0.1.34-59'
        package = b'synthetic package'
        checksum = hashlib.sha256(package).hexdigest()
        asset = dict(name='HongguoTV-0.1.34-windows-x64.zip', size=len(package), digest='sha256:' + checksum,
                     state='uploaded', browser_download_url=f'https://github.com/{publish.repository}/releases/download/{tag}/HongguoTV-0.1.34-windows-x64.zip')
        body = 'Windows 0.1.34：恢复修复；未签名；真机仍未实测。\n\n' + publish.pending_publication_note
        current = dict(tag_name=tag, draft=False, prerelease=False, body=body, assets=[asset])
        previous = {'sha': 'previous', 'content': base64.b64encode(json.dumps(
            {'schema': 1, 'release': {'tag_name': 'windows-v0.1.22-47'}}).encode()).decode()}
        with mock.patch.object(publish, 'github', side_effect=[json.dumps(current), json.dumps({'commit': {'sha': 'channel'}})]), \
                mock.patch.object(publish, 'read_json', return_value={'bytes': len(package), 'sha256': checksum}), \
                mock.patch.object(publish.urllib.request, 'urlopen', return_value=io.BytesIO(package)), \
                mock.patch.object(publish.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout=json.dumps(previous))), \
                mock.patch.dict(publish.os.environ, {'RUNNER_TEMP': 'synthetic-temp'}), \
                mock.patch.object(Path, 'write_text') as written, mock.patch.object(publish, 'write_json'):
            publish.publish_channel(tag, '0.1.34', '59')
            payload = json.loads(written.call_args.args[0])
            manifest = json.loads(base64.b64decode(payload['content']))
            self.assertIn('未签名；真机仍未实测', manifest['release']['body'])
            self.assertNotIn(publish.pending_publication_note, manifest['release']['body'])
            self.assertNotIn(publish.verified_publication_note, manifest['release']['body'])

    def test_final_notes_mark_verified_channel_and_preserve_unsigned_limits(self):
        tag = 'windows-v0.1.34-59'
        body = '0.1.34+59\n假全屏与取源恢复修复。\nWindows x64 仍未签名；真实站源仍未实测。\n' + publish.pending_publication_note
        final = body.replace(publish.pending_publication_note, publish.verified_publication_note)
        current = dict(tag_name=tag, draft=False, prerelease=False, target_commitish='current', body=body)
        with mock.patch.object(publish, 'github', side_effect=[json.dumps(current), json.dumps({**current, 'body': final})]) as reads, \
                mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current', 'RUNNER_TEMP': 'synthetic-temp'}), \
                mock.patch.object(Path, 'write_text') as written, mock.patch.object(publish.subprocess, 'run') as edits:
            publish.finalize_release_notes(tag)
            written.assert_called_once_with(final, encoding='utf-8')
            edits.assert_called_once_with(['gh', 'release', 'edit', tag, '--notes-file',
                                          str(Path('synthetic-temp') / 'windows-release-notes-final.md')], check=True)
            self.assertEqual(reads.call_args_list, [mock.call('api', f'repos/{publish.repository}/releases/tags/{tag}')] * 2)
            self.assertNotIn(publish.pending_publication_note, final)
            self.assertIn('仍未签名；真实站源仍未实测', final)

    def test_final_notes_cannot_modify_old_or_unverified_release(self):
        tag = 'windows-v0.1.34-59'
        current = dict(tag_name=tag, draft=False, prerelease=False, target_commitish='current', body=publish.pending_publication_note)
        cases = [('tag_name', 'windows-v0.1.22-47'), ('draft', True), ('prerelease', True),
                 ('target_commitish', 'old'), ('body', 'no publication status')]
        for field, value in cases:
            with self.subTest(field=field), mock.patch.object(publish, 'github', return_value=json.dumps({**current, field: value})), \
                    mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current'}), \
                    mock.patch.object(Path, 'write_text') as written, mock.patch.object(publish.subprocess, 'run') as edits:
                with self.assertRaises(ValueError):
                    publish.finalize_release_notes(tag)
                written.assert_not_called()
                edits.assert_not_called()

    def test_failed_android_isolation_never_marks_notes_complete(self):
        with mock.patch.object(Path, 'read_text', return_value='version: 0.1.34+59\n'), \
                mock.patch.object(publish.os, 'chdir'), \
                mock.patch.object(publish, 'read_json', return_value={'before': {'tag': 'app-v0.1.22-47'}}), \
                mock.patch.object(publish, 'metadata', return_value={'tag': 'app-v0.1.20-45'}), \
                mock.patch.object(publish, 'finalize_release_notes') as notes, \
                mock.patch.object(publish.subprocess, 'run') as writes, \
                mock.patch('sys.argv', ['publish_windows_stable.py', 'finalize']):
            with self.assertRaisesRegex(ValueError, 'Android Latest or original assets changed'):
                publish.main()
            notes.assert_not_called()
            writes.assert_not_called()


class WindowsStablePublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'dist/windows'
        self.output.mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 0.1.34+59\n')
        self.package = self.output / 'HongguoTV-0.1.34-windows-x64.zip'
        self.package.write_bytes(b'synthetic package')
        self.smoke = {name: True for name in [
            'ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux',
            'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'playbackPower',
            'fullscreen', 'miniReuseResizeRestore', 'miniNativeCaptionHidden', 'miniNativeResizeBorder', 'normalNativeCaptionRestored', 'nativeTrayHidden', 'trayPausesOnClose', 'trayRestoreStaysPaused',
            'nativeTrayRestored', 'nativeTrayQuit', 'playerUiDetached', 'playerDisposedBeforeExit', 'windowBrandIcon', 'trayBrandIcon', 'firstLaunchNoticeVisible', 'mediaKitPlayback', 'cleanPath',
            'nonAsciiPath', 'differentWorkingDirectory', 'javaEnvironmentRemoved', 'normalAppStartup', 'remoteImagesDisabled']}
        self.smoke.update(processExitCode=0, version='0.1.34', build=59, nativeTrayToggles=2)
        self.write('Windows-smoke.json', self.smoke)
        self.write('Windows-validation.json', {'ok': True, 'architecture': 'x64', 'build': 59,
                   'version': '0.1.34', 'bytes': self.package.stat().st_size, 'brandIconsVerified': True, 'identityAssetsVerified': True, 'sha256': hashlib.sha256(self.package.read_bytes()).hexdigest()})
        self.write('Windows-signature.json', {'status': 'NotSigned', 'signed': False})
        self.transactions = {'ok': True, 'version': '0.1.34', 'build': 59, 'cases': [{'case': name, 'ok': True, 'build': 59, 'oldBuild': 48, 'startupAcknowledged': True} for name in [
            'success', 'crash', 'hang', 'busy', 'tamper', 'version', 'semantic', 'architecture',
            'unowned', 'junction', 'second-instance', 'cross-directory-client', 'cancel-before-ready', 'cancel-after-ready', 'no-handoff', 'stop-unconfirmed', 'real-client-startup-ack']]}
        self.write('Windows-update-transaction.json', self.transactions)
        self.single_instance = {
            'compiler': {'family': 'MSVC', 'path': 'synthetic-cl.exe'},
            'nativeExecuted': True, 'successful': True, 'testsRun': 16,
            'sourceCommit': 'current', 'workflowRun': '100',
            'cases': [{'test': '__main__.WindowsSingleInstanceNativeTests.' + name, 'status': 'passed'} for name in [
                'test_concurrent_launches_have_one_primary',
                'test_same_user_different_paths_share_identity',
                'test_hidden_tray_restore_preserves_pause',
                'test_minimized_restore_preserves_pause',
                'test_restore_waits_for_both_ready_signals',
                'test_missing_ipc_window_is_bounded_and_then_recovers',
                'test_hung_window_is_bounded',
                'test_legacy_hidden_and_minimized_restore_without_toggle',
                'test_legacy_without_window_blocks_new_client',
                'test_normal_and_abnormal_exit_release_mutex',
                'test_mutex_handle_is_not_inherited',
                'test_update_start_does_not_activate_or_ack_running_owner',
                'test_update_start_waits_for_exit_then_owns_mutex',
                'test_cross_path_owner_blocks_updater_child_without_ack',
                'test_update_start_refuses_legacy_owner',
                'test_shutdown_activation_waits_for_takeover_or_cancelled_exit',
            ]]}
        self.write('Windows-single-instance-native.json', self.single_instance)
        for patch in [mock.patch.object(publish, 'root', self.root), mock.patch.object(publish, 'output', self.output),
                      mock.patch.object(publish, 'github', return_value=json.dumps({'object': {'sha': 'current'}})),
                      mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current', 'GITHUB_RUN_ID': '100',
                                                          'WINDOWS_BINARY_COMMIT': 'current', 'WINDOWS_BINARY_RUN': '100'}),
                      mock.patch.object(publish.os, 'chdir'),
                      mock.patch.object(publish, 'validate_release_source')]:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, name, data):
        (self.output / name).write_text(json.dumps(data))

    def stage(self):
        with mock.patch('sys.argv', ['publish_windows_stable.py', 'stage']):
            publish.main()

    def test_native_tray_mini_or_transaction_failure_blocks_all_release_actions(self):
        with mock.patch.object(publish.subprocess, 'run') as github:
            for name in ['miniReuseResizeRestore', 'miniNativeCaptionHidden', 'miniNativeResizeBorder', 'normalNativeCaptionRestored', 'trayPausesOnClose', 'trayRestoreStaysPaused', 'nativeTrayRestored', 'nativeTrayQuit']:
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

    def test_single_instance_requires_complete_current_msvc_execution_before_release(self):
        variants = [
            {**self.single_instance, 'nativeExecuted': False},
            {**self.single_instance, 'successful': False},
            {**self.single_instance, 'compiler': {'family': 'LLVM-MinGW'}},
            {**self.single_instance, 'testsRun': 15},
            {**self.single_instance, 'cases': self.single_instance['cases'][:-1]},
            {**self.single_instance, 'cases': [*self.single_instance['cases'][:-1], self.single_instance['cases'][0]]},
            {**self.single_instance, 'cases': [{**item, 'status': 'skipped'} for item in self.single_instance['cases']]},
            {**self.single_instance, 'sourceCommit': 'previous-source'},
            {**self.single_instance, 'workflowRun': 'previous-run'},
        ]
        with mock.patch.object(publish.subprocess, 'run') as commands:
            for index, value in enumerate(variants):
                self.write('Windows-single-instance-native.json', value)
                with self.subTest(index=index), self.assertRaisesRegex(ValueError, 'single-instance'):
                    self.stage()
            commands.assert_not_called()

    def test_cross_directory_configuration_protection_is_required_before_release(self):
        cases = [item for item in self.transactions['cases'] if item['case'] != 'cross-directory-client']
        self.write('Windows-update-transaction.json', {**self.transactions, 'cases': cases})
        with mock.patch.object(publish.subprocess, 'run') as commands:
            with self.assertRaisesRegex(ValueError, 'Native update transactions'):
                self.stage()
            commands.assert_not_called()

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

    def test_old_workflow_binary_or_source_cannot_publish(self):
        for variables in [{'WINDOWS_BINARY_COMMIT': 'old-source'}, {'WINDOWS_BINARY_RUN': 'previous-run'}]:
            with self.subTest(variables=variables), mock.patch.dict(publish.os.environ, variables), \
                    mock.patch.object(publish, 'github') as github, \
                    mock.patch.object(publish.subprocess, 'run') as writes:
                with self.assertRaisesRegex(ValueError, 'fresh compilation'):
                    self.stage()
                github.assert_not_called()
                writes.assert_not_called()

    def test_changed_android_latest_blocks_windows_publication(self):
        with mock.patch.object(publish, 'metadata', return_value={'tag': 'app-v0.1.20-45'}), \
                mock.patch.object(publish, 'release_identity', return_value={}), \
                mock.patch.object(publish.subprocess, 'run', return_value=mock.Mock(returncode=1)) as commands:
            with self.assertRaisesRegex(ValueError, 'approved stable baseline'):
                self.stage()
            self.assertEqual(commands.call_args_list, [mock.call(
                ['gh', 'release', 'view', 'windows-v0.1.34-59'],
                stdout=publish.subprocess.DEVNULL, stderr=publish.subprocess.DEVNULL)])

    def test_fallback_channel_requires_actual_public_bytes_before_any_mutation(self):
        tag = 'windows-v0.1.34-59'
        asset = {'name': self.package.name, 'size': self.package.stat().st_size,
                 'digest': 'sha256:' + hashlib.sha256(self.package.read_bytes()).hexdigest(),
                 'browser_download_url': f'https://github.com/{publish.repository}/releases/download/{tag}/{self.package.name}',
                 'state': 'uploaded'}
        release = {'tag_name': tag, 'draft': False, 'prerelease': False, 'body': 'release', 'assets': [asset]}
        with mock.patch.object(publish, 'github', return_value=json.dumps(release)) as github, \
                mock.patch.object(publish.urllib.request, 'urlopen', return_value=io.BytesIO(b'tampered')), \
                mock.patch.object(publish.subprocess, 'run') as mutations:
            with self.assertRaisesRegex(ValueError, 'checksum'):
                publish.publish_channel(tag, '0.1.34', '59')
            self.assertEqual(github.call_count, 1)
            mutations.assert_not_called()

    def test_fallback_channel_never_replaces_a_newer_build(self):
        tag = 'windows-v0.1.34-59'
        asset = {'name': self.package.name, 'size': self.package.stat().st_size,
                 'digest': 'sha256:' + hashlib.sha256(self.package.read_bytes()).hexdigest(),
                 'browser_download_url': f'https://github.com/{publish.repository}/releases/download/{tag}/{self.package.name}',
                 'state': 'uploaded'}
        release = {'tag_name': tag, 'draft': False, 'prerelease': False, 'body': 'release', 'assets': [asset]}
        existing = {'sha': 'previous', 'content': base64.b64encode(json.dumps(
            {'schema': 1, 'release': {**release, 'tag_name': 'windows-v0.1.35-60'}}).encode()).decode()}
        with mock.patch.object(publish, 'github', return_value=json.dumps(release)) as github, \
                mock.patch.object(publish.urllib.request, 'urlopen', return_value=io.BytesIO(self.package.read_bytes())), \
                mock.patch.object(publish.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout=json.dumps(existing))):
            with self.assertRaisesRegex(ValueError, 'newer'):
                publish.publish_channel(tag, '0.1.34', '59')
            self.assertEqual(github.call_count, 1)


if __name__ == '__main__':
    unittest.main()
