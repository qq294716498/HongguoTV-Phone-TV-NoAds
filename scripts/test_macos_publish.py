import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import publish_macos as publish


class MacOSPublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.artifacts = self.root / 'artifacts'
        self.output = self.root / 'dist/macos-publish'
        self.commit, self.release_commit, self.run = 'a' * 40, 'b' * 40, '123'
        self.content = b'synthetic validated universal package'
        self.checksum = hashlib.sha256(self.content).hexdigest()
        (self.root / 'pubspec.yaml').write_text('version: 0.1.49+84\n')
        self.identity = {'ok': True, 'version': '0.1.49', 'build': 84,
                         'sourceCommit': self.commit, 'workflowRun': self.run, 'allSources': False}
        names = ['Contents/MacOS/HongguoTV', 'Contents/Frameworks/libduanju_core.dylib']
        self.package_report = {**self.identity, 'package': publish.PACKAGE, 'bytes': len(self.content),
                               'sha256': self.checksum, 'minimumMacOS': '13.0', 'renderer': 'Skia Metal',
                               'signature': 'ad-hoc', 'notarized': False,
                               'architectures': {name: ['arm64', 'x86_64'] for name in names},
                               'nativeMinimumVersions': {name: ['13.0', '13.0'] for name in names}}
        self.checks = {**self.identity, 'flutterTestsPassed': 1234, 'flutterTestsSkipped': 5,
                       'flutterTestsFailed': 0, 'flutterCompletedSuccessfully': True,
                       'analysisErrors': 0, 'analysisWarnings': 0, 'analysisInfos': 192}
        self.write('package/macOS-validation.json', self.package_report)
        self.write('package/macOS-checks.json', self.checks)
        (self.artifacts / 'package' / publish.PACKAGE).write_bytes(self.content)
        for arch in ('arm64', 'x86_64'):
            smoke_run = {'version': '0.1.49', 'build': 84, **{key: True for key in publish.SMOKE_KEYS}}
            self.write(f'{arch}/macOS-smoke.json', {**self.identity, 'platform': 'macos', 'hostArchitecture': arch,
                                                   'repeatedLaunches': 3, 'runs': [copy.deepcopy(smoke_run) for _ in range(3)]})
            self.write(f'playback-{arch}/macOS-app-autoplay-chain.json', self.chain(arch))
        self.protected = {'androidLatest': 'current-48', 'windowsRelease': 'current-48', 'windowsChannel': 'current', 'oldMacOS': '34'}
        for patch in [mock.patch.object(publish, 'root', self.root),
                      mock.patch.object(publish, 'source_commit', return_value=self.release_commit),
                      mock.patch.object(publish, 'BUILD_RUN', ''), mock.patch.object(publish, 'BUILD_COMMIT', ''),
                      mock.patch.object(publish, 'SHA256', ''),
                      mock.patch.object(publish, 'RUNTIME_BASELINE', 'd' * 40)]:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, name, value):
        path = self.artifacts / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def chain(self, arch):
        return {
            **self.identity, 'platform': 'macos', 'hostArchitecture': arch,
            'dartAbi': 'macos_arm64' if arch == 'arm64' else 'macos_x64',
            'nativeExecuted': True, 'hardwareVideoOutput': False,
            'expectedHwdec': 'videotoolbox-copy', 'decoder': {'hwdec': 'videotoolbox-copy'},
            'fixtureAudioOutput': 'null', 'playerCount': 1, 'playerOpenCount': 1,
            'samePlayer': True, 'nativeQueueVerified': True, 'nativeHandle': 12345,
            'firstFrameMeasured': False, 'physicalAudioVideoContinuityMeasured': False,
            'failures': [], 'playbackErrors': [], 'resolvedEpisodes': [1],
            'episodes': [{'episode': episode, 'ok': True, 'observedAtOneSecond': True, 'noEarlyAdvance': True,
                          'title': 'synthetic', 'episodeLabel': str(episode), 'nativeHandle': 12345,
                          'positionAtOneSecondMs': 1000, 'nativePositionAtOneSecondMs': 1050,
                          'durationMs': 5000, 'nearEndPositionMs': 4500, 'nativeNearEndPositionMs': 4600}
                         for episode in range(1, 5)],
            'handoffs': [{'from': episode, 'to': episode + 1, 'identity': 'next-' + str(episode),
                          'generation': episode, 'activated': True, 'ready': True,
                          'nativeHandle': 12345, 'previousHistoryPositionMs': 4900} for episode in range(1, 4)],
            'queueEvents': [{'kind': kind, 'episode': episode + 1, 'identity': 'next-' + str(episode),
                             'generation': episode} for episode in range(1, 4) for kind in ('activated', 'ready')],
            'history': [{'episode': episode, 'positionMs': 4900} for episode in range(1, 5)],
        }

    def prepare(self):
        with mock.patch.object(publish, 'validate_build'), mock.patch.object(publish, 'validate_release_source', return_value=['README.md']), \
                mock.patch.object(publish, 'isolation_state', return_value=self.protected):
            return publish.prepare(self.artifacts, self.output, self.run, self.commit)

    def pins(self):
        for name, value in [('BUILD_RUN', self.run), ('BUILD_COMMIT', self.commit), ('SHA256', self.checksum)]:
            patch = mock.patch.object(publish, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def test_prepare_assembles_exact_reviewable_assets_without_release_mutation(self):
        with mock.patch.object(publish.subprocess, 'run') as mutation:
            result = self.prepare()
        mutation.assert_not_called()
        self.assertEqual(result['sha256'], self.checksum)
        self.assertEqual(len(result['files']), 10)
        report = publish.read_json(self.output / 'macOS-source-and-checks.json')
        self.assertEqual((report['flutterTestsPassed'], report['analysisInfos']), (1234, 192))
        self.assertEqual((report['binaryBuildCommit'], report['releaseSourceCommit']), (self.commit, self.release_commit))
        self.assertIs(report['allSources'], False)
        self.assertEqual(publish.read_json(self.output / 'macOS-protected-platforms.json'), self.protected)

    def test_unpinned_publication_and_existing_release_cannot_create_or_overwrite(self):
        with mock.patch('sys.argv', ['publish_macos.py', 'publish']), mock.patch.object(publish.subprocess, 'run') as mutation:
            with self.assertRaisesRegex(ValueError, 'pinned'):
                publish.main()
            mutation.assert_not_called()
        self.pins()
        with mock.patch('sys.argv', ['publish_macos.py', 'publish']), mock.patch.object(publish, 'optional_api', return_value={'id': 1}), \
                mock.patch.object(publish.subprocess, 'run') as mutation:
            with self.assertRaisesRegex(ValueError, 'verify-public'):
                publish.main()
            mutation.assert_not_called()

    def test_build_requires_exact_workflow_source_and_all_five_successful_jobs(self):
        run = {'head_sha': self.commit, 'conclusion': 'success', 'status': 'completed', 'path': '.github/workflows/macos.yml'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in publish.JOBS]
        with mock.patch.object(publish, 'api', side_effect=[run, {'jobs': jobs}]):
            publish.validate_build(self.run, self.commit)
        for value in [{**run, 'head_sha': 'c' * 40}, {**run, 'path': '.github/workflows/build.yml'}, {**run, 'conclusion': 'failure'}]:
            with mock.patch.object(publish, 'api', return_value=value), self.assertRaises(ValueError):
                publish.validate_build(self.run, self.commit)
        for value in [jobs[:-1], [*jobs, jobs[0]], [{**job, 'conclusion': 'skipped'} if index == 0 else job for index, job in enumerate(jobs)]]:
            with mock.patch.object(publish, 'api', side_effect=[run, {'jobs': value}]), self.assertRaises(ValueError):
                publish.validate_build(self.run, self.commit)

    def test_runtime_production_paths_cannot_be_whitelisted_by_directory(self):
        for name in ['lib/player_screen.dart', 'native/core/bridge.go', 'packages/plugin/file.dart', 'pubspec.yaml', 'pubspec.lock']:
            with self.subTest(path=name), mock.patch.object(publish.subprocess, 'check_output', side_effect=[publish.RUNTIME_BASELINE + '\n', name + '\n']), self.assertRaisesRegex(ValueError, 'Runtime source'):
                publish.validate_release_source(self.commit)
        with mock.patch.object(publish.subprocess, 'check_output', side_effect=[publish.RUNTIME_BASELINE + '\n', 'README.md\nscripts/publish_macos.py\n']):
            self.assertEqual(publish.validate_release_source(self.commit), ['README.md', 'scripts/publish_macos.py'])

    def test_unpinned_runtime_blocks_source_validation_and_publication(self):
        with mock.patch.object(publish, 'RUNTIME_BASELINE', ''), \
                mock.patch.object(publish.subprocess, 'check_output') as command:
            with self.assertRaisesRegex(ValueError, 'baseline must be pinned'):
                publish.validate_release_source(self.commit)
            command.assert_not_called()
        self.pins()
        with mock.patch.object(publish, 'RUNTIME_BASELINE', ''), self.assertRaisesRegex(ValueError, 'pinned'):
            publish.require_pins()

    def test_package_rejects_tampering_newer_system_thin_binaries_or_signing_changes(self):
        variants = [{**self.package_report, 'sha256': '0' * 64}, {**self.package_report, 'bytes': 1},
                    {**self.package_report, 'allSources': True}, {**self.package_report, 'sourceCommit': 'c' * 40},
                    {**self.package_report, 'signature': 'Developer ID'}, {**self.package_report, 'notarized': True},
                    {**self.package_report, 'architectures': {}}, {**self.package_report, 'nativeMinimumVersions': {}}]
        for field, item in [('architectures', ['arm64']), ('nativeMinimumVersions', ['13.0', '14.0']), ('nativeMinimumVersions', ['13.0'])]:
            value = copy.deepcopy(self.package_report)
            value[field]['Contents/MacOS/HongguoTV'] = item
            variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(ValueError):
                publish.validate_package(value, self.artifacts / 'package' / publish.PACKAGE, self.commit, self.run)

    def test_app_chain_requires_architecture_probe_clocks_history_and_actual_unique_handoffs(self):
        value = self.chain('arm64')
        publish.validate_app_autoplay_chain(value, 'arm64', self.commit, self.run)
        variants = [{**value, key: replacement} for key, replacement in [
            ('sourceCommit', 'c' * 40), ('workflowRun', '99'), ('hostArchitecture', 'x86_64'),
            ('dartAbi', 'macos_x64'), ('hardwareVideoOutput', True), ('expectedHwdec', 'auto'),
            ('nativeHandle', 0), ('playerOpenCount', 4), ('samePlayer', False),
            ('firstFrameMeasured', True), ('failures', ['failure']), ('playbackErrors', ['error']),
            ('resolvedEpisodes', [1, 2]), ('history', []), ('queueEvents', value['queueEvents'][:-1]),
            ('queueEvents', [*value['queueEvents'], value['queueEvents'][0]])]]
        for field, replacement in [('positionAtOneSecondMs', 0), ('nativePositionAtOneSecondMs', float('nan')),
                                   ('nearEndPositionMs', 1000), ('nativeNearEndPositionMs', 0), ('noEarlyAdvance', False)]:
            changed = copy.deepcopy(value)
            changed['episodes'][1][field] = replacement
            variants.append(changed)
        for field, replacement in [('generation', 0), ('identity', ''), ('previousHistoryPositionMs', 0), ('from', 1)]:
            changed = copy.deepcopy(value)
            changed['handoffs'][1][field] = replacement
            variants.append(changed)
        for index, changed in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValueError):
                publish.validate_app_autoplay_chain(changed, 'arm64', self.commit, self.run)
        hardware = {**value, 'hardwareVideoOutput': True, 'expectedHwdec': 'auto', 'decoder': {'hwdec': 'auto'}}
        publish.validate_app_autoplay_chain(hardware, 'arm64', self.commit, self.run)

    def test_either_architecture_or_complete_check_failure_blocks_prepare(self):
        for path, field, replacement in [('package/macOS-checks.json', 'flutterTestsPassed', 999),
                                         ('package/macOS-checks.json', 'analysisWarnings', 1),
                                         ('x86_64/macOS-smoke.json', 'repeatedLaunches', 2),
                                         ('playback-x86_64/macOS-app-autoplay-chain.json', 'playerCount', 2)]:
            original = publish.read_json(self.artifacts / path)
            self.write(path, {**original, field: replacement})
            with self.subTest(path=path, field=field), self.assertRaises(ValueError):
                self.prepare()
            self.write(path, original)

    def test_permission_failure_does_not_count_as_absent_release(self):
        denied = subprocess.CompletedProcess([], 1, '', 'gh: Forbidden (HTTP 403)')
        with mock.patch.object(publish.subprocess, 'run', return_value=denied), self.assertRaisesRegex(ValueError, 'lookup failed'):
            publish.optional_api('releases/tags/' + publish.TAG)

    def test_isolation_snapshot_captures_all_platform_assets_and_static_channel(self):
        releases = {tag: {'id': index, 'tag_name': tag, 'target_commitish': 'c' * 40,
                          'draft': False, 'prerelease': False, 'body': 'existing release',
                          'assets': [{'id': index, 'name': 'existing-package', 'size': 100,
                                      'digest': 'sha256:' + 'd' * 64, 'state': 'uploaded',
                                      'browser_download_url': 'https://github.com/synthetic/existing'}]}
                    for index, tag in enumerate(publish.PROTECTED_TAGS)}
        manifest = {'schema': 1, 'release': {'tag_name': publish.PROTECTED_TAGS[1], 'draft': False, 'prerelease': False}}

        def api(route):
            if route == 'releases/latest':
                return releases[publish.PROTECTED_TAGS[0]]
            if route.startswith('releases/tags/'):
                return releases[route[len('releases/tags/'):]]
            if route == 'contents/windows-stable.json?ref=windows-stable-channel':
                return {'sha': 'blob-identity', 'content': base64.b64encode(json.dumps(manifest).encode()).decode()}
            if route == 'git/ref/heads/windows-stable-channel':
                return {'object': {'sha': 'e' * 40}}
            raise AssertionError(route)

        with mock.patch.object(publish, 'api', side_effect=api):
            before = publish.isolation_state()
            self.assertEqual(set(before['releases']), {
                'app-v0.1.49-84', 'windows-v0.1.49-84', 'macos-v0.1.48-74', 'macos-v0.1.34-59',
                'app-v0.1.46-71', 'windows-v0.1.46-71'})
            for tag in ('macos-v0.1.34-59', 'app-v0.1.46-71', 'windows-v0.1.46-71'):
                original = releases[tag]['assets'][0]['id']
                releases[tag]['assets'][0]['id'] = 999
                self.assertNotEqual(before, publish.isolation_state())
                releases[tag]['assets'][0]['id'] = original
            self.assertEqual(before['windowsChannel']['branchCommit'], 'e' * 40)
            releases[publish.PROTECTED_TAGS[0]]['tag_name'] = 'app-v0.1.46-71'
            with self.assertRaisesRegex(ValueError, 'Latest must remain on app-v0.1.49-84'):
                publish.isolation_state()
            releases[publish.PROTECTED_TAGS[0]]['tag_name'] = publish.PROTECTED_TAGS[0]
            manifest['release']['tag_name'] = 'windows-v0.1.43-68'
            with self.assertRaisesRegex(ValueError, 'channel identity'):
                publish.isolation_state()

    def test_publish_workflow_checks_fresh_source_pins_before_artifact_reads(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/macos-publish.yml').read_text()
        download = workflow.index('uses: actions/download-artifact@v4')
        self.assertLess(workflow.index('publish_macos.require_pins()'), download)
        self.assertLess(workflow.index('publish_macos.validate_release_source(publish_macos.BUILD_COMMIT)'), download)
        self.assertNotIn('41383092284', workflow)
        self.assertIn('branches: [release/macos-0.1.49-84]', workflow)
        self.assertEqual(workflow.count('run-id: ${{ env.MACOS_BUILD_RUN }}'), 5)

    def public_fixture(self):
        self.prepare()
        self.pins()
        assets = [{'id': index, 'name': path.name, 'size': path.stat().st_size,
                   'digest': 'sha256:' + publish.digest(path), 'state': 'uploaded',
                   'browser_download_url': f'https://github.com/{publish.REPO}/releases/download/{publish.TAG}/{path.name}'}
                  for index, path in enumerate(sorted(self.output.iterdir()))]
        value = {'tag_name': publish.TAG, 'draft': False, 'prerelease': False,
                 'target_commitish': self.release_commit, 'assets': assets, 'body': publish.PENDING_NOTE}

        def api(route):
            if route == 'releases/tags/' + publish.TAG:
                return value
            if route == 'git/ref/tags/' + publish.TAG:
                return {'object': {'type': 'commit', 'sha': self.release_commit}}
            raise AssertionError(route)

        def command(arguments, **kwargs):
            if arguments[0] == 'curl':
                Path(arguments[-1]).write_bytes(self.content)
            elif arguments[:3] == ['gh', 'release', 'edit']:
                value['body'] = Path(arguments[-1]).read_text()
            elif arguments[:3] == ['gh', 'release', 'upload']:
                path = Path(arguments[4])
                value['assets'].append({'name': path.name, 'size': path.stat().st_size,
                                        'digest': 'sha256:' + publish.digest(path), 'state': 'uploaded'})
            else:
                raise AssertionError(arguments)
            return subprocess.CompletedProcess(arguments, 0)

        return value, api, command

    def test_public_verification_checks_download_and_isolation_then_finishes_only_mac_release(self):
        value, api, command = self.public_fixture()
        with mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'isolation_state', return_value=self.protected), \
                mock.patch.object(publish.subprocess, 'run', side_effect=command) as calls:
            result = publish.verify_public(self.output)
        self.assertTrue(result['windowsStableChannelPreserved'])
        self.assertEqual(value['body'], publish.VERIFIED_NOTE)
        self.assertEqual([call.args[0][:3] for call in calls.call_args_list], [
            ['curl', '--fail', '--location'], ['gh', 'release', 'upload'], ['gh', 'release', 'edit']])

    def test_existing_verified_report_is_idempotent_and_conflicting_report_is_never_overwritten(self):
        value, api, command = self.public_fixture()
        with mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'isolation_state', return_value=self.protected), \
                mock.patch.object(publish.subprocess, 'run', side_effect=command):
            publish.verify_public(self.output)
        with mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'isolation_state', return_value=self.protected), \
                mock.patch.object(publish.subprocess, 'run', side_effect=command) as calls:
            publish.verify_public(self.output)
        self.assertEqual([call.args[0][0] for call in calls.call_args_list], ['curl'])
        value['assets'][-1]['digest'] = 'sha256:' + '0' * 64
        with mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'isolation_state', return_value=self.protected), \
                mock.patch.object(publish.subprocess, 'run', side_effect=command) as calls, self.assertRaisesRegex(ValueError, 'refusing overwrite'):
            publish.verify_public(self.output)
        self.assertEqual([call.args[0][0] for call in calls.call_args_list], ['curl'])

    def test_created_release_download_failure_recovers_without_second_create(self):
        value, api, command = self.public_fixture()
        result = {'sourceCommit': self.release_commit, 'files': [path.name for path in self.output.iterdir()]}
        downloading_fails = True

        def action(arguments, **kwargs):
            if arguments[:3] == ['gh', 'release', 'create']:
                self.assertIn('--latest=false', arguments)
                self.assertEqual(arguments[arguments.index('--target') + 1], self.release_commit)
                return subprocess.CompletedProcess(arguments, 0)
            if arguments[0] == 'curl' and downloading_fails:
                raise subprocess.CalledProcessError(22, arguments)
            return command(arguments, **kwargs)

        with mock.patch.object(publish, 'optional_api', return_value=None), mock.patch.object(publish, 'prepare', return_value=result), \
                mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'isolation_state', return_value=self.protected), \
                mock.patch.object(publish.subprocess, 'run', side_effect=action) as calls:
            with mock.patch('sys.argv', ['publish_macos.py', 'publish', '--output', str(self.output)]), self.assertRaises(subprocess.CalledProcessError):
                publish.main()
            downloading_fails = False
            publish.verify_public(self.output)
        creates = [call for call in calls.call_args_list if call.args[0][:3] == ['gh', 'release', 'create']]
        self.assertEqual(len(creates), 1)
        self.assertEqual(value['body'], publish.VERIFIED_NOTE)

    def test_public_isolation_failure_cannot_upload_or_finalize_notes(self):
        value, api, command = self.public_fixture()
        with mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish, 'isolation_state', return_value={'changed': True}), \
                mock.patch.object(publish.subprocess, 'run', side_effect=command) as calls, self.assertRaisesRegex(ValueError, 'Protected'):
            publish.verify_public(self.output)
        self.assertEqual(value['body'], publish.PENDING_NOTE)
        self.assertTrue(all(call.args[0][0] == 'curl' for call in calls.call_args_list))

    def test_tampered_recovery_manifest_cannot_download_or_upload(self):
        value, api, command = self.public_fixture()
        (self.output / 'macOS-checks.json').write_text('{}')
        with mock.patch.object(publish, 'api', side_effect=api), mock.patch.object(publish, 'validate_build'), \
                mock.patch.object(publish, 'validate_release_source'), mock.patch.object(publish.subprocess, 'run') as calls, \
                self.assertRaisesRegex(ValueError, 'integrity'):
            publish.verify_public(self.output)
        calls.assert_not_called()


if __name__ == '__main__':
    unittest.main()
