# 红果TV · 手机 / Android TV / Windows

基于 [guoapp](https://github.com/zhoufuweigg/guoapp) 的非官方独立客户端。手机与 Android TV 共用 Android 应用，另提供 Windows x64 独立客户端。支持短剧浏览、搜索、在线播放、追剧和下载。

## 开发中：0.1.19+44（未发布）

本轮从已发布 Android `app-v0.1.18-43` 与 Windows 维护源码增量修改，仅提交源码与验证，不创建 release、标签或替换现有资产。

- Windows 纳入 `ebbf44c` 的关闭到托盘前暂停并保存进度、恢复后保持暂停行为。更新助手增加带事务 nonce 的取消与交接许可：就绪超时或退出准备失败时先取消并等待助手退出，确认退出后才能删除暂存目录；无法确认退出则保留现场及恢复文件。新客户端启动失败时同样确认其实际退出后再回滚，不能确认则保留新目录、旧目录备份和配置。
- Windows 更新诊断保留阶段、原始 Win32 错误、源/目标路径、助手及子进程 PID、等待/终止/退出结果；不再把所有重命名失败归为文件占用。启动失败及回滚结果通过更新界面提示。此前用户机器快照未留下失败现场，不能确定原故障由 DLL、360 或多开导致。旧客户端安装新版时仍执行旧客户端所带助手，这些保护在运行包含本修改的客户端后用于后续更新。
- Windows 完整包清除上游 ANGLE 中未被任何包内 PE 导入的 `libc++.dll` 与 `zlib.dll`；它们原先依赖调试版 VC++ 运行库，开发 runner 自带的调试库会掩盖问题。打包拒绝旧构建残留，包验证独立拒绝调试 CRT 导入，不依赖 runner 是否装有调试库。实际所需的 ANGLE、mpv、FFmpeg 和 VC++ 发布运行库仍完整捆绑。
- TV 全局设置增加持久的“TV 解码模式”，实体电视选择标准布局时也能修改；TV 播放设置使用同一偏好。自动模式保持系统选择并允许初始化回退；仅硬件解码/系统软件解码按 Media3 声明筛选视频解码器，音频选择保持原策略。播放器内修改会重新打开当前集并保留进度，全局修改在下一次打开视频时生效。预准备复用同一解码策略。
- TV 已识别的解码能力/初始化/解码失败停止自动线路重试，保留设置、手动备用线路（存在时）、日记、站源诊断与返回入口。加载期间也保留设置和返回入口。网络错误继续使用原有有限恢复；手机和 Windows 播放不应用 TV 解码选项。视频输出的流畅/兼容模式只改变输出表面，不等同硬解/软解。
- [Issue #12](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/issues/12) 无评论、附件或完整日志，仅提到索尼及 `hvc1`、`NO_EXCEEDS_CAPABILITIES`；无法确认具体型号、Android 版本、HEVC profile/level/位深或是否发生原生进程崩溃。需要原电视型号、完整播放日记与崩溃附近 logcat 才能定位。系统软解只使用设备自带软件解码器，并未引入通用 FFmpeg 视频软解，缺少相应 HEVC 解码器或性能不足仍可能失败；请尝试不同线路/较低规格视频。未降低 Android 最低版本。
- Windows 底部黑条仍未在合成回归中复现，未新增裁剪、拉伸或遮挡视频的改动。云端自动化使用合成数据并禁用站源图片，不等同索尼电视实机 HEVC、遥控操作、真实播放或长时间连播验收。

- 云端验证：默认 Flutter 596 通过 / 3 跳过，全站源 597 通过 / 2 跳过；192 个 Dart 文件格式检查通过，静态分析无错误和警告（152 条提示）；Python 48 项通过，两种 Go 配置的竞态测试和模块校验通过。
- [Android 无签名源码验证](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/39220472932)通过：插件/应用 Kotlin 与 Java 编译、19 组共 145 项原生测试均通过；插件与应用 Lint 门禁通过（应用仍有 22 条既有警告，插件 1 条基线清理提示）。任务图已核对无 APK 打包和签名任务，没有生成安装包用于发布。
- [Windows 打包清理后的完整复验](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/39221734603)通过：0.1.19+44 x64 完整包的版本、架构、DLL 导入、资源和校验和检查通过；合成 H264/AAC 媒体实际启动 smoke、关闭到托盘暂停/恢复仍暂停、16 项更新事务及真实客户端重启 ack 均通过。未使用的两个 ANGLE 调试 DLL 不再入包，客户端仍未签名。发布步骤明确跳过，产物仅为 CI 验证包；Android Latest 仍为 0.1.18+43，Windows 正式版仍为 0.1.17，本轮没有发布或更改现有资产。

## 当前 Android 版本：0.1.18+43

手机/TV 共用 Android 0.1.18+43 已正式发布，该版本只调整 TV 行为，保留既有播放源、弹幕、预加载、连播、全季、追剧/进度、搜索和下载。运行时代码来自已验证 TV 提交 `0cf19ed`；正式源码以 `app-v0.1.18-43` 标签为准。Windows 正式版仍为 0.1.17；0.1.18+43 发布阶段未构建或发布 Windows 独立修改，本次 Windows 源码验证见上方 0.1.19+44 开发记录。

[Android 0.1.18 正式发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.18-43) · [构建与发布验证](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/39107356975) · [对应源码提交 7544a05](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/commit/7544a0566b34aff5d853bd1b6f64c6a7cb3a1701)

- Windows 独立后续修改：普通窗口关闭进入托盘前暂停并保存进度，恢复窗口后保持暂停，需手动播放；打开视频过程中关闭及迟到的播放完成事件也不能自动恢复。普通最小化的暂停策略保留；迷你窗“退出红果TV”仍直接退出。
- Windows 底部黑条仅检查：控件背景、反馈、标题及右缘入口位于同一淡出层，没有独立占位底栏。960×540 与 480×300 的合成像素回归确认控件隐藏后底部 90px 采样点恢复视频原色；未提供真实 PC 画面，暂不声称已复现或修复，不裁剪、不拉伸视频。
- 0.1.18 阶段对 Windows 更新流程仅作检查与建议：下载已显示 MB/总量，但安装准备、校验完整目录和等待助手期间仍沿用统一“正在重新验证安装包”状态。建议分阶段显示校验/准备/等待重启，并在播放阻止安装时提供更直接的暂停入口；具体改动待确认下载、安装还是重启体验的问题后实施。
- TV 弹幕使用真实内容运动时长，避免系统“移除动画”将弹幕加速约 20 倍；速度仍独立于视频倍速，普通界面动画继续遵循系统设置。实体电视选择标准布局时同样保留内容运动时长；手机和 Windows 的原有弹幕行为保持。
- TV 追剧、历史、下载及标准布局搜索框分开浏览和编辑状态：获焦后方向键浏览，确认进入输入；编辑期间方向键继续交给文字光标、输入法及候选词，返回/提交后恢复浏览。未改动密码、数字或服务器设置输入框。
- TV 播放控制条合并为单排紧凑操作，选集弹窗采用 48px 卡片、6px 间距及清晰焦点，保留当前集定位、VIP 标识和“查看全季”。窄屏可横向滚动操作按钮。
- 播放控制条隐藏时，左右沿用 ±15 秒定位，长按第 6 次重复起沿用 30 秒步进与进度预览；上下显示控制条，菜单键直接打开选集。控制条和弹窗显示时方向键只导航；关闭弹窗后返回播放画面，需要时再按上下唤出控制条。
- 验证：默认 Flutter 回归 579 通过 / 3 跳过，全站源回归 580 通过 / 2 跳过；CI 同范围静态分析无错误和警告（154 条既有提示）；189 个 Dart 文件格式检查通过。脚本测试 45 项通过。16 组弹幕运动测试覆盖 500 条合成缓存、0.5/1 倍弹幕速度、3 倍视频速度、30/60/120 帧、不同分辨率/DPI及系统移除动画开关；中文控制条预览已检查。
- 云端测试使用合成数据并禁用站源图片；未做实体电视输入法、遥控器及真实视频播放验收。三 ABI 正式包及候选/正式公网更新下载均已复验签名、包名、版本、架构、资源、大小与 SHA-256；云端再次实测更新器下载并核对 59 个原生 ELF、521 个运行时源码文件。4 个既有发布及 50 个资产逐项比对保持不变。
- 此前独立检查 Windows 托盘暂停源码时，专项 22 项回归通过；该次检查未执行 Windows runner 编译或原生 smoke，修改当时尚未发布。

## 此前发布：0.1.17+42

- 追剧已有与当前观看季匹配的“已有下季”结果时，自动检查跳过重复远端查询；当前剧、源或季变化后重新判断，无标签的追剧保持原检查策略。手动“检查下季”可强制重新查询。
- “已有下季”改为封面左上角红粉色斜彩带，白色文字；保持卡片高度、点击与 TV 焦点边框。
- 手机横竖屏短按原“弹”按钮开关/重试，长按打开“弹幕设置”；全局设置也提供同一面板、共用持久偏好并实时应用，播放器不增加按钮。锁屏、桌面与 TV 原有操作保留。
- “查看全季”下方的集编号使用紧凑布局和至少 44px 热区，保留选中态与 TV 焦点；上方季标签及其他页面选集保持原布局。
- 修复 Issue #11：收藏锚点保持不变，局域网追剧进度原子携带真实观看季、集数、秒数与时间戳；冲突显示具体季名，删除历史保留清理标记，观看历史超过 300 条后仍可续播已追剧的当前季。
- 同步 schema 2 在读取差异记录和写入前校验；两端均需升级后同步，新旧客户端互联会提示升级并保留数据。旧 schema 1 LAN 缓存可迁移，未解决冲突保留；同步范围仍为已追剧及其进度，不含全部未追剧历史。自动化设备传输使用合成数据，未做真实双机/小米 TV 验收，不声称修复 Issue #10。
- Android 三 ABI 与 Windows x64 已正式发布，可在“设置 → 软件更新 → 检查更新”获取。跨季追剧同步需要两端均升级到本版。

两平台使用同一源码提交 [34ec11d](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/commit/34ec11d73de7b796e444bcf81463e2e9a203650b)；[Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/38991254539) 与 [Android CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/38992467269) 均已全部成功。

## Windows 正式版：0.1.17+42

本次增加追剧下季结果复用、红粉色斜彩带、跨季续播同步与全季紧凑集号；全局弹幕设置实时生效。保留迷你窗、托盘与更新回退。跨季 LAN 同步使用 schema 2，需双方升级；不包含未追剧的普通观看历史。

基于已发布 Android `app-v0.1.16-41` 与共享源码 `265906c4b6638d62b8eb0d9b4c0776c8f83f2b7f` 增量修改。远端 `main` 的应用源码可能较旧，请使用发布标签。保留 Android 0.1.16 与 Windows 0.1.15 已有资产。

- [Windows 正式版发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/windows-v0.1.17-42)。本版构建、原生启动与更新验证已通过，结果见 [Windows CI](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/38991254539) 和发布资产。
- [完整 Windows x64 ZIP 下载](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.17-42/HongguoTV-0.1.17-windows-x64.zip) · [SHA-256 校验清单](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.17-42/SHA256SUMS.txt) · [对应纯源码 ZIP](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/windows-v0.1.17-42/HongguoTV-0.1.17-source.zip)。
- Windows 10 / 11 x64 完整 ZIP 包含 `HongguoTV.exe`、更新助手、Go 核心、Flutter、mpv、FFmpeg、ANGLE、VC 运行库及资源；不提供 ARM64 / 32 位包。完整解压到独立、可写的新目录后运行，避免混放旧程序文件，不要只复制 EXE；不需要安装 Flutter、Go 或 FFmpeg。
- 未签名，无 Windows 签名证书。独立正式标签 `windows-v0.1.17-42`，`prerelease=false`、`make_latest=false`；Windows 发布不更改 Android Latest；Android 新版另经签名流程发布，已有 Android 资产保留。
- 首次从 0.1.13 / 0.1.14 预览版迁移需手动下载完整正式包；旧预览客户端只查预览渠道。0.1.15 正式版只检查 Windows 正式渠道；Release API 限流或网络失败时备用读取本仓库的静态正式更新清单，仍验证完整 ZIP 大小和 SHA-256；0.1.14 客户端在限流时首次升级需手动下载完整包。下载与安装需明确操作。

### Windows 功能与交互

| 功能 | Windows 行为 |
| --- | --- |
| 播放源、搜索、发现、全季、追剧、观看进度 | 复用本版 Android 全站源构建与本地数据逻辑；源站可用性取决于网络 |
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

验证包括默认/全站源回归、Windows x64 编译、版本/DLL/资源/校验和、干净 PATH 与中文空格目录启动、合成 H.264/AAC 首帧/快进/倍速/音量/全屏、原生托盘关闭/恢复/暂停/退出、迷你窗反复切换及调整大小、12 个更新事务场景（含真实客户端重启确认）。本版另已完成公开 ZIP 下载及备用清单验证；完整包共 220 个文件，51 个 EXE/DLL 均为 x64，12 项更新事务通过，逐文件清单与 SHA-256 一致。Android Latest 仅由独立签名流程升级，旧 Android 0.1.16 与 Windows 0.1.15 的 25 个既有资产均保留；实际结论见发布 JSON 报告。

尚未实测真实源站解码、音频设备输出、消费级 Windows 10/11 GPU/旧 CPU 兼容、长时间跨集跨季连播，以及旧预览客户端通过公网完成整个升级事务。自动化结果不等同用户电脑验收，不会在用户电脑自动安装或运行。

## Android 最近更新：0.1.18+43

- 基于已验证的 TV 提交 `0cf19ed34f5dd84bcd5d0a6e777f0eab2e92081b`，运行时代码不附加其他功能；手机/TV 继续共用 `com.hongguo.tv` 安装包，不包含 Windows 独立修改。
- 修复 TV 弹幕受系统“移除动画”影响而约 20 倍加速的问题；弹幕速度独立于视频倍速，保留表情、透明度及开关。
- TV 追剧、历史、下载与标准布局搜索框增加浏览/编辑状态，方向键浏览，确认输入，编辑时保留输入法和候选词，返回/提交后恢复遥控焦点。
- 播放控制条改为单排紧凑操作，选集采用 48px 卡片和 6px 间距；保留当前集定位、全季入口与遥控焦点。
- 控制条隐藏时左右按原 ±15 秒快进后退，长按沿用加速及进度预览；上下打开控制条，菜单键打开选集并可查看全季。菜单/弹窗内方向键只导航，返回后回到播放画面。
- 构建号由 42 递增至 43；ARM64 / 32 位 / x86_64 versionCode 分别为 2043 / 1043 / 4043。既有证书、包名、三 ABI、资源、大小、SHA-256 与客户端公网更新下载均已验证后提升为 Latest；同 ABI 满足包名/签名一致且 versionCode 递增的覆盖升级条件，未做实体覆盖安装。
- 现有 Windows 0.1.17 与所有旧 Android 发布资产保留。本轮未做实体 TV 输入法/遥控器、真实源站解码、覆盖安装或长时间连播验收。


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
| arm64-v8a · 大多数手机及较新的电视 / 盒子 | [HongguoTV 0.1.18 ARM64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.18-43/HongguoTV-0.1.18-arm64-v8a.apk) |
| armeabi-v7a · 32 位手机 / 电视 / 盒子 | [HongguoTV 0.1.18 32 位](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.18-43/HongguoTV-0.1.18-armeabi-v7a.apk) |
| x86_64 · 对应架构模拟器 | [HongguoTV 0.1.18 x86_64](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.18-43/HongguoTV-0.1.18-x86_64.apk) |

支持 Android 8.0 及以上系统。请选择与设备和已安装应用匹配的架构；更新时直接覆盖安装，无需先卸载。

三架构 APK 的 [SHA-256 校验清单](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/download/app-v0.1.18-43/SHA256SUMS.txt) 与源码见 [0.1.18 发布页](https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/releases/tag/app-v0.1.18-43)。最新版本源码可从该版本标签查看；其他分支的源码版本以各自的 `pubspec.yaml` 为准。

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
| Android 手机 / Android TV | 0.1.17 三架构安装包、现有证书签名及公开更新验证结果见正式发布页 |
| Windows | 独立 Windows x64 正式渠道；0.1.17+42 的构建、运行验证结果及下载以正式发布页为准 |
| iOS | 保留工程与构建支持，尚无本次已签名安装包 |

本版静态分析无错误和警告，保留 154 条既有 info 提示；Python 44 项测试（3 项条件跳过）、Flutter 默认 550 项与全站源 551 项通过（分别 3 / 2 项条件跳过），Go race 两种构建配置通过。Android 三 ABI 沿用原证书，构建和公网下载均核对包名、版本、ABI、对齐、CRC、资源与 SHA-256；Windows 的完整包、原生 smoke 和更新事务结果见发布报告。真实手机 / TV 的覆盖安装、实际播放与长时间连播仍待验收。

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

