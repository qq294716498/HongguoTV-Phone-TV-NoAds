import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
output = root / 'dist/android'
repository = 'qq294716498/HongguoTV-Phone-TV-NoAds'
certificate = '55c3c3395a00e56e99b8bfd580b14c99618da74db19692a2e42606eb05c47ba9'
windows_tag = 'windows-v0.1.26-51'
windows_tags = ('windows-v0.1.15-40', 'windows-v0.1.17-42', 'windows-v0.1.19-44', 'windows-v0.1.22-47', 'windows-v0.1.23-48', 'windows-v0.1.24-49', 'windows-v0.1.25-50', windows_tag)
previous_android_tag = 'app-v0.1.25-50'
previous_android_commit = '71868ff6447431a12a925d784f553391e6f845a4'
pending_publication_note = '公开发布核验进行中：尚未完成三 ABI 公网下载、签名复核及 Android / Windows 升级通道隔离检查。'
verified_publication_note = '公开发布核验已完成：三 ABI 公网下载、SHA-256、正式证书与版本复核通过；Android Latest 和 Windows 升级通道隔离、旧版本资产保持检查通过。'
windows_verified_publication_note = '公开发布核验已完成：Windows 公网 ZIP 下载与 SHA-256、正式升级通道和 API 限流回退检查通过；Android Latest 隔离及旧版本资产保持检查通过。'
offsets = {'arm64-v8a': 2000, 'armeabi-v7a': 1000, 'x86_64': 4000}
release_branch = 'release/windows-android-0.1.26-51'
approved_source = 'b77d118585be7be798afb7abfc4441a851912fd4'
release_only_paths = frozenset({
    'README.md', '.github/workflows/android-stable.yml',
    '.github/workflows/windows-preview.yml',
    'scripts/publish_android_stable.py', 'scripts/test_android_stable_publish.py',
    'scripts/publish_windows_stable.py', 'scripts/test_windows_stable_publish.py',
    'scripts/reuse_windows_package.py', 'scripts/test_reuse_windows_package.py',
    'test/app_update_live_test.dart', 'test/windows_update_live_test.dart',
    'scripts/test_windows_single_instance_native.py',
    'scripts/tests/windows_single_instance_harness.cpp',
})


def validate_release_source(commit):
    if not re.fullmatch(r'[0-9a-f]{40}', approved_source):
        raise ValueError('Final approved runtime source must be pinned before release')
    ancestor = subprocess.check_output(['git', 'merge-base', approved_source, commit], cwd=root, text=True).strip()
    if ancestor != approved_source:
        raise ValueError('Release must descend from the approved runtime source')
    changed = set(subprocess.check_output(['git', 'diff', '--name-only', approved_source, commit, '--'], cwd=root, text=True).splitlines())
    if changed - release_only_paths:
        raise ValueError('Runtime source changed beyond the approved runtime commit: ' + ', '.join(sorted(changed - release_only_paths)))


def github(*arguments):
    return subprocess.check_output(['gh', *arguments], cwd=root, text=True)


def release(tag):
    return json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))


def finalize_release_notes(tag):
    published = release(tag)
    if tag != 'app-v0.1.26-51' or published['tag_name'] != tag or published['draft'] or published['prerelease'] or published['target_commitish'] != os.environ['GITHUB_SHA']:
        raise ValueError('Only the current verified Android stable release notes may be finalized')
    body = published['body']
    if body.count(pending_publication_note) != 1:
        raise ValueError('Android publication status paragraph is missing or ambiguous')
    notes = body.replace(pending_publication_note, verified_publication_note)
    notes_file = Path(os.environ['RUNNER_TEMP']) / 'android-release-notes-final.md'
    notes_file.write_text(notes, encoding='utf-8')
    subprocess.run(['gh', 'release', 'edit', tag, '--notes-file', str(notes_file)], check=True)
    if release(tag)['body'] != notes:
        raise ValueError('Final Android release notes update was not confirmed')


def snapshot(value):
    return {'id': value['id'], 'tag': value['tag_name'], 'target': value['target_commitish'],
            'prerelease': value['prerelease'], 'assets': sorted([
                {key: asset[key] for key in ['id', 'name', 'size', 'digest']} for asset in value['assets']], key=lambda a: a['id'])}


def validated_windows_snapshots(commit):
    published = {name: release(name) for name in windows_tags}
    candidate = published[windows_tag]
    required = {'Windows-update-check.json', 'Windows-update-channel.json', 'Windows-update-transaction.json', 'Windows-single-instance-native.json', 'Android-isolation.json', 'SHA256SUMS.txt'}
    if candidate['draft'] or candidate['prerelease'] or candidate['target_commitish'] != commit or not required.issubset({asset['name'] for asset in candidate['assets']}) or windows_verified_publication_note not in candidate.get('body', ''):
        raise ValueError('Published Windows baseline is not finalized or has a different source')
    return {name: snapshot(value) for name, value in published.items()}


def wait_for_windows(commit, timeout=1200):
    deadline = time.monotonic() + timeout
    required = {'Windows-update-check.json', 'Windows-update-channel.json', 'Windows-update-transaction.json', 'Windows-single-instance-native.json', 'Android-isolation.json', 'SHA256SUMS.txt'}
    while time.monotonic() < deadline:
        result = subprocess.run(['gh', 'api', f'repos/{repository}/releases/tags/{windows_tag}'], capture_output=True, text=True)
        if result.returncode == 0:
            candidate = json.loads(result.stdout)
            if candidate['target_commitish'] != commit:
                raise ValueError('Windows release source differs from this Android candidate')
            if not candidate['draft'] and not candidate['prerelease'] and required.issubset({asset['name'] for asset in candidate['assets']}) and windows_verified_publication_note in candidate.get('body', ''):
                print('Matching Windows release finalized; Android public validation may proceed.', flush=True)
                return
        elif '404' not in result.stderr:
            raise ValueError('Unable to verify the Windows release dependency: ' + result.stderr)
        print('Waiting for the matching Windows release to finish public update and isolation checks.', flush=True)
        time.sleep(30)
    raise TimeoutError('Windows release dependency did not finalize before the Android publication deadline')


def write(name, value):
    (output / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def read(name):
    return json.loads((output / name).read_text(encoding='utf-8-sig'))


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate_apks(records, version, build, directory):
    if len(records) != 3 or {row['abi'] for row in records} != set(offsets):
        raise ValueError('Expected one validated APK per ABI')
    for row in records:
        filename = f'HongguoTV-{version}-{row["abi"]}.apk'
        file = directory / filename
        if row['name'] != filename or row['package'] != 'com.hongguo.tv' or row['certificate'] != certificate or row['version'] != version or row['code'] != offsets[row['abi']] + build:
            raise ValueError('APK release identity or signing certificate mismatch')
        if not all(row.get(key) is True for key in ['crcVerified', 'zipAlignmentVerified', 'identityAssetsVerified']):
            raise ValueError('APK integrity and identity assets were not verified')
        if file.stat().st_size != row['bytes'] or digest(file) != row['sha256']:
            raise ValueError('Verified APK bytes changed')


def main():
    os.chdir(root)
    version, raw_build = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.M).group(1).split('+')
    build = int(raw_build)
    if version != '0.1.26' or build != 51:
        raise ValueError('This workflow only publishes Android 0.1.26+51')
    validate_release_source(os.environ['GITHUB_SHA'])
    tag = f'app-v{version}-{build}'
    phase = sys.argv[1]
    if phase == 'wait-windows':
        wait_for_windows(os.environ['GITHUB_SHA'])
    elif phase == 'stage':
        head = json.loads(github('api', f'repos/{repository}/git/ref/heads/{release_branch}'))['object']['sha']
        if head != os.environ['GITHUB_SHA']:
            raise ValueError('Newer Android source superseded this build')
        validate_apks(read('APK-validation.json'), version, build, output)
        if read('Signing-availability.json')['ok'] is not True:
            raise ValueError('Existing signing Secrets not confirmed')
        exists = subprocess.run(['gh', 'release', 'view', tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if exists.returncode == 0:
            raise ValueError('Release exists; never replace published APK assets')
        latest = json.loads(github('api', f'repos/{repository}/releases/latest'))
        if latest['tag_name'] != previous_android_tag or int(latest['tag_name'].rsplit('-', 1)[1]) >= build:
            raise ValueError('Android version must increase beyond current stable')
        listed = json.loads(github('api', f'repos/{repository}/releases?per_page=100'))
        for item in listed:
            match = re.fullmatch(r'app-v\d+\.\d+\.\d+-(\d+)', item['tag_name'])
            if match and int(match[1]) >= build:
                raise ValueError('A newer or reserved Android build already exists')
        write('Release-before.json', {'android': snapshot(latest), 'windows': validated_windows_snapshots(os.environ['GITHUB_SHA'])})
        subprocess.run([sys.executable, 'scripts/finish_task.py', '--message', 'Android 0.1.26 手机与TV弱网降清晰度确认、签名站源检测与下一季查询修复；三ABI既有正式签名新构建及集中回归通过，未实测实体手机或TV'], check=True)
        subprocess.run([sys.executable, 'scripts/sync_source.py', '--check'], check=True)
        source = max(root.parent.glob('真果·鉴-*.zip'), key=lambda p: p.stat().st_mtime_ns)
        source_package = output / f'HongguoTV-{version}-source.zip'
        shutil.copy2(source, source_package)
        write('Source-and-checks.json', {'version': version, 'build': build, 'sourceCommit': head,
              'androidBaseline': previous_android_tag, 'androidBaselineCommit': previous_android_commit,
              'preservedWindowsBaseline': windows_tag,
              'runtimeBaselineCommit': approved_source, 'runtimeChangesBeyondApprovedCommit': False,
              'workflowRun': f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
              'sourceArchiveSha256': digest(source_package), 'expectedCertificate': certificate,
              'formatAnalysisPythonFlutterAndGoRacePassed': True, 'allThreeSignedApksValidated': True,
              'realPhoneOrTvPerformanceMeasured': False, 'realDevicePlaybackVerified': False})
        readme = (root / 'README.md').read_text()
        notes = readme.split('## Android 最近更新：', 1)[1].split('\n## ', 1)[0]
        notes += f'\n源码：https://github.com/{repository}/commit/{head}\n\nCI：https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}\n\n手机 / TV 继续共用 com.hongguo.tv、既有正式证书和 Android 8.0 最低版本。真实手机 / TV 覆盖安装、流畅度、解码和长时间连播仍未实测。\n\n{pending_publication_note}\n'
        notes_file = Path(os.environ['RUNNER_TEMP']) / 'android-release-notes.md'
        notes_file.write_text(notes, encoding='utf-8')
        assets = [output / f'HongguoTV-{version}-{abi}.apk' for abi in offsets] + [source_package, output / 'APK-validation.json', output / 'Source-and-checks.json', output / 'Signing-availability.json']
        subprocess.run(['gh', 'release', 'create', tag, *map(str, assets), '--target', head,
                        '--title', f'红果TV Android {version} · 发布验证中', '--notes-file', str(notes_file), '--prerelease', '--latest=false'], check=True)
        Path('staged-release.json').write_text(json.dumps(release(tag)), encoding='utf-8')
    elif phase == 'promote':
        head = json.loads(github('api', f'repos/{repository}/git/ref/heads/{release_branch}'))['object']['sha']
        if head != os.environ['GITHUB_SHA']:
            raise ValueError('Newer source superseded this candidate; do not promote')
        before = read('Release-before.json')
        if {name: snapshot(release(name)) for name in windows_tags} != before['windows']:
            raise ValueError('Windows release changed during Android validation')
        current = json.loads(github('api', f'repos/{repository}/releases/latest'))
        if snapshot(current) != before['android']:
            raise ValueError('Another Android release changed Latest; do not overwrite it')
        validate_apks(read('staged-apk-validation.json'), version, build, root / 'dist/update-check')
        checks = json.loads((root / 'dist/update-check/staged-update-check.json').read_text())
        if {row['abi'] for row in checks} != set(offsets) or not all(row['downloadVerified'] for row in checks):
            raise ValueError('Public updater download not verified for all ABIs')
        subprocess.run(['gh', 'release', 'edit', tag, '--prerelease=false', '--latest', '--title', f'红果TV Android {version} · 手机 / TV 正式版'], check=True)
    elif phase == 'finalize':
        before = read('Release-before.json')
        latest = json.loads(github('api', f'repos/{repository}/releases/latest'))
        if latest['tag_name'] != tag or latest['draft'] or latest['prerelease']:
            raise ValueError('Android Latest does not match verified release')
        validate_apks(read('latest-apk-validation.json'), version, build, root / 'dist/update-check')
        if {name: snapshot(release(name)) for name in windows_tags} != before['windows']:
            raise ValueError('Published Windows assets changed')
        if snapshot(release(before['android']['tag'])) != before['android']:
            raise ValueError('Previous Android assets changed')
        for phase_name in ['staged', 'latest']:
            shutil.copy2(root / f'dist/update-check/{phase_name}-update-check.json', output)
        write('Windows-isolation.json', {'ok': True, 'before': before['windows'], 'after': {name: snapshot(release(name)) for name in windows_tags}, 'previousAndroidUnchanged': True})
        files = sorted(p for p in output.iterdir() if p.is_file() and p.name != 'SHA256SUMS.txt' and p.name != 'Release-before.json')
        (output / 'SHA256SUMS.txt').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in files), encoding='ascii')
        subprocess.run(['gh', 'release', 'upload', tag, *[str(output / name) for name in ['staged-apk-validation.json', 'latest-apk-validation.json', 'staged-update-check.json', 'latest-update-check.json', 'Windows-isolation.json', 'SHA256SUMS.txt']]], check=True)
        finalize_release_notes(tag)
    else:
        raise ValueError('Expected wait-windows, stage, promote or finalize')


if __name__ == '__main__':
    main()
