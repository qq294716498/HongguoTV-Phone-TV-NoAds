import hashlib
import json
import re
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from check_android_signing import availability, SIGNING_NAMES
import publish_android_stable as publish
from publish_android_stable import certificate, offsets, validate_apks


class AndroidStablePublishTests(unittest.TestCase):
    def test_release_uses_published_022_baseline_and_preserves_all_windows_releases(self):
        import publish_windows_stable as windows
        self.assertEqual(publish.previous_android_tag, 'app-v0.1.22-47')
        self.assertEqual(publish.previous_android_commit, '1281b06ed7d49aba3b380b6ca310d98f38481486')
        self.assertEqual(windows.previous_android_tag, publish.previous_android_tag)
        self.assertEqual(windows.previous_android_commit, publish.previous_android_commit)
        self.assertEqual(publish.windows_tag, 'windows-v0.1.23-48')
        self.assertEqual(windows.previous_windows_tags, (
            'windows-v0.1.15-40', 'windows-v0.1.17-42', 'windows-v0.1.19-44', 'windows-v0.1.22-47'))
        self.assertEqual(publish.windows_tags, (*windows.previous_windows_tags, publish.windows_tag))
        self.assertEqual(windows.release_branch, publish.release_branch)
        self.assertEqual(windows.release_only_paths, publish.release_only_paths)

    def test_final_notes_mark_verified_public_downloads_and_preserve_limits(self):
        tag = 'app-v0.1.23-48'
        body = '0.1.23+48\n取源恢复与冷却修复。\n既有证书；Android 8.0；真实手机 / TV 仍未实测。\n' + publish.pending_publication_note
        final = body.replace(publish.pending_publication_note, publish.verified_publication_note)
        current = dict(tag_name=tag, draft=False, prerelease=False, target_commitish='current', body=body)
        with mock.patch.object(publish, 'release', side_effect=[current, {**current, 'body': final}]) as reads, \
                mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current', 'RUNNER_TEMP': 'synthetic-temp'}), \
                mock.patch.object(Path, 'write_text') as written, mock.patch.object(publish.subprocess, 'run') as edits:
            publish.finalize_release_notes(tag)
            written.assert_called_once_with(final, encoding='utf-8')
            edits.assert_called_once_with(['gh', 'release', 'edit', tag, '--notes-file',
                                          str(Path('synthetic-temp') / 'android-release-notes-final.md')], check=True)
            self.assertEqual(reads.call_args_list, [mock.call(tag), mock.call(tag)])
            self.assertNotIn(publish.pending_publication_note, final)
            self.assertIn('真实手机 / TV 仍未实测', final)

    def test_final_notes_cannot_modify_old_or_unverified_release(self):
        tag = 'app-v0.1.23-48'
        current = dict(tag_name=tag, draft=False, prerelease=False, target_commitish='current', body=publish.pending_publication_note)
        cases = [('tag_name', 'app-v0.1.22-47'), ('draft', True), ('prerelease', True),
                 ('target_commitish', 'old'), ('body', 'no publication status')]
        for field, value in cases:
            with self.subTest(field=field), mock.patch.object(publish, 'release', return_value={**current, field: value}), \
                    mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current'}), \
                    mock.patch.object(Path, 'write_text') as written, mock.patch.object(publish.subprocess, 'run') as edits:
                with self.assertRaises(ValueError):
                    publish.finalize_release_notes(tag)
                written.assert_not_called()
                edits.assert_not_called()

    def test_failed_public_latest_validation_never_marks_notes_complete(self):
        with mock.patch.object(Path, 'read_text', return_value='version: 0.1.23+48\n'), \
                mock.patch.object(publish.os, 'chdir'), mock.patch.object(publish, 'validate_release_source'), \
                mock.patch.object(publish, 'read', return_value={}), \
                mock.patch.object(publish, 'github', return_value=json.dumps({'tag_name': 'app-v0.1.22-47'})), \
                mock.patch.object(publish, 'finalize_release_notes') as notes, \
                mock.patch.object(publish.subprocess, 'run') as writes, \
                mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current'}), \
                mock.patch('sys.argv', ['publish_android_stable.py', 'finalize']):
            with self.assertRaisesRegex(ValueError, 'Latest does not match'):
                publish.main()
            notes.assert_not_called()
            writes.assert_not_called()

    def test_only_exact_release_branch_push_or_explicit_dispatch_can_publish(self):
        root = Path(__file__).resolve().parents[1]
        fix = 'fix/hongguo-playback-release-0.1.22-47'
        release = 'release/windows-android-0.1.23-48'
        for filename in ['android-stable.yml', 'windows-preview.yml']:
            workflow = (root / '.github/workflows' / filename).read_text()
            branches = re.search(r'(?m)^    branches: (.*)$', workflow).group(1)
            self.assertIn(fix, branches)
            self.assertIn(release, branches)
            expression = re.search(r'(?m)^  release:\n(?:    [^\n]*\n)*?    if: ([^\n]+)', workflow).group(1)
            expression = expression.replace('github.ref', 'ref').replace('github.event_name', 'event').replace('inputs.publish_release', 'publish')
            expression = expression.replace('&&', ' and ').replace('||', ' or ')
            for branch in [fix, release, 'candidate/hongguo-retry-single-instance-0.1.23-48', 'release/windows-android-0.1.22-47', 'windows/other', 'main']:
                for event in ['push', 'workflow_dispatch', 'pull_request']:
                    for publish in [False, True]:
                        expected = branch == release and (event == 'push' or (event == 'workflow_dispatch' and publish))
                        with self.subTest(workflow=filename, branch=branch, event=event, publish=publish):
                            actual = eval(expression, {'__builtins__': {}}, {'ref': 'refs/heads/' + branch, 'event': event, 'publish': publish})
                            self.assertEqual(actual, expected)
        windows = (root / '.github/workflows/windows-preview.yml').read_text()
        self.assertNotIn('reuse_run_id', windows)
        self.assertNotIn('reuse_windows_package.py', windows)
        self.assertIn('WINDOWS_BINARY_COMMIT: ${{ github.sha }}', windows)
        self.assertIn('WINDOWS_BINARY_RUN: ${{ github.run_id }}', windows)

    def test_android_waits_for_final_windows_evidence_without_republishing_it(self):
        names = ['Windows-update-check.json', 'Windows-update-channel.json', 'Windows-update-transaction.json', 'Windows-single-instance-native.json', 'Android-isolation.json', 'SHA256SUMS.txt']
        complete = dict(target_commitish='current', draft=False, prerelease=False, body=publish.windows_verified_publication_note,
                        assets=[{'name': name} for name in names])
        waiting = mock.Mock(returncode=0, stdout=json.dumps({**complete, 'assets': complete['assets'][:-1]}))
        ready = mock.Mock(returncode=0, stdout=json.dumps(complete))
        with mock.patch.object(publish.subprocess, 'run', side_effect=[waiting, ready]) as calls, mock.patch.object(publish.time, 'sleep') as sleep:
            publish.wait_for_windows('current')
            self.assertEqual(calls.call_count, 2)
            self.assertTrue(all(call.args[0][0:2] == ['gh', 'api'] for call in calls.call_args_list))
            sleep.assert_called_once_with(30)

    def test_android_waits_until_windows_final_notes_confirm_completion(self):
        from publish_windows_stable import verified_publication_note
        self.assertEqual(publish.windows_verified_publication_note, verified_publication_note)
        names = ['Windows-update-check.json', 'Windows-update-channel.json', 'Windows-update-transaction.json', 'Windows-single-instance-native.json', 'Android-isolation.json', 'SHA256SUMS.txt']
        complete = dict(target_commitish='current', draft=False, prerelease=False,
                        assets=[{'name': name} for name in names])
        waiting = mock.Mock(returncode=0, stdout=json.dumps({**complete, 'body': '公开发布核验进行中'}))
        ready = mock.Mock(returncode=0, stdout=json.dumps({**complete, 'body': publish.windows_verified_publication_note}))
        with mock.patch.object(publish.subprocess, 'run', side_effect=[waiting, ready]) as calls, mock.patch.object(publish.time, 'sleep') as sleep:
            publish.wait_for_windows('current')
            self.assertEqual(calls.call_count, 2)
            sleep.assert_called_once_with(30)

    def test_windows_dependency_denies_different_source_and_permission_errors(self):
        for result in [mock.Mock(returncode=0, stdout=json.dumps({'target_commitish': 'other'})),
                       mock.Mock(returncode=1, stderr='HTTP 403: Resource not accessible by integration')]:
            with mock.patch.object(publish.subprocess, 'run', return_value=result), mock.patch.object(publish.time, 'sleep') as sleep, self.assertRaises(ValueError):
                publish.wait_for_windows('current')
            sleep.assert_not_called()

    def test_published_windows_baseline_is_verified_and_preserved_without_republishing(self):
        assets = [{'id': n, 'name': name, 'size': 1, 'digest': 'sha256:synthetic'}
                  for n, name in enumerate(['Windows-update-check.json', 'Windows-update-channel.json', 'Windows-update-transaction.json',
                                           'Windows-single-instance-native.json', 'Android-isolation.json', 'SHA256SUMS.txt'])]
        old = dict(id=1, tag_name='windows-v0.1.15-40', target_commitish='old', draft=False, prerelease=False, assets=[])
        current = dict(id=2, tag_name=publish.windows_tag, target_commitish='current', draft=False, prerelease=False, assets=assets,
                       body=publish.windows_verified_publication_note)
        def releases(tag):
            return current if tag == publish.windows_tag else old
        with mock.patch.object(publish, 'release', side_effect=releases):
            self.assertEqual(set(publish.validated_windows_snapshots('current')), set(publish.windows_tags))
            with self.assertRaisesRegex(ValueError, 'Windows baseline'):
                publish.validated_windows_snapshots('different')
            for field, value in [('assets', assets[:-1]), ('draft', True), ('prerelease', True), ('body', 'pending publication')]:
                previous = current[field]
                current[field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    publish.validated_windows_snapshots('current')
                current[field] = previous

    def test_release_scope_rejects_windows_runtime_and_other_unapproved_changes(self):
        approved = 'a' * 40
        with mock.patch.object(publish, 'approved_source', approved), mock.patch.object(publish.subprocess, 'check_output', side_effect=[approved, 'README.md\n.github/workflows/android-stable.yml\n']):
            publish.validate_release_source('candidate')
        for changed in ['lib/windows_desktop.dart', 'lib/player_screen.dart', 'pubspec.yaml']:
            with mock.patch.object(publish, 'approved_source', approved), mock.patch.object(publish.subprocess, 'check_output', side_effect=[approved, changed]), self.subTest(changed=changed), self.assertRaisesRegex(ValueError, 'Runtime source changed'):
                publish.validate_release_source('candidate')
        with mock.patch.object(publish, 'approved_source', approved), mock.patch.object(publish.subprocess, 'check_output', return_value='other'), self.assertRaisesRegex(ValueError, 'approved runtime source'):
            publish.validate_release_source('candidate')

    def test_unpinned_runtime_source_blocks_release_before_git_or_github(self):
        with mock.patch.object(publish, 'approved_source', 'PIN_FINAL_RUNTIME_COMMIT_BEFORE_RELEASE'), \
                mock.patch.object(publish.subprocess, 'check_output') as commands:
            with self.assertRaisesRegex(ValueError, 'must be pinned'):
                publish.validate_release_source('candidate')
            commands.assert_not_called()

    def test_changed_android_latest_blocks_staging_without_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'pubspec.yaml').write_text('version: 0.1.23+48\n')
            values = [json.dumps({'object': {'sha': 'current'}}),
                      json.dumps({'tag_name': 'app-v0.1.20-45'})]
            with mock.patch.object(publish, 'root', root), mock.patch.object(publish.os, 'chdir'), \
                    mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'validate_apks'), \
                    mock.patch.object(publish, 'read', return_value={'ok': True}), \
                    mock.patch.object(publish, 'github', side_effect=values) as github, \
                    mock.patch.object(publish.subprocess, 'run', return_value=mock.Mock(returncode=1)) as commands, \
                    mock.patch.dict(publish.os.environ, {'GITHUB_SHA': 'current'}), \
                    mock.patch('sys.argv', ['publish_android_stable.py', 'stage']):
                with self.assertRaisesRegex(ValueError, 'increase beyond current stable'):
                    publish.main()
                self.assertEqual(github.call_count, 2)
                self.assertEqual(commands.call_args_list, [mock.call(
                    ['gh', 'release', 'view', 'app-v0.1.23-48'],
                    stdout=publish.subprocess.DEVNULL, stderr=publish.subprocess.DEVNULL)])

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
