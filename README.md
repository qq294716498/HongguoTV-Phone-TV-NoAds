# 红果TV · 手机 / Android TV / Windows

基于 [guoapp](https://github.com/zhoufuweigg/guoapp) 的非官方独立客户端。手机与 Android TV 共用 Android 应用，另提供 Windows x64 独立测试客户端。支持短剧浏览、搜索、在线播放、追剧和下载。

## Windows 测试版：0.1.13-preview.1+37

基于已发布的 `app-v0.1.12-36`（`48d081cd916d01f41f6e9d0d543b0ae9d3e20026`）增量适配；远端 `main` 的应用版本可能较旧，请按发布标签取得源码。

- 完整 ZIP 包含 `HongguoTV.exe`、Go 核心、Flutter、mpv、FFmpeg、ANGLE、VC 运行库及资源。支持 Windows 10 / 11 x64；不提供 ARM64 或 32 位包。
- 完整解压到可写的新目录后运行 `HongguoTV.exe`，不要仅复制 EXE。不需要在电脑安装 Flutter、Go 或 FFmpeg。用户数据保存在系统应用数据目录。
- 沿用已发布 Android 版本的全部站源与业务逻辑，新增桌面品牌、最小窗口尺寸、播放保持亮屏和独立更新检测。
- 未使用 Windows 签名证书，属于未签名试用包。不会自动安装、运行新版本或修改旧桌面伴侣程序。
- 使用独立 `windows-v<版本>-<构建号>` 标签和 prerelease，发布时明确 `--latest=false`；不覆盖 Android 0.1.12 资产，也不改动 Android Latest。
- 测试发布页：[Windows 0.1.13-preview.1](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.13-preview.1-37)。只有必要检查通过后才提供测试包；验证结果与下载资产以 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/workflows/windows-preview.yml) 和对应测试发布页为准；未通过全部必要检查时不得标为完成。

### Windows 功能与交互

| 功能 | Windows 行为 |
| --- | --- |
| 播放源、搜索、发现、全季、追剧、观看进度 | 复用 0.1.12 全部站源构建与本地数据逻辑；源站可用性取决于网络 |
| 弹幕与表情 | 保留内置表情、重复合并、速度、透明度和开关；仍按桌面窗口宽度布局 |
| 预加载、下一集、下一季 | 保留共用状态机、预缓冲、跨季选择与续播提示 |
| 鼠标操作 | 点按播放、暂停、选集；拖动进度条；控制栏提供音量、倍速、快进 15 秒、下一集和全屏 |
| 键盘 | 播放区域获焦时：空格暂停/播放；← 后退 5 秒；→ 短按前进 5 秒、长按临时 3 倍速；↑↓ 调整应用音量；M 静音；F/F11 全屏；Esc 先退出全屏再返回；Tab 在控件间移动 |
| 手机手势与状态 | 不提供手机亮度手势、系统媒体音量手势、Android 画中画或手机电量状态；使用桌面音量与窗口控件；切换到其他窗口继续播放，最小化后暂停 |
| 手机观看提醒 | Windows 不显示或计时每日时长/睡觉提醒；保留移动端设置数据，不伪称系统通知可用 |
| 下载、合并、备份、网络与资源设置 | 保留设备端逻辑；后台下载依赖应用进程，退出应用后不会作为 Windows 服务运行；局域网首次使用可能受系统防火墙限制 |
| 更新与日志 | 设置/关于可手动检查，支持自动检查；只识别 Windows 测试 ZIP，显示发布日志并校验大小/SHA-256；打开下载目录后由用户退出应用并完整解压到新目录 |

Windows runner 将检查 x64 PE、版本、直接/延迟导入 DLL、资源、校验和、未签名状态，并在清理 PATH、含空格/中文的解压目录中启动包，使用本地合成 H.264/AAC 验证播放、首帧、探测、合并、快进、倍速、音量、全屏和亮屏通道。自动化不等同真实电脑验收：在线源站解码、音频设备输出、GPU/旧 CPU 兼容、实际跨版本更新及长时间跨集跨季连播仍需实机验证。

### Windows 开发分支：0.1.14-preview.1+38（未发布）

分支 `windows/desktop-ui-updater-0.1.14` 基于上述 Windows 已发布源码增量开发；本轮只构建 Actions 验证产物，发布 job 已禁用。Android Latest 及既有发布资产不变。

- Windows 独立底部时间轴、时间与播放/暂停、快进 15 秒、前后集控制组；保留倍速、选集/全季、弹幕开关和完整播放设置。仍使用原 Player、VideoController、弹幕和预加载状态；Android 控制界面不变。
- 音量图标悬停或获焦弹出向上的 0–100 滑条，点击图标静音/恢复原非零音量，保存应用音量；不会修改 Windows 系统音量。播放中无操作两秒隐藏，真实移动/操作显示，悬停工具栏、弹层、菜单或拖动时保持，暂停时常显。
- Windows 播放和暂停两态均不显示中央播放按钮，不因显示控制栏压暗整幅视频；播放操作和普通操作提示均放底部，仅底部工具栏使用局部背景。必要加载和错误提示保留；Android 界面不变。
- 右侧选集栏可收起，底部选集按钮作为展开入口，偏好保存在桌面设置中。窄窗口与全屏自动让出视频空间，仍可从底部打开选集；恢复窗口后按原偏好恢复，选集分页与滚动位置保留，播放器和当前进度不重建。
- 下载完成后点击“安装并重启”，自动限制解压文件数/体积、拒绝危险路径/链接/重复名称，验证 CRC、清单、逐文件 SHA-256、PE x64 与原生版本。播放中或准备连播时拒绝重启；暂停后保存进度、音量与配置，启动更新助手，再退出当前进程。
- 同卷准备完整新目录，保留整个旧目录，原子改名替换；新版本完成应用初始化后确认启动，崩溃/超时回滚旧目录和更新前配置并重启旧版。旧目录、配置备份与事务状态留存，不自动删除。占用、只读、重解析点或含安装清单以外文件的应用目录会停止更新，不提权、不改变系统安全策略。
- 0.1.13 没有更新助手，首次升级到本机制仍需完整新包；之后版本才支持集成替换。更新检测仍是 Windows 独立测试渠道，下载与安装需明确操作，不会在播放中突然重启。
- 重启恢复同一用户的剧集和位置，保持暂停；受保护/已锁定用户或受限来源不会自动进入播放页。托盘、迷你窗本轮未实现，不显示占位按钮。

新增验证覆盖桌面交互、危险 ZIP/清单、播放中拦截、Windows 更新助手提交/回滚/占用/篡改及真实客户端启动确认。尚未验证公网新版本升级、真实源站解码和长时间连播；以该分支 CI 的实际结果为准。

`38847959214` 的真实包重启确认曾失败并回滚。已为新进程正确提供标准输入/输出句柄和受控启动日志，由客户端实际探测数据与程序目录，并补上 CRLF/nonce/版本握手回归。源码 `9f1a371` 的 [CI 38849610551](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/38849610551) 已全部通过：真实客户端完成初始化、首帧和 nonce 确认，11 个隔离事务场景通过；60 秒确认窗口和回滚保护未放宽。底部控件与可收起选集栏继续随当前分支复验，尚未发布。

## Android 最近更新：0.1.12

- 修复页面操作卡顿，优化追剧与列表流畅度。
- 保留“查看全季”和进入追剧检查下季功能。
- 优化应用内更新，下载和安装前重新确认当前版本。
- 改善下载进度显示，并加强安装包版本验证。
- 已有收藏、观看记录及备份数据继续保留。

安装包和验证结果请以对应版本发布页为准。

[查看历史更新记录 →](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases)

## 与 guoapp 的主要区别

保留 [guoapp](https://github.com/zhoufuweigg/guoapp) 的浏览、搜索、站源、追剧和下载等基础功能，在原项目基础上重点增加或调整以下体验：

| 方向 | 红果TV 的主要调整 |
| --- | --- |
| 应用与发布 | 统一使用“红果TV”名称，提供手机 / TV 通用 Android 安装包，通过本仓库发布新版 |
| 手机播放交互 | 调整竖屏观看布局、点按和上下滑动切集体验；增加快进 15 秒、下一集等快捷操作 |
| TV 观看体验 | 优化遥控选集、焦点操作、标题与控制栏，分别调整手机与 TV 的弹幕显示体验 |
| 连播与衔接 | 优化下一集预缓冲、切集等待画面和跨季续播提示 |
| 弹幕 | 调整顶部弹幕，重复内容合并显示爱心计数；增加内置表情、速度与透明度设置 |
| 手机观看提醒 | 增加每日观看时长和睡觉时间提醒，可分别开启、关闭和调整 |
| 全季与追剧 | 直接查看同剧各季、按最近观看的季集继续播放，进入追剧时检查下季 |
| 应用内更新 | 从本仓库检查正式版，按当前安装架构下载更新，支持手动检查 |

## 下载安装

[查看最新正式版](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/latest)

| 设备架构 | 下载 |
| --- | --- |
| arm64-v8a · 大多数手机及较新的电视 / 盒子 | [HongguoTV 0.1.12 ARM64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.12-36/HongguoTV-0.1.12-arm64-v8a.apk) |
| armeabi-v7a · 32 位手机 / 电视 / 盒子 | [HongguoTV 0.1.12 32 位](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.12-36/HongguoTV-0.1.12-armeabi-v7a.apk) |
| x86_64 · 对应架构模拟器 | [HongguoTV 0.1.12 x86_64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.12-36/HongguoTV-0.1.12-x86_64.apk) |

支持 Android 8.0 及以上系统。请选择与设备和已安装应用匹配的架构；更新时直接覆盖安装，无需先卸载。

源码及安装包校验文件见 [0.1.12 发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.12-36)。最新版本源码可从该版本标签查看；其他分支的源码版本以各自的 `pubspec.yaml` 为准。

## 应用内更新

在“关于”或设置中的“软件更新”页面点击“检查更新”，确认版本后下载并安装。应用会自动选择与当前安装版本匹配的架构。

启动和恢复前台时也会自动检查；自动检查结果最多缓存 12 小时，需要立即刷新时请手动检查。应用不会自动下载或安装，可以在设置中关闭自动检查。

## 主要功能

- 手机 / TV 通用：自动适配触摸操作与电视遥控器。
- 内容浏览：分类、榜单、搜索、推荐及分集选择。
- 播放体验：倍速、快进、自动连播、下一集预缓冲和手机手势操作。
- 弹幕：手机与 TV 顶部弹幕、速度与透明度设置、重复内容合并及内置表情。
- 观看提醒：手机可设置每日观看时长和睡觉时间提醒，两项均默认关闭。
- 全季与追剧：查看同剧各季、直接选集；按系列保存追剧并继续最近观看，提供“已有下季”提示。
- 下载与备份：分集下载、任务管理、设置备份与恢复。
- 设备互联：同一局域网内配对、追剧同步和推送播放。

## 使用说明

### 手机

竖屏观看时，可从播放页打开选集、简介和下载面板；上下滑动切换分集。控制栏隐藏时，轻点画面唤出控制栏；控制栏显示时可切换播放 / 暂停。

横屏提供亮度、音量、倍速及快进操作。长按可临时加速，松手恢复；双击左右区域可后退 / 快进 15 秒。

### Android TV

通过方向键移动焦点，确认键选择内容，返回键关闭当前弹层或返回。手机与 TV 使用同一安装包，无需另装电视专版。

### 弹幕与提醒

在播放设置中调整弹幕速度、透明度或关闭弹幕。手机观看提醒可以在全局设置或播放设置中开启，并按本地用户保存。

### 追剧、下载与备份

从详情页或播放选集中的“查看全季”切换季并直接选择集数，无需先加入追剧。追剧只提供加入 / 取消；同系列集中显示最近观看的季和集，进入追剧页会检查是否已有下季。历史页面继续保留各季的观看记录。详情页或播放页可选择分集下载；下载列表支持暂停、继续、重试和删除任务。更换设备前可从设置中导出备份。

### 网络设置

管理员可在“设置与备份 → 网络与资源”选择自动、直连或手动代理，并调整请求与下载并发。内容可用性、清晰度及访问情况取决于源站和网络。

## 平台与验证状态

| 平台 | 状态 |
| --- | --- |
| Android 手机 / Android TV | 已发布 0.1.12 三架构正式安装包 |
| Windows | 独立 Windows x64 测试渠道；0.1.13-preview.1+37 的构建、运行验证结果及下载以测试发布页为准 |
| iOS | 保留工程与构建支持，尚无本次已签名安装包 |

正式发布前执行自动化检查、安装包校验和更新下载验证；真实手机 / TV 的覆盖安装、实际播放与长时间连播仍待验收。

后续优先完成 Android 手机和 Windows 的实际使用验证，其次是 Android TV 遥控与连播验证，最后安排 iOS 构建与设备验证。

## 项目与许可

本项目基于原项目继续维护，原作者与依赖作者的贡献及许可随源码保留。“无广爽看”是项目的体验定位，具体资源和广告情况取决于内容来源。

内置表情使用 Microsoft Fluent Emoji 3D 素材，相关 MIT 许可随资源保留，应用“关于”的许可列表可查看。播放器及媒体组件的许可见下方依赖说明与各依赖目录。

## 开发与构建

Flutter `3.47.4`、Dart `3.12+`、Go `1.24.1+`、Python `3.10+`。Android 需要 JDK 17、SDK 36、NDK `28.2.13676358`；Windows 需要 Visual Studio C++ 桌面组件及 MinGW-w64 x64；iOS 需要 macOS、完整 Xcode 和 CocoaPods。

构建脚本对子进程默认设置 `GOPROXY=https://goproxy.cn,direct`、`GOSUMDB=off`，同名环境变量可覆盖。

~~~sh
python3 scripts/build_android.py                 # 红果鉴
python3 scripts/build_android.py --all-sources   # 真果鉴
python3 scripts/build_android.py --abi arm64-v8a
python3 scripts/build_android.py --cn-mirrors    # 国内镜像
~~~

~~~powershell
.\scripts\build_windows.ps1
.\scripts\build_windows.ps1 -AllSources
.\scripts\build_windows.ps1 -ChinaMirrors
~~~

~~~sh
python3 scripts/build_ios.py
python3 scripts/build_ios.py --all-sources
python3 scripts/build_ios.py --core-only [--simulator]
python3 scripts/build_ios.py --export-options /path/to/ExportOptions.plist
~~~

产物在 `dist/android`、`dist/windows`、`dist/ios`。红果TV Android 全站源安装包命名为 `HongguoTV-{版本}-{架构}.apk`。

首次 Android 调试先编译对应架构核心，再运行：

~~~sh
python3 scripts/build_native.py --platform android --abi arm64-v8a
flutter pub get --enforce-lockfile
flutter run
~~~

调试全站源版：先给 `build_native.py` 加 `--all-sources`，再 `flutter run --dart-define=ALL_SOURCES=true`；iOS 对应 `build_ios.py --core-only --all-sources`。脚本会同步设置 Dart 常量和 Go 编译参数，应用启动时校验二者一致，避免混装原生库。

播放器使用 [media_kit](https://github.com/media-kit/media-kit) / libmpv，合并和导出使用 [FFmpegKit min-gpl](https://github.com/sk3llo/ffmpeg_kit_flutter)（含 GPL 媒体组件）。FFmpegKit 不参与正常播放或下载的转码。

### 集中检查与真机回归

~~~sh
python3 -m unittest discover -s scripts -p 'test_*.py'
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
dart analyze --fatal-infos lib test integration_test test_driver
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true --dart-define=ALL_SOURCES=true
cd native
go test -race ./...
go test -race -ldflags="-X duanjuapp/native/core.buildAllSources=true" ./...
~~~

Android 设备回归（连接并授权 USB 调试、保持解锁）：

~~~sh
python3 scripts/create_test_media.py
python3 scripts/serve_test_media.py
adb reverse tcp:38473 tcp:38473
flutter drive --driver=test_driver/playback.dart --target=integration_test/playback_test.dart \
  --dart-define=DISABLE_REMOTE_IMAGES=true --dart-define=FIXTURE_BASE_URL=http://127.0.0.1:38473
~~~

结果在 `build/device-test/results/`；结束后停服务并 `adb reverse --remove tcp:38473`。

### 源码同步

~~~sh
python3 scripts/finish_task.py --message "本次实际完成的变更"
python3 scripts/sync_source.py --check
~~~

脚本只同步纯源码到同级 `../guoapp`，并生成 `真果·鉴-YYYYMMDDHHMM.zip` 源码压缩包；不执行 Git 提交、分支或推送。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `lib` | 页面、播放器、本地用户、FFI、下载和媒体处理 |
| `native/core`、`native/bridge` | 独立站源核心、缓存、下载、目录迁移及 C ABI |
| `android`、`windows`、`ios` | 平台工程与必要资源 |
| `assets/video_enhancement`、`packages/media_kit_libs_windows_video` | 增强 Shader 与许可、固定 Windows 媒体依赖插件 |
| `scripts`、`.github/workflows` | 构建、签名、验证、同步和版本快照 |
| `test`、`integration_test` | 自动化与设备回归 |

