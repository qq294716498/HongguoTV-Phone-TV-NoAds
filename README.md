# 红果TV · 手机 / Android TV / Windows

基于 [guoapp](https://github.com/zhoufuweigg/guoapp) 的非官方独立客户端。手机与 Android TV 共用 Android 应用，另提供 Windows x64 客户端；支持浏览、搜索、播放、弹幕、追剧和下载。

## 开发中：0.1.24-dev.1+49

本分支基于 0.1.23+48 修正网页详情回退丢失内容类型，以及备用取流请求固定使用漫剧类型 1004 的问题。已知类型沿用对应剧集的值；旧缓存和未知类型保留原回退行为。

以《持械入宋：第六季》第 1 集为在线验证目标，对比原客户端与所提供官方 APK 7.4.1.32 的请求参数。自动化分别检查源码回归和真实取址；仅在取址成功后检查最多 64 字节的 MP4 文件头，不请求站源图片，不输出媒体地址、密钥、Cookie 或设备身份。

此版本尚未通过在线播放验收，不属于正式修复版，不更新现有安装包和正式发布。

GitHub 首轮验证：默认站源与全站源的 Go 竞争检查、回归及源码同步通过；Linux 和 Windows 对指定集数的在线取流均失败。正式解析器、APK 7.4.1.32 参数和既有签名对照均未取得有效媒体；官方播放接口返回 HTTP 200、正文 0 字节。测试继续保留失败状态，不将回归通过等同于播放恢复。

## 最近正式更新：0.1.23+48

本次补齐红果播放模型接口偶发空正文时的有限重试，并增加 Windows 单实例和更新交接保护。保留 0.1.22 的取源时限与取消、切集恢复、Windows 全屏和剧情简介、当前集与本季数量、跳过版本及弹幕表情改进，以及播放源、弹幕设置、预加载、下一集 / 下一季、全季、追剧与进度、搜索发现、下载与合并、备份、TV 解码设置和局域网互联。安装包、源码及验证结果以对应 Release 和附件为准；自动化不等同用户设备验收。

## Windows 正式版：0.1.23+48

- 红果播放模型接口遇到 HTTP 200 且正文为零字节时，最多增加一次短退避重试；仍服从当前请求时限、取消和站源冷却，不刷新设备身份，不把所有空响应都视为已经解决。
- 同一 Windows 账户下，支持单实例的客户端跨安装目录共用一个实例；再次启动唤醒托盘或最小化窗口，保持原暂停状态。旧版 0.1.22 及更早的 EXE 无法追溯补上启动检查，请先从托盘退出旧版，再使用新版入口。
- 更新重启继续等待旧客户端退出；发生跨目录实例冲突时保护正在使用的用户配置，保留事务记录供恢复。
- 红果取源增加统一时限和取消处理；切集、返回或关闭时终止过期任务，隔离迟到结果，避免旧请求占用新一集的状态。预加载失败后可重新取源。
- 正确显示站源冷却剩余时间并停止无效自动重试，遵守服务端 429 的 Retry-After；保留限流保护，不绕过冷却。
- 修复最大化进入全屏、迷你窗恢复全屏时原生客户区不足的问题；退出全屏恢复正常标题栏和原窗口状态。保持视频比例及正常黑边。
- 侧栏加入可展开、滚动的剧情简介，修复深色面板文字颜色；显示当前集与本季数量，连载或未完整列表使用“已更新 / 已载入”，保留特别篇名称。
- “跳过此版本”只隐藏该版本的自动提示，设置中仍可手动检查、下载和安装；新版本重新提示。
- 弹幕补充 [笑]、[哭]、[什么]、[敬礼]、[吃瓜] 等表情；图片未就绪或失败时保留原始文字，未知名称不丢失。
- 未取得确切对应素材的 [没看够] 保留完整方括号文字；手机、TV 和 Windows 共用此回退规则，不用其他表情代替，也不显示空白或 OBJ。

Windows 10/11 x64 完整 ZIP 仍未签名。构建、完整包校验、合成媒体启动、托盘 / 迷你窗、更新事务及公网更新下载 / 静态清单回退的结果见本次 Release 附件。真实站源长时间连播、用户旧版本原地替换、消费级 GPU、音频设备和多显示器混合 DPI 尚未实测；保持视频比例及正常黑边。

## Android 最近更新：0.1.23+48

- 手机与 TV 共用播放模型接口的空正文有限重试：最多增加一次短退避，仍在原总时限内；取消、切集立即终止旧任务，429 / Retry-After 不重试绕过。
- 手机与 TV 共用红果取源、预加载及切集修复：统一请求时限，取消过期任务并隔离迟到结果，失败后可重新获取播放地址。
- 正确显示冷却剩余时间，停止无效自动重试并遵守服务端 429 的 Retry-After；不绕过限流保护。
- 修复简介正文颜色，显示当前集与本季播放列表数量；连载、未完整列表和特别篇保留对应含义。
- “跳过此版本”只关闭该版本的自动提示，设置中的手动检查、下载和安装继续可用。
- 补充弹幕表情与 [吃瓜] 别名；图片加载失败或尚未就绪时保留原始文字，未知名称保持原文。
- [没看够] 暂未取得确切素材，保留完整原文；缺图时手机、TV、Windows 均不使用不相关表情替代。

手机 / TV 继续共用 com.hongguo.tv、既有正式证书和三 ABI，最低 Android 8.0 不变。版本、证书、ABI、安装包完整性与公开更新下载的核验结果见本次 Release 附件。真实手机 / TV 覆盖安装、索尼 HEVC、遥控器及长时间连播尚未实测。

## 下载安装

请选择与平台和架构匹配的安装包；可用版本、校验清单和源码以对应 Release 的实际附件为准。

[Android 最新正式版](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/latest) · [Windows 正式版](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.23-48)

| 设备架构 | 下载 |
| --- | --- |
| Windows 10/11 x64 · 完整 ZIP、未签名 | [HongguoTV 0.1.23 Windows x64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.23-48/HongguoTV-0.1.23-windows-x64.zip) |
| Android arm64-v8a · 大多数手机及较新的电视 / 盒子 | [HongguoTV 0.1.23 ARM64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.23-48/HongguoTV-0.1.23-arm64-v8a.apk) |
| Android armeabi-v7a · 32 位手机 / 电视 / 盒子 | [HongguoTV 0.1.23 32 位](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.23-48/HongguoTV-0.1.23-armeabi-v7a.apk) |
| Android x86_64 · 对应架构模拟器 | [HongguoTV 0.1.23 x86_64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.23-48/HongguoTV-0.1.23-x86_64.apk) |

支持 Android 8.0 及以上系统。请选择与设备和已安装应用匹配的架构；更新时直接覆盖安装，无需先卸载。

三架构 APK 的 [SHA-256 校验清单](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.23-48/SHA256SUMS.txt) 与源码见 [0.1.23 发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.23-48)。Windows 的校验清单及源码见上方 Windows 正式版入口。最新版本源码可从对应发布标签查看；其他分支的源码版本以各自的 `pubspec.yaml` 为准。

Windows 请完整解压到可写目录，勿只复制 EXE 或混放旧 DLL。**首次从旧版升级，或旧更新器在暂存目录解压 DLL 时报告拒绝访问，请先保存进度并从托盘彻底退出旧程序，再下载完整 ZIP，解压到独立的新目录。**同一 Windows 账户继续使用原应用数据；保留原目录，不卸载或清除数据。手动换用完整包不会修复仍在运行的旧更新器；新版交接保护在运行新版后用于后续更新。

## 应用内更新

在“关于”或设置中的“软件更新”页面点击“检查更新”，确认版本后下载并安装。应用会自动选择与当前安装版本匹配的架构。

启动和恢复前台时也会自动检查；自动检查结果最多缓存 12 小时，需要立即刷新时请手动检查。应用不会自动下载或安装，可以在设置中关闭自动检查。“跳过此版本”只隐藏该版本自动提示，手动更新继续可用，新版本仍会提示。

## 主要功能

- 手机 / TV 通用：自动适配触摸操作与电视遥控器。
- 内容浏览：分类、榜单、搜索、推荐及分集选择。
- 播放体验：倍速、快进、自动连播、下一集预缓冲和手机手势操作。
- 弹幕：手机与 TV 顶部弹幕、速度与透明度设置、重复内容合并及内置表情。
- 观看提醒：手机可设置每日观看时长和睡觉时间提醒，两项均默认关闭。
- 全季与追剧：查看同剧各季、直接选集；按系列保存追剧并继续最近观看，提供“已有下季”提示。
- 下载、合并与备份：分集下载、任务管理、设备端合并导出、设置备份与恢复。
- 设备互联：同一局域网内配对、追剧同步和推送播放。

## 使用说明

### 手机

竖屏观看时，可从播放页打开选集、简介和下载面板；上下滑动切换分集。控制栏隐藏时，轻点画面唤出控制栏；控制栏显示时可切换播放 / 暂停。

横屏提供亮度、音量、倍速及快进操作。长按可临时加速，松手恢复；双击左右区域可后退 / 快进 15 秒。

### Windows

空格播放 / 暂停，左右方向键短按后退 / 前进 5 秒，右方向键长按临时加速，上下方向键调整应用音量，M 静音，F/F11 全屏，Esc 退出全屏。右缘入口打开选集 / 全季，侧栏可切换简介；迷你窗复用当前播放器。默认关闭窗口会暂停并保存进度后进入托盘，恢复后保持暂停；设置可改为直接退出。

### Android TV

通过方向键移动焦点，确认键选择内容，返回键关闭当前弹层或返回。手机与 TV 使用同一安装包，无需另装电视专版。TV 播放设置与全局设置共用解码模式，手机不应用该选项；系统软解仅使用设备自带解码器，不保证所有 HEVC 规格可用。

### 弹幕与提醒

在播放设置中调整弹幕速度、透明度或关闭弹幕。手机观看提醒可以在全局设置或播放设置中开启，并按本地用户保存。

### 追剧、下载与备份

从详情页或播放选集中的“查看全季”切换季并直接选择集数，无需先加入追剧。追剧只提供加入 / 取消；同系列集中显示最近观看的季和集，进入追剧页会检查是否已有下季。历史页面继续保留各季的观看记录。详情页或播放页可选择分集下载；下载列表支持暂停、继续、重试和删除任务。更换设备前可从设置中导出备份。

### 网络设置

管理员可在“设置与备份 → 网络与资源”选择自动、直连或手动代理，并调整请求与下载并发。内容可用性、清晰度及访问情况取决于源站和网络。

## 平台与验证状态

| 平台 | 安装包与验证结果 |
| --- | --- |
| Android 手机 / Android TV | 0.1.23+48 三 ABI、既有正式证书、最低 Android 8.0；包名、版本、架构、证书、CRC / 对齐、资源、SHA-256 与公网更新下载结果见发布附件 |
| Windows | 0.1.23+48 x64 未签名完整 ZIP；构建、版本 / DLL / 运行库、资源、SHA-256、合成媒体原生启动、托盘 / 迷你窗、17 项更新事务、16 项单实例回归和公网下载 / 静态清单回退结果见发布附件 |
| iOS | 保留工程与构建支持，本次无已签名安装包 |

静态检查、默认 / 全站源自动化、Python 门禁、两种 Go race 配置及平台构建的结果，见 [Android 发布附件](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.23-48) 与 [Windows 发布附件](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.23-48)。请以本次 CI 和随包报告为准，不把源码、构建记录或签名检查等同完整实机验收。

自动化使用合成数据 / 媒体并禁用站源图片。真实手机 / TV 覆盖安装、索尼 HEVC、遥控器、真实站源长时间连播，以及用户 Windows 旧版原地替换、消费级 GPU / 音频设备和多显示器混合 DPI 尚未实测；正常宽屏留黑和素材自带黑边保留。取源失败还可能受源站与网络影响，不把本次生命周期修复认定为全部现场故障的唯一原因。

## 项目与许可

本软件免费提供，仅供学习交流，请勿付费购买，谨防盗卖。学习用途不免除内容版权与许可义务。应用“关于”保留[维护仓库](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds)、上游来源和依赖许可；首次来源提示确认后跨版本、跨用户保存，卸载清数据后可再次显示。

Windows 图标与 Android 使用相同品牌来源。内置表情使用 Microsoft Fluent Emoji 3D 素材，MIT 许可随资源保留；播放器及媒体组件许可见下方依赖说明与各依赖目录。“无广爽看”是体验定位，具体资源与广告情况取决于来源。

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
