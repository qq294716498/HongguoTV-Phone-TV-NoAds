import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
output = root / 'dist/windows'
repository = 'qq294716498/HongguoTV-Phone-TV-NoAds'


def github(*arguments):
    return subprocess.check_output(['gh', *arguments], cwd=root, text=True)


def metadata():
    value = json.loads(github('api', f'repos/{repository}/releases/latest'))
    return {'id': value['id'], 'tag': value['tag_name'], 'assets': [
        {'id': item['id'], 'name': item['name'], 'bytes': item['size'], 'digest': item['digest']}
        for item in value['assets']]}


def write_json(name, value):
    (output / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def read_json(name):
    return json.loads((output / name).read_text(encoding='utf-8-sig'))


def main():
    os.chdir(root)
    version, build = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE).group(1).split('+')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Only Windows stable releases are allowed')
    tag = f'windows-v{version}-{build}'
    package = output / f'HongguoTV-{version}-windows-x64.zip'
    if sys.argv[1] == 'stage':
        validation = read_json('Windows-validation.json')
        smoke = read_json('Windows-smoke.json')
        signature = read_json('Windows-signature.json')
        transactions = read_json('Windows-update-transaction.json')
        cases = transactions.get('cases', [])
        expected_cases = {'success', 'crash', 'hang', 'busy', 'tamper', 'version', 'semantic', 'architecture', 'unowned', 'junction', 'second-instance', 'real-client-startup-ack'}
        if transactions.get('ok') is not True or transactions.get('build') != int(build) or transactions.get('version') != version or len(cases) != len(expected_cases) or {item.get('case') for item in cases} != expected_cases or not all(item.get('ok') is True for item in cases):
            raise ValueError('Native update transactions not validated')
        real = next(item for item in cases if item['case'] == 'real-client-startup-ack')
        if real.get('build') != int(build) or real.get('oldBuild', int(build)) >= int(build) or real.get('startupAcknowledged') is not True:
            raise ValueError('Actual client restart was not acknowledged')
        if validation['ok'] is not True or validation['architecture'] != 'x64' or validation['build'] != int(build) or validation['version'] != version:
            raise ValueError('Windows package identity was not validated')
        with package.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if validation['sha256'] != digest:
            raise ValueError('Validated package bytes changed')
        for field in ['ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux',
                      'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'playbackPower',
                      'fullscreen', 'miniReuseResizeRestore', 'nativeTrayHidden', 'trayKeepsPlaying', 'nativeTrayRestored', 'nativeTrayQuit', 'mediaKitPlayback', 'cleanPath', 'nonAsciiPath', 'differentWorkingDirectory', 'javaEnvironmentRemoved', 'normalAppStartup', 'remoteImagesDisabled']:
            if smoke.get(field) is not True:
                raise ValueError('Missing Windows smoke check: ' + field)
        if smoke.get('nativeTrayToggles') != 2:
            raise ValueError('Native tray toggles were not validated')
        if smoke['processExitCode'] != 0 or smoke['version'] != version or smoke['build'] != int(build):
            raise ValueError('Smoke process identity or exit code failed')
        if signature['status'] != 'NotSigned' or signature['signed'] is not False:
            raise ValueError('Unexpected signing state')
        exists = subprocess.run(['gh', 'release', 'view', tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if exists.returncode == 0:
            raise ValueError('Release exists; never replace published assets')
        android = metadata()
        if not android['tag'].startswith('app-v'):
            raise ValueError('Android latest is not an Android release')
        subprocess.run(['git', 'fetch', '--depth=1', 'origin', 'tag', 'app-v0.1.12-36'], check=True)
        original = subprocess.check_output(['git', 'show', 'app-v0.1.12-36:lib/app_updates.dart'], text=True)
        current = (root / 'lib/app_updates.dart').read_text(encoding='utf-8')
        start = '  static AppRelease? parse('
        old = original[original.index(start):original.index('  Map<String, Object> get validation')].strip()
        new = current[current.index(start):current.index('  static AppRelease? parseWindows(')].strip()
        if old != new:
            raise ValueError('Android release parser changed')
        write_json('Android-isolation.json', {'before': android, 'androidParserUnchanged': True,
                                              'parserSha256': hashlib.sha256(old.encode()).hexdigest()})
        subprocess.run([sys.executable, 'scripts/finish_task.py', '--message',
                        '完成 Windows x64 正式版界面、托盘、迷你窗及更新事务验证'], check=True)
        subprocess.run([sys.executable, 'scripts/sync_source.py', '--check'], check=True)
        source = max(root.parent.glob('真果·鉴-*.zip'), key=lambda file: file.stat().st_mtime_ns)
        source_package = output / f'HongguoTV-{version}-source.zip'
        shutil.copy2(source, source_package)
        commit = os.environ['GITHUB_SHA']
        ci = f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}'
        write_json('Source-and-checks.json', {
            'version': version, 'build': int(build), 'sourceCommit': commit,
            'baselineTag': 'app-v0.1.12-36', 'baselineCommit': '48d081cd916d01f41f6e9d0d543b0ae9d3e20026',
            'workflowRun': ci,
            'binaryBuildCommit': os.environ.get('WINDOWS_BINARY_COMMIT', commit),
            'binaryBuildRun': os.environ.get('WINDOWS_BINARY_RUN', os.environ['GITHUB_RUN_ID']),
            'formatAndAnalysisPassed': True, 'pythonTestsPassed': True,
            'flutterDefaultAndAllSourceTestsPassed': True, 'goRaceDefaultAndAllSourcesPassed': True,
            'windowsCompileAndPackageValidationPassed': True, 'nativeUpdateTransactionsPassed': True,
            'nativeTrayAndMiniWindowPassed': True, 'unsigned': True,
            'sourceArchiveSha256': hashlib.file_digest(source_package.open('rb'), 'sha256').hexdigest(),
            'notTested': ['real-provider playback', 'long-running episode/season transitions',
                          'public-release-to-running-previous-client replacement', 'consumer Windows 10/11 GPU/CPU compatibility',
                          'audio device output']})
        readme = (root / 'README.md').read_text(encoding='utf-8')
        notes = readme.split('## Windows 正式版：', 1)[1].split('## Android 最近更新：', 1)[0]
        notes += f'\n构建及静态回归、Windows 完整包与合成媒体启动验证已通过。\n\n源码提交：https://github.com/{repository}/commit/{commit}\n\nCI：{ci}\n\n校验：SHA256SUMS.txt。Windows 正式渠道发布后继续验证实际更新下载和 Android Latest 隔离。\n'
        notes_file = Path(os.environ['RUNNER_TEMP']) / 'windows-release-notes.md'
        notes_file.write_text(notes, encoding='utf-8')
        assets = [package, source_package] + [output / name for name in
                 ['Windows-validation.json', 'Windows-smoke.json', 'Windows-signature.json', 'Windows-update-transaction.json', 'Source-and-checks.json']]
        subprocess.run(['gh', 'release', 'create', tag, *map(str, assets), '--target', commit,
                        '--title', f'红果TV Windows {version} · x64 未签名正式版',
                        '--notes-file', str(notes_file), '--draft', '--latest=false'], check=True)
        subprocess.run(['gh', 'release', 'edit', tag, '--draft=false', '--prerelease=false', '--latest=false'], check=True)
        published = json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))
        if published['draft'] or published['prerelease'] or metadata() != android:
            raise ValueError('Stable channel publication or Android isolation failed')
        with Path(os.environ['GITHUB_ENV']).open('a', encoding='utf-8') as stream:
            stream.write(f'EXPECTED_WINDOWS_TAG={tag}\nEXPECTED_ANDROID_TAG={android["tag"]}\n')
    elif sys.argv[1] == 'finalize':
        isolation = read_json('Android-isolation.json')
        after = metadata()
        if isolation['before'] != after:
            raise ValueError('Android Latest or original assets changed during Windows release')
        update = read_json('Windows-update-check.json')
        if update['ok'] is not True or update['windowsTag'] != tag or update['androidLatest'] != after['tag']:
            raise ValueError('Actual update download or channel isolation failed')
        published = json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))
        if published['draft'] or published['prerelease'] or update.get('windowsPrerelease') is not False:
            raise ValueError('Public Windows release is not stable')
        isolation.update(after=after, ok=True, windowsPrerelease=False, windowsMarkedLatest=False)
        write_json('Android-isolation.json', isolation)
        files = sorted(file for file in output.iterdir() if file.is_file() and file.name != 'SHA256SUMS.txt')
        (output / 'SHA256SUMS.txt').write_text(''.join(
            f'{hashlib.file_digest(file.open("rb"), "sha256").hexdigest()}  {file.name}\n' for file in files), encoding='ascii')
        subprocess.run(['gh', 'release', 'upload', tag,
                        str(output / 'Android-isolation.json'), str(output / 'Windows-update-check.json'),
                        str(output / 'SHA256SUMS.txt')], check=True)
    else:
        raise ValueError('Expected stage or finalize')


if __name__ == '__main__':
    main()
