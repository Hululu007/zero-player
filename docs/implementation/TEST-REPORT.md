# 测试报告

## 2026-11-19 外部书架实现接续复查

最终 Flutter 全量 **1630 项通过、12 项跳过、退出 0**；vault 注册拆分后定向 **19 项通过**，遗留明文修复与界面/聚合定向 **30 项通过**。覆盖损坏密文、配置丢失、迁移/嵌套事务回滚、锁定期间认证/读写、公开私密隔离、旧页面及弹窗销毁、后台听书、漫画图片和来源加密、离线目录恢复与下载书单归属。全仓 analyze 无问题，527 文件模块边界通过，31 个 Dart 文件格式检查通过；规模仍有 **104 条既有超限**，比外部起点少 3 条，无新增，不能称全仓规模门禁通过。

Windows 原生漫画业务 **1 项通过**（日志 +2 含 tearDownAll）；Android Kotlin 离线编译通过。普通 Windows Release 最终构建成功，7 份受保护文件恢复并与起点一致，608 份构建输入及固定原生依赖摘要核对通过。本轮不产出新 Android APK，指纹未真机验证。加密范围是数据库记录、离线文字/图片与相关来源信息；音频、EPUB/PDF 原文件不加密。修复细节见 [复查报告](BOOKS-SHELF-VAULT-2026-11-19.md)，原始日志见 `build/shelf-vault-review-20261119/`。

## 2026-11-19 书架移除/删除与私密书架（外部初始提交历史）

`flutter analyze --no-pub` 无问题；`flutter test --no-pub test/books` 678 项全部通过，其中私密书架 6 项、书架移除/删除界面 1 项、下载目标空间 3 项。Android `:app:compileDebugKotlin` 通过，`:app:assembleDebug --offline` 产出 116 MB arm64 debug APK 并确认包含指纹通道。真机指纹录入、指纹变更失效与 API 26–27 回退未执行，不能据此认定设备侧通过。设计与边界见 [本轮报告](BOOKS-SHELF-VAULT-2026-11-19.md)。

## 2026-10-28 渠道、直播与广播验收

静态分析无诊断，源码/函数规模检查通过；全量单元及界面测试 222 通过、2 个显式公网测试跳过。Windows 原生广播流程与托盘集成各 1 项通过，托盘测试使用真实媒体引擎验证隐藏后静音音频解码进度继续增长。Windows x64 Release 构建成功。资源来源、功能边界和命令见 [本轮报告](CHANNEL-RADIO-2026-10-28.md)。

最新一轮：82项单测、首页及播放原生回归、Windows/Android构建结果见 [页面细化报告](REFINEMENT-2026-10-27.md)。下文保留此前阶段记录。

日期：2026-10-27。Windows11 x64 / Flutter3.44.1 / Dart3.12.1。受控素材为本机生成的色条和正弦音，不依赖第三方影视内容。

| 检查 | 结果 | 证据（项目根目录相对路径） |
| --- | --- | --- |
| flutter analyze --no-pub | No issues found | artifacts/final-analyze.log |
| Dart AST 文件/函数尺寸 | 通过（1500/100行） | artifacts/source-size.log |
| flutter test --no-pub | 39项全部通过 | artifacts/unit-tests.log |
| Windows 原生产品集成 | 2个场景全部通过 | artifacts/windows-product-integration-final.log |
| HLS 原生导出与完整解码 | 5输入×2封装，共10例通过 | artifacts/native-export-results.json |
| Android release构建 | 成功，arm64/x64，开发签名 | artifacts/android-product-build-final.log |
| Windows release构建 | 成功 | artifacts/windows-product-build-final.log |
| APK签名/ABI完整性 | 签名校验通过；仅arm64/x64，主程序和原生媒体/SQLite库齐全 | artifacts/apk-verification.log、tool/verify_apk.py |
| Windows安装及启动/关闭 | 本机安装退出码0；窗口启动、正常关闭、窗口尺寸落盘 | artifacts/installer-smoke.log、installed-app-smoke.log |

## 覆盖内容

单测覆盖调度/取消/凭证隔离、HLS/Range、原子缓存/租约/容量、源解析、共享订阅与覆盖、备份类型/语义校验和事务回滚、M3U往返/EPG时区、推荐榜单和新番解析、无扩展名下载识别、离线分片持久化/哈希损坏/清单循环与变化拒绝，以及续播/暂停保存/3x恢复/连播一次/跳过撤销。

Windows 原生测试包含 TS、fMP4、AES128、BYTERANGE、独立音轨 HLS，各自导出 MP4 与 TS，经 FFprobe 时长和全量解码验证。UI测试搜索→详情→640×360实际解码→暂停→退出→历史，另检查手机宽度和大屏布局，无框架异常。

已查看截图：artifacts/product-detail.png、product-phone-settings.png、product-tv-sources.png。测试隔离本地数据，启动本地CMS/媒体服务。结果不等于公网源或所有编码均可播放。

## 尚未验证

用户要求先实现，故 Android 模拟器/手机/TV实测暂后；未计作通过。未进行两小时连续播放、内存趋势、冷启动/首帧P95、真实遥控器独立操作、干净Windows10安装、Android导出/PiP/SAF或正式签名安装。公网60s曾返回429，已验证解析与错误回退路径，不保证公网服务可用。

构建中的 CupertinoIcons 缺字体提示来自原生视频依赖的备用控制组件；产品使用自定义 Material 控件，当前已验证的界面未出现缺图标。后续启用其他播放器控件时需补字体。

安装测试使用 artifacts/install-smoke 目录，启动的是实际 release 安装结果；宿主已安装开发工具，因此不能据此声称干净系统安装通过。APK 检查发现并修复依赖附带32位库、却未编译32位Dart主体的问题，最终只声明arm64/x64。

早期 M0 APK 和失败日志仅保留诊断，不能用作当前交付。当前安装文件以 artifacts/release/SHA256SUMS.txt 为准。

## 2026-10-27 体验增强回归

本节为本轮最新证据，前面的安装包记录属于增强前基线。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 静态分析 | No issues found | artifacts/enhancement-analyze.log |
| 源码/函数尺寸 | 1500/100 行限制通过 | artifacts/enhancement-size.log |
| 单元与本地网络测试 | 53 项全部通过 | artifacts/enhancement-unit-tests.log |
| Windows 原生集成 | 2 个场景通过 | artifacts/enhancement-windows-integration.log |
| Windows release | 构建成功 | artifacts/enhancement-windows-build.log |
| Android release | arm64/x64 开发签名构建成功 | artifacts/enhancement-android-build.log |
| APK 原生库完整性 | arm64-v8a、x86_64 均通过 | artifacts/enhancement-apk-verification.log |

新增确定性覆盖：内置源首次启用/保留用户选择/显式恢复；API 延迟及站点信息；搜索实际并发上限与同义分类合并；年份/季数/版本隔离；GET 有界重试和 Retry-After、取消、播放保留额度；拒绝响应的上游释放；HLS 画质保留独立音轨；下载失败换源、关闭换源、多源并发分集、屏蔽来源排除和共享容量预算。

Windows UI 实测：影院/明亮首页及源分类、390px 手机布局、1280px 桌面/大屏、应用全屏切换、详情全选两集并实际完成 MP4+HLS 下载、视频解码、静置隐藏控制栏、方向键唤醒隐藏控件、防误触锁/解锁、暂停退出保存记录。继续覆盖原生五类 HLS × MP4/TS 的 10 例导出及完整解码。

已逐张查看截图：enhancement-home-cinema.png、enhancement-home-light.png、enhancement-home-phone.png、enhancement-download-selection.png、enhancement-player-controls.png、enhancement-player-immersive.png，以及 product-detail.png、product-tv-sources.png。测试海报是本地生成的图案，不是公网影视封面可用率证明。

回归发现并修复 HTTP 放弃响应体后未可靠取消上游订阅的问题，避免关闭客户端时异步错误；原有进度条逐像素触发 seek 改为拖动预览、松手提交；MP4 续传绑定原始地址，防止跨地址拼接。

Android/TV 真机、遥控器完整流程、移动端手势硬件表现、长时性能曲线和公网源全量实播仍未验收。本轮没有创建新安装器；运行最新 Windows 程序请使用 build/windows/x64/runner/Release 的完整目录，旧 artifacts/release 仍是增强前产物。

本轮 Android 首次构建因 integration_test 注册残留失败，执行完整 flutter build 后由工具重生成注册并通过，未手工修改生成文件。最新 APK 位于 build/app/outputs/flutter-apk/app-release.apk；仍为开发签名，未进行真机安装。最终二进制摘要见 artifacts/enhancement-SHA256SUMS.txt。

## 2026-10-27 首页封面、频道和分页专项

本节是首页专项的最终测试记录。实现说明见 HOME-ENHANCEMENT.md。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 静态分析 | No issues found | artifacts/home-analyze.log |
| 文件/函数尺寸 | 1500/100 行限制通过 | artifacts/home-size.log |
| 单元与本地网络 | 74 项全部通过（新增 21 项） | artifacts/home-unit-tests.log |
| 首页 Windows 集成 | 2 个场景通过（含公共网络封面） | artifacts/home-windows-integration.log |
| 原有产品 Windows 回归 | 2 个场景通过；10 例 HLS 导出/完整解码继续通过 | artifacts/home-product-regression.log |
| 真实豆瓣封面请求比较 | 旧请求 8/8 返回 403/418，新加载器 8/8 取得图片 | artifacts/home-public-cover-probe.json |
| 真实封面原生解码 | 8/8 成功，记录解码尺寸，并渲染首页截图 | artifacts/home-public-decode.json、home-public-douban.png |

确定性覆盖：分页参数、重复页终止、列表 240 项上限、分类最多 6 类和实际并发不超过 2、相同作品去重、首屏分类请求失败后的重试、旧请求取消与过期结果隔离、退出无迟到通知、失败重试相同页、缓存首屏不混拼后续页；CMS 相对封面和成人分类过滤；默认频道与布局的设置/备份往返；封面请求头边界、HTML 拒绝、图片请求共享/最后使用者取消、失败短缓存和字节预算淘汰。

Windows UI 覆盖：默认 CMS 开屏、三页 36 部自动追加、结束后无重复请求、下拉刷新、刷新保留所选分类、分类聚合、保存后离开/返回恢复、失效默认源临时回退、390/1280 宽度、离开页面图片请求释放。已查看 home-public-douban.png、home-aggregate-desktop.png、home-aggregate-phone.png；受控 CMS 使用本地生成的图案，公共豆瓣截图使用真实返回的封面。

公网采样只代表本次本机网络条件，不能代表所有封面或所有渠道长期可用。Android/TV 真机、两小时性能/内存曲线尚未验收。图片缓存和列表的预算限制已有代码及单测证据，不等于实测应用总内存峰值。

首页专项平台产物：Windows release 构建成功（artifacts/home-windows-build.log）；Android arm64/x64 release 构建成功且 ABI 完整性通过（home-android-build.log、home-apk-verification.log）。产物摘要见 artifacts/home-SHA256SUMS.txt。Windows 使用 build/windows/x64/runner/Release 的完整目录；APK 位于 build/app/outputs/flutter-apk/app-release.apk，仍为开发签名，未作 Android 真机验收。旧 artifacts/release 安装器未重新打包。



## 2026-10-27 字体、操作与电视直播（本轮最新）

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 静态分析 | No issues found | artifacts/interaction-analyze.log |
| 文件 / 函数尺寸 | 全部满足 1500 / 100 行限制 | artifacts/interaction-size.log |
| 单元与回环网络 | 104 项通过，2 项需显式开启的公网测试跳过 | artifacts/interaction-tests.log |
| Windows 首页回归 | 1 场景通过 | artifacts/interaction-home-native.log |
| Windows 交互 / 直播 | 1 场景通过 | artifacts/interaction-live-native.log |
| Windows 产品回归 | 2 场景通过 | artifacts/interaction-product-native.log |
| 本地点播预检 | 76 个入口：22 可解析、13 明确错误、41 未确定 | assets/source_precheck.json |
| 本地直播列表预检 | 11 份列表：9 可解析、0 明确错误、2 超时未确定 | assets/live_precheck.json |

新增确定性覆盖：手动追加精确条目数、整页余量复用、跨分类去重、旧加载结果隔离；四种字体、开屏全屏开关与加载数量的备份往返；CCTV 自然排序与分组；频道停用后检测/刷新不改变个人选择；地址变化作废旧健康结论；直播订阅停用、刷新、恢复及备份；失效收藏保留停用选择且不参与央视默认选台；首路失败次路成功、未查完备用路、超时/429/503 未确定、关闭时取消不记录失败。

原生界面实测：默认央视与 CCTV-1 选中但无媒体请求；点击才开始播放；方向键选择与清晰焦点；频道检测、收藏、停用、恢复；窄屏整份订阅管理；Home/End/PageUp/PageDown、输入框不抢键、设置页滚动作用域、搜索清空/Esc/系统返回、全屏 F11、字体切换；390 / 800 / 1280 / 1920 尺寸无框架异常。回归继续包含原生 5 种 HLS × 2 种封装的 10 例导出和完整解码。

已检查本轮截图：interaction-live-desktop.png、interaction-live-390.png、interaction-live-light.png、interaction-live-subscriptions-phone.png、interaction-font-notoSerif.png，以及本轮重跑生成的首页明亮布局。直播测试使用回环媒体样本，不代表 CCTV 公网实播成功率。

回归中修复了懒加载 End 跳转边界变化、页面 Navigator 覆盖主滚动控制器、频道缺少独立焦点，以及订阅异步列表刷新返回 Future 给 setState 的问题；修复后重新通过对应原生用例。

Android / 平板 / TV 物理设备、真实遥控器、所有公网频道完整解码和长期内存曲线尚未验收。此次两个手动公网测试的跳过不掩盖本地预检：点播与直播列表另以显式开发检查命令运行，并保存逐项原始结果。


本轮平台构建：Windows x64 release 成功（interaction-windows-build.log）；Android arm64-v8a / x86_64 release 成功，APK 143.4 MB，ABI 完整性及 v2 签名校验通过（interaction-android-build.log、interaction-apk-verification.log）。已核对 APK 内三份字体、许可文件和实际预检快照。二进制摘要见 artifacts/interaction-SHA256SUMS.txt。

本轮同步重打 artifacts/release 下的 Windows 安装器、便携包、Android 开发 APK 与源码包；旧交付物保留在 artifacts/release-before-interaction-20261027。最终打包摘要位于 artifacts/release/SHA256SUMS.txt。本轮未重新执行安装器安装测试；APK 仍为开发签名，Windows 未代码签名，Android / TV 真机测试继续待验。
