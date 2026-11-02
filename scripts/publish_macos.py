import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess

REPO = 'qq294716498/HongguoTV-Phone-TV-NoAds'
BUILD_RUN = 41383092284
BUILD_COMMIT = '0af8eb27588ed1685aacc7a5ff3afeb29f2f165a'
SHA256 = ''
RUNTIME_BASELINE = '58a40832b75b3687c531d8f50bfa1eeda54e0432'
VERSION, BUILD = '0.1.46', 71
TAG = 'macos-v0.1.46-71'
PACKAGE = 'HongguoTV-0.1.46-macos-universal.zip'
PROTECTED_TAGS = ('app-v0.1.46-71', 'windows-v0.1.46-71', 'macos-v0.1.34-59')
JOBS = {'build', 'smoke (macos-15)', 'smoke (macos-15-intel)',
        'playback (macos-15)', 'playback (macos-15-intel)'}
PENDING_NOTE = '公开发布核验进行中：尚未完成 macOS 公网下载、SHA-256 与其他平台隔离复核。'
VERIFIED_NOTE = '公开发布核验已完成：macOS 公网下载、SHA-256 与其他平台隔离复核通过。'
root = Path(__file__).resolve().parents[1]
release_only_paths = frozenset({
    'README.md', '.github/workflows/android-stable.yml', '.github/workflows/windows-preview.yml',
    'scripts/publish_android_stable.py', 'scripts/test_android_stable_publish.py',
    'scripts/publish_windows_stable.py', 'scripts/test_windows_stable_publish.py',
    'scripts/reuse_windows_package.py', 'scripts/test_reuse_windows_package.py',
    'test/app_update_live_test.dart', 'test/windows_update_live_test.dart',
    'test/windows_update_cleanup_test.dart',
    'integration_test/windows_playback_queue_test.dart',
    'integration_test/windows_app_autoplay_chain_test.dart',
    'integration_test/macos_app_autoplay_chain_test.dart',
    'integration_test/desktop_app_autoplay_chain.dart',
    'scripts/verify_android_player_tests.py', 'scripts/test_verify_android_player_tests.py',
    'scripts/test_windows_single_instance_native.py', 'scripts/tests/windows_single_instance_harness.cpp',
    '.github/workflows/macos.yml', '.github/workflows/macos-publish.yml',
    'scripts/build_macos.py', 'scripts/publish_macos.py', 'scripts/test_macos_publish.py',
    'scripts/verify_macos_checks.py', 'scripts/test_verify_macos_checks.py',
})
SMOKE_KEYS = ('ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux',
              'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'encryptedPlayback',
              'playbackPower', 'fullscreen', 'mediaKitPlayback')


def api(route):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{route}'], cwd=root, text=True))


def optional_api(route):
    result = subprocess.run(['gh', 'api', f'repos/{REPO}/{route}'], cwd=root, capture_output=True, text=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if 'HTTP 404' in result.stderr:
        return None
    raise ValueError('GitHub lookup failed: ' + result.stderr.strip())


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def source_commit():
    return os.environ.get('GITHUB_SHA') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()


def validate_release_source(commit):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Exact release source commit is required')
    ancestor = subprocess.check_output(['git', 'merge-base', RUNTIME_BASELINE, commit], cwd=root, text=True).strip()
    if ancestor != RUNTIME_BASELINE:
        raise ValueError('Release must descend from the approved runtime baseline')
    changed = subprocess.check_output(['git', 'diff', '--name-only', RUNTIME_BASELINE, commit, '--'], cwd=root, text=True).splitlines()
    forbidden = set(changed) - release_only_paths
    if forbidden:
        raise ValueError('Runtime source changed beyond the approved baseline: ' + ', '.join(sorted(forbidden)))
    return sorted(changed)


def validate_identity(value, commit, run, scope=True):
    if value.get('ok') is not True or value.get('version') != VERSION or value.get('build') != BUILD:
        raise ValueError('macOS evidence version or success mismatch')
    if value.get('sourceCommit') != commit or str(value.get('workflowRun')) != str(run):
        raise ValueError('macOS evidence source or workflow mismatch')
    if scope and value.get('allSources') is not False:
        raise ValueError('macOS existing source scope must remain false')


def validate_build(run, commit):
    if not re.fullmatch(r'[1-9][0-9]*', str(run)) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Validated macOS build run and commit must be pinned')
    value = api(f'actions/runs/{run}')
    if value.get('head_sha') != commit or value.get('conclusion') != 'success' or value.get('status') != 'completed' or value.get('path') != '.github/workflows/macos.yml':
        raise ValueError('Exact macOS build workflow did not pass')
    jobs = api(f'actions/runs/{run}/jobs?filter=latest&per_page=100')['jobs']
    if len(jobs) != len(JOBS) or {job['name'] for job in jobs} != JOBS or any(job.get('conclusion') != 'success' for job in jobs):
        raise ValueError('All five macOS build and architecture jobs must pass')


def minimum_version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError('Invalid native minimum macOS version')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def validate_package(value, package, commit, run):
    validate_identity(value, commit, run)
    if value.get('package') != PACKAGE or value.get('sha256') != digest(package) or value.get('bytes') != package.stat().st_size or package.stat().st_size <= 0:
        raise ValueError('macOS package size, name or digest mismatch')
    if value.get('minimumMacOS') != '13.0' or value.get('renderer') != 'Skia Metal' or value.get('signature') != 'ad-hoc' or value.get('notarized') is not False:
        raise ValueError('macOS renderer, system or signing contract changed')
    architectures, minimums = value.get('architectures', {}), value.get('nativeMinimumVersions', {})
    required = {'Contents/MacOS/HongguoTV', 'Contents/Frameworks/libduanju_core.dylib'}
    if not required.issubset(architectures) or set(architectures) != set(minimums):
        raise ValueError('Complete native architecture and minimum-system evidence is required')
    for name, archs in architectures.items():
        if not isinstance(archs, list) or len(archs) != 2 or set(archs) != {'arm64', 'x86_64'}:
            raise ValueError('Universal binary architecture missing: ' + name)
        versions = minimums[name]
        if not isinstance(versions, list) or len(versions) != 2 or any(minimum_version(version) > (13, 0, 0) for version in versions):
            raise ValueError('Native library requires a newer macOS or lacks both slice minimums: ' + name)


def validate_checks(value, commit, run):
    validate_identity(value, commit, run)
    if type(value.get('flutterTestsPassed')) is not int or value['flutterTestsPassed'] < 1000 or type(value.get('flutterTestsSkipped')) is not int or value['flutterTestsSkipped'] < 0 or value.get('flutterTestsFailed') != 0 or value.get('flutterCompletedSuccessfully') is not True:
        raise ValueError('Complete successful macOS Flutter regression is required')
    if any(type(value.get(key)) is not int or value[key] != 0 for key in ('analysisErrors', 'analysisWarnings', 'flutterTestsFailed')) or type(value.get('analysisInfos')) is not int or value['analysisInfos'] < 0:
        raise ValueError('macOS static analysis evidence is invalid')


def validate_smoke(value, arch, commit, run):
    validate_identity(value, commit, run)
    runs = value.get('runs', [])
    if value.get('platform') != 'macos' or value.get('hostArchitecture') != arch or value.get('repeatedLaunches') != 3 or len(runs) != 3:
        raise ValueError('Both architectures need three actual native launches')
    for item in runs:
        if item.get('version') != VERSION or item.get('build') != BUILD or not all(item.get(key) is True for key in SMOKE_KEYS):
            raise ValueError('Native macOS media smoke validation failed')


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_app_autoplay_chain(value, arch, commit, run):
    validate_identity(value, commit, run)
    abi = {'arm64': 'macos_arm64', 'x86_64': 'macos_x64'}[arch]
    if value.get('nativeExecuted') is not True or value.get('platform') != 'macos' or value.get('hostArchitecture') != arch or value.get('dartAbi') != abi:
        raise ValueError('App autoplay must execute on the expected native macOS architecture')
    hardware = value.get('hardwareVideoOutput')
    expected = 'auto' if hardware is True else 'videotoolbox-copy'
    if type(hardware) is not bool or value.get('expectedHwdec') != expected or value.get('decoder', {}).get('hwdec') != expected or value.get('fixtureAudioOutput') != 'null':
        raise ValueError('App autoplay must preserve the probed production macOS decoder configuration')
    handle = value.get('nativeHandle')
    if type(handle) is not int or handle <= 0 or value.get('playerCount') != 1 or value.get('playerOpenCount') != 1 or value.get('samePlayer') is not True or value.get('nativeQueueVerified') is not True:
        raise ValueError('App autoplay must keep one actual player and open media only once')
    if value.get('firstFrameMeasured') is not False or value.get('physicalAudioVideoContinuityMeasured') is not False:
        raise ValueError('App autoplay cannot claim physical first-frame or audio/video acceptance')
    if value.get('failures') != [] or value.get('playbackErrors') != [] or value.get('resolvedEpisodes') != [1]:
        raise ValueError('App autoplay failures, errors or ordinary reopen fallback were observed')
    episodes, handoffs, history = value.get('episodes', []), value.get('handoffs', []), value.get('history', [])
    if len(episodes) != 4 or [item.get('episode') for item in episodes] != [1, 2, 3, 4] or len(handoffs) != 3:
        raise ValueError('App autoplay must verify four consecutive episodes and three handoffs')
    for item in episodes:
        duration = item.get('durationMs')
        if item.get('ok') is not True or item.get('observedAtOneSecond') is not True or item.get('noEarlyAdvance') is not True or item.get('nativeHandle') != handle or not item.get('title') or not item.get('episodeLabel') or not numeric(duration) or duration < 4500:
            raise ValueError('App autoplay episode identity or stable early playback is missing')
        if not all(numeric(item.get(key)) and 900 <= item[key] <= 2500 for key in ('positionAtOneSecondMs', 'nativePositionAtOneSecondMs')) or not all(numeric(item.get(key)) and duration - 1000 <= item[key] <= duration + 1000 for key in ('nearEndPositionMs', 'nativeNearEndPositionMs')):
            raise ValueError('App autoplay public and native clocks must reach early and tail checkpoints')
        threshold = 4000 if item['episode'] == 4 else 3000
        if not any(row.get('episode') == item['episode'] and numeric(row.get('positionMs')) and row['positionMs'] >= threshold for row in history):
            raise ValueError('App autoplay per-episode viewing history is incomplete')
    previous = 0
    identities = set()
    events = value.get('queueEvents', [])
    for index, item in enumerate(handoffs, start=1):
        generation, identity = item.get('generation'), item.get('identity')
        progress = item.get('previousHistoryPositionMs')
        if item.get('from') != index or item.get('to') != index + 1 or item.get('activated') is not True or item.get('ready') is not True or item.get('nativeHandle') != handle or not isinstance(identity, str) or not identity or identity in identities or type(generation) is not int or generation <= previous or not numeric(progress) or progress < 3000:
            raise ValueError('App autoplay handoff order, identity or previous history was not validated')
        for kind in ('activated', 'ready'):
            matches = [row for row in events if row.get('episode') == index + 1 and row.get('kind') == kind]
            if len(matches) != 1 or matches[0].get('identity') != identity or matches[0].get('generation') != generation:
                raise ValueError('App autoplay must show exactly one actual queue activation and ready event')
        identities.add(identity)
        previous = generation


def release_identity(value):
    return {**{key: value[key] for key in ('id', 'tag_name', 'target_commitish', 'draft', 'prerelease', 'body')},
            'assets': sorted([{key: item.get(key) for key in ('id', 'name', 'size', 'digest', 'state', 'browser_download_url')}
                              for item in value['assets']], key=lambda item: item['id'])}


def isolation_state():
    latest = api('releases/latest')
    if latest.get('tag_name') != PROTECTED_TAGS[0]:
        raise ValueError('Android Latest must remain on the existing 0.1.46 release')
    releases = {tag: release_identity(api('releases/tags/' + tag)) for tag in PROTECTED_TAGS}
    if any(value['draft'] or value['prerelease'] for value in releases.values()):
        raise ValueError('Protected releases must remain stable')
    channel = api('contents/windows-stable.json?ref=windows-stable-channel')
    content = base64.b64decode(channel['content'], validate=False)
    manifest = json.loads(content)
    windows = manifest.get('release', {})
    if manifest.get('schema') != 1 or windows.get('tag_name') != PROTECTED_TAGS[1] or windows.get('draft') is not False or windows.get('prerelease') is not False:
        raise ValueError('Existing Windows stable channel identity is invalid')
    branch = api('git/ref/heads/windows-stable-channel')['object']['sha']
    return {'androidLatest': release_identity(latest), 'releases': releases,
            'windowsChannel': {'blob': channel['sha'], 'branchCommit': branch, 'sha256': hashlib.sha256(content).hexdigest()}}


def prepare(artifacts=None, output=None, build_run=None, build_commit=None):
    artifacts = artifacts or root / 'artifacts'
    output = output or root / 'dist/macos-publish'
    run, commit = str(build_run or BUILD_RUN), build_commit or BUILD_COMMIT
    release_commit = source_commit()
    validate_build(run, commit)
    validate_release_source(commit)
    changed = validate_release_source(release_commit)
    version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.M).group(1)
    if version != f'{VERSION}+{BUILD}':
        raise ValueError('Existing 0.1.46+71 version must be preserved')
    package = artifacts / 'package' / PACKAGE
    package_report = read_json(artifacts / 'package/macOS-validation.json')
    validate_package(package_report, package, commit, run)
    checksum = digest(package)
    if SHA256 and checksum != SHA256:
        raise ValueError('Pinned macOS package digest mismatch')
    checks = read_json(artifacts / 'package/macOS-checks.json')
    validate_checks(checks, commit, run)
    sources = {PACKAGE: package, 'macOS-validation.json': artifacts / 'package/macOS-validation.json',
               'macOS-checks.json': artifacts / 'package/macOS-checks.json'}
    for arch in ('arm64', 'x86_64'):
        smoke = artifacts / arch / 'macOS-smoke.json'
        chain = artifacts / ('playback-' + arch) / 'macOS-app-autoplay-chain.json'
        validate_smoke(read_json(smoke), arch, commit, run)
        validate_app_autoplay_chain(read_json(chain), arch, commit, run)
        sources[f'macOS-smoke-{arch}.json'] = smoke
        sources[f'macOS-app-autoplay-chain-{arch}.json'] = chain
    protected = isolation_state()
    output.mkdir(parents=True, exist_ok=True)
    for name, path in sources.items():
        shutil.copy2(path, output / name)
    write_json(output / 'macOS-protected-platforms.json', protected)
    write_json(output / 'macOS-source-and-checks.json', {
        **checks, 'binaryBuildCommit': commit, 'releaseSourceCommit': release_commit,
        'runtimeBaselineCommit': RUNTIME_BASELINE, 'runtimeChangesBeyondApprovedCommit': False,
        'releaseOnlyPathsChanged': changed, 'buildWorkflow': f'https://github.com/{REPO}/actions/runs/{run}',
        'publishWorkflow': f'https://github.com/{REPO}/actions/runs/{os.environ["GITHUB_RUN_ID"]}' if os.environ.get('GITHUB_RUN_ID') else None,
        'nativeRepeatedLaunchesPerArchitecture': 3, 'nativeAutoplayEpisodesPerArchitecture': 4,
        'physicalDeviceTested': False, 'hardwareVideoOutputTested': False,
        'liveUpstreamPlaybackTested': False, 'notarized': False, 'packageSha256': checksum,
    })
    names = sorted([*sources, 'macOS-protected-platforms.json', 'macOS-source-and-checks.json'])
    (output / 'SHA256SUMS.txt').write_text(''.join(digest(output / name) + '  ' + name + '\n' for name in names), encoding='utf-8')
    return {'sha256': checksum, 'sourceCommit': release_commit, 'files': [*names, 'SHA256SUMS.txt']}


def require_pins():
    if not re.fullmatch(r'[1-9][0-9]*', str(BUILD_RUN)) or not re.fullmatch(r'[0-9a-f]{40}', BUILD_COMMIT) or not re.fullmatch(r'[0-9a-f]{64}', SHA256):
        raise ValueError('Publication refused until exact BUILD_RUN, BUILD_COMMIT and SHA256 are pinned')


def notes():
    return f'''红果TV macOS {VERSION} · Apple 芯片 / Intel 通用版

同步已发布 0.1.46+71 的连续自动切集修复与灰白“已追剧”配色，保留单播放器、现有站源范围和兼容策略。

两种架构分别完成三次普通 / 加密合成媒体启动自检及四集真实 PlayerScreen 自动续播检查，验证公共 / 原生时钟、交接身份、观看记录与单播放器。完整 Flutter 回归、静态检查和 Go race 通过；实际数量见附件报告。使用 Skia Metal，最低 macOS 13。

下载 ZIP，解压后将 HongguoTV.app 移至“应用程序”。仅有 ad-hoc 本地签名，未做 Apple Developer ID 签名和公证。首次打开可能需要在“系统设置 → 隐私与安全性”允许。真实 Mac 硬件输出、上游内容播放及长期音画连续性仍待实机验收；云端合成测试不能替代实机验证。Mac 暂无应用内自动安装更新。

{PENDING_NOTE}

Android Latest、Windows 正式版及静态更新通道、旧 Mac 0.1.34 发布均保持不变。
构建提交：{BUILD_COMMIT}
发布源码：{source_commit()}
构建 CI：https://github.com/{REPO}/actions/runs/{BUILD_RUN}
'''


def verify_public(output):
    require_pins()
    validate_build(str(BUILD_RUN), BUILD_COMMIT)
    validate_release_source(source_commit())
    source = read_json(output / 'macOS-source-and-checks.json')
    if source.get('binaryBuildCommit') != BUILD_COMMIT or source.get('packageSha256') != SHA256 or source.get('releaseSourceCommit') != source_commit():
        raise ValueError('Prepared publication identity does not match pinned source and package')
    value = api('releases/tags/' + TAG)
    if value.get('tag_name') != TAG or value.get('draft') is not False or value.get('prerelease') is not False or value.get('target_commitish') != source['releaseSourceCommit']:
        raise ValueError('Published macOS release metadata mismatch')
    tag = api('git/ref/tags/' + TAG)['object']
    if tag.get('type') != 'commit' or tag.get('sha') != source['releaseSourceCommit']:
        raise ValueError('Published macOS tag does not identify the release source')
    expected = dict(line.split('  ', 1)[::-1] for line in (output / 'SHA256SUMS.txt').read_text().splitlines())
    required_names = {PACKAGE, 'macOS-validation.json', 'macOS-checks.json',
                      'macOS-protected-platforms.json', 'macOS-source-and-checks.json',
                      'macOS-smoke-arm64.json', 'macOS-smoke-x86_64.json',
                      'macOS-app-autoplay-chain-arm64.json', 'macOS-app-autoplay-chain-x86_64.json'}
    if set(expected) != required_names or any(not re.fullmatch(r'[0-9a-f]{64}', checksum) or digest(output / name) != checksum for name, checksum in expected.items()):
        raise ValueError('Prepared macOS manifest or attachment integrity mismatch')
    expected['SHA256SUMS.txt'] = digest(output / 'SHA256SUMS.txt')
    assets = value.get('assets', [])
    if len({item['name'] for item in assets}) != len(assets) or set(expected) - {item['name'] for item in assets} or {item['name'] for item in assets} - set(expected) - {'macOS-public-download.json'}:
        raise ValueError('Published macOS asset set differs from the prepared release')
    for name, checksum in expected.items():
        asset = next(item for item in assets if item['name'] == name)
        if asset.get('size') != (output / name).stat().st_size or asset.get('digest') != 'sha256:' + checksum or asset.get('state') != 'uploaded':
            raise ValueError('Published macOS attachment mismatch: ' + name)
    asset = next(item for item in assets if item['name'] == PACKAGE)
    url = f'https://github.com/{REPO}/releases/download/{TAG}/{PACKAGE}'
    if asset.get('browser_download_url') != url:
        raise ValueError('Public macOS package URL mismatch')
    downloaded = output.parent / 'macos-public.zip'
    subprocess.run(['curl', '--fail', '--location', '--connect-timeout', '30', '--max-time', '180', url, '--output', str(downloaded)], check=True)
    if digest(downloaded) != SHA256 or downloaded.stat().st_size != asset['size']:
        raise ValueError('Public macOS ZIP failed SHA-256 or size verification')
    if isolation_state() != read_json(output / 'macOS-protected-platforms.json'):
        raise ValueError('Protected Android, Windows or old macOS release/channel changed')
    report = {'ok': True, 'version': VERSION, 'build': BUILD, 'url': url, 'sha256': SHA256,
              'bytes': asset['size'], 'releaseSourceCommit': source['releaseSourceCommit'],
              'binaryBuildCommit': BUILD_COMMIT, 'buildWorkflowRun': str(BUILD_RUN),
              'publicMetadataVerified': True, 'androidLatestPreserved': True,
              'androidReleasePreserved': True, 'windowsReleasePreserved': True,
              'windowsStableChannelPreserved': True, 'previousMacOSReleasePreserved': True}
    report_path = output / 'macOS-public-download.json'
    write_json(report_path, report)
    existing = [item for item in assets if item['name'] == report_path.name]
    if existing:
        if existing[0].get('digest') != 'sha256:' + digest(report_path):
            raise ValueError('Existing public verification report differs; refusing overwrite')
    else:
        subprocess.run(['gh', 'release', 'upload', TAG, str(report_path), '--repo', REPO], check=True)
    body = value.get('body', '')
    if body.count(PENDING_NOTE) == 1 and VERIFIED_NOTE not in body:
        final_notes = output / 'macos-final-notes.md'
        final_notes.write_text(body.replace(PENDING_NOTE, VERIFIED_NOTE), encoding='utf-8')
        subprocess.run(['gh', 'release', 'edit', TAG, '--repo', REPO, '--notes-file', str(final_notes)], check=True)
        if api('releases/tags/' + TAG).get('body') != final_notes.read_text(encoding='utf-8'):
            raise ValueError('Final macOS publication notes update was not confirmed')
    elif body.count(VERIFIED_NOTE) != 1 or PENDING_NOTE in body:
        raise ValueError('macOS publication status paragraph is missing or ambiguous')
    final = api('releases/tags/' + TAG)
    reports = [item for item in final.get('assets', []) if item.get('name') == report_path.name]
    if len(reports) != 1 or reports[0].get('size') != report_path.stat().st_size or reports[0].get('digest') != 'sha256:' + digest(report_path) or reports[0].get('state') != 'uploaded':
        raise ValueError('Public macOS verification report upload was not confirmed')
    if final.get('body', '').count(VERIFIED_NOTE) != 1 or PENDING_NOTE in final.get('body', ''):
        raise ValueError('Final macOS verified publication status was not confirmed')
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('prepare', 'publish', 'verify-public'))
    parser.add_argument('--artifacts', type=Path, default=root / 'artifacts')
    parser.add_argument('--output', type=Path, default=root / 'dist/macos-publish')
    parser.add_argument('--build-run')
    parser.add_argument('--build-commit')
    options = parser.parse_args()
    if options.action == 'prepare':
        result = prepare(options.artifacts, options.output, options.build_run, options.build_commit)
        print(json.dumps(result, ensure_ascii=False))
        return
    if options.build_run or options.build_commit:
        raise ValueError('Publication cannot override pinned build identity')
    require_pins()
    if options.action == 'verify-public':
        print(json.dumps(verify_public(options.output), ensure_ascii=False))
        return
    if optional_api('releases/tags/' + TAG) is not None:
        raise ValueError('macOS release already exists; use verify-public to recover verification without publishing again')
    if optional_api('git/ref/tags/' + TAG) is not None:
        raise ValueError('macOS tag already exists; refusing to overwrite or reuse it')
    result = prepare(options.artifacts, options.output)
    notes_file = options.output / 'macos-notes.md'
    notes_file.write_text(notes(), encoding='utf-8')
    subprocess.run(['gh', 'release', 'create', TAG,
                    *[str(options.output / name) for name in result['files']], '--repo', REPO,
                    '--target', result['sourceCommit'], '--title', f'红果TV {VERSION} · macOS 通用版',
                    '--notes-file', str(notes_file), '--latest=false'], check=True)
    print(json.dumps(verify_public(options.output), ensure_ascii=False))


if __name__ == '__main__':
    main()
