import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

import reuse_windows_package as reuse
import publish_windows_stable as windows


class RecoveryGateTests(unittest.TestCase):
    def setUp(self):
        self.current = 'c' * 40
        self.provenance = {
            'binarySourceCommit': reuse.approved_commit, 'binaryWorkflowRun': reuse.approved_run,
            'validationSourceCommit': self.current, 'validationWorkflowRun': '200',
            'originalHarnessSourceSha256': '1' * 64,
            'validationHarnessSourceSha256': '2' * 64,
            'instanceGuardSourceSha256': '3' * 64,
        }

    def original_run(self):
        return {'id': int(reuse.approved_run), 'head_sha': reuse.approved_commit,
                'head_branch': 'release/windows-android-0.1.48-74', 'run_attempt': 1,
                'status': 'completed', 'conclusion': 'failure',
                'path': '.github/workflows/windows-preview.yml',
                'head_repository': {'full_name': 'qq294716498/HongguoTV-Phone-TV-NoAds'}}

    def jobs(self):
        return [{'id': reuse.approved_checks_job, 'name': 'checks', 'conclusion': 'success'},
                {'id': reuse.approved_job, 'name': 'windows', 'status': 'completed',
                 'conclusion': 'failure', 'run_attempt': 1, 'steps': [
                     {'name': 'Run python scripts/build_windows.py --all-sources', 'conclusion': 'success'},
                     {'name': 'Verify isolated native single-instance lifecycle with MSVC', 'conclusion': 'failure'}]}]

    def artifact(self):
        return {'id': reuse.approved_artifact, 'name': 'hongguotv-windows-x64',
                'expired': False, 'size_in_bytes': reuse.approved_outer_bytes,
                'digest': 'sha256:' + reuse.approved_outer_sha256,
                'workflow_run': {'id': int(reuse.approved_run), 'head_sha': reuse.approved_commit}}

    def original_failure(self):
        return {'sourceCommit': reuse.approved_commit, 'workflowRun': reuse.approved_run,
                'compiler': {'family': 'MSVC'}, 'nativeExecuted': True, 'successful': False,
                'testsRun': 16, 'cases': [
                    *[{'test': 'original-' + str(i), 'status': 'passed'} for i in range(15)],
                    {'test': reuse.failed_case, 'status': 'failed',
                     'detail': "takeover = waiting.wait_state(lambda value: value['attached']); 'attached': False"}]}

    def red(self):
        return {'sourceCommit': self.current, 'workflowRun': '200',
                'compiler': {'family': 'MSVC'}, 'nativeExecuted': True, 'successful': False,
                'testsRun': 1, 'sourceHashNormalization': 'LF',
                'harnessSourceSha256': self.provenance['originalHarnessSourceSha256'],
                'instanceGuardSourceSha256': self.provenance['instanceGuardSourceSha256'],
                'cases': [{'test': reuse.reader_case, 'status': 'failed',
                           'detail': 'Synthetic fixture condition was not reached before timeout; updated = owner.wait_state',
                           'observations': [{'operation': 'restore-while-report-reader-denies-delete',
                                             'nativeVisible': True, 'publishedVisible': False,
                                             'publishedRestores': 0}]}]}

    def green(self):
        value = self.red()
        value.update(successful=True, testsRun=17,
                     harnessSourceSha256=self.provenance['validationHarnessSourceSha256'])
        value['cases'][0].update(status='passed', detail='')
        value['cases'][0]['observations'].append({'operation': 'publish-after-reader-release',
                                                'reportPublishFailures': 1, 'lastReportError': 32})
        return value

    def test_exact_failed_attempt_requires_successful_compile_and_only_the_known_fixture_failure(self):
        reuse.validate_original_run(self.original_run(), reuse.approved_run)
        reuse.validate_original_jobs(self.jobs())
        for key, value in [('id', 1), ('head_sha', 'other'), ('conclusion', 'success'),
                           ('run_attempt', 2), ('head_branch', 'main'),
                           ('path', '.github/workflows/build.yml')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_original_run({**self.original_run(), key: value}, reuse.approved_run)
        for alter in ['job', 'checks', 'compile', 'failure', 'extra']:
            jobs = self.jobs()
            if alter == 'job': jobs[1]['id'] = 1
            elif alter == 'checks': jobs[0]['conclusion'] = 'failure'
            elif alter == 'compile': jobs[1]['steps'][0]['conclusion'] = 'skipped'
            elif alter == 'failure': jobs[1]['steps'][1]['name'] = 'Unrelated runtime failure'
            else: jobs[1]['steps'].append({'name': 'Other failure', 'conclusion': 'failure'})
            with self.subTest(alter=alter), self.assertRaises(ValueError):
                reuse.validate_original_jobs(jobs)

    def test_only_pinned_artifact_and_original_failure_report_are_accepted(self):
        reuse.validate_artifact(self.artifact())
        reuse.validate_original_failure(self.original_failure())
        for key, value in [('id', 1), ('expired', True), ('size_in_bytes', 1), ('digest', 'sha256:' + '0' * 64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_artifact({**self.artifact(), key: value})
        for key, value in [('sourceCommit', 'other'), ('nativeExecuted', False),
                           ('successful', True), ('testsRun', 15)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_original_failure({**self.original_failure(), key: value})
        bad = self.original_failure();bad['cases'][-1]['status'] = 'error'
        with self.assertRaises(ValueError): reuse.validate_original_failure(bad)

    def test_source_gate_rejects_runtime_changes_dirty_tracked_files_wrong_checkout_and_renames(self):
        effects = [self.current, reuse.approved_commit, 'README.md\n.github/workflows/windows-recovery.yml', '']
        with mock.patch.dict(reuse.os.environ, {'GITHUB_SHA': self.current}), mock.patch.object(reuse, 'git', side_effect=effects) as commands:
            self.assertEqual(reuse.validate_source(Path('.')), (self.current, ['.github/workflows/windows-recovery.yml', 'README.md']))
            self.assertIn('--no-renames', commands.call_args_list[2].args)
            self.assertIn('--untracked-files=no', commands.call_args_list[3].args)
        variants = [[self.current, 'other'],
                    [self.current, reuse.approved_commit, 'lib/main.dart'],
                    [self.current, reuse.approved_commit, 'pubspec.yaml'],
                    [self.current, reuse.approved_commit, 'scripts/build_windows.py'],
                    [self.current, reuse.approved_commit, 'README.md', ' M lib/main.dart']]
        for values in variants:
            with mock.patch.dict(reuse.os.environ, {'GITHUB_SHA': self.current}), \
                    mock.patch.object(reuse, 'git', side_effect=values), self.assertRaises(ValueError):
                reuse.validate_source(Path('.'))
        with mock.patch.dict(reuse.os.environ, {'GITHUB_SHA': 'other'}), \
                mock.patch.object(reuse, 'git', return_value=self.current), self.assertRaises(ValueError):
            reuse.validate_source(Path('.'))

    def test_old_reader_lock_evidence_must_fail_at_controlled_publication_wait_not_setup(self):
        reuse.validate_reader_lock(self.red(), self.provenance)
        for key, value in [('nativeExecuted', False), ('successful', True), ('testsRun', 0),
                           ('sourceCommit', 'other'), ('workflowRun', 'old'),
                           ('harnessSourceSha256', '2' * 64), ('sourceHashNormalization', 'unknown')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_reader_lock({**self.red(), key: value}, self.provenance)
        for key, value in [('status', 'error'), ('detail', 'setupClass failed'), ('observations', [])]:
            bad = self.red();bad['cases'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_reader_lock(bad, self.provenance)
        bad = self.red();bad['cases'][0]['observations'][0]['nativeVisible'] = False
        with self.assertRaises(ValueError): reuse.validate_reader_lock(bad, self.provenance)

    def test_fixed_evidence_must_record_real_retry_and_belong_to_current_validation(self):
        reuse.validate_fixed_reader(self.green(), self.provenance)
        for key, value in [('workflowRun', 'old'), ('harnessSourceSha256', '1' * 64),
                           ('instanceGuardSourceSha256', '4' * 64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_fixed_reader({**self.green(), key: value}, self.provenance)
        for key, value in [('reportPublishFailures', 0), ('lastReportError', 0)]:
            bad = self.green();bad['cases'][0]['observations'][1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_fixed_reader(bad, self.provenance)

    def test_source_hash_normalization_preserves_equal_lf_and_crlf_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            p = Path(temporary) / 'harness.cpp'
            p.write_bytes(b'a\nb\n');lf = reuse.source_file_digest(p)
            p.write_bytes(b'a\r\nb\r\n')
            self.assertEqual(lf, reuse.source_file_digest(p))
            self.assertNotEqual(lf, reuse.digest(p))

    def test_unpinned_reuse_blocks_before_git_or_network(self):
        for name in ['approved_commit', 'approved_run', 'approved_sha256', 'approved_outer_sha256']:
            with mock.patch.object(reuse, name, 'PIN_BEFORE_REUSE'), mock.patch.object(reuse, 'git') as commands:
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'must be pinned'):
                    reuse.validate_source(Path('.'))
                commands.assert_not_called()

    def test_recovery_publication_keeps_binary_target_but_does_not_change_validation_identity(self):
        with mock.patch.dict(windows.os.environ, {'WINDOWS_RECOVERY': 'true', 'GITHUB_SHA': self.current,
                                                'WINDOWS_BINARY_COMMIT': reuse.approved_commit,
                                                'WINDOWS_BINARY_RUN': reuse.approved_run}):
            self.assertEqual(windows.release_target(), reuse.approved_commit)
            self.assertEqual(windows.os.environ['GITHUB_SHA'], self.current)
            with mock.patch.object(reuse, 'check_provenance', return_value=self.provenance), \
                    mock.patch.object(reuse, 'manifest', return_value={'reports': {'a': 'new'}}), \
                    mock.patch.object(windows, 'read_json', side_effect=[self.provenance, {'reports': {'a': 'old'}}]):
                with self.assertRaisesRegex(ValueError, 'report hashes'):
                    windows.validate_recovery()
        with mock.patch.dict(windows.os.environ, {'WINDOWS_RECOVERY': 'true', 'GITHUB_SHA': self.current,
                                                'WINDOWS_BINARY_COMMIT': 'other',
                                                'WINDOWS_BINARY_RUN': reuse.approved_run}):
            with self.assertRaisesRegex(ValueError, 'pinned original'):
                windows.validate_recovery()

    def test_windows_runtime_gate_still_requires_approved_ancestor_and_release_only_changes(self):
        approved = 'a' * 40
        with mock.patch.object(windows, 'approved_source', approved), mock.patch.object(windows.subprocess, 'check_output', side_effect=[approved, 'README.md\n']):
            windows.validate_release_source('candidate')
        with mock.patch.object(windows, 'approved_source', approved), mock.patch.object(windows.subprocess, 'check_output', return_value='other'), self.assertRaisesRegex(ValueError, 'approved runtime source'):
            windows.validate_release_source('candidate')
        with mock.patch.object(windows, 'approved_source', approved), mock.patch.object(windows.subprocess, 'check_output', side_effect=[approved, 'windows/updater/updater.cpp']), self.assertRaisesRegex(ValueError, 'Runtime source changed'):
            windows.validate_release_source('candidate')
        with mock.patch.object(windows, 'approved_source', 'PIN_FINAL_RUNTIME_COMMIT_BEFORE_RELEASE'), \
                mock.patch.object(windows.subprocess, 'check_output') as commands:
            with self.assertRaisesRegex(ValueError, 'must be pinned'):
                windows.validate_release_source('candidate')
            commands.assert_not_called()


if __name__ == '__main__':
    unittest.main()
