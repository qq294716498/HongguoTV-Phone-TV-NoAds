import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

REPO = 'qq294716498/HongguoTV-Phone-TV-NoAds'
BUILD_RUN = 40633050384
BUILD_COMMIT = 'e87c6d6d6773edd01c2d843a232438e4098c78ef'
SOURCE_COMMIT = '127ee8915bc512c5406e8e2461d06faaedf22862'
TAG = 'macos-v0.1.33-58'
PACKAGE = 'HongguoTV-0.1.33-macos-universal.zip'
SHA256 = '741a850cb917d0cb04c27d76b391cc3e042e84240db28cf817b2206277681981'
root = Path(__file__).resolve().parents[1]
output = root / 'dist/macos-publish'
output.mkdir(parents=True, exist_ok=True)


def api(route):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{route}'], text=True))


def windows_state():
    data = api('releases/tags/windows-v0.1.32-57')
    return {'id': data['id'], 'target': data['target_commitish'],
            'assets': sorted((item['id'], item['name'], item['size'], item.get('digest'))
                             for item in data['assets'])}


run = api(f'actions/runs/{BUILD_RUN}')
if run['head_sha'] != BUILD_COMMIT or run['conclusion'] != 'success':
    raise SystemExit('Approved build did not pass')
jobs = api(f'actions/runs/{BUILD_RUN}/jobs?filter=latest')['jobs']
if {j['name'] for j in jobs} != {'build', 'smoke (macos-15)', 'smoke (macos-15-intel)'} or any(j['conclusion'] != 'success' for j in jobs):
    raise SystemExit('Both native architecture checks must pass')
changed = subprocess.check_output(['git', 'diff', '--name-only', BUILD_COMMIT, SOURCE_COMMIT], cwd=root, text=True).splitlines()
if changed != ['README.md']:
    raise SystemExit('Release source differs from approved runtime')
package = root / 'artifacts/package' / PACKAGE
report = json.loads((root / 'artifacts/package/macOS-validation.json').read_text())
if hashlib.sha256(package.read_bytes()).hexdigest() != SHA256 or report['sha256'] != SHA256:
    raise SystemExit('Package digest mismatch')
if not report['ok'] or report['minimumMacOS'] != '13.0' or report['renderer'] != 'Skia Metal' or report['version'] != '0.1.33' or report['build'] != 58:
    raise SystemExit('Package metadata mismatch')
if any(set(archs) != {'arm64', 'x86_64'} for archs in report['architectures'].values()):
    raise SystemExit('Universal architecture missing')
shutil.copy2(package, output / PACKAGE)
shutil.copy2(root / 'artifacts/package/macOS-validation.json', output)
for arch in ('arm64', 'x86_64'):
    source = root / f'artifacts/{arch}/macOS-smoke.json'
    data = json.loads(source.read_text())
    if data['hostArchitecture'] != arch or not data['ok'] or data['repeatedLaunches'] != 3 or len(data['runs']) != 3:
        raise SystemExit('Repeated native launch verification missing')
    for result in data['runs']:
        if result['version'] != '0.1.33' or result['build'] != 58 or not all(result.get(key) for key in ('ok', 'nativeCore', 'preferences', 'bundledAssets', 'ffprobe', 'remux', 'flutterWindow', 'videoFrameRendered', 'seekRateVolume', 'encryptedPlayback', 'playbackPower', 'fullscreen', 'mediaKitPlayback')):
            raise SystemExit('Native media validation failed')
    shutil.copy2(source, output / f'macOS-smoke-{arch}.json')
checks = {'ok': True, 'version': '0.1.33', 'build': 58, 'binaryBuildCommit': BUILD_COMMIT,
          'releaseSourceCommit': SOURCE_COMMIT, 'changesAfterBuild': changed,
          'buildWorkflow': f'https://github.com/{REPO}/actions/runs/{BUILD_RUN}',
          'publishWorkflow': f'https://github.com/{REPO}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
          'flutterTestsPassed': 739, 'flutterTestsSkipped': 5, 'goRacePassed': True,
          'analysisErrors': 0, 'analysisWarnings': 0, 'analysisInfos': 175,
          'nativeRepeatedLaunchesPerArchitecture': 3, 'physicalDeviceTested': False,
          'hardwareVideoOutputTested': False, 'liveUpstreamPlaybackTested': False,
          'notarized': False}
(output / 'macOS-source-and-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
(output / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in sorted(output.iterdir()) if p.is_file() and p.name != 'SHA256SUMS.txt'))
if api('releases/latest')['tag_name'] != 'app-v0.1.32-57':
    raise SystemExit('Android Latest changed before publication')
before = windows_state()
existing = subprocess.run(['gh', 'release', 'view', TAG, '--repo', REPO], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if existing.returncode == 0:
    raise SystemExit('Release already exists; refusing overwrite')
notes = root / 'dist/macos-notes.md'
notes.write_text('''macOS 13 及以上，Apple 芯片与 Intel 共用一个通用包。

下载 ZIP，解压后将 HongguoTV.app 移到“应用程序”。支持现有浏览、签名搜索、播放、弹幕、追剧和下载；新增 Mac 原生核心、桌面控制、图形能力检测及全屏适配。使用 Skia Metal，避免验证环境中出现的图形初始化崩溃与全屏切换问题。

两种架构分别连续三次通过合成普通及加密视频播放、跳转、倍速、音量、全屏进出和媒体合并检查。Flutter 回归 739 项通过、5 项跳过；Go race、静态检查和所有原生库双架构 / 最低系统版本检查通过。完整报告及 SHA-256 见附件。

此包仅有 ad-hoc 本地签名，未做 Apple Developer ID 签名和公证。首次打开可能需要在“系统设置 → 隐私与安全性”允许。真实 Mac 硬件输出、上游内容播放及长时间流畅度仍待实机验收。暂不提供 Windows 专用托盘、迷你窗及自动安装更新。

Android 与 Windows 正式版仍为 0.1.32+57，本发布不改变它们的更新入口。

''' + f'构建提交：{BUILD_COMMIT}\n发布源码：{SOURCE_COMMIT}（仅 README 更新）\n构建 CI：{checks["buildWorkflow"]}\n发布校验：{checks["publishWorkflow"]}\n')
subprocess.run(['gh', 'release', 'create', TAG, *map(str, sorted(output.iterdir())), '--repo', REPO,
                '--target', SOURCE_COMMIT, '--title', '红果TV 0.1.33 · macOS 通用版',
                '--notes-file', str(notes), '--latest=false'], check=True)
public_url = f'https://github.com/{REPO}/releases/download/{TAG}/{PACKAGE}'
public_file = root / 'dist/macos-public.zip'
subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--connect-timeout', '30', '--max-time', '180', public_url, '--output', str(public_file)], check=True)
if hashlib.sha256(public_file.read_bytes()).hexdigest() != SHA256:
    raise SystemExit('Public download digest mismatch')
if api('releases/latest')['tag_name'] != 'app-v0.1.32-57' or windows_state() != before:
    raise SystemExit('Existing platform release changed')
(root / 'dist/macOS-public-download.json').write_text(json.dumps({'ok': True, 'url': public_url, 'sha256': SHA256, 'bytes': public_file.stat().st_size, 'androidLatestPreserved': True, 'windowsReleasePreserved': True}, indent=2) + '\n')
print('macOS public download verified; Android and Windows releases preserved')
