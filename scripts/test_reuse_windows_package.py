import unittest
from unittest import mock
from pathlib import Path

import reuse_windows_package as reuse
import publish_windows_stable as windows


class ReleaseSourceGateTests(unittest.TestCase):
    def test_reuse_accepts_release_configuration_but_rejects_application_or_build_changes(self):
        with mock.patch.object(reuse.subprocess, 'check_output', return_value='README.md\n.github/workflows/android-stable.yml\n'):
            reuse.validate_source(Path('.'))
        for path in ['lib/main.dart', 'pubspec.lock', 'scripts/build_windows.py', 'packages/media_kit_libs_windows_video/windows/CMakeLists.txt']:
            with self.subTest(path=path), mock.patch.object(reuse.subprocess, 'check_output', return_value=path), self.assertRaisesRegex(ValueError, 'fresh compilation'):
                reuse.validate_source(Path('.'))

    def test_only_the_approved_successful_original_workflow_can_be_reused(self):
        original = {'id': int(reuse.approved_run), 'head_sha': reuse.approved_commit,
                    'conclusion': 'success', 'path': '.github/workflows/windows-preview.yml',
                    'head_repository': {'full_name': 'qq294716498/HongguoTV-Phone-TV-NoAds'}}
        reuse.validate_original_run(original, reuse.approved_run)
        for key, value in [('id', 1), ('head_sha', 'other'), ('conclusion', 'failure'),
                           ('path', '.github/workflows/build.yml'), ('head_repository', {'full_name': 'other/fork'})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                reuse.validate_original_run({**original, key: value}, reuse.approved_run)
        with self.assertRaises(ValueError):
            reuse.validate_original_run(original, '1')

    def test_windows_publication_requires_approved_runtime_ancestor_and_only_release_changes(self):
        approved = 'a' * 40
        with mock.patch.object(windows, 'approved_source', approved), mock.patch.object(windows.subprocess, 'check_output', side_effect=[approved, 'README.md\n']):
            windows.validate_release_source('candidate')
        with mock.patch.object(windows, 'approved_source', approved), mock.patch.object(windows.subprocess, 'check_output', return_value='other'), self.assertRaisesRegex(ValueError, 'approved runtime source'):
            windows.validate_release_source('candidate')
        with mock.patch.object(windows, 'approved_source', approved), mock.patch.object(windows.subprocess, 'check_output', side_effect=[approved, 'windows/updater/updater.cpp']), self.assertRaisesRegex(ValueError, 'Runtime source changed'):
            windows.validate_release_source('candidate')

    def test_unpinned_windows_runtime_blocks_release_before_git(self):
        with mock.patch.object(windows, 'approved_source', 'PIN_FINAL_RUNTIME_COMMIT_BEFORE_RELEASE'), \
                mock.patch.object(windows.subprocess, 'check_output') as commands:
            with self.assertRaisesRegex(ValueError, 'must be pinned'):
                windows.validate_release_source('candidate')
            commands.assert_not_called()


if __name__ == '__main__':
    unittest.main()
