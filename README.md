<p align="center"><img src="assets/brand/logo.jpg" alt="Zero Player" width="240"></p>

# Zero Player

面向 **Windows 桌面和 Android 手机 / TV** 的本地在线视频聚合播放器。支持频道浏览、聚合搜索、点播、直播、续播、离线下载与导出，无需单独部署业务后端。

**v0.8.0 阶段预发行** · [下载 Windows 新版](https://github.com/yixunfei/zero-player/releases/tag/v0.8.0) · [Android v0.8.0 开发测试包](https://github.com/yixunfei/zero-player/releases/download/v0.8.0/zero-player-0.8.0-android-arm64-devtest.apk) · [Windows v0.0.11 稳定版](https://github.com/yixunfei/zero-player/releases/tag/v0.0.11) · [Android v0.0.7 正式版](https://github.com/yixunfei/zero-player/releases/tag/v0.0.7)

## v0.8.0

源码版本 **0.8.0+80**。整合性能优化、书架移除与私密书架、阅读下载与续播修复、书源新域和 GitHub 影视渠道更新，并修复 12 项审计问题。专业图书独立模块仍处于规划阶段。详见[发行说明](https://github.com/yixunfei/zero-player/releases/tag/v0.8.0)。

Android 开发测试版使用独立包名 `dev.zeroplayer.zero_player.devtest` 和已有测试签名，可与正式版并存；Android 最新正式版仍为 v0.0.7。Windows 安装器未做商业代码签名。Android/TV 真机、长期播放及后台生命周期仍待验收，来源可用性以实际网络为准。

全新安装提供可跳过的监管设置提示；首次在非监管状态关闭成人过滤需完成本机访问密码验证。监管开启期间禁止关闭成人过滤，普通备份不传递本机验证记录。

## 功能

- 影院与明亮主题，首页频道和搜索同栏展示，支持单类浏览、分类聚合、分页与继续观看。
- 可配置视频源与聚合搜索，标题纯文本清理、来源检查和失败提示。
- 点播、直播、播放快捷键、Windows 沉浸全屏和窗口恢复。
- 直播单击选中、双击播放，随包预检通过目录、更新复检后恢复，4/8/16 路测活、健康优先排序、同台别名合并、备用线路与可配置 XMLTV 节目表。
- 搜索默认查询全渠道，优先当前浏览来源；发现页推荐无当前来源，支持手动仅当前来源、失败重试与逐源进度。
- 统一成人过滤，监管模式覆盖点播、直播和广播；支持频道/关键词屏蔽，每次敏感操作验证密码，恢复码由用户自行保管。
- **在线广播（实验阶段）**：电台分组/搜索、收藏、广播与电视伴听分类、健康筛选/测活、失败换线、迷你播放器；离开页面继续播放，Windows 支持托盘收听与退出。
- **在线音乐**：默认浏览 QQ 音乐热歌，可选择网易云新歌和 Apple Music 中国区热门歌曲。Flutter 客户端直接请求各播放渠道，无需部署音乐服务器。首次搜索默认聚合 MY FREE MP3、网易云公开音频、Audius、酷狗公开音频和酷我试听，优先查询收藏渠道。可在“我的歌单”导入网易云公开歌单，在播放器查看网易云歌曲的同步歌词和可用译文。另有播放队列、历史续播、离线下载、迷你播放器和 Windows 托盘控制。实验性 LX 渠道的可用性受上游协议及地区限制。
- **听书**：中文书音FM、博看有声、喜马拉雅免费有声、Lit2Go 与 Gutenberg 公版朗读及两路文化播客；提供搜索、分类、书架、离线章节、续播、连续播放、定时暂停和离页后台播放。部分渠道已完成 Windows 原生样本验证，设备可用性仍需实际检查。
- 渠道按实际诊断自动启停并持续复检，频道选择显示 TCP Ping；收藏和重复接口整理保持独立。
- 受控媒体网关、私网访问拦截、HLS 引用校验、原生脚本/协议限制与有界退出清理。
- 播放中特征跳过（默认关闭）：原画质直接播放，后台优先检测音频；没有规则、资源缺失或检测失败时继续播放。支持频道/全剧声画样本、保守/积极/提示策略、离线关键词检测。关键词始终先确认，默认跳过时长 20 秒，可调整并撤销。轻量关键词、OCR / ASR 资源在设置中手动下载，不随基础包安装。Android 实机性能待设备验收。
- 下载、续传、指定目录自动保存、离线播放与 TS/MP4 导出；本地视频播放、续播、内嵌音轨/字幕选择及 Windows 可选文件关联（v0.0.8）。设置、历史记录及用户数据保存在本机。
- 一次性导航引导、版权说明与开源许可证入口。

广播内置源：[popocoding/awesome-m3u 的中国广播列表](https://raw.githubusercontent.com/popocoding/awesome-m3u/refs/heads/main/radio/cn.m3u)。首次离线可使用随包成功快照，超过 24 小时后台更新；刷新失败保留旧列表。源站可能变更，列表收录不保证可播放性或授权。

## 下载与安装

| 使用场景 | 发布文件 |
| --- | --- |
| Windows 10/11 x64 安装 | windows-x64-setup.exe |
| Windows x64 便携运行 | windows-x64-portable.zip（完整解压后运行 zero_player.exe） |
| Android 8.0+ ARM64 手机/平板/TV | v0.0.7 的 android-arm64.apk |
| Android 8.0+ ARM64 开发测试 | v0.8.0 的 android-arm64-devtest.apk（测试签名，独立包名） |
| 审查/重新构建 | source.zip、third-party-notices.zip 与原生构建来源材料 |

本次 v0.8.0 提供 `zero-player-0.8.0-windows-x64-setup.exe` 和 `zero-player-0.8.0-windows-x64-portable.zip`，另附源码、第三方声明、原生来源及 `SHA256SUMS.txt`。Android 开发测试附件为 `zero-player-0.8.0-android-arm64-devtest.apk`，附测试说明；最新正式 Android 包仍为 v0.0.7。Windows 二进制未做商业代码签名；本轮未重新验收安装卸载或 Android/TV 实机。

不支持 32 位 ARM/x86 Android、Windows ARM64 原生版、macOS 或 iOS。便携包必须完整解压，不能仅复制 EXE。

## 开发

开发与测试使用下列命令；发行范围和已知限制见对应 GitHub Release。

使用 Flutter 3.44.1 / Dart 3.12.1，锁定依赖见 pubspec.lock。Android 构建需要 JDK 21 和 Android SDK；Windows 构建需要 Visual Studio C++ 桌面工具链。

~~~powershell
flutter pub get
flutter analyze
dart run tool/check_module_boundaries.dart
dart run tool/check_source_size.dart
flutter test
~~~

lib/features 按业务划分；lib/media 包含播放、HLS、回环网关、缓存与导出；lib/core 提供网络、数据库和平台边界；lib/app 负责依赖组合、路由与布局。模块依赖约束由 `tool/architecture/module_boundaries.dart` 定义，边界检查也随 `flutter test` 执行。平台测试和 Flutter 构建应串行执行，避免共享插件注册文件冲突。图标由 assets/brand/logo.jpg 通过 tool/generate_brand.py 生成。

仓库仅提交代码、测试、必要素材、依赖锁文件及 README/许可证。密钥、本地配置、下载工具链、测试产物、缓存和发行二进制均不进入 Git；发行文件通过 Releases 提供。

## 开源致谢

感谢以下项目及其贡献者。名称与链接用于注明来源，不表示上游为本项目或内置资源背书。

| 项目 | 在本项目中的用途 |
| --- | --- |
| [Flutter / Dart](https://github.com/flutter/flutter) | 跨平台应用框架与语言 |
| [LibreTV](https://github.com/LibreSpark/LibreTV) | 功能与公开接口协议参考；独立 Flutter/Dart 实现 |
| [media_kit](https://github.com/media-kit/media-kit)、[mpv](https://github.com/mpv-player/mpv) | 音视频播放及平台原生播放器 |
| [FFmpeg](https://ffmpeg.org/)、[FFmpegKit](https://github.com/sk3llo/ffmpeg_kit_flutter_android)、[Windows 移植](https://github.com/sk3llo/ffmpeg_kit_flutter) | 媒体处理、校验与导出 |
| [Riverpod](https://github.com/rrousselGit/riverpod)、[go_router](https://github.com/flutter/packages/tree/main/packages/go_router) | 状态管理与路由 |
| [Drift](https://github.com/simolus3/drift)、[sqlite3.dart](https://github.com/simolus3/sqlite3.dart)、[SQLite](https://sqlite.org/) | 本地数据持久化 |
| [window_manager](https://github.com/leanflutter/window_manager) | 桌面窗口控制 |
| [Dart html](https://github.com/dart-lang/tools/tree/main/pkgs/html)、[Dart XML](https://github.com/renggli/dart-xml) | HTML 与 XML 文档解析 |
| [Flutter packages](https://github.com/flutter/packages)、[Dart core](https://github.com/dart-lang/core) | 文件选择、存储路径、路径处理与摘要计算 |
| [awesome-m3u](https://github.com/popocoding/awesome-m3u) | 实验广播内置列表来源 |
| [m1ngzer/tingshu-sources](https://github.com/m1ngzer/tingshu-sources) | 书音FM公开接口协议参考；本项目独立实现，不运行其 JAR |
| [freefly22/tingshu-free-jar](https://github.com/freefly22/tingshu-free-jar) | 博看有声、喜马拉雅免费音轨公开接口协议参考；本项目独立实现，不运行其 JAR |
| [iptv-org/iptv](https://github.com/iptv-org/iptv) | 中国公开直播列表来源 |
| [Xiaolai](https://github.com/lxgw/kose-font)、[Noto fonts](https://github.com/google/fonts) | 中文字体 |
| [Inno Setup](https://jrsoftware.org/isinfo.php)、[Pillow](https://github.com/python-pillow/Pillow) | Windows 安装器和品牌素材构建工具 |

各依赖保留其各自许可证，完整声明及原生组件来源见 [NOTICE.md](NOTICE.md)，发布包附第三方声明。不能将包含 mpv、FFmpeg 等组件的整个二进制包一概描述为 MIT。

## 版权与使用范围

本项目仅提供聚合和播放器入口，资源信息来自公开网络及用户配置的第三方渠道，不运营媒体源站。项目仅供学习交流；公开可访问不代表已获授权。媒体内容及相关商标的权利归各权利人，使用者应在合法授权范围内使用。若涉及内容版权问题，请联系对应渠道、内容提供方或列表维护方；项目自身代码问题可通过仓库 Issues 反馈。

应用不执行远程 Spider/JAR/JavaScript/Python，不绕过 DRM 或付费访问控制。默认无遥测和跨设备同步；联网加载频道、封面及播放资源会访问相关第三方服务。

项目代码采用 [AGPL-3.0-or-later](LICENSE)。测试通过不等于不存在所有缺陷；设备与源站差异仍可能影响体验。广播当前明确处于实验阶段。

## 构建与测试补充

Windows 普通 Release：先设置 `FFMPEGKIT_LOCAL_DIR` 指向已校验的 FFmpegKit 目录，再运行 `flutter build windows --release`。Android ARM64 开发测试包：设置 `ORG_GRADLE_PROJECT_ZERO_PLAYER_DEVICE_TEST=true`，运行 `flutter build apk --release --target-platform android-arm64`；使用已有测试证书和独立包名。正式 Android 构建需要本地签名配置，密钥不入库。原生依赖摘要以 `tool/native_sources.json`、`tool/pdfium_checksums.json` 和平台构建配置为准。

历史书源审计工具依赖固定路径与字节摘要。其必要 JSON 测试数据位于 `test_support/book_source_audit/`；运行历史审计工具前执行 `python tool/prepare_book_audit_workspace.py`，将数据复制到已忽略的本地审计目录。该步骤不联网，也不覆盖已有的不同内容。常规 `flutter test` 直接读取测试数据，不依赖本地工作文档。
