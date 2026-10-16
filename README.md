# 红果TV · 手机 / Android TV / Windows

基于 [guoapp](https://github.com/zhoufuweigg/guoapp) 的非官方独立客户端。手机与 Android TV 共用 Android 应用，另提供 Windows x64 独立客户端。支持短剧浏览、搜索、在线播放、追剧和下载。

## Windows 正式版：0.1.15+40

本次补丁修复迷你窗仍显示系统标题行、底部选集入口重复，以及 GitHub Release API 限流时无法检查更新的问题；不更改已发布 0.1.14+39 资产。

基于已发布 Android `app-v0.1.12-36`（`48d081cd916d01f41f6e9d0d543b0ae9d3e20026`）及已发布 Windows `windows-v0.1.14-39`（`64cc42f441453915bb0a4dab93f3b075ced5bfa2`）源码增量适配。远端 `main` 的应用源码可能较旧，请使用对应发布标签。

- [Windows 正式版发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.15-40)。仅在必要检查全部通过后发布；结果以 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/workflows/windows-preview.yml) 和对应资产为准。
- [完整 Windows x64 ZIP 下载](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.15-40/HongguoTV-0.1.15-windows-x64.zip) · [SHA-256 校验清单](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.15-40/SHA256SUMS.txt) · [对应纯源码 ZIP](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.15-40/HongguoTV-0.1.15-source.zip)。
- Windows 10 / 11 x64 完整 ZIP 包含 `HongguoTV.exe`、更新助手、Go 核心、Flutter、mpv、FFmpeg、ANGLE、VC 运行库及资源；不提供 ARM64 / 32 位包。完整解压到可写目录后运行，不要只复制 EXE；不需要安装 Flutter、Go 或 FFmpeg。
- 未签名，无 Windows 签名证书。独立正式标签 `windows-v0.1.15-40`，`prerelease=false`、`make_latest=false`；Android Latest 和原 Android 资产保持不变。
- 首次从 0.1.13 / 0.1.14 预览版迁移需手动下载完整正式包；旧预览客户端只查预览渠道。0.1.15 正式版只检查 Windows 正式渠道；Release API 限流或网络失败时备用读取本仓库的静态正式更新清单，仍验证完整 ZIP 大小和 SHA-256；0.1.14 客户端在限流时首次升级需手动下载完整包。下载与安装需明确操作。

### Windows 功能与交互

| 功能 | Windows 行为 |
| --- | --- |
| 播放源、搜索、发现、全季、追剧、观看进度 | 复用 Android 0.1.12 全站源构建与本地数据逻辑；源站可用性取决于网络 |
| 弹幕与表情 | 保留内置表情、重复合并、透明度和开关；Windows 字号按播放器内实际视频逻辑区域自适应（12–28 逻辑像素），使用相同文字/表情比例，不按源视频分辨率或整块屏幕缩放。窗口、侧栏、全屏、迷你窗和 DPI 变化保留弹幕身份与当前位置；速度独立于视频倍速，0.5/0.75/1/1.15/1.25/1.5/2 倍，保存到播放偏好 |
| 预加载、下一集、下一季 | 保留共用状态机、预缓冲、跨季选择与续播提示 |
| 播放控件 | 更薄的透明底栏，正常布局约 58px、背景 40% 不透明；控制栏不压暗整幅视频；普通操作提示在底部。鼠标离开后一秒隐藏，移回/点击可唤出；拖进度/音量、菜单和键盘焦点操作期间保持。音量悬停/获焦向上展开，点击静音/恢复；快进、倍速、前后集、弹幕与完整播放设置保留 |
| 选集栏、剧名 | 展开/收起入口位于视频右缘垂直中间；按用户反馈移除底部重复四宫格按钮，窄窗/全屏/迷你窗仍可用右缘入口打开选集/全季。记住展开偏好、分页和滚动位置；窄窗、全屏与迷你窗让出视频空间。标题按实际剧集号显示“第 N 集”，随切集切季更新 |
| 键盘 | 空格播放/暂停；← 后退 5 秒；→ 短按前进 5 秒、长按临时 3 倍速；↑↓ 应用音量；M 静音；F/F11 全屏；Esc 返回原窗口/退出全屏；Tab 移动焦点 |
| 托盘 | 默认关闭窗口进入系统托盘，保持关闭前的播放/暂停状态和预加载；右键恢复、播放/暂停或“退出红果TV”。设置可关闭此行为，改为直接退出；设置中另有明确退出入口。无托盘时关闭直接退出 |
| 迷你窗 | 播放页进入，默认置顶，隐藏系统标题/最小化/最大化/关闭行；唤出控件后可拖动顶部剧名区域，保留边框缩放、返回原窗口和退出按钮；复用同一 Player / VideoController，不重开视频。返回时恢复位置、大小、最大化、置顶与全屏状态；可转全屏 |
| 手机专属功能 | 无手机亮度/系统音量手势、Android 画中画、电量状态或每日时长/睡觉提醒；使用桌面控件、托盘和迷你窗。普通窗口最小化仍暂停；关闭进托盘继续保持原状态 |
| 下载、合并、备份、网络与资源设置 | 保留设备端逻辑；真正退出后无独立下载服务。局域网首次使用可能受系统防火墙限制 |
| 更新与日志 | 设置中自动/手动检查 Windows 正式版、显示日志；校验完整 ZIP 大小/SHA-256 后“安装并重启”，失败回滚。播放/连播准备中拒绝重启，暂停后保存进度和配置；更新退出绕过托盘 |

更新先验证路径、CRC、文件清单、逐文件 SHA-256、PE x64 与版本；同卷准备完整目录，保留旧目录并原子替换。新客户端完成初始化、首帧及 nonce 确认后提交；崩溃/超时回滚旧目录和配置并重启旧版。旧目录和配置备份保留；只读、占用、重解析点或含清单外文件时停止，不提权。恢复同一用户的剧集和位置并保持暂停；锁定用户或受限来源不会自动进入播放页。

验证包括默认/全站源回归、Windows x64 编译、版本/DLL/资源/校验和、干净 PATH 与中文空格目录启动、合成 H.264/AAC 首帧/快进/倍速/音量/全屏、原生托盘关闭/恢复/暂停/退出、迷你窗反复切换及调整大小、12 个更新事务场景（含真实客户端重启确认）。发布后继续验证公开下载与 Android Latest/资产隔离；各项实际结论见发布 JSON 报告。

尚未实测真实源站解码、音频设备输出、消费级 Windows 10/11 GPU/旧 CPU 兼容、长时间跨集跨季连播，以及旧预览客户端通过公网完成整个升级事务。自动化结果不等同用户电脑验收，不会在用户电脑自动安装或运行。

## Android 最近更新：0.1.16+41

- 追剧页面不再读取和排序未使用的观看记录；观看记录筛选后的继续播放匹配使用集合，减少重复扫描。
- 网格刷新时一次建立保留条目集合，减少逐焦点逐列表查找；保留已有网格虚拟化、海报解码限制与 0.1.12 排序缓存修复。
- 关于页加入本仓库 GitHub 头像、仓库入口、免费学习交流及防盗卖声明；首次提示仅在点击“我知道了”且保存成功后记录，全局跨版本、跨用户不重弹。
- 保留播放源、弹幕、预加载、下一集/下一季、全季、追剧/进度、搜索发现、下载与手机/TV 设置。
- 三 ABI 使用既有正式证书与包名 `com.hongguo.tv`；构建号 41，ARM64 / 32 位 / x86_64 的 versionCode 分别为 2041 / 1041 / 4041。
- 发布先验证现有签名 Secrets、完整回归和三架构包，再通过实际更新器公网下载，核对签名、版本、架构、资源与哈希后转正式 Latest。没有实测帧率提升、真实手机/TV覆盖安装、源站解码或长时间连播，不将减少计算等同实机流畅度结论。

安装包和验证报告见对应发布页。Windows 0.1.15 正式资产及其旧版本保持不变。

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
| arm64-v8a · 大多数手机及较新的电视 / 盒子 | [HongguoTV 0.1.16 ARM64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.16-41/HongguoTV-0.1.16-arm64-v8a.apk) |
| armeabi-v7a · 32 位手机 / 电视 / 盒子 | [HongguoTV 0.1.16 32 位](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.16-41/HongguoTV-0.1.16-armeabi-v7a.apk) |
| x86_64 · 对应架构模拟器 | [HongguoTV 0.1.16 x86_64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.16-41/HongguoTV-0.1.16-x86_64.apk) |

支持 Android 8.0 及以上系统。请选择与设备和已安装应用匹配的架构；更新时直接覆盖安装，无需先卸载。

源码及安装包校验文件见 [0.1.16 发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.16-41)。最新版本源码可从该版本标签查看；其他分支的源码版本以各自的 `pubspec.yaml` 为准。

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
| Android 手机 / Android TV | 0.1.16 三架构安装包、现有证书签名及公开更新验证结果见正式发布页 |
| Windows | 独立 Windows x64 正式渠道；0.1.15+40 的构建、运行验证结果及下载以正式发布页为准 |
| iOS | 保留工程与构建支持，尚无本次已签名安装包 |

正式发布前执行自动化检查、安装包校验和更新下载验证；真实手机 / TV 的覆盖安装、实际播放与长时间连播仍待验收。

后续优先完成 Android 手机和 Windows 的实际使用验证，其次是 Android TV 遥控与连播验证，最后安排 iOS 构建与设备验证。

## 项目与许可

应用“关于”注明 [qq294716498 的维护仓库](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds)，展示 GitHub API 确认的公开头像（已打包，离线可用，加载失败显示默认头像），并保留上游与依赖许可。

本软件免费提供，仅供学习交流，请勿付费购买，谨防盗卖。学习用途不免除内容版权与许可义务。该共享实现随 Android 0.1.16 与 Windows 正式版提供；旧 Android 0.1.12 包不含本轮新增。首次启动显示来源提示，点击“我知道了”后以全局、跨版本标记保存；覆盖更新或切换用户不重弹，卸载清数据可再次显示。

Windows 主程序、更新助手、窗口、任务栏与托盘统一使用当前 Android Manifest 实际引用的 `drawable/app_icon → drawable-nodpi/hongguo_logo.png`，不使用未被引用的默认 mipmap。ICO 含 16–256 多尺寸，构建验证逐个检查 EXE 内嵌帧与来源校验和。

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

