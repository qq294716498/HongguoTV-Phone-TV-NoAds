# 红果TV

**QQ 交流群：636504313** 🐧 交流使用问题、反馈 Bug、分享下载文件。

手机、电视和电脑上的短剧客户端，支持搜索、播放、弹幕、追剧、分集下载与局域网同步。

[下载安装](#下载安装) · [使用说明](#使用说明) · [问题反馈](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/issues) · [全部发布](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases)

## 下载安装

**手机和 Android TV 共用 APK，Windows 与 Mac 分别下载对应 ZIP。** 各平台独立更新，版本号可能不同。

| 平台 | 系统要求 | 当前正式版 | 下载入口 |
| --- | --- | --- | --- |
| Android 手机 / 平板 | Android 8.0 及以上 | 0.1.51 | [64 位 APK](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.51-87/HongguoTV-0.1.51-arm64-v8a.apk) · [32 位 APK](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.51-87/HongguoTV-0.1.51-armeabi-v7a.apk) |
| Android TV / 电视盒子 | Android 8.0 及以上 | 0.1.51 | [64 位 APK](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.51-87/HongguoTV-0.1.51-arm64-v8a.apk) · [32 位 APK](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.51-87/HongguoTV-0.1.51-armeabi-v7a.apk) |
| Windows 电脑 | Windows 10 / 11，x64 | 0.1.51 | [Windows 完整 ZIP](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.51-87/HongguoTV-0.1.51-windows-x64.zip) |
| Mac 电脑 | macOS 13 及以上，Apple 芯片 / Intel | 0.1.48 | [macOS 通用 ZIP](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/macos-v0.1.48-74/HongguoTV-0.1.48-macos-universal.zip) |
| Android x86_64 模拟器 | Android 8.0 及以上，x86_64 | 0.1.51 | [x86_64 APK](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.51-87/HongguoTV-0.1.51-x86_64.apk) |
| iPhone / iPad | 暂无已签名安装包 | — | 暂不提供下载，仅保留 iOS 工程 |

### 怎么选、怎么装

- **手机：** 大多数新手机选择 64 位 APK。更新时使用与原安装一致的架构，直接覆盖安装，无需卸载。
- **电视 / 盒子：** 按设备的 Android 系统架构选择。部分设备芯片是 64 位，但系统是 32 位，应使用 32 位 APK。安装后支持遥控器操作，不需要另找电视专版。
- **Windows：** 将完整 ZIP 解压到可写目录后启动，保留全部 DLL 和资源文件，不要只复制 EXE。手动升级前从托盘彻底退出旧版；若旧更新器报错，可将新版完整包解压到新目录使用，保留原应用数据。当前 EXE 未签名。
- **Mac：** 解压 ZIP，将 `HongguoTV.app` 移入“应用程序”。当前应用为 ad-hoc 签名，未经过 Apple Developer ID 签名和公证；首次启动可能需要在“系统设置 → 隐私与安全性”中允许打开。

找不到附件时，在对应发布页展开 **Assets**：[Android](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.51-87) · [Windows](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.51-87) · [macOS](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/macos-v0.1.48-74)。源码、SHA-256 校验清单和验证报告也在发布附件中；安装应用请选择 APK 或平台 ZIP，不要下载 GitHub 自动生成的 Source code。

## 主要功能

- **浏览与搜索：** 分类、推荐、榜单、剧名搜索及分集选择。
- **播放与弹幕：** 倍速、快进快退、自动连播、下一集预加载，以及弹幕速度、透明度等设置。
- **多季与追剧：** 查看同剧各季、保存观看记录、继续观看和检查下一季。
- **下载与本地播放：** 分集下载、暂停、继续、重试、任务管理及合并导出。
- **设备互联：** 局域网配对、追剧进度同步和推送播放。
- **设置与备份：** 本地用户、配置备份与恢复、网络设置及手机观看提醒。

各端界面和部分能力不同，具体以所装版本为准；片源、清晰度和可用性取决于源站与网络。

## 使用说明

### 手机 / 平板

在播放页打开选集、简介或下载面板；上下滑动切换集数，轻点画面显示控制栏。横屏支持亮度、音量和快进操作，长按可临时加速，双击左右区域可后退或快进。弹幕和观看提醒可在设置中调整。

### Android TV / 电视盒子

使用方向键移动焦点，确认键选择，返回键关闭弹层或返回上页。播放页可进入选集、查看全季和播放设置。电视端解码模式按设备能力选择，支持情况以设备实际表现为准。

### Windows / Mac

支持键盘、鼠标操作和全屏播放。Windows 可使用空格播放／暂停、F 或 F11 全屏、Esc 退出全屏，并提供托盘和迷你窗；Mac 的窗口行为以 macOS 版本为准。

### 追剧、下载与备份

从“查看全季”选择季与集数；加入追剧后，可继续观看并检查是否有下一季。详情页或播放页支持分集下载，下载后的内容可本地播放。更换设备或重装前，建议先在设置中导出备份。

## 应用内更新

Android 和 Windows 可在“关于”或设置的“软件更新”页面手动检查更新。应用按当前平台和安装架构选择安装包，不会自动下载或安装；自动检查可在设置中关闭。

“跳过此版本”仅隐藏该版本的自动提醒，仍可手动检查。若旧版更新器无法读取更新信息，请使用上方完整安装包手动更新。

Mac 当前不支持应用内自动安装更新，请从 macOS 下载入口获取新版。

## 问题反馈

加入 **QQ 群 636504313**，或提交 [GitHub Issue](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/issues)。反馈时尽量附上：

- 应用版本、设备型号、系统版本及使用的站源。
- 剧名、季数、集数和触发问题的操作步骤。
- 截图或播放调试日志；分享前移除账号、令牌等私人信息。

## 项目与致谢

本项目是基于 [guoapp](https://github.com/zhoufuweigg/guoapp) 的非官方独立客户端，并参考 [Xanerix/guoapp](https://github.com/Xanerix/guoapp)、[hongguo-open-player](https://github.com/zfdang/hongguo-open-player) 等开源项目的实现。

软件免费提供，请勿付费购买，谨防盗卖。使用时请遵守内容版权及相关许可。

播放器涉及 [media_kit](https://github.com/media-kit/media-kit) / libmpv，合并导出使用 [FFmpegKit min-gpl](https://github.com/sk3llo/ffmpeg_kit_flutter)，包含 GPL 媒体组件。内置 Microsoft Fluent Emoji 3D 素材按 MIT 许可保留；各组件许可见应用“关于”和对应依赖目录。

<details>
<summary>开发与构建</summary>

工具链：Flutter 3.47.4、Go 1.24.1+、Python 3.10+。Android 使用 JDK 17、SDK 36、NDK 28.2.13676358；Windows 需要 Visual Studio C++ 桌面组件与 MinGW-w64 x64；Mac / iOS 需要 macOS、Xcode 与 CocoaPods。

```sh
flutter pub get --enforce-lockfile
python3 scripts/build_android.py --all-sources
python3 scripts/build_android.py --all-sources --abi arm64-v8a
python3 scripts/build_macos.py
python3 scripts/build_ios.py
```

```powershell
.\scripts\build_windows.ps1 -AllSources
```

产物位于 `dist/android`、`dist/windows`、`dist/macos`、`dist/ios`。不同站源构建应使用匹配的 Dart 与原生核心配置。构建脚本的网络镜像与签名选项见脚本参数。

集中验证使用 `flutter test --dart-define=DISABLE_REMOTE_IMAGES=true`，全站源加 `--dart-define=ALL_SOURCES=true`；Go 核心在 `native` 下运行 `go test -race ./...`。平台构建与自动化通过不等同所有实体设备验收。

源码修改后执行：

```sh
python3 scripts/finish_task.py --message "本次实际完成的变更"
python3 scripts/sync_source.py --check
```

</details>
