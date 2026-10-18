import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = root / 'dist/android'
repository = 'qq294716498/HongguoTV-Phone-TV-NoAds'
certificate = '55c3c3395a00e56e99b8bfd580b14c99618da74db19692a2e42606eb05c47ba9'
windows_tag = 'windows-v0.1.17-42'
windows_tags = ('windows-v0.1.15-40', windows_tag)
offsets = {'arm64-v8a': 2000, 'armeabi-v7a': 1000, 'x86_64': 4000}
release_branch = 'release/tv-0.1.18-43'
tv_source = '0cf19ed34f5dd84bcd5d0a6e777f0eab2e92081b'
windows_source = '34ec11d73de7b796e444bcf81463e2e9a203650b'
release_only_paths = frozenset({
    'README.md', '.github/workflows/android-stable.yml',
    'scripts/publish_android_stable.py', 'scripts/test_android_stable_publish.py',
    'test/app_update_live_test.dart',
})


def validate_release_source(commit):
    ancestor = subprocess.check_output(['git', 'merge-base', tv_source, commit], cwd=root, text=True).strip()
    if ancestor != tv_source:
        raise ValueError('Release must descend from the approved TV source')
    changed = set(subprocess.check_output(['git', 'diff', '--name-only', tv_source, commit, '--'], cwd=root, text=True).splitlines())
    if changed - release_only_paths:
        raise ValueError('Runtime source changed beyond the approved TV commit: ' + ', '.join(sorted(changed - release_only_paths)))


def github(*arguments):
    return subprocess.check_output(['gh', *arguments], cwd=root, text=True)


def release(tag):
    return json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))


def snapshot(value):
    return {'id': value['id'], 'tag': value['tag_name'], 'target': value['target_commitish'],
            'prerelease': value['prerelease'], 'assets': sorted([
                {key: asset[key] for key in ['id', 'name', 'size', 'digest']} for asset in value['assets']], key=lambda a: a['id'])}


def validated_windows_snapshots(commit):
    published = {name: release(name) for name in windows_tags}
    candidate = published[windows_tag]
    required = {'Windows-update-check.json', 'Windows-update-channel.json', 'Android-isolation.json', 'SHA256SUMS.txt'}
    if candidate['draft'] or candidate['prerelease'] or candidate['target_commitish'] != commit or not required.issubset({asset['name'] for asset in candidate['assets']}):
        raise ValueError('Published Windows baseline is not finalized or has a different source')
    return {name: snapshot(value) for name, value in published.items()}


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
    if version != '0.1.18' or build != 43:
        raise ValueError('This workflow only publishes Android 0.1.18+43')
    validate_release_source(os.environ['GITHUB_SHA'])
    tag = f'app-v{version}-{build}'
    phase = sys.argv[1]
    if phase == 'stage':
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
        if latest['tag_name'] != 'app-v0.1.17-42' or int(latest['tag_name'].rsplit('-', 1)[1]) >= build:
            raise ValueError('Android version must increase beyond current stable')
        listed = json.loads(github('api', f'repos/{repository}/releases?per_page=100'))
        for item in listed:
            match = re.fullmatch(r'app-v\d+\.\d+\.\d+-(\d+)', item['tag_name'])
            if match and int(match[1]) >= build:
                raise ValueError('A newer or reserved Android build already exists')
        write('Release-before.json', {'android': snapshot(latest), 'windows': validated_windows_snapshots(windows_source)})
        subprocess.run([sys.executable, 'scripts/finish_task.py', '--message', 'Android 0.1.18 TV 弹幕真实时长、遥控搜索焦点、紧凑控制条与选集、播放方向键和菜单键；三ABI既有正式签名构建及集中回归通过，未实测实体TV'], check=True)
        subprocess.run([sys.executable, 'scripts/sync_source.py', '--check'], check=True)
        source = max(root.parent.glob('真果·鉴-*.zip'), key=lambda p: p.stat().st_mtime_ns)
        source_package = output / f'HongguoTV-{version}-source.zip'
        shutil.copy2(source, source_package)
        write('Source-and-checks.json', {'version': version, 'build': build, 'sourceCommit': head,
              'androidBaseline': 'app-v0.1.17-42', 'preservedWindowsBaseline': windows_tag,
              'runtimeBaselineCommit': tv_source, 'runtimeChangesBeyondApprovedTvCommit': False,
              'workflowRun': f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
              'sourceArchiveSha256': digest(source_package), 'expectedCertificate': certificate,
              'formatAnalysisPythonFlutterAndGoRacePassed': True, 'allThreeSignedApksValidated': True,
              'realPhoneOrTvPerformanceMeasured': False, 'realDevicePlaybackVerified': False})
        readme = (root / 'README.md').read_text()
        notes = readme.split('## Android 最近更新：', 1)[1].split('\n## ', 1)[0]
        notes += f'\n源码：https://github.com/{repository}/commit/{head}\n\nCI：https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}\n\n现有正式证书签名；三ABI公网下载、SHA-256与签名版本校验完成后才转正式Latest。真实手机/TV流畅度、解码与长时间连播仍未实测。\n'
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
    else:
        raise ValueError('Expected stage, promote or finalize')


if __name__ == '__main__':
    main()
