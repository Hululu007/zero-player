# 网络小说模块代码审查（2026-11-16）

> 第二轮审查更新。范围仍是 `lib/features/books` 全模块与相关测试；本版修正上一版随代码改动而过时的行号（如 B-01 的 `book_store.dart:1046`、B-06 的 `660/75/224`），
> 把 [`STATUS.md`](/K:/zero-player/docs/implementation/STATUS.md) 的通用验收条目（`:911/:912/:950` 属「下一步与验收边界」与直播下载说明，并非小说专项）改为小说专项记录，
> 并补充图文混排、自动阅读与两端对齐的新发现。以下行号均以当前工作区为准：
> [`books_repository.dart`](/K:/zero-player/lib/features/books/data/books_repository.dart) 2479 行、
> [`book_discovery_view.dart`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart) 1637 行、
> [`book_store.dart`](/K:/zero-player/lib/features/books/data/book_store.dart) 1220 行、
> [`book_reader_page.dart`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart) 945 行。

## 审查范围

- 数据与下载：[`book_client.dart`](/K:/zero-player/lib/features/books/data/book_client.dart)、[`books_repository.dart`](/K:/zero-player/lib/features/books/data/books_repository.dart)、[`book_store.dart`](/K:/zero-player/lib/features/books/data/book_store.dart)、[`book_download_coordinator.dart`](/K:/zero-player/lib/features/books/data/book_download_coordinator.dart)、[`book_download_guard.dart`](/K:/zero-player/lib/features/books/data/book_download_guard.dart)、[`book_repository_media_access.dart`](/K:/zero-player/lib/features/books/data/book_repository_media_access.dart)、[`book_comic_download.dart`](/K:/zero-player/lib/features/books/data/book_comic_download.dart)、[`book_image_payload.dart`](/K:/zero-player/lib/features/books/data/book_image_payload.dart)。
- 界面：[`books_page.dart`](/K:/zero-player/lib/features/books/presentation/books_page.dart)、[`book_shelf_view.dart`](/K:/zero-player/lib/features/books/presentation/book_shelf_view.dart)、[`book_discovery_view.dart`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart)、[`book_search_page.dart`](/K:/zero-player/lib/features/books/presentation/book_search_page.dart)、[`book_reader_page.dart`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart)、[`reader_session.dart`](/K:/zero-player/lib/features/books/presentation/reader_session.dart)、[`reader_pagination.dart`](/K:/zero-player/lib/features/books/presentation/reader_pagination.dart)、[`reader_style.dart`](/K:/zero-player/lib/features/books/presentation/reader_style.dart)、[`book_image_chapter.dart`](/K:/zero-player/lib/features/books/presentation/book_image_chapter.dart)、[`book_download_management_page.dart`](/K:/zero-player/lib/features/books/presentation/book_download_management_page.dart)、[`media_library_hub.dart`](/K:/zero-player/lib/app/media_library_hub.dart)。
- 对照文档：[`STATUS.md`](/K:/zero-player/docs/implementation/STATUS.md)（小说/听书各轮记录）、`USER-GUIDE.md`。
- 对照测试：`test/books/`、`test/widgets/book_phone_layout_test.dart`、`test/widgets/book_discovery_phone_search_test.dart`。

## 确认问题

### B-01 漫画单章大小限制在全部图片载入内存后才检查｜中等

- 位置：[`book_comic_download.dart:12-25`](/K:/zero-player/lib/features/books/data/book_comic_download.dart:12)、[`book_repository_media_access.dart:115`](/K:/zero-player/lib/features/books/data/book_repository_media_access.dart:115)、[`book_store.dart:1050`](/K:/zero-player/lib/features/books/data/book_store.dart:1050)。
- 现状：`_downloadComic` 先取章节全部图片地址，再逐张 `chapterImageBytes` 写入 `Map`（第 18 行），全部取完之后才调用 `saveOfflineImages`；48 MiB 的章节上限在该函数内部才判断，单图 4 MiB 上限也只作用于单张请求。
- 影响：100 张 × 4 MiB 的最坏情况会在判断前先持有约 400 MiB 原始字节；`saveOfflineImages` 还要先对每张图做 base64 再 jsonEncode 成字符串数组（[`book_store.dart:1046-1049`](/K:/zero-player/lib/features/books/data/book_store.dart:1046)），而 1050 行的 48 MiB 判断统计的是这些 base64 字符串的字符长度，因此实际允许的原始字节约 36 MiB、峰值内存可达原始数据的数倍。漫画并发为 3（[`book_download_coordinator.dart`](/K:/zero-player/lib/features/books/data/book_download_coordinator.dart) 的 `_parallelByKind`），最坏瞬时占用可达 1 GiB 量级，低内存设备可能直接被系统杀掉。
- 建议：改为流式累加，每张图下载后立即累加已用字节，超过 48 MiB 立刻中止并释放已下载内容；把单图上限与总上限的判断提前到请求之前。

### B-02 阅读图片只校验 MIME，不校验可解码性即写入持久缓存｜中等

- 位置：[`book_repository_media_access.dart:127-135`](/K:/zero-player/lib/features/books/data/book_repository_media_access.dart:127)、[`book_store.dart:940`](/K:/zero-player/lib/features/books/data/book_store.dart:940)、[`book_store.dart:950`](/K:/zero-player/lib/features/books/data/book_store.dart:950)、[`book_image_payload.dart:20`](/K:/zero-player/lib/features/books/data/book_image_payload.dart:20)。
- 现状：`_guardedChapterImageBytes` 只检查响应 `Content-Type` 是否以 `image/` 开头（第 127 行），随后直接 `readableBookImageBytes`（第 131 行）并写入 `cacheReadingImage`（第 135 行）。`cacheReadingImage` 的 `validate` 参数是策略/授权回调（[`book_repository_media_access.dart:100-105`](/K:/zero-player/lib/features/books/data/book_repository_media_access.dart:100)），不做图片解码；读取侧 `readingImage` 只做 `base64Decode`。真正的校验函数 `validateReadableBookImage`（尺寸/像素/解码）全仓仅在 [`book_repository_probe.dart:142`](/K:/zero-player/lib/features/books/data/book_repository_probe.dart:142) 使用。
- 影响：4 MiB 以内、MIME 正确但内容损坏（截断、非图片、超高分图）的响应会被写进 `app_meta` 的阅读图片缓存，直到 24 MiB 预算淘汰才消失；同一路径也没有像素上限（`validateReadableBookImage` 里的 2400 万像素上限未生效），存在解压炸弹导致的解码 OOM 风险。`saveOfflineImages` 的离线图片同样未做解码校验。
- 建议：在写入缓存前调用 `validateReadableBookImage`（或至少做一次 `instantiateImageCodec` 解码），校验失败不落盘、只返回一次性的内存结果。

### B-03 小说与听书没有删除阅读历史的入口｜中等

- 位置：[`media_library_hub.dart:58`](/K:/zero-player/lib/app/media_library_hub.dart:58)、[`media_library_hub.dart:64`](/K:/zero-player/lib/app/media_library_hub.dart:64)、[`books_page.dart:124`](/K:/zero-player/lib/features/books/presentation/books_page.dart:124)、[`book_shelf_view.dart:466`](/K:/zero-player/lib/features/books/presentation/book_shelf_view.dart:466)。
- 现状：`media_library_hub` 的小说/听书「历史」都只是把书架按 `last != null` 过滤后展示；书架卡片菜单只有「归入分组、集合或书单」与「追更」（[`book_shelf_view.dart:495-502`](/K:/zero-player/lib/features/books/presentation/book_shelf_view.dart:495)），整个 books 模块没有「移出书架」动作；`books_page.dart:124` 只做过滤，没有删除动作。全模块只有「清理阅读缓存」（[`book_detail_page.dart:1019`](/K:/zero-player/lib/features/books/presentation/book_detail_page.dart:1019)）、「删除离线内容」（[`book_download_management_page.dart:184`](/K:/zero-player/lib/features/books/presentation/book_download_management_page.dart:184)）和「删除列表」（[`book_shelf_view.dart:383`](/K:/zero-player/lib/features/books/presentation/book_shelf_view.dart:383)），都不是历史删除。视频侧 [`history_page.dart`](/K:/zero-player/lib/features/library/presentation/history_page.dart) 有单条删除与清空。
- 影响：用户无法从历史里移除单本小说或听书，也没有「移出书架」可用，只能等来源下架或从数据层清理；与其他媒体历史能力不一致。
- 建议：历史视图提供单条删除与「清空历史」，删除只清 `last`/进度而不删书架条目；删除后同步刷新 `books_page` 过滤结果。

### B-04 书发现页「返回顶部」常驻，与视频发现页的浮动按钮不一致｜轻微

- 位置：[`book_discovery_view.dart:879`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart:879)、[`book_discovery_view.dart:903`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart:903)、[`book_discovery_view.dart:750-763`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart:750)、[`discovery_page.dart:286`](/K:/zero-player/lib/features/discovery/presentation/discovery_page.dart:286)、[`discovery_page.dart:342`](/K:/zero-player/lib/features/discovery/presentation/discovery_page.dart:342)。
- 现状：书发现页宽/窄两套工具栏都常驻「返回顶部」图标按钮；视频发现页用 FAB，仅在滚动超过 500 px 时出现。滚动动画曲线也不同：书 240 ms `Curves.easeOutCubic`（第 759 行），视频 350 ms `Curves.easeOutCubic`（第 358-370 行）。
- 影响：同类操作用户需记忆两套位置与节奏；「返回顶部」在未滚动时也可见，占据窄屏工具栏空间。
- 建议：统一为同一交互（浮动按钮 + 阈值）与同一时长/曲线，或至少在书发现页顶部按钮加显隐阈值。

### B-05 快捷样式面板没有行距控制，与「最小行距 1.2」的口径不一致｜中等 UX

- 位置：[`reader_style.dart:105`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:105)、[`reader_style.dart:339-421`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:339)、[`reader_style.dart:510`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:510)、[`reader_style.dart:511-519`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:511)、[`reader_style.dart:575-580`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:575)。
- 现状：`ReaderPreferences` 把行距限制在 1.2–2.6（第 105-106 行），但完整的行距滑杆只在完整设置面板（`_typography`，第 481-554 行）；`showReaderQuickStyle`（第 339-421 行）只有预设、字号滑杆（12–44）、两端对齐与加粗开关、「更多样式」。上一版把它写成「快捷面板最小 12/行距 1.2」，实际快捷面板根本没有行距控件，1.2 只能在完整面板或预设里达到。
- 影响：正文行距这一高频调整入口被藏进二级面板，快捷面板里用户只能靠四个预设近似调整；与「快捷样式」的定位不符。
- 建议：把行距滑杆并入快捷面板，或让预设卡片直接展示行距值并提供增减按钮。

### B-06 漫画阅读沿用固定纵向列表，忽略翻页模式与点击行为｜中等

- 位置：[`book_reader_page.dart:669-689`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:669)、[`book_reader_page.dart:674`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:674)、[`book_image_chapter.dart:113`](/K:/zero-player/lib/features/books/presentation/book_image_chapter.dart:113)、[`book_image_chapter.dart:79`](/K:/zero-player/lib/features/books/presentation/book_image_chapter.dart:79)、[`book_image_chapter.dart:228`](/K:/zero-player/lib/features/books/presentation/book_image_chapter.dart:228)。
- 现状：漫画分支直接返回 `BookImageChapter`（第 674 行构造），不传翻页模式、样式或纸张配色；组件内部固定 `ListView.builder` 纵向滚动（第 113 行），`turn()` 以 `viewportDimension * .85` 模拟翻页（第 79 行），点击图片一律打开 `InteractiveViewer` 对话框（第 228 行）。
- 影响：用户设置的「仿真翻页/横向滑动」在漫画模式下无效，且点击既不翻页也不收起工具栏，只能靠滚动，和文本阅读的操作模型割裂。
- 建议：至少把翻页模式映射为纵向滚动/横向 PageView 两种行为并按模式决定点击语义（左右点按翻页、中心缩放）。

### B-07 图文混排章节的正文不跟随纸张配色与排版设置｜中等（本轮新增）

- 位置：[`book_image_chapter.dart:131-137`](/K:/zero-player/lib/features/books/presentation/book_image_chapter.dart:131)、[`book_image_chapter.dart:135`](/K:/zero-player/lib/features/books/presentation/book_image_chapter.dart:135)、[`book_reader_page.dart:605-638`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:605)、[`book_reader_page.dart:704`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:704)。
- 现状：混合章节里的文字段落用 `SelectableText(part.text, style: Theme.of(context).textTheme.bodyLarge)`（第 135 行），使用应用主题的正文样式；`BookImageChapter` 构造函数没有接收配色或阅读样式的参数。文本阅读器在 `book_reader_page.dart:704` 把正文颜色改成 `palette.ink`，但图文混排路径没有等价处理。
- 影响：夜间/墨黑纸张只换了背景（[`book_reader_page.dart:598`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:598) 与 `:724` 使用 `palette.paper`），文字仍是亮色主题下的深色，可能暗底暗字；字号、字体、两端对齐、行距在图文章节里也全部失效，同一本书在纯文本章与图文章之间排版跳变。
- 建议：给 `BookImageChapter` 传入 `palette` 与 `ReaderPreferences`，文字段落用与正文相同的 `bodyStyle.copyWith(color: palette.ink)` 与 `TextAlign`；或在该子树外包一层 `DefaultTextStyle`/`Theme` 覆盖。

### B-08 暂停自动阅读后打开样式面板会静默关闭「自动阅读」偏好｜中等（本轮新增）

- 位置：[`book_reader_page.dart:506-512`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:506)、[`book_reader_page.dart:531-538`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:531)、[`book_reader_page.dart:542-552`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:542)。
- 现状：打开样式面板时传的是运行时快照 `_style.copyWith(autoEnabled: _autoRunning)`（第 509、534 行）。任何触摸都会先暂停（[`book_reader_page.dart:615-616`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:615) 的 `onPointerDown` 调用 `_stopAutomation`），使 `_autoRunning = false`；面板返回后 `_applyStyle` 把这份 `autoEnabled: false` 写回 `_style`，`_editStyle` 又在第 548 行把 `_style.toJson()` 持久化。
- 影响：用户只是触摸暂停、改个字号，并没有关闭自动阅读，偏好却被持久化成关闭；下次打开该书不会自动阅读，且面板里的「自动阅读」开关也会显示为关闭，用户很难察觉是被自己「改样式」改掉的。
- 建议：面板只应传递用户显式改动的字段，`autoEnabled` 从持久化偏好读取而非运行时快照；或在 `_applyStyle` 中保留原 `_style.autoEnabled`，除非面板确实返回了显式变更。

### B-09 「更多样式」交接会打断自动阅读预览，且 `_configuring` 缺少异常保护｜轻微（本轮新增）

- 位置：[`reader_style.dart:373-379`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:373)、[`book_reader_page.dart:542-552`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:542)、[`reader_session.dart:3-41`](/K:/zero-player/lib/features/books/presentation/reader_session.dart:3)。
- 现状：快捷面板的「更多样式」执行 `Navigator.of(context).pop(); onMore();`（第 373-379 行）。外层 `_editStyle` 的 `await open()` 在 `pop` 后立即返回，随后把 `_configuring` 置回 `false`，而完整设置面板此时才刚打开；`_advanceAutomatically` 的守卫是 `if (!_ready || _controls || (!_configuring && ModalRoute.of(context)?.isCurrent != true)) return;`，于是路由不是当前页且 `_configuring` 已为 false，自动阅读在此期间停止翻页，直到用户拖动任一开关触发新的 `_applyStyle`。
- 另外 `_editStyle` 的 `await open()` 没有 `try/finally`，任一面板 Future 抛错都会把 `_configuring` 永久留在 `true`，之后自动阅读可能在其它页面上继续翻页；偏好也会被写两次（外层早写、内层最终写）。
- 建议：`_configuring` 用 `try/finally` 复位；「更多样式」改为在同一次 `_editStyle` 里串行打开（先 pop 再 await 完整面板），或把 `_configuring` 做成计数/嵌套深度。

### B-10 两端对齐在分页排版下每页末行都不齐｜轻微（本轮新增）

- 位置：[`book_reader_page.dart:710`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:710)、[`reader_pagination.dart:48`](/K:/zero-player/lib/features/books/presentation/reader_pagination.dart:48)、[`reader_pagination.dart:57-84`](/K:/zero-player/lib/features/books/presentation/reader_pagination.dart:57)、[`reader_pagination.dart:105-108`](/K:/zero-player/lib/features/books/presentation/reader_pagination.dart:105)。
- 现状：分页器对每一页的文本切片单独构造 `TextPainter` 并传入 `textAlign`，`Align` 在 [`book_reader_page.dart:710`](/K:/zero-player/lib/features/books/presentation/book_reader_page.dart:710) 按 `justify` 切换。实测（`tmp/justify_probe_test.dart`，宽 320、字号 18、行距 1.8）左对齐各行宽 `[108, 0, 306, 306, …, 288, 216]`，两端对齐后为 `[108, 0, 320, 320, …, 320, 216]`：章节标题 108（换行硬断）与段落末行 216 保持原宽，但每页切片自己的最后一行（例中 288）没有拉伸到 320。
- 影响：两端对齐只在页内生效，每页最后一行都留出随机右侧空白，长文阅读时右侧边缘逐页参差；与「仅段落末行不拉伸」的常规排版预期不一致。
- 建议：分页时记录每页末行是否等于段落末行，仅对非段落末页做整行拉伸（可用 `TextPainter` 逐行 `LineMetrics` + 手动 `Canvas` 绘制或按行宽补空格）；或接受现状并在设置里说明该对齐为页级对齐。

## 性能与资源优化

- 阅读缓存修剪每次都重扫全表：`cacheReading` 写完后 `SELECT key,length(...) FROM app_meta WHERE key GLOB 'books_read_cache:*' ORDER BY rowid DESC` 累计到超预算再逐条删除（[`book_store.dart:831-862`](/K:/zero-player/lib/features/books/data/book_store.dart:831)），`cacheMixedReading`（[`book_store.dart:900-935`](/K:/zero-player/lib/features/books/data/book_store.dart:900)）与 `cacheReadingImage`（[`book_store.dart:950-975`](/K:/zero-player/lib/features/books/data/book_store.dart:950)）同样在每次写入时全量扫描。正文按章频繁写入，章节多时是 O(n²) 级别的重复扫描；全局图片预算也是同样的「每次保存扫描全部图片行」（`saveOfflineImages`，第 1037-1081 行）。
- 搜索书单已在 isolate 解析（[`book_client.dart:349-363`](/K:/zero-player/lib/features/books/data/book_client.dart:349) 的 `_parseHtmlBooks` 使用 `Isolate.run`），但章节详情与正文仍是主线程同步解析 HTML/规则；长章节的正文抽取与大段文本 `TextPainter` 分页都在 UI 线程完成（[`reader_pagination.dart:57-84`](/K:/zero-player/lib/features/books/presentation/reader_pagination.dart:57)），大体量章节翻页时存在掉帧风险。
- 下载并发按作品类型分级：text 4、comic 3、audio 2（[`book_download_coordinator.dart`](/K:/zero-player/lib/features/books/data/book_download_coordinator.dart) `_parallelByKind`），续传预扫描 8 路（[`books_repository.dart:1914-1915`](/K:/zero-player/lib/features/books/data/books_repository.dart:1914)）。真实带宽下未测，`ContentBlocked` 会暂停整单。
- 每次下载校验都会开启一次数据库事务并重读来源/受限主机：`validate` 在 [`book_download_guard.dart:142-148`](/K:/zero-player/lib/features/books/data/book_download_guard.dart:142) 开事务，`_validatePersistent`（[`book_download_guard.dart:153-190`](/K:/zero-player/lib/features/books/data/book_download_guard.dart:153)）再读 `blockedSources`、来源与内容 epoch，`capture`（第 87-140 行）也一样。预扫描 8 路与下载 worker 共用同一连接，drift 事务串行执行，章节数多时校验排队会拉长启动时间；建议预扫描复用一次批量查询，而不是逐章开事务。
- 阅读缓存 24 MiB、离线图片 192 MiB、单章 48 MiB 都硬编码在 `book_store.dart`，与「阅读缓存/离线空间分档配置」分散在两处；调整上限需要改代码。

## 功能缺失与交互一致性

- B-03 历史删除入口缺失（见上）。
- B-04 返回顶部交互与视频发现页不一致（见上）。
- B-05 快捷面板缺行距/边距（见上）。
- B-06 漫画模式忽略翻页设置（见上）。
- 其他未单独立项的小问题：
  - 行距滑杆取不到标称值：Flutter `Slider` 离散化得到 `1.7999999999999998`（[`slider.dart:782-796`](/D:/env/Flutter/flutter/packages/flutter/lib/src/material/slider.dart:782)），而 `_ReaderPreset.matches` 用 `==` 比较（[`reader_style.dart:563-566`](/K:/zero-player/lib/features/books/presentation/reader_style.dart:563)），拖动行距后「标准」预设卡片不会高亮。
  - 搜索页清除「范围」筛选时，若输入框为空，`_submit()` 在 `_scoped = false` 之后提前 return，不触发 `setState`，范围 chip 可能继续显示（[`book_search_page.dart:595-603`](/K:/zero-player/lib/features/books/presentation/book_search_page.dart:595)）。
  - 分类条固定 `height: 40`（[`book_discovery_view.dart:1076`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart:1076)），系统字号放大时 chip 文本可能被裁剪（`STATUS.md:8` 尚未覆盖此叠加场景）。
  - 阅读顶栏在 320 dp 手机上次要按钮较多，标题区域被压缩，超长书名会截断（`STATUS.md:8` 记录未覆盖超长书名与大字号叠加）。

## 结构与整理项

- [`books_repository.dart`](/K:/zero-player/lib/features/books/data/books_repository.dart) 已 2479 行，贴近项目 2500 行上限，且同时承担下载编排、续传预扫描、换源、音量/音轨、进度与策略校验；建议按「下载」「换源」「进度/策略」拆文件。
- [`book_discovery_view.dart`](/K:/zero-player/lib/features/books/presentation/book_discovery_view.dart) 1637 行，宽/窄两套工具栏与搜索、分类、书单、来源展开混在一个 State 里，继续加交互会逼近上限（`STATUS.md:10` 已记录规模）。
- 缓存容量与离线限制分散在 `book_store.dart` 多个方法，缺少统一常量；已就 B-01/B-02 建议改为流式与统一预算。
- `lib/features/books/domain` 下仍有较多逐来源的历史修正/隔离文件，新增来源时容易重复实现，后续可归并为来源适配层（不影响本次问题判定）。

## 已知功能缺口与待验收

- 来源兼容历史问题仍未闭环：[`STATUS.md:17`](/K:/zero-player/docs/implementation/STATUS.md:17) 的 #207、[`STATUS.md:27`](/K:/zero-player/docs/implementation/STATUS.md:27) 的 #203。
- 书坊长章节的抽取/分页耗时只在受控样本中观察过，未做真机长文压力测试（[`STATUS.md:29`](/K:/zero-player/docs/implementation/STATUS.md:29)）。
- Android/TV 真机与系统挂起后的后台下载未验收（[`STATUS.md:166`](/K:/zero-player/docs/implementation/STATUS.md:166)）；听书的系统后台、通知栏与锁屏行为也未真机验收（[`STATUS.md:121`](/K:/zero-player/docs/implementation/STATUS.md:121)）。
- 两端对齐、字重、系统大字号等排版项未在真机核对（[`STATUS.md:7`](/K:/zero-player/docs/implementation/STATUS.md:7)）；620 px 断点与 320/390 px 回归未覆盖超长书名与大字号叠加（[`STATUS.md:8`](/K:/zero-player/docs/implementation/STATUS.md:8)）。
- 真实带宽下的并发下载表现未测（[`STATUS.md:9`](/K:/zero-player/docs/implementation/STATUS.md:9)）。
- 上一版本引用的 `STATUS.md:911/912/950` 仍存在，但属于「下一步与验收边界」和直播下载说明，不是小说模块的专项记录；本版改用小说/听书章节的有效行号（`:7`–`:10`、`:17`、`:27`、`:29`、`:121`、`:166`），后续引用仍应按当前 977 行的文件核对。

## 验证结果

本轮实际执行（串行，避免 Flutter 工具并发写 `build/native_assets`）：

- `flutter analyze --no-pub`：`No issues found! (ran in 115.0s)`。
- 定向测试第一批（漫画下载、阅读缓存、下载协调器、图片章节、图片载荷等）：`01:01 +30: All tests passed!`。
- 定向测试第二批（图片载荷、书架筛选、手机布局、书发现手机搜索）：`00:05 +8: All tests passed!`。
- 两端对齐分页实测：`tmp/justify_probe_test.dart`，宽 320、字号 18、行距 1.8，结果见 B-10。
- `git diff --check -- lib/features/books test/books test/widgets integration_test`：无输出。
- 未重跑全量测试（沿用 [`STATUS.md:10`](/K:/zero-player/docs/implementation/STATUS.md:10) 的 1268 通过 / 12 跳过记录）；未做 Android/TV 真机、真实网络带宽与长时间后台下载验证。
- 经验记录：并发运行两条 Flutter 命令会因 `build/native_assets/windows/sqlite3.dll` 被占用而崩溃（`PathAccessException: Deletion failed … errno = 5`），后续验证须串行。

## 结论

本轮共确认 10 项问题：7 项中等（B-01、B-02、B-03、B-05、B-06、B-07、B-08）、3 项轻微（B-04、B-09、B-10），其中 B-07～B-10 为本轮新增。相对上一版：修正了 B-01/B-06 的过时行号，把 B-04 的视频侧曲线描述改为 `easeOutCubic`，把 B-05 的结论改为「快捷面板没有行距控件」，并把 `STATUS.md` 引用从通用验收条目换成小说/听书章节的有效行号。

未发现越权、内容策略绕过或数据一致性问题：阅读/下载的图片路径都会经过监管与受限目标检查，`ContentBlocked` 能中断整单，缓存与离线写入都在事务内复核策略。主要风险集中在**内存峰值（B-01）**与**图片解码校验缺失（B-02）**；与之并列的是三处阅读体验缺口（图文配色 B-07、自动阅读偏好 B-08、漫画翻页 B-06）。建议优先处理 B-01、B-02、B-08，再按交互统一（B-03、B-04、B-06）与排版细节（B-05、B-09、B-10）分批修复，并在修复后进行 Android/TV 真机与长章节压力验收。

## 修复与复验（2026-11-16）

下表记录基于本报告的后续修复；上文为修复前的审查证据，行号不再代表修复后的源码位置。

| 编号 | 修复结果 |
| --- | --- |
| B-01 | 图片请求受单图 4 MiB 和单章剩余原始字节预算约束；累计达到 48 MiB 后停止后续请求，超过 100 张在下载前拒绝。离线保存先按原始字节检查，再逐图编码入事务，不再创建整章 base64 字符串数组；全局 192 MiB 仍按实际编码存储计量。 |
| B-02 | 下载与缓存写入前检查尺寸、像素和解码；旧阅读缓存读出失败时删除并重新获取。离线写入同样验证图片，失败不覆盖旧章节；图片解码后的策略校验仍执行。 |
| B-03 | 单本菜单可删除阅读历史；小说／听书历史视图可确认后清空当前历史列表。重置 last、position、textOffset 和富文本位置，保留书架、收藏、追更、笔记与离线内容，并刷新列表。 |
| B-04 | 返回顶部统一为滚动超过 500 px 后出现的浮动按钮，动画 350 ms / easeOutCubic，尊重关闭动画设置。 |
| B-05 | 快捷面板加入行距和页边距；行距存值规整到百分位，预设匹配使用浮点容差。 |
| B-06 | 漫画支持纵向连续滚动、横向分页（含仿真设置的映射）与纵向分页，恢复分页进度；图片边缘点按翻页、中心缩放、长按切换阅读菜单，保留键盘翻页。漫画不渲染纸页卷曲动画。 |
| B-07 | 图文文字接收正文样式、墨色、对齐方式和边距，跟随阅读设置。 |
| B-08 | 样式面板从持久偏好而非运行快照读取自动阅读状态；修改普通排版不会关闭偏好或仅因暂停而重启自动阅读。 |
| B-09 | 快捷／完整面板在同一次编辑中依次 await，结束时仅保存一次，配置标记通过 finally 复位。 |
| B-10 | 保留下一页的段落延续参与 Text 布局，以当前页行数裁剪，避免把软换行的页末当成段末；真实段末继续保持自然宽度。 |

另修复空查询清除范围 chip 未刷新的问题、分类栏在放大文字下的高度，并将发现页搜索／工具栏／分类栏拆至 `book_discovery_toolbar.dart`。数据预算集中至 `BookResourceLimits`。

复验：全量 Flutter 回归 **1275 通过、12 跳过**（`build/books-review-fix-full-20261116.log`）；最终定向回归 **17 通过**（`build/books-review-fix-final-targeted-20261116.log`）；正式源码与测试范围 `flutter analyze --no-pub lib test integration_test tool test_support` 无问题（`build/books-review-fix-analyze-final-20261116.log`）。原始全工作区 analyze 因原有 `tmp/preset_probe.dart` 的 `print` 提示失败，临时文件已保留，没有将这次失败当作通过。

Windows 原生新增受控用例 **1 项通过**（不计 tearDownAll）：离线图片实际解码、分页、缩放、键盘翻页、清历史后保留收藏与离线内容。日志 `.dart_tool/native-5c9049a5/books_review_native_test.log`，驱动仍有既有 integration_test 插件检测提示，实际结果及退出码成功。

源码规模检查仍返回失败，详见 `build/books-review-fix-size-final-20261116.log`：`books_repository.dart` 2488 行超过工具统一 1500 行提示、仍在复杂源码 2500 行边界内，其他历史超长函数与工具／测试也继续保留。发现页本体已降至 1500 行以内，本轮新图片访问和新增回归函数不超过 100 行。

性能建议中的缓存全表扫描、长章节解析／排版压力和预扫描事务优化仍待专项测量；来源 #203／#207、超长标题叠加系统大字号、Android／TV 实机、真实带宽和长时后台验证仍未闭环。本次未降低既有监管、内容过滤或网络访问限制。

重打包已完成：`artifacts/device-test/0.7.4-20261116-232253/`，含 Windows x64 安装器／便携 ZIP 和 Android ARM64 开发测试 Release（`0.7.4+74`，独立包名、既有测试证书），附 `BUILD-INFO.json`、声明／原生来源与 `SHA256SUMS.txt`。包体验证日志及逐文件证据为 `build/books-review-fix-package-check-20261116.json`；Android／TV 实机与干净 Windows 安装／卸载未验证。本轮未提交、推送或公开发布，保留原有工作区修改。
