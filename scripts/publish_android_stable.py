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
        raise ValueError('Publish and finalize Windows from this exact source before Android staging')
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
    if version != '0.1.17' or build != 42:
        raise ValueError('This workflow only publishes Android 0.1.17+42')
    tag = f'app-v{version}-{build}'
    phase = sys.argv[1]
    if phase == 'stage':
        head = json.loads(github('api', f'repos/{repository}/git/ref/heads/fix/follow-sync-danmaku-ribbon-0.1.17-42'))['object']['sha']
        if head != os.environ['GITHUB_SHA']:
            raise ValueError('Newer Android source superseded this build')
        validate_apks(read('APK-validation.json'), version, build, output)
        if read('Signing-availability.json')['ok'] is not True:
            raise ValueError('Existing signing Secrets not confirmed')
        exists = subprocess.run(['gh', 'release', 'view', tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if exists.returncode == 0:
            raise ValueError('Release exists; never replace published APK assets')
        latest = json.loads(github('api', f'repos/{repository}/releases/latest'))
        if latest['tag_name'] != 'app-v0.1.16-41' or int(latest['tag_name'].rsplit('-', 1)[1]) >= build:
            raise ValueError('Android version must increase beyond current stable')
        listed = json.loads(github('api', f'repos/{repository}/releases?per_page=100'))
        for item in listed:
            match = re.fullmatch(r'app-v\d+\.\d+\.\d+-(\d+)', item['tag_name'])
            if match and int(match[1]) >= build:
                raise ValueError('A newer or reserved Android build already exists')
        write('Release-before.json', {'android': snapshot(latest), 'windows': validated_windows_snapshots(head)})
        subprocess.run([sys.executable, 'scripts/finish_task.py', '--message', 'Android 0.1.17 跨季续播同步、下季缓存彩带、长按弹幕设置及紧凑全季选集，三ABI正式签名构建回归通过'], check=True)
        subprocess.run([sys.executable, 'scripts/sync_source.py', '--check'], check=True)
        source = max(root.parent.glob('真果·鉴-*.zip'), key=lambda p: p.stat().st_mtime_ns)
        source_package = output / f'HongguoTV-{version}-source.zip'
        shutil.copy2(source, source_package)
        write('Source-and-checks.json', {'version': version, 'build': build, 'sourceCommit': head,
              'androidBaseline': 'app-v0.1.16-41', 'sharedBaseline': windows_tag,
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
        head = json.loads(github('api', f'repos/{repository}/git/ref/heads/fix/follow-sync-danmaku-ribbon-0.1.17-42'))['object']['sha']
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
