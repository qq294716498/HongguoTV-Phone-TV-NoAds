import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile


approved_commit = '8c999359160d7127d9358cf605b86a1b1cd81cbf'
approved_run = '39221734603'
approved_sha256 = '5086ae22e2bb1c34fa45b1f93f8f0659158b062a83f326c6ea8ae52e59314b05'
release_only_paths = frozenset({
    'README.md', '.github/workflows/android-stable.yml',
    '.github/workflows/windows-preview.yml',
    'scripts/publish_android_stable.py', 'scripts/test_android_stable_publish.py',
    'scripts/publish_windows_stable.py', 'scripts/test_windows_stable_publish.py',
    'scripts/reuse_windows_package.py', 'scripts/test_reuse_windows_package.py',
    'test/app_update_live_test.dart', 'test/windows_update_live_test.dart',
})


def validate_original_run(run, run_id):
    if (run_id != approved_run or str(run.get('id')) != approved_run
            or run.get('head_sha') != approved_commit
            or run.get('conclusion') != 'success'
            or run.get('path') != '.github/workflows/windows-preview.yml'
            or run.get('head_repository', {}).get('full_name') != 'qq294716498/HongguoTV-Phone-TV-NoAds'):
        raise ValueError('Original run is not the approved successful Windows build')


def validate_source(root):
    changed = set(subprocess.check_output(['git', 'diff', '--name-only', approved_commit, 'HEAD'], cwd=root, text=True).splitlines())
    if changed - release_only_paths:
        raise ValueError('Application or build inputs changed; a fresh compilation is required')


def main():
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    commit = approved_commit
    run_id = os.environ['REUSE_RUN_ID']
    if not re.fullmatch(r'\d+', run_id):
        raise ValueError('Invalid original build run')
    run = json.loads(subprocess.check_output([
        'gh', 'api', f'repos/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/{run_id}'], text=True))
    validate_original_run(run, run_id)
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', commit], check=True)
    validate_source(root)
    output = root / 'dist/windows'
    validation = json.loads((output / 'Windows-validation.json').read_text(encoding='utf-8-sig'))
    if (validation.get('ok') is not True or validation.get('architecture') != 'x64'
            or validation.get('version') != '0.1.19' or validation.get('build') != 44
            or validation.get('sha256') != approved_sha256):
        raise ValueError('The original package did not pass validation')
    package = output / validation['package']
    if package.parent != output or package.stat().st_size != validation['bytes']:
        raise ValueError('Unexpected original package path or size')
    with package.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != validation['sha256']:
            raise ValueError('Original package checksum mismatch')
    destination = root / 'build/windows/x64/runner/Release'
    destination.mkdir(parents=True)
    with zipfile.ZipFile(package) as archive:
        for name in archive.namelist():
            path = PurePosixPath(name)
            if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
                raise ValueError('Unsafe original package path')
        if archive.testzip() is not None:
            raise ValueError('Original package CRC mismatch')
        archive.extractall(destination)
    print(json.dumps({'originalRun': run_id, 'binarySourceCommit': commit,
                      'applicationSourceUnchanged': True, 'packageSha256': validation['sha256']}))


if __name__ == '__main__':
    main()
