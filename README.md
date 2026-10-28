# 红果TV · 手机 / Android TV / Windows / macOS

基于 [guoapp](https://github.com/zhoufuweigg/guoapp) 的非官方独立客户端。手机与 Android TV 共用 Android 应用，另提供 Windows x64 与 macOS 通用客户端；支持浏览、搜索、播放、弹幕、追剧和下载。

## 0.1.34+59（验证中，尚未发布）

- 下一季搜索增加从长剧名提取副标题的定向查询，兼容中文 / 阿拉伯数字及省略“第”的季数；定向搜索最多检查三页，追剧与自动续播共用查询词。查询保留取消与总超时，已发现下一季时不再因其他搜索页未读完而记为检测失败。
- 实际签名搜索确认《谁说没灵根不能修仙的？之无灵证道第42季》与《谁说没灵根不能修仙的？之无灵证道43季》简介一致。完整长标题搜索会漏掉后续季，副标题“无灵证道 第43季”返回第 43 季。真实文本与分集数据回放到追剧更新、自动续播和重启恢复后通过；未请求站源图片。
- 各平台弹幕基础移动速度提高 15%，保持用户速度档位和播放倍速独立。电视端的实时弹幕不再因播放进度漂移校正反复重启动画，缓存未变化的弹幕索引，减少重复分配；暂停、跳转和换集仍按状态同步。真实电视流畅度待实机验收。

## macOS 正式版：0.1.33+58（已发布）

新增 macOS 13 及以上通用应用工程，原生核心同时编译 Apple 芯片 arm64 和 Intel x86_64。播放器使用 media_kit，补齐全屏、桌面控制条、播放防休眠和本地核心加载；下载、合并使用共用核心及 FFmpegKit。Mac 设备互联归类为电脑；暂不提供 Windows 专用托盘、迷你窗及自动安装更新。 新增原生图形能力预检，具备条件时使用硬件输出，否则使用兼容输出并尝试 VideoToolbox copy 解码，避免缺少 OpenGL 图形格式时直接崩溃。界面使用 Skia Metal，规避 Intel 验证环境中 Impeller 的 GPU 挂起；全屏请求按顺序执行并等待系统完成事件，避免进入动画尚未结束就切换退出。打包时逐项校验原生库的双架构及最低系统版本。

构建：macOS 上安装 Flutter 3.47.4、Go 1.24.1 或更新、Xcode 与 CocoaPods，执行 `flutter pub get --enforce-lockfile` 和 `python3 scripts/build_macos.py`。产物是 `dist/macos/HongguoTV-0.1.33-macos-universal.zip`，解压后将应用移入 Applications。当前仅本地 ad-hoc 签名，未做 Apple Developer ID 签名和公证；不能视为已完成 Gatekeeper 信任验证。[macOS CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40633050384) 已通过：739 项 Flutter 回归通过、5 项跳过，Go race 与静态检查通过；Apple 芯片和 Intel 分别连续三次通过原生核心、合成普通及加密视频播放、跳转、倍速、音量、全屏进出、FFprobe 和合并检查。41 个原生二进制均含 arm64 / x86_64，原生库最低系统要求不高于 macOS 13。云端使用兼容视频输出，真实 Mac 硬件输出、上游内容播放和长时间流畅度仍待实机验收。

Mac 通用 ZIP 已发布：[下载 0.1.33](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/macos-v0.1.33-58/HongguoTV-0.1.33-macos-universal.zip) · [发布页与验证报告](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/macos-v0.1.33-58)。构建提交 `e87c6d6d6773edd01c2d843a232438e4098c78ef`，发布源码 `127ee8915bc512c5406e8e2461d06faaedf22862` 仅增加 README 验证说明。[发布 CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40634937163) 已核对公开下载 SHA-256，并确认 Android Latest 与 Windows 更新发布保持不变。

## 本次修复：0.1.32+57（已正式发布）

- 修复旧跨季续播记录在新版匹配规则下被拒绝：已保存的同源、同基础剧名、同季数单位记录继续兼容，不因两季简介识别出不同人物而拒绝读取。新剧发现仍使用原有的剧名相似度与人物证据规则。
- 该异常会同时影响追剧页渲染、剧目资料保存及继续观看；不删除追剧、历史或同步版本，已有进度和冲突候选保持。
- 保存失败不再一律提示存储空间 / 权限，记录实际异常并提供“查看日记”；追剧读取异常显示可重试诊断界面，自动更新异常被捕获，避免整页灰屏。
- 手机独立榜单默认与首页榜单一致，每行三张海报，保留排名、热度及列表切换。TV 遥控列表保持不变。
- 手机横屏选集标题与工具区合计 64 逻辑像素，网格占可用面板至少 80%，每行 6 集、字号 12、集数按钮高度 44。全季入口合并为图标，去除独立跳转与前后页按钮；滚到边界继续拖动后自动切换相邻 50 集分段，保留范围选择和定位当前。
- 发现、追剧、历史、推荐与榜单的红果剧目菜单提供“搜索其他季”，不必先收藏；搜索结果可直接选择季和集进入播放。

已用旧跨季记录复现 `续播剧目与追剧系列不一致`；修复后追剧渲染、保存、重启和继续观看入口保留原季、原集及播放位置。手机三列榜单在 320 / 390 / 430 宽度验证。追剧、继续观看、榜单三列、全屏六列与边界翻页、剧目菜单搜索均有合成回归；全站源 Flutter 完整回归 730 项通过、3 项跳过；Python 门禁及静态检查通过，两端构建及公开下载检查通过，用户设备仍需复验。

Android 三 ABI 与 Windows x64 已从 `c91e9e073cb14d27180ef1120c7185bd31b31e12` 发布。[Android CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40624354706) 与 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40624354678) 均通过；公网下载、SHA-256、APK 原证书及两端更新通道隔离检查通过。Windows 启动、合成媒体播放和更新事务通过；Windows ZIP 未签名，用户设备仍待验收。

## 上次修复：0.1.31+56（已正式发布）

- 修复首页读取旧剧库后在界面线程进行大批量追剧匹配与序列化的问题，移至后台 isolate；提交前复核当前用户、权限与页面生命周期，避免过期结果写入。
- 续季匹配先检查标题相关性，再提取简介人物；缓存不可变剧目的归一化标题，复用人物匹配正则。保留近似标题和共同主角规则。
- 原生接口返回的大 JSON 在工作 isolate 解码，减少首页缓存读取时的界面线程工作量。

复现：8,500 部合成剧目与 100 部追剧的旧匹配循环连续运行约 46 秒；修复后同一循环约 1 秒。新增大剧库后台合并测试验证主线程定时事件持续执行，伪神下一季匹配和重启恢复仍正确。此为合成负载验证，尚未在用户手机确认卡死已消失。

默认及全站源 Flutter 完整回归、两种 Go race、Python 门禁、静态检查和两端构建通过。Android 三 ABI 原证书、版本与完整性复核、公开更新器下载及 SHA-256 校验通过；Windows 启动、更新事务和公开下载校验通过。正式源码提交 `6ddb3c6def86cbef0e8b4bb76b96b5e4ffb7c98e`；[Android CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40619707778) 与 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40619707719) 均通过。Android 已成为 Latest，支持原证书覆盖升级。用户手机仍待复验，合成负载和构建通过不等同实机卡死已完全解决。

## 上次修复：0.1.30+55（已正式发布）

- 红果取流返回 HTTP 200 空正文时，播放器保持加载并显示第几轮重试，最多三轮、取址总计不超过 65 秒；整次播放准备最长 75 秒。修复原先前端 20 秒超时早于核心 30 秒预算的问题。切集、返回和关闭停止旧请求；限流、权限和本地文件错误不自动重试。
- 空响应通过结构化错误码传递给两端；设备重新注册后的重发同样执行退避，避免首轮轮换时连续立即请求。正常请求仍复用已注册身份；仅已存在的空响应恢复流程可能更新身份。
- 追剧和自动续播共用季数与匹配规则，兼容“剧名2”形式；剧名略有变化时，要求标题相似且简介中识别到相同人物名。使用规则提取人物，不是语义理解；缺少证据不会自动合并。多版本歧义仍需手动选择。
- 修复追剧本地索引仅按完整剧名归组导致近似续集不能显示的问题，并保留重启后的候选资料。基础搜索暂时失败后仍尝试定向下一季搜索，取消和限流立即停止。
- 下载视频在应用内播放时保留原剧与原集的弹幕身份，两端均可加载弹幕。弹幕请求不参与本地视频启动，失败不会阻止视频播放；未缓存的弹幕仍需要网络，导出的裸视频在外部播放器中不会自动附带弹幕。
- 手机横屏选集面板缩小为可用宽度约 34%（240–320 逻辑像素），紧凑网格保留至少 44 像素触控高度；适配右侧安全区及大字体，避免重复标题挤占选集空间。
- 修正红果目录、推荐和分集接口的签名：对齐参考项目的 Gorgon / Argus / Ladon 配置，不再混用旧 Medusa / Helios 或 Cookie；搜索仍使用已验证的 PureSign。站源检测目录只抽查每分类一页，避免把全库爬取塞进播放检测。
- 红果站源“检测连接与播放”每个空响应步骤最多三轮恢复，每步最多 65 秒，整体仍受 3 分钟任务时限约束；显示当前重试轮次，停止检测和限流立即生效。成功的搜索分类结果不再因另一分类失败而被丢弃。

验证状态：默认及全站源 Go race、两种 Flutter 完整回归与 Python 发布门禁通过；新增匹配、下载弹幕、横屏选集回归通过，两端构建和发布校验通过。真实《觉醒伪神：神明弃我我自为神2》搜索查得第三季（ID `7677963872489196569`、120 集），两季详情主角均为陈昊宇；将真实搜索及分集数据回放到追剧更新、自动续播和重启恢复入口后验证通过。第二季第 1、70、139 集及第三季第 1 集的 1080P 取址、两端流解码、完整下载及离线解码通过。首次搜索分页遇到部分失败；修复保留部分结果后另一次分页联网验证通过，不代表上游不再间歇失败。

伪神的真实站源六步检测通过：目录 54 部、签名搜索 19 条、分集 139 集、播放地址、密钥和媒体字节读取均成功。此前用旧目录签名实测返回 200 空正文，修正签名并限制检测页数后复验通过。

Android 三 ABI 与 Windows x64 完整包已从提交 `259190d77185051386bf8edc2c32f6f270260e9b` 正式发布。[Android CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40614984598) 与 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40614984633) 均通过；公开下载、SHA-256、APK 原证书及版本 / ABI / 完整性复核、Windows 启动和更新事务、两端升级通道隔离检查通过。Android 已成为 Latest；Windows 完整 ZIP 仍未签名。

HTTP 200 仅表示 HTTP 请求成功，空正文无法证明所有上游拒绝的具体原因；尚未在用户设备复现本次间歇性失败或进行长期流畅度验收。

## 上次修复：0.1.29+54

- 播放与下载按 [Xanerix/guoapp](https://github.com/Xanerix/guoapp/tree/4ca33fb0581b8daf5d1e631b897b2518a3f7290d) 对齐：单集 `/novel/player/video_model/v1/`、`content_type=1`、`video_platform=3`，7.3.5.32 参数与播放器 Gorgon / Argus / Ladon 签名。正常请求复用已注册的 device_id / iid；仅空响应时进行有界重新注册，并合并并发恢复，注册失败暂停自动轮换。旧版随机身份批量接口不再用于正式播放和下载。
- 注册使用参考项目的 JSON 注册地址及 7.3.5.32 设备配置；沿用原有本地身份文件、启动注册门禁和搜索分页功能。取流签名不与搜索缓存混用，红果站源卡展示当前策略和状态。
- 下载串行获取元数据，低优先级排队，让前台请求优先；视频传输继续遵从下载并发设置。保留下一集预载、同清晰度备用地址、取消与有限恢复，取址失败不再误导用户降低清晰度。
- 首页加入总热播、真人、漫剧和 AI 榜单，直接展示排行海报及热度，可切换列表；Windows 使用紧凑导航、常驻搜索和更紧凑的卡片网格。保留手机触屏及 TV 遥控布局。
- 清晰度与倍速使用播放器按钮旁的浮动菜单，选中后直接收起；实际片源提供 540P 时也可选择。自动模式仍选择最高可用分辨率，显示实际档位；参考项目同样默认选择最高片源、关闭画质增强，没有证据证明其默认渲染更清晰。

验证：默认 Go race 与全站源 Go race 通过；默认与全站源 Flutter 回归通过。真实目标剧《觉醒伪神：神明弃我我自为神2》第 1–4、70、139 集均通过 1080P 取址、Windows 加密流 / Android 本地解密流音视频解码、完整文件下载及离线解码。每次解码验证读取前 8 秒；另完成 45 秒实时 1080P 播放并同时下载整集（耗时 47.521 秒），拖动至第 30 秒后继续解码 8 秒通过。上述云端链路验证不代表消费级硬件长时间流畅度验收；不下载或处理站源图片。签名搜索分页实测取得 62 条结果，包含多个后续季。

Android 三 ABI 与 Windows x64 完整包已从提交 `fc0b54ce049c78dadb5eca4937b7b23cec02e762` 正式发布。[Android CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40485975553) 与 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40485975583) 均通过；公开下载、SHA-256、APK 原证书及版本 / ABI / 完整性复核、Windows 启动和更新事务、两端升级通道隔离检查通过。Android 已成为 Latest；Windows 完整 ZIP 仍未签名。

## 上一测试版：0.1.28+53（自动化通过，联网取流仍失败）

- 红果下载仅在获取地址阶段逐个执行，取得地址后继续按设置并行下载文件。取流总预算为每轮 45 秒，其中 App 初始阶段 36 秒；空响应或超时延迟 2 秒后最多恢复一轮。每轮仍最多 4 次 App 请求，不无限重试，取消和站源限流立即停止。
- 前台播放取流预算由 18 秒调整为 30 秒，App 初始阶段由 9 秒调整为 24 秒，仍给备用路径保留时间；后台预取预算不变。
- 取流失败不再自动显示“是否尝试较低清晰度”；仅已有播放地址时提供降画质操作，自动卡顿提醒同集最多一次。错误详情保留在独立入口。
- 按用户最新要求，取流每一次请求（包括内部重试）均重新生成临时 device_id / iid 和签名，不再使用签名缓存，不读取或发送注册 Cookie。注册身份仍供搜索等功能使用，取流不修改已保存的注册数据。
- 取流请求对齐参考项目的字段插入顺序、百分号编码、7.1.3.32 参数、请求体、15 秒单请求超时、分支抖动及二次 GET；使用独立 HTTP/1.1 传输并禁用自动压缩，保留用户代理配置与证书验证。12 组固定输入的完整 Medusa 签名与参考 JavaScript 逐字节一致，原始参考提交为 `71d25c2e23c2663d9bc7f1e52a4ed44fd878050b`；测试向量固定随机值、进程 nonce 和时间生成。

验证：702 项 Flutter 测试通过（3 项跳过）；默认 / 全站源 Go 并发测试、go vet、86 项 Python 测试（19 项平台跳过）通过；静态检查无错误或警告（161 条既有提示）。新增覆盖前两集成功、后续两集空响应后恢复的合成批量下载、恢复次数限制、取消与限流停止，以及取流失败不建议降画质、同集拒绝后不再自动弹窗。

联网未通过：已通过搜索定位《觉醒伪神：神明弃我我自为神2》（series_id：7676383631534722073）并获取完整分集。请求顺序和重试身份调整后的首次四集取址仅一集成功，其他为空；切换与参考一致的 HTTP/1.1 后仍观察到空响应。参考项目原样 JavaScript 取流请求在当前环境网络中也返回 HTTP 200、0 字节。上述改动不代表已经解决上游拒绝或实现真实整剧下载；没有下载站源图片或视频，未进行手机或用户 Windows 设备播放验收。按用户要求已从独立测试分支 `test/hongguo-reference-0.1.28-53` 的提交 `673e2ae1b83c2666e30bd24dba58c76b9e2f17b4` 构建两端测试包：[Android APK](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40445691281/artifacts/12708324448)、[Windows x64 完整包](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40445695351/artifacts/12708573102)。两端完整 CI 成功，Release 均跳过；Android 原证书 / ABI / 对齐校验和 Windows 启动 / 单实例 / 更新事务检查通过。下载后复核两个产物 ZIP、三个 APK、Windows 完整包及其清单文件的 SHA-256，通过。ARM64 APK：`0794959221dcc0cbce33932697fa60f5f0dd16dde60315b7e2c411b90f4b7b7f`；Windows ZIP：`49a3b4269bb5425c027a512353401837a2ef804632b35b978f4f5b47522b9f48`。Windows EXE 仍未签名，测试下载需登录 GitHub。目标剧最新 HTTP/1.1 四集取流验证均失败，原项目原生 Node.js HTTP 请求经同一环境代理也返回 200 空正文，不能把构建通过视为播放问题已解决。

## 上一测试版：0.1.27+52

对照 [hongguo-web 的取流实现](https://github.com/sunnysky123/hongguo-web/blob/71d25c2e23c2663d9bc7f1e52a4ed44fd878050b/server/src/service/app-source.js)，取流请求使用其 7.1.3.32 版本配置，补齐播放器能力参数、SDK 请求头与 ts；签名缓存同时保留 ts、_rticket 和签名头，刷新时一起更新。fallback_api 支持 URL、数组、对象与内嵌 JSON，二次请求继续检查域名且不转发签名。搜索和注册流程保持现有行为。

按用户最新确认，取流采用对方 localId 范围（10^15 + 48 位随机数）生成临时 device_id / iid，不携带注册 Cookie；每次新的取流生成一组，同次内部重试复用。搜索等请求仍使用注册身份，临时身份不写回注册文件。不能仅从 HTTP 200 空正文证明是哪一个字段导致失败。现有多次退避和最后刷新策略保留，不增加无限重试。

随机取流身份版本联网连续两次取得 1080P 播放地址及 5 个候选，生成 2 次签名、内部重试复用 3 次、强制刷新 0 次；仍观察到需要重试，不能保证消除上游空响应。没有下载视频或图片，也没有进行真实手机播放验收。默认和全站源 Go 并发测试、go vet 通过；前轮 40 项相关 Flutter 测试通过，本轮身份策略与站源文案修改后追加 11 项界面回归通过；应用静态分析无错误或警告。测试 APK 已从独立分支 `test/android-hongguo-0.1.27-52` 的提交 `82ce4503590a758dcb0d83c7305a9692432ee55c` 构建：[浏览器下载测试产物](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40439595783/artifacts/12706034193)。完整 CI 检查、原证书 / 版本 / ABI / CRC / 对齐校验通过，下载后三个 APK 的 SHA-256 和大小再次核对通过。ARM64 文件为 `HongguoTV-0.1.27-arm64-v8a.apk`，SHA-256：`0d323a9b0fa85b7daeed00f3305cc9921e28dcad54a742553f416e215d61b5a2`。Release 步骤已跳过，尚未正式发布；测试产物需登录 GitHub 下载 ZIP 后解压。

## 上一测试版：0.1.26+51

- 清晰度菜单固定提供自动、360P、480P、720P、1080P，可重新获取本集片源；源站未提供目标画质时不会假装已经降清晰度。
- 红果播放取流最多尝试 4 次，对 HTTP 200 空正文逐步退避，优先给 App 取流留足重试时间；搜索、片库、分集等只读接口空响应也短暂重试，取消和服务器限流仍立即生效。
- 全软件共用持久化的 device_id / iid 和 PureSign 签名缓存；重启、重试及签名刷新不更换设备身份；同一地址、参数、正文在 30 秒内复用原签名，连续空响应到最后一次才刷新。不同请求必须独立签名；红果站源卡显示生成 / 复用 / 失败后刷新次数及最近请求结果，不显示密钥、设备 ID 或签名原文。
- 在线播放长时间停滞时先询问是否重新获取较低清晰度，确认后保留播放位置重试；一次分集内只自动询问一次。取流失败页也提供逐级尝试 720P / 480P / 360P 的入口，本地播放和解码错误不自动当作弱网处理。
- 红果站源目录与播放取流继续共用已注册身份和 PureSign；“检测连接与播放”新增独立的 App 签名搜索步骤，可辨别目录、搜索、分集、取流各阶段失败。
- 追剧与自动续播增加中文 / 数字下一季定向搜索，兼容括号、省略“第”的季数标题；已找到候选时不再因无关搜索分页未结束而报同名结果过多。仍保留多版本歧义检查。
- HTTP 200 空正文属于上游未返回数据，降低清晰度仅是可选重试，不能保证恢复。真实手机 / TV 和用户 Windows 设备仍未实测。

验证：默认版 700 项、全站源版 701 项 Flutter 测试通过；静态分析无错误和警告（161 条既有提示），Go 两种构建的并发测试、go vet、86 项 Python 测试（19 项平台跳过）通过。联网签名搜索找到《万妖图录传》多个后续季；同一分集连续两次真实取流成功，签名生成 1 次、复用 1 次、刷新 0 次。已验证持续空响应最后刷新签名时 device_id / iid 不变。联网只验证搜索与取流，没有实机播放验收。按用户要求，本轮仅提供 APK 测试包，暂停 Windows 构建与 GitHub Release，须用户测试确认后才能正式发布。Android 测试构建 [40347721286](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40347721286) 已通过，源码为 `690fc791b6f81558df14371d36600ed371738f9d`；三 ABI APK 沿用既有证书，下载后 SHA-256 再次核对通过，发布步骤已跳过。ARM64 测试包为 `dist/testing/HongguoTV-0.1.26-arm64-v8a.apk`，SHA-256 为 `76e9bf09cf0b3f3ec928e70e34bd7da787fc8470ba6952b661ea529602713900`。下方下载仍为 0.1.25 正式版，更新通道未改变。

## 上次更新：0.1.25+50

- Android 手机 / TV 和 Windows 启动后先显示设备注册状态，注册及本地保存完成后才进入主界面；失败时提供“重新注册”，已注册设备直接复用本地身份。
- 搜片与下一季查找共用 App 搜索 `/reading/bookapi/search/tab/v`，优先复用本地 PureSign；匿名设备注册成功后缓存服务端下发的设备 ID 对和 Cookie，不需要导入账号。搜索、播放、片库、弹幕及下载取源在请求层共用同一组注册设备 ID 和 Cookie。旧搜索身份自动迁移，不再混用本地随机身份。
- 短剧 / 漫剧分别请求 tab 11 / 19，按页缓存并原样回传 `search_id`、`passback`、`next_offset`；客户端“继续加载”和下一季查找可以读取后续页。游标过期或停滞时提示重新搜索。
- App 首次搜索失败或为空时回退免签官网搜索与原有联想补充；后续页失败不重复展示官网第一页。保留部分结果及可重试提示。
- 搜索设备身份仅保存到应用数据目录，源码包不包含生成的设备身份、Cookie 或站源响应。请求继续遵守取消、超时和站源限流。

验证：2026-10-26 联网使用本项目 PureSign 与匿名注册身份，短剧 / 漫剧各读取前两页，共 4 次搜索请求，去重后取得 58 条结果，包含《万妖图录传》第二季、第三季；首屏与第二页走客户端实际搜索入口；App 成功不触发官网兜底的分支另经合成响应测试验证。上游另观察到间歇性 `100103`，仅对此业务码增加一次短退避，不对空正文反复注册或重发。Go 全量测试、`go vet`、`go test -race`、Linux C 共享核心库构建、Windows amd64 核心交叉编译及源码收尾脚本的 8 项测试均通过。新增启动注册成功 / 失败 / 重试的手机和桌面布局测试、统一身份与身份迁移测试均通过；默认版 692 项、全站源版 693 项 Flutter 测试通过。Android 三 ABI 与 Windows x64 完整包已从提交 `71868ff6447431a12a925d784f553391e6f845a4` 全新编译并正式发布：APK 既有证书、版本 / ABI / CRC / 对齐、Windows 正常启动与注册流程、17 项更新事务、16 项原生单实例回归、两端公网下载 / SHA-256 与升级通道隔离均通过。验证记录见 [Android CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40282381783) 和 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/40282381767)。未进行真实手机 / TV 与用户 Windows 设备验收。

协议字段参考 [HGTV 接口说明](https://github.com/pan8664716/HGTV/blob/main/docs/HONGGUO_API.md) 与 [设备注册说明](https://github.com/pan8664716/HGTV/blob/main/docs/DEVICE_REGISTER.md)，搜索签名继续使用本仓库现有 PureSign。

## 上一版本：0.1.24+49

本次修复红果取流长期失败。播放模型接口已迁到 multi_video_model/v1，请求改用 mixed_video_id_map（槽位 1004、video_platform 1024）；签名补齐 x-ladon / x-argus / x-helios / x-medusa 四个头并抖动 _rticket 避开服务端不接受的分支；兼容 video_list 直接返回与 fallback_api 二次请求两种形态，受 key_seed 保护的媒体地址按 spade 方案解密；同名同季存在多个版本时按简介相似度裁决下一季，证据不足仍交由用户选择。安装包、源码及验证结果以对应 Release 和附件为准；自动化不等同用户设备验收。

## Windows 正式版：0.1.32+57

- 修复旧跨季记录校验导致的追剧灰屏、继续观看和保存失败，保留已有记录与同步版本。
- 保存错误提供真实诊断入口；手机榜单默认每行三张海报，全屏选集每行六集、选集区至少 80%、边界翻页。
- 红果剧目菜单新增“搜索其他季”，无需收藏即可查找并选集播放。
- 自动化及两端安装包校验结果见发布附件，用户设备仍待复验。

## Windows 历史更新：0.1.31+56

- 首页大剧库的追剧匹配与 JSON 处理移出界面线程，修复加载期间长时间不响应。
- 优化续季匹配，保留伪神数字季数、简介同人物与下载弹幕功能。
- 两端构建、签名及下载校验结果见发布附件；用户手机卡死修复尚未实机验收。

## Windows 历史更新：0.1.30+55

- 红果空响应在当前播放页进行最多三轮自动恢复，显示重试进度，统一取址时限并支持取消。
- 数字季数、近似剧名及简介同人物匹配统一用于追剧和自动续播；修复追剧持久化索引与搜索失败恢复。
- 下载视频可加载原集弹幕，弹幕失败不影响本地播放；手机横屏选集面板收窄，站源检测增加有界自动重试。
- Windows x64 完整 ZIP 仍未签名。

自动化和两端包校验结果见 Release 附件；用户设备间歇性空响应与长时间播放仍未实测，不承诺消除上游空响应。

## Windows 历史更新：0.1.29+54

- 修复红果播放和下载取流，采用 Xanerix/guoapp 的单集接口、播放器签名和注册设备恢复逻辑。
- 首页直达四类红果榜单，海报 / 列表切换、排名与热度展示、紧凑导航和常驻搜索。
- 播放器清晰度、倍速改为锚定菜单，自动显示实际分辨率；保留下一集预载、拖动恢复与下载低优先级取址。
- 沿用 Windows 更新通道、单实例和更新回滚；x64 完整 ZIP 仍未签名。

已验证目标剧真实取流、音视频解码及完整下载后离线解码；真实 Windows 设备的长时间播放、音频输出与旧版原地升级仍未实测。构建、启动、更新下载及完整性结果见本次 Release 附件。

## Android 最近更新：0.1.32+57

- 修复旧跨季记录校验导致的追剧灰屏、继续观看和保存失败，保留已有记录与同步版本。
- 保存错误提供真实诊断入口；手机榜单默认每行三张海报，全屏选集每行六集、选集区至少 80%、边界翻页。
- 红果剧目菜单新增“搜索其他季”，无需收藏即可查找并选集播放。
- 自动化及两端安装包校验结果见发布附件，用户设备仍待复验。

## Android 历史更新：0.1.31+56

- 首页大剧库的追剧匹配与 JSON 处理移出界面线程，修复加载期间长时间不响应。
- 优化续季匹配，保留伪神数字季数、简介同人物与下载弹幕功能。
- 两端构建、签名及下载校验结果见发布附件；用户手机卡死修复尚未实机验收。

## Android 历史更新：0.1.30+55

- 红果空响应在当前播放页进行最多三轮自动恢复，显示重试进度，统一取址时限并支持取消。
- 数字季数、近似剧名及简介同人物匹配统一用于追剧和自动续播；修复追剧持久化索引与搜索失败恢复。
- 下载视频可加载原集弹幕，弹幕失败不影响本地播放；手机横屏选集面板收窄，站源检测增加有界自动重试。
- 沿用 com.hongguo.tv、Android 8.0 最低版本、原正式证书与三 ABI。

自动化和两端包校验结果见 Release 附件；用户设备间歇性空响应与长时间播放仍未实测，不承诺消除上游空响应。

## Android 历史更新：0.1.29+54

- 修复红果播放和下载取流，采用 Xanerix/guoapp 的单集接口、播放器签名和注册设备恢复逻辑，正常使用不再反复更换 iid。
- 首页新增四类红果榜单；播放清晰度、倍速使用浮动菜单，保留可用的 360P / 480P / 540P / 720P / 1080P 片源。
- 保留本地解密、下一集预载、下载队列、弱网有限恢复和启动注册门禁。
- 沿用 com.hongguo.tv、Android 8.0 最低版本、既有正式证书与三 ABI，支持覆盖升级。

已验证目标剧 Android 本地解密流和完整下载后的音视频解码。真实手机 / TV 覆盖安装、遥控器和长时间播放仍未实测；安装包和公网更新验证结果见本次 Release 附件。

## Windows 历史更新：0.1.23+48

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

## Android 历史更新：0.1.23+48

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

[Android 最新正式版](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/latest) · [Windows 正式版](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.32-57) · [macOS 正式版](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/macos-v0.1.33-58)

| 设备架构 | 下载 |
| --- | --- |
| Windows 10/11 x64 · 完整 ZIP、未签名 | [HongguoTV 0.1.32 Windows x64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.32-57/HongguoTV-0.1.32-windows-x64.zip) |
| macOS 13 及以上 · Apple 芯片 / Intel 通用，未公证 | [HongguoTV 0.1.33 macOS 通用 ZIP](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/macos-v0.1.33-58/HongguoTV-0.1.33-macos-universal.zip) |
| Android arm64-v8a · 大多数手机及较新的电视 / 盒子 | [HongguoTV 0.1.32 ARM64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.32-57/HongguoTV-0.1.32-arm64-v8a.apk) |
| Android armeabi-v7a · 32 位手机 / 电视 / 盒子 | [HongguoTV 0.1.32 32 位](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.32-57/HongguoTV-0.1.32-armeabi-v7a.apk) |
| Android x86_64 · 对应架构模拟器 | [HongguoTV 0.1.32 x86_64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.32-57/HongguoTV-0.1.32-x86_64.apk) |

支持 Android 8.0 及以上系统。请选择与设备和已安装应用匹配的架构；更新时直接覆盖安装，无需先卸载。

三架构 APK 的 [SHA-256 校验清单](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.32-57/SHA256SUMS.txt) 与源码见 [0.1.32 发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.32-57)。Windows 的校验清单及源码见上方 Windows 正式版入口。最新版本源码可从对应发布标签查看；其他分支的源码版本以各自的 `pubspec.yaml` 为准。

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
| Android 手机 / Android TV | 0.1.32+57 三 ABI、既有正式证书、最低 Android 8.0；包名、版本、架构、证书、CRC / 对齐、资源、SHA-256 与公网更新下载结果见发布附件 |
| Windows | 0.1.32+57 x64 未签名完整 ZIP；构建、版本 / DLL / 运行库、资源、SHA-256、合成媒体原生启动、托盘 / 迷你窗、17 项更新事务、16 项单实例回归和公网下载 / 静态清单回退结果见发布附件 |
| macOS | 0.1.33+58 通用 ZIP，最低 macOS 13；41 个原生二进制双架构及最低系统版本、ad-hoc 签名完整性、两种架构各三次合成播放 / 加密解码 / 全屏 / 合并和公网 SHA-256 检查通过；未做 Apple 公证，真实硬件输出及上游播放仍待实机验收 |
| iOS | 保留工程与构建支持，本次无已签名安装包 |

静态检查、默认 / 全站源自动化、Python 门禁、两种 Go race 配置及平台构建的结果，见 [Android 发布附件](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.32-57) 与 [Windows 发布附件](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.32-57)。请以本次 CI 和随包报告为准，不把源码、构建记录或签名检查等同完整实机验收。

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

