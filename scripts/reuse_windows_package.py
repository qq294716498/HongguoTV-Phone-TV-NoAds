import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile


def main():
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    commit = 'ee60cf8abada4b75f9f57dac24a6adb154641f06'
    run_id = os.environ['REUSE_RUN_ID']
    if not re.fullmatch(r'\d+', run_id):
        raise ValueError('Invalid original build run')
    run = json.loads(subprocess.check_output([
        'gh', 'api', f'repos/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/{run_id}'], text=True))
    if run['head_sha'] != commit:
        raise ValueError('Original run does not contain the expected compiled source')
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', commit], check=True)
    changed = set(subprocess.check_output(['git', 'diff', '--name-only', commit, 'HEAD'], text=True).splitlines())
    allowed = {'scripts/smoke_windows.py', 'scripts/reuse_windows_package.py', '.github/workflows/windows-preview.yml'}
    if changed - allowed:
        raise ValueError('Application or build inputs changed; a fresh compilation is required')
    output = root / 'dist/windows'
    validation = json.loads((output / 'Windows-validation.json').read_text(encoding='utf-8-sig'))
    if validation.get('ok') is not True or validation.get('architecture') != 'x64':
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
