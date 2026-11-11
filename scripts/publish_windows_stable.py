import hashlib
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
output = root / 'dist/windows'
repository = 'qq294716498/HongguoTV-Phone-TV-NoAds'
release_branch = 'release/windows-android-0.1.49-84'
approved_source = 'ffe63c54f530bc97cc7a7fd62f2c5c10b81e60fa'
previous_windows_tags = ('windows-v0.1.15-40', 'windows-v0.1.17-42', 'windows-v0.1.19-44', 'windows-v0.1.22-47', 'windows-v0.1.23-48', 'windows-v0.1.24-49', 'windows-v0.1.25-50', 'windows-v0.1.29-54', 'windows-v0.1.30-55', 'windows-v0.1.31-56', 'windows-v0.1.32-57', 'windows-v0.1.34-59', 'windows-v0.1.38-63', 'windows-v0.1.39-64', 'windows-v0.1.43-68', 'windows-v0.1.46-71', 'windows-v0.1.48-74')
previous_android_tag = 'app-v0.1.48-74'
previous_android_commit = 'ca5a75106b2b7c2efb9ec0b180992fdf48bb941d'
pending_publication_note = '公开发布核验进行中：尚未完成 Windows 公网 ZIP 下载、升级通道及 Android Latest 隔离检查。'
verified_publication_note = '公开发布核验已完成：Windows 公网 ZIP 下载与 SHA-256、正式升级通道和 API 限流回退检查通过；Android Latest 隔离及旧版本资产保持检查通过。'
release_only_paths = frozenset({
    'README.md', '.github/workflows/android-stable.yml',
    '.github/workflows/windows-preview.yml',
    'scripts/publish_android_stable.py', 'scripts/test_android_stable_publish.py',
    'scripts/publish_windows_stable.py', 'scripts/test_windows_stable_publish.py',
    'scripts/reuse_windows_package.py', 'scripts/test_reuse_windows_package.py',
    'test/app_update_live_test.dart', 'test/windows_update_live_test.dart',
    'integration_test/windows_playback_queue_test.dart',
    'integration_test/windows_app_autoplay_chain_test.dart',
    'scripts/verify_android_player_tests.py', 'scripts/test_verify_android_player_tests.py',
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


def release_description(version):
    return '优化之前无法播放\n'


def finalize_release_notes(tag):
    published = json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))
    if tag != 'windows-v0.1.49-84' or published['tag_name'] != tag or published['draft'] or published['prerelease'] or published['target_commitish'] != os.environ['GITHUB_SHA']:
        raise ValueError('Only the current verified Windows stable release notes may be finalized')
    body = published['body']
    if body.count(pending_publication_note) != 1:
        raise ValueError('Windows publication status paragraph is missing or ambiguous')
    notes = body.replace(pending_publication_note, verified_publication_note)
    notes_file = Path(os.environ['RUNNER_TEMP']) / 'windows-release-notes-final.md'
    notes_file.write_text(notes, encoding='utf-8')
    subprocess.run(['gh', 'release', 'edit', tag, '--notes-file', str(notes_file)], check=True)
    if json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))['body'] != notes:
        raise ValueError('Final Windows release notes update was not confirmed')


def metadata():
    value = json.loads(github('api', f'repos/{repository}/releases/latest'))
    return {'id': value['id'], 'tag': value['tag_name'], 'assets': [
        {'id': item['id'], 'name': item['name'], 'bytes': item['size'], 'digest': item['digest']}
        for item in value['assets']]}


def write_json(name, value):
    (output / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def read_json(name):
    return json.loads((output / name).read_text(encoding='utf-8-sig'))


def release_identity(value):
    return {**{name: value[name] for name in ['id', 'tag_name', 'target_commitish', 'draft', 'prerelease']},
            'assets': sorted([{name: asset[name] for name in ['id', 'name', 'size', 'digest']}
                              for asset in value['assets']], key=lambda asset: asset['id'])}


def validate_single_instance(value):
    names = {
        'test_concurrent_launches_have_one_primary',
        'test_same_user_different_paths_share_identity',
        'test_hidden_tray_restore_preserves_pause',
        'test_minimized_restore_preserves_pause',
        'test_restore_waits_for_both_ready_signals',
        'test_missing_ipc_window_is_bounded_and_then_recovers',
        'test_hung_window_is_bounded',
        'test_legacy_hidden_and_minimized_restore_without_toggle',
        'test_legacy_without_window_blocks_new_client',
        'test_normal_and_abnormal_exit_release_mutex',
        'test_mutex_handle_is_not_inherited',
        'test_update_start_does_not_activate_or_ack_running_owner',
        'test_update_start_waits_for_exit_then_owns_mutex',
        'test_cross_path_owner_blocks_updater_child_without_ack',
        'test_update_start_refuses_legacy_owner',
        'test_shutdown_activation_waits_for_takeover_or_cancelled_exit',
    }
    expected = {'__main__.WindowsSingleInstanceNativeTests.' + name for name in names}
    cases = value.get('cases', [])
    if value.get('nativeExecuted') is not True or value.get('successful') is not True or value.get('compiler', {}).get('family') != 'MSVC' or value.get('testsRun') != len(expected) or len(cases) != len(expected) or {item.get('test') for item in cases} != expected or not all(item.get('status') == 'passed' for item in cases):
        raise ValueError('Native single-instance behavior not validated with MSVC')
    if value.get('sourceCommit') != os.environ['GITHUB_SHA'] or value.get('workflowRun') != os.environ['GITHUB_RUN_ID']:
        raise ValueError('Native single-instance evidence must come from this source and workflow run')


def validate_playback_queue(value, version, build):
    expected = {'natural', 'manual-paused', 'suspend-resume', 'failed-fallback'}
    cases = value.get('cases', [])
    if value.get('ok') is not True or value.get('nativeExecuted') is not True or value.get('playerCount') != 1 or value.get('version') != version or value.get('build') != int(build):
        raise ValueError('Native single-player queue identity was not validated')
    if value.get('sourceCommit') != os.environ['GITHUB_SHA'] or str(value.get('workflowRun')) != os.environ['GITHUB_RUN_ID']:
        raise ValueError('Native queue evidence must come from this source and workflow run')
    if len(cases) != len(expected) or {item.get('case') for item in cases} != expected:
        raise ValueError('Native queue cases are incomplete or duplicated')
    for item in cases:
        before, after = item.get('nativeHandleBefore'), item.get('nativeHandleAfter')
        if item.get('ok') is not True or item.get('samePlayer') is not True or not before or str(before) in {'0', '0x0'} or before != after:
            raise ValueError('Native queue must retain one actual player across every case')


def validate_app_autoplay_chain(value, version, build):
    if value.get('ok') is not True or value.get('nativeExecuted') is not True or value.get('version') != version or value.get('build') != int(build):
        raise ValueError('Native App autoplay chain identity was not validated')
    if value.get('sourceCommit') != os.environ['GITHUB_SHA'] or str(value.get('workflowRun')) != os.environ['GITHUB_RUN_ID']:
        raise ValueError('Native App autoplay evidence must come from this source and workflow run')
    handle = value.get('nativeHandle')
    if isinstance(handle, bool) or not isinstance(handle, int) or handle <= 0 or value.get('playerCount') != 1 or value.get('playerOpenCount') != 1 or value.get('samePlayer') is not True or value.get('nativeQueueVerified') is not True:
        raise ValueError('Native App autoplay must use one actual player without reopening media')
    if value.get('firstFrameMeasured') is not False or value.get('physicalAudioVideoContinuityMeasured') is not False:
        raise ValueError('Native App autoplay cannot claim physical first-frame or audio/video acceptance')
    episodes = value.get('episodes', [])
    handoffs = value.get('handoffs', [])
    if len(episodes) != 4 or [item.get('episode') for item in episodes] != [1, 2, 3, 4] or len(handoffs) != 3:
        raise ValueError('Native App autoplay must verify four consecutive episodes and three handoffs')
    for item in episodes:
        duration = item.get('durationMs', 0)
        positions = [item.get(name) for name in ['positionAtOneSecondMs', 'nativePositionAtOneSecondMs']]
        near_end = [item.get(name) for name in ['nearEndPositionMs', 'nativeNearEndPositionMs']]
        if item.get('ok') is not True or item.get('observedAtOneSecond') is not True or item.get('noEarlyAdvance') is not True or item.get('nativeHandle') != handle or not item.get('title') or not item.get('episodeLabel') or not isinstance(duration, (int, float)) or duration < 4500:
            raise ValueError('Native App autoplay episode identity or stable early playback was not validated')
        if not all(isinstance(position, (int, float)) and 900 <= position <= 2500 for position in positions) or not all(isinstance(position, (int, float)) and duration - 1000 <= position <= duration + 1000 for position in near_end):
            raise ValueError('Native App autoplay must validate real early and near-end playback clocks')
    previous_generation = 0
    for index, item in enumerate(handoffs, start=1):
        generation = item.get('generation')
        if item.get('from') != index or item.get('to') != index + 1 or item.get('activated') is not True or item.get('ready') is not True or item.get('nativeHandle') != handle or not item.get('identity') or isinstance(generation, bool) or not isinstance(generation, int) or generation <= previous_generation or item.get('previousHistoryPositionMs', 0) < 3000:
            raise ValueError('Native App autoplay handoff identity, order, or previous progress was not validated')
        previous_generation = generation


def publish_channel(tag, version, build):
    published = json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))
    if published['draft'] or published['prerelease'] or published['tag_name'] != tag:
        raise ValueError('Only a published Windows stable release can enter the fallback channel')
    expected = f'HongguoTV-{version}-windows-x64.zip'
    assets = [item for item in published['assets'] if item['name'] == expected]
    validation = read_json('Windows-validation.json')
    if len(assets) != 1 or assets[0]['size'] != validation['bytes'] or assets[0]['digest'] != 'sha256:' + validation['sha256']:
        raise ValueError('Public Windows package does not match the validated package')
    asset = assets[0]
    url = f'https://github.com/{repository}/releases/download/{tag}/{expected}'
    if asset['browser_download_url'] != url:
        raise ValueError('Unexpected public Windows package URL')
    digest = hashlib.sha256()
    received = 0
    with urllib.request.urlopen(url, timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            received += len(chunk)
            if received > asset['size']:
                raise ValueError('Public Windows download exceeds declared size')
            digest.update(chunk)
    if received != asset['size'] or digest.hexdigest() != validation['sha256']:
        raise ValueError('Public Windows download failed checksum verification')
    release = {name: published[name] for name in ['tag_name', 'draft', 'prerelease', 'body']}
    release['body'] = release['body'].replace(pending_publication_note, '').strip()
    release['assets'] = [{name: item[name] for name in
                          ['name', 'size', 'digest', 'state', 'browser_download_url']} for item in assets]
    manifest = {'schema': 1, 'release': release}
    encoded = json.dumps(manifest, ensure_ascii=False, indent=2).encode('utf-8') + b'\n'
    branch = 'windows-stable-channel'
    path = f'repos/{repository}/contents/windows-stable.json'
    previous = subprocess.run(['gh', 'api', path + '?ref=' + branch], capture_output=True, text=True)
    payload = {'message': f'Publish verified Windows stable update channel {tag}',
               'branch': branch, 'content': base64.b64encode(encoded).decode('ascii')}
    if previous.returncode == 0:
        current = json.loads(previous.stdout)
        old = json.loads(base64.b64decode(current['content']))
        match = re.fullmatch(r'windows-v\d+\.\d+\.\d+-(\d+)', old['release']['tag_name'])
        if not match or int(match[1]) > int(build):
            raise ValueError('Refusing to replace a newer Windows update channel')
        if int(match[1]) == int(build) and old != manifest:
            raise ValueError('Refusing to replace existing update metadata for the same build')
        payload['sha'] = current['sha']
    elif '404' in previous.stderr:
        ref = subprocess.run(['gh', 'api', f'repos/{repository}/git/ref/heads/{branch}'], capture_output=True, text=True)
        if ref.returncode != 0:
            if '404' not in ref.stderr:
                raise ValueError('Unable to read the Windows channel branch: ' + ref.stderr)
            github('api', '--method', 'POST', f'repos/{repository}/git/refs',
                   '-f', 'ref=refs/heads/' + branch, '-f', 'sha=' + os.environ['GITHUB_SHA'])
    else:
        raise ValueError('Unable to read the Windows update channel: ' + previous.stderr)
    request_file = Path(os.environ['RUNNER_TEMP']) / 'windows-channel-request.json'
    request_file.write_text(json.dumps(payload), encoding='utf-8')
    result = json.loads(github('api', '--method', 'PUT', path, '--input', str(request_file)))
    write_json('Windows-update-channel.json', {
        'ok': True, 'tag': tag, 'branch': branch, 'commit': result['commit']['sha'],
        'manifestSha256': hashlib.sha256(encoded).hexdigest(),
        'publicPackageBytes': received, 'publicPackageSha256': digest.hexdigest(),
        'url': f'https://raw.githubusercontent.com/{repository}/{branch}/windows-stable.json'})


def main():
    os.chdir(root)
    version, build = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE).group(1).split('+')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Only Windows stable releases are allowed')
    if version != '0.1.49' or build != '84':
        raise ValueError('This workflow only publishes Windows 0.1.49+84')
    tag = f'windows-v{version}-{build}'
    package = output / f'HongguoTV-{version}-windows-x64.zip'
    if sys.argv[1] == 'stage':
        validate_release_source(os.environ['GITHUB_SHA'])
        if os.environ.get('WINDOWS_BINARY_COMMIT') != os.environ['GITHUB_SHA'] or os.environ.get('WINDOWS_BINARY_RUN') != os.environ['GITHUB_RUN_ID']:
            raise ValueError('Windows release requires fresh compilation in this workflow run')
        current_head = json.loads(github('api', f'repos/{repository}/git/ref/heads/{release_branch}'))['object']['sha']
        if current_head != os.environ['GITHUB_SHA']:
            raise ValueError('A newer source commit superseded this release candidate')
        validation = read_json('Windows-validation.json')
        smoke = read_json('Windows-smoke.json')
        signature = read_json('Windows-signature.json')
        transactions = read_json('Windows-update-transaction.json')
        validate_single_instance(read_json('Windows-single-instance-native.json'))
        validate_playback_queue(read_json('Windows-playback-queue.json'), version, build)
        validate_app_autoplay_chain(read_json('Windows-app-autoplay-chain.json'), version, build)
        cases = transactions.get('cases', [])
        expected_cases = {'success', 'crash', 'hang', 'busy', 'tamper', 'version', 'semantic', 'architecture', 'unowned', 'junction', 'second-instance', 'cross-directory-client', 'cancel-before-ready', 'cancel-after-ready', 'no-handoff', 'stop-unconfirmed', 'real-client-startup-ack', 'real-client-cleanup-retry'}
        if transactions.get('ok') is not True or transactions.get('build') != int(build) or transactions.get('version') != version or len(cases) != len(expected_cases) or {item.get('case') for item in cases} != expected_cases or not all(item.get('ok') is True for item in cases):
            raise ValueError('Native update transactions not validated')
        real = next(item for item in cases if item['case'] == 'real-client-startup-ack')
        if real.get('build') != int(build) or real.get('oldBuild', int(build)) >= int(build) or real.get('startupAcknowledged') is not True:
            raise ValueError('Actual client restart was not acknowledged')
        cleanup = next(item for item in cases if item['case'] == 'real-client-cleanup-retry')
        if cleanup.get('build') != int(build) or cleanup.get('oldBuild', int(build)) >= int(build) or not all(
                cleanup.get(name) is True for name in ['cleanupVerified', 'backupRemoved', 'downloadRemoved', 'transactionRemoved', 'retryAfterRestart']):
            raise ValueError('Actual client update cleanup and deferred retry were not verified')
        if validation['ok'] is not True or validation['architecture'] != 'x64' or validation['build'] != int(build) or validation['version'] != version:
            raise ValueError('Windows package identity was not validated')
        if validation.get('brandIconsVerified') is not True or validation.get('identityAssetsVerified') is not True:
            raise ValueError('Windows branding and provenance assets were not validated')
        with package.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if validation['sha256'] != digest:
            raise ValueError('Validated package bytes changed')
        for field in ['ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux',
                      'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'playbackPower',
                      'fullscreen', 'miniReuseResizeRestore', 'miniNativeCaptionHidden', 'miniNativeResizeBorder', 'normalNativeCaptionRestored', 'nativeTrayHidden', 'trayPausesOnClose', 'trayRestoreStaysPaused', 'nativeTrayRestored', 'nativeTrayQuit', 'playerUiDetached', 'playerDisposedBeforeExit', 'windowBrandIcon', 'trayBrandIcon', 'firstLaunchNoticeVisible', 'mediaKitPlayback', 'cleanPath', 'nonAsciiPath', 'differentWorkingDirectory', 'javaEnvironmentRemoved', 'normalAppStartup', 'remoteImagesDisabled']:
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
        write_json('Windows-previous-release.json', {name: release_identity(json.loads(github('api', f'repos/{repository}/releases/tags/{name}'))) for name in previous_windows_tags})
        android = metadata()
        if android['tag'] != previous_android_tag:
            raise ValueError('Android latest changed beyond the approved stable baseline')
        subprocess.run(['git', 'fetch', '--depth=1', 'origin', 'tag', previous_android_tag], check=True)
        original = subprocess.check_output(['git', 'show', f'{previous_android_tag}:lib/app_updates.dart'], text=True)
        current = (root / 'lib/app_updates.dart').read_text(encoding='utf-8')
        start = '  static AppRelease? parse('
        old_end = '  static AppRelease? parseWindows(' if '  static AppRelease? parseWindows(' in original else '  Map<String, Object> get validation'
        old = original[original.index(start):original.index(old_end)].strip()
        new = current[current.index(start):current.index('  static AppRelease? parseWindows(')].strip()
        if old != new:
            raise ValueError('Android release parser changed')
        write_json('Android-isolation.json', {'before': android, 'androidParserUnchanged': True,
                                              'parserSha256': hashlib.sha256(old.encode()).hexdigest()})
        subprocess.run([sys.executable, 'scripts/finish_task.py', '--message',
                        '完成 Windows 0.1.49 x64 弹幕切集平滑退场、最高季最高集同步及播放性能优化；保留完整App四集与更新事务门禁，实体设备音画连续性仍未验收'], check=True)
        subprocess.run([sys.executable, 'scripts/sync_source.py', '--check'], check=True)
        source = max(root.parent.glob('真果·鉴-*.zip'), key=lambda file: file.stat().st_mtime_ns)
        source_package = output / f'HongguoTV-{version}-source.zip'
        shutil.copy2(source, source_package)
        commit = os.environ['GITHUB_SHA']
        ci = f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}'
        write_json('Source-and-checks.json', {
            'version': version, 'build': int(build), 'sourceCommit': commit,
            'baselineTag': previous_android_tag, 'baselineCommit': previous_android_commit,
            'runtimeBaselineCommit': approved_source, 'runtimeChangesBeyondApprovedCommit': False,
            'workflowRun': ci,
            'binaryBuildCommit': os.environ['WINDOWS_BINARY_COMMIT'],
            'binaryBuildRun': os.environ['WINDOWS_BINARY_RUN'],
            'formatAndAnalysisPassed': True, 'pythonTestsPassed': True,
            'flutterDefaultAndAllSourceTestsPassed': True, 'goRaceDefaultAndAllSourcesPassed': True,
            'windowsCompileAndPackageValidationPassed': True, 'nativeUpdateTransactionsPassed': True,
            'nativeSingleInstancePassed': True, 'nativeSinglePlayerQueuePassed': True,
            'nativeAppAutoplayChainPassed': True,
            'nativeTrayAndMiniWindowPassed': True, 'unsigned': True,
            'reportedPrivateAndroidTestAVRestored': True,
            'reportedPrivateTestVersion': '0.1.48-test.1+73',
            'physicalWindowsAudioVideoVerified': False,
            'sourceArchiveSha256': hashlib.file_digest(source_package.open('rb'), 'sha256').hexdigest(),
            'notTested': ['real-provider playback on physical Windows hardware', 'long-running episode/season transitions',
                          'public-release-to-running-previous-client replacement', 'consumer Windows 10/11 GPU/CPU compatibility',
                          'audio device output', 'physical audio/display continuity', 'actual Android IME latency', 'macOS queue playback']})
        notes = release_description(version)
        notes += f'\n源码提交：https://github.com/{repository}/commit/{commit}\n\nCI：{ci}\n\n校验：SHA256SUMS.txt。\n\n{pending_publication_note}\n'
        notes_file = Path(os.environ['RUNNER_TEMP']) / 'windows-release-notes.md'
        notes_file.write_text(notes, encoding='utf-8')
        assets = [package, source_package] + [output / name for name in
                 ['Windows-validation.json', 'Windows-smoke.json', 'Windows-signature.json', 'Windows-update-transaction.json', 'Windows-single-instance-native.json', 'Windows-playback-queue.json', 'Windows-app-autoplay-chain.json', 'Source-and-checks.json']]
        subprocess.run(['gh', 'release', 'create', tag, *map(str, assets), '--target', commit,
                        '--title', f'红果TV Windows {version} · x64 未签名正式版',
                        '--notes-file', str(notes_file), '--draft', '--latest=false'], check=True)
        subprocess.run(['gh', 'release', 'edit', tag, '--draft=false', '--prerelease=false', '--latest=false'], check=True)
        published = json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))
        if published['draft'] or published['prerelease'] or metadata() != android:
            raise ValueError('Stable channel publication or Android isolation failed')
        with Path(os.environ['GITHUB_ENV']).open('a', encoding='utf-8') as stream:
            stream.write(f'EXPECTED_WINDOWS_TAG={tag}\nEXPECTED_ANDROID_TAG={android["tag"]}\n')
    elif sys.argv[1] == 'channel':
        publish_channel(tag, version, build)
    elif sys.argv[1] == 'finalize':
        isolation = read_json('Android-isolation.json')
        after = metadata()
        if isolation['before'] != after:
            raise ValueError('Android Latest or original assets changed during Windows release')
        previous_windows = {name: release_identity(json.loads(github('api', f'repos/{repository}/releases/tags/{name}'))) for name in previous_windows_tags}
        if previous_windows != read_json('Windows-previous-release.json'):
            raise ValueError('Previously published Windows release changed during patch publication')
        update = read_json('Windows-update-check.json')
        if update['ok'] is not True or update['windowsTag'] != tag or update['androidLatest'] != after['tag']:
            raise ValueError('Actual update download or channel isolation failed')
        published = json.loads(github('api', f'repos/{repository}/releases/tags/{tag}'))
        if published['draft'] or published['prerelease'] or update.get('windowsPrerelease') is not False:
            raise ValueError('Public Windows release is not stable')
        channel = read_json('Windows-update-channel.json')
        if channel.get('ok') is not True or channel.get('tag') != tag or update.get('rateLimitFallbackVerified') is not True:
            raise ValueError('Windows fallback update channel has not been verified')
        isolation.update(after=after, ok=True, windowsPrerelease=False, windowsMarkedLatest=False,
                         previousWindowsTags=list(previous_windows_tags), previousWindowsUnchanged=True)
        write_json('Android-isolation.json', isolation)
        files = sorted(file for file in output.iterdir() if file.is_file() and file.name != 'SHA256SUMS.txt')
        (output / 'SHA256SUMS.txt').write_text(''.join(
            f'{hashlib.file_digest(file.open("rb"), "sha256").hexdigest()}  {file.name}\n' for file in files), encoding='ascii')
        subprocess.run(['gh', 'release', 'upload', tag,
                        str(output / 'Android-isolation.json'), str(output / 'Windows-update-check.json'),
                        str(output / 'Windows-update-channel.json'),
                        str(output / 'Windows-previous-release.json'),
                        str(output / 'SHA256SUMS.txt')], check=True)
        finalize_release_notes(tag)
    else:
        raise ValueError('Expected stage or finalize')


if __name__ == '__main__':
    main()
