# Zero Player 代码审查反馈（2026-11-18）

> **修复核查说明**：以下原始审查正文保留用于编号对照，其中“确证”不代表最终核查结论；请以末尾“附录 C 逐项复核与修复”及本轮验证记录为准。M-07、L-04、L-09 的原缺陷判断不成立，S-03、M-04、M-06 等建议已收窄。

> 审查对象：`K:/zero-player`，工作区干净（仅 `tmp/` 未跟踪），HEAD `007c2e1`。
> 审查范围：`lib/` 515 个 Dart 文件（90,589 物理行）、本轮性能重构全部改动（`718f229..HEAD`，30 个 `lib` 文件、约 3,000 行增删）、`test/` 与 `tool/` 门禁脚本。
> 方式：静态分析与既有门禁复跑 + 按子系统并行通读调用链 + 对每条结论回读源码复核行号；未修改任何项目文件。
> 限制：只读审查，未在 Android/TV 真机、真实公网媒体上验证；标注「**需设备验证**」的条目仅有代码层证据。项目既有的监管/成人过滤、私网拦截、HLS 引用校验、恢复码边界等安全策略本身不计为缺陷。

## 严重程度定义

沿用项目 2026-11-04 审查报告的口径：

| 等级 | 判定标准 |
| --- | --- |
| 严重 | 核心功能失败、数据丢失或不可恢复的资源/状态泄漏 |
| 中等 | 特定输入、竞态或异常下功能错误、状态不一致、数据被错误覆盖 |
| 轻微 | 边界健壮性、显示口径、防御性编程缺失、局部体验问题 |

「**确证**」表示已回读源码并能给出确定的触发路径；「**需设备验证**」表示代码层风险明确，但触发依赖平台或第三方数据形态。

## 汇总

| 等级 | 数量 | 其中与本轮改动相关 |
| --- | ---: | ---: |
| 严重 | 3 | 0 |
| 中等 | 15 | 1（M-05） |
| 轻微 | 10 | 1（L-07） |
| **合计** | **28** | **2** |

**总体结论**：本轮重构的方向与边界控制是正确的——监管放行点未被削弱、`changesFor` 的域过滤只会过度通知不会漏通知、缓存摘要在写入路径上的语义正确、播放页局部订阅没有丢失状态、字体迁移覆盖了旧设置与旧备份。**没有发现由本次重构直接引入的功能回归。**

发现的 28 个问题几乎全部是**既有缺陷**，只是在这次通读中才被定位；其中仅 2 项与本轮改动相关（缓存计量的孤儿文件、`MetadataDomain.live` 建了域却没有写入方）。这说明本次「先证明不变量、再减少工作量」的重构方法有效，但也说明：**已有的自动化测试没有覆盖续播拒绝、下载删除回滚、缓存异常路径这些真正会丢数据的分支**（全量 1552 项通过并未拦住上述严重问题）。

---

## 一、严重

### S-01 续播被拒绝后播放器进入「半瘫痪」状态（`确证`，既有）

**位置**：`lib/features/playback/application/playback_controller.dart:433-440`、`:584`、`:589-596`、`:652-658`、`:990`、`:1003-1016`

**三条触发路径最终都只置 `_resumeRejected = true`，却不把 `_resume` 置空**：

1. 12 秒内拿不到时长（`:433` 的定时器）；
2. 资源时长小于续播点（`:589`）；
3. `_seekEngine` 恢复失败（`:652`，此处还 `_resume = target`）。

**后果**（`_onState` 在 `:584` 提前返回，而唯一的 `notifyListeners()` 在 `:632`）：

- 位置快照不再通知，进度条、时间、播放图标**冻结**（视频实际仍在播）；
- `toggle()` 在 `:990` 直接 return，**暂停/播放永久失效**；
- `_health.observe(enabled: _resume == null)` 恒为 false，卡顿/漂移自动恢复停用；
- `_saveTimer` 每 4 秒执行的 `save()` 在 `:1003` 使用 `_resume ?? ...`，**持续把旧续播点写回历史**——用户继续看 40 分钟，下次打开仍回到原位；
- `cancelRecovery()` 已把 `_recoveryCancelled` 置真，整场无自动恢复。

**修复**：拒绝续播时把位置转存到 `_recoveryPosition` 并清空 `_resume`；`_onState` 改为只跳过与续播相关的分支，不要跳过整个通知；`toggle()` 只拦 `awaitingResume`。该分支目前**没有任何测试覆盖**（全仓检索「未能读取可续播」无命中）。

### S-02 下载删除：不可逆的目录与 pin 清理早于可回滚的事务（`确证`，既有）

**位置**：`lib/features/downloads/application/download_scheduler.dart:340-353`（`remove`）、`:349`；`lib/features/downloads/data/download_repository.dart:168-175`

`remove()` 的顺序是：递归删除目录 → `store.unpin(id)` → `repository.remove(id)`（DB 事务）。事务若失败（磁盘满、DB 锁、trigger 拒绝），目录和 pin 已经没了，但任务行回滚为 `complete`，`local_path` 指向不存在的目录。

**放大因素**：`_attempt` 仅在 `localPath == null` 时执行（`:211`），下载页对 `complete` 任务不提供「重试」，于是该任务**永远无法重新下载**，只有播放时才报「文件缺失」。本地文件被外部删除、备份只带回 DB 行时走同一条死路。

**修复**：先在同一事务中删除/标记任务行（或先写 `download_cleanup` 意图），成功后再删目录与 unpin；`resume` 前校验 `local_path` 是否真实存在，缺失则清空重下。

### S-03 恢复下载时媒资 URL 变化会丢弃已下载数据（`确证`，既有）

**位置**：`lib/features/downloads/application/mp4_download.dart:67-75`；`lib/features/downloads/application/download_resolver.dart:47`；`lib/features/downloads/application/hls_download.dart:74-96`

`_attempt` 每次恢复都先 `resolve!()`，`relocate` 把新解析的 URL 写回任务；`_Mp4Transfer` 发现 `state['uri'] != uri.toString()` 就删除 `.part` 从 0 重下，HLS 发现 `saved['root'] != uri` 就新建 revision。

**影响**：带签名或轮换镜像的源上（国内 CDN 常见），**每次暂停/崩溃后的恢复都是从零开始**；HLS 还会因新 revision 的 key 全变而重下全部分片，且旧 pin 到结束才释放，容量紧张时直接报「安全重下需额外空间」。

**修复**：检查点绑定**集身份**（source/remote/line/episode）而非最终 URL；MP4 用 `ETag`/`Last-Modified` + `If-Range` 作为唯一续传依据；HLS 用清单内容指纹判定同一 revision。

---

## 二、中等

### M-01 暂停无法打断已排队的自动切歌（`确证`，既有）

**位置**：`lib/features/music/application/music_controller.dart:688-695`、`:775-789`

`_advance()` 先 `await _record()` 再 `select()`；`_suspend(clear: false)` 的 `retire = loading || clear` 在非加载态为 false，**不递增 `_generation`**。曲目播完进入 `_advance` 后按暂停，`_generation` 未变，`select()` 继续执行并把 `_wantsPlayback` 置回 true，下一首自动开播。手动 `next()` 后立刻暂停同样命中。

**修复**：为「切歌推进」单独发票据，在 `_suspend` 与 `toggle` 的暂停分支递增；或在 `_record()` 之后补 `!_wantsPlayback` 判断。

### M-02 书源页订阅未加域过滤，刷新风暴时会把列表清空（`确证`，既有）

**位置**：`lib/features/books/presentation/book_sources_page.dart:77`、`:167-206`

`changesFor(const {'app_meta'})` 未传 `metadataDomains`，`affects()` 在订阅方 `domains == null` 时对**任何** `app_meta` 写入返回 true（`app_database.dart:259-269`）。因此音乐历史、直播状态、书源抽查结果等高频写入都会触发 `_reloadSources()`（两次全表 `GLOB` 扫描 + 全量 JSON 解码）。

更严重的是 `:167` 的重试循环：4 次尝试中只要 `_sourceRevision` 变化就 `continue`，全部失效后执行 `_entries = []` 并显示「启用书源后即可在这里找书」。并发写入密集时存在**列表被清空**的窗口。

**修复**：为书源新增 `MetadataDomain.books` 并让写入走 `setMetadata`；订阅时传域（未标记写入仍会全量通知，不会漏刷新）。同时 `_reloadSources` 失败路径应保留旧 `_entries`。

### M-03 无关的策略通知会打断下载与阅读（`确证`，既有）

**位置**：`lib/features/books/data/book_download_coordinator.dart:311-319`；`lib/features/books/presentation/rich_reader_page.dart:121-133`

`ContentPolicy.refresh()` 是无条件 `notifyListeners()`（`content_policy.dart:66`），全仓有 **14 处调用**，其中包含保存文本替换规则（`book_chapter_policy.dart:200`）、提交站点抽查证据（`book_repository_site_checks.dart:432`）等与当前任务无关的路径。

- 书下载：`_policyChanged` 不复查任务是否仍被允许，直接 `_stoppedByPolicy = true` + `cancel()`，全部任务变 `paused` 并提示「内容策略已改变，下载已暂停」，需手动续传。对比 `AudiobookController._policyChanged`（`:313-327`）先复核 `kindAllowed/bookAllowed/downloadGuard` 再动作，此处明显不对称。
- EPUB/PDF 阅读：`_onPolicyChanged` 直接 `_error = '内容策略已变更，请退出后重新打开'`，与正在读的本地文件无关的策略变化也会强制退出。

**修复**：两处都改为「先按当前快照复核，仅在确被限制时停止/退出」；或比较 `bookSitePolicySnapshot` 而不是监听裸通知。

### M-04 直播预检的预写标记在取消后不回滚（`确证`，既有）

**位置**：`lib/features/live/application/channel_preflight.dart:60-80`、`:93-94`；解码侧 `lib/features/live/domain/live_health.dart:42-56`

`refresh()` 先对队列内**所有**频道写入 `preflight:true, enabled:false, autoDisabled:true, pendingValidation:true`，再开始探测。若用户取消（`token.check()` 抛出）、应用退出或某个 worker 抛错，未探测到的频道停留在「停用 + 待验证」——`decode` 中 `valid=false` 会强制 `enabled=false`、`availability=unknown`，界面显示「待媒体复检通过后恢复」。原本可正常播放、仅因超过 24h 进入队列的频道被静默停用。

**修复**：只对「即将开始探测」的频道在 worker 内预写；或记录预写前快照，在取消/异常路径恢复。

### M-05 缓存提交顺序会在失败时留下永久未计量的 `.bin`（`确证`，与本轮计量改动相关）

**位置**：`lib/media/cache/segment_store.dart:349-372`、`:86-108`

`_commit` 的顺序是 `_makeRoom()` → `temporary.rename(target)` → `metadata.put()` → `_setEntry()`。若 `metadata.put`（SQLite）抛错，`write()` 的 catch 只删 `$key.part`（已改名不存在），目标 `.bin` 留在盘上；`_setEntry` 未执行 → `_sizeBytes/_cacheBytes` 都不计；`initialize()` 只清理 `*.part`，永不回收。

**影响**：配额按计数判断，因此缓存目录可无限超额（磁盘满时恰好最容易触发），`find()` 也查不到该文件。相关地，`initialize()` 的 `else` 分支（`:94-96`）只删 DB 行、不减计数，重复初始化时会造成计数虚高并误报 `Cache is full with active resources`。

**修复**：metadata 写入失败时删除 target；`initialize()` 反向核对目录中的 `*.bin`，把不在索引中的文件删除或计入；`else` 分支同步扣减计数。

### M-06 空 body 或截断的 chunked 响应会被当作完整分片永久缓存（`确证`，既有）

**位置**：`lib/media/cache/segment_store.dart:300-347`；`lib/media/cache/segment_fetcher.dart:61-63`；`lib/media/gateway/media_gateway.dart:495-497`

`expectedLength` 在 `contentLength < 0`（chunked）时为 null，`write()` 只校验该值，对 `bytes == 0` 无拦截；摘要按实际字节计算，于是 0 字节/截断文件在结构上与完整文件不可区分，`verify()` 重算哈希自然通过，缓存无 TTL。

**影响**：该 URL 的分片被**永久毒化**，播放每次都在同一处失败且不自愈，只有被淘汰才恢复。

**修复**：媒体分片拒绝 `bytes == 0`；存在 `Content-Range` 时用 `end-start+1` 交叉校验；记录 `content-length` 与实际字节的偏差。

### M-07 `ProbeSampler` 的轨道探测条件写反（`确证`，既有）

**位置**：`lib/media/content_filter/probe_sampler.dart:23`

```dart
if (!visual || !audio || _probedInput == input) return;
```

只有「至少一个轨道不需要」时才跳过探测。而 `feature_capture.dart:44-49` 的 `mode == both`（默认采集方式）与 `content_filter_service.dart:81-87` 的「特征 + 关键词同时开启」都会传入 `visual: true, audio: true`，于是**最需要探测的场景反而不探测**，`_hasVisual/_hasAudio` 保持默认 true。

**影响**：纯视频（无音轨）或纯音频源上，ffmpeg 因 `-map 0:a:0` / `-map 0:v:0` 失败，特征采集报「没有可识别的有效内容」，后台检测永久停在「此段检测失败，正在自动重试」。

**修复**：条件改为仅 `if (_probedInput == input) return;`，并对采不到的轨道不生成对应 `-map`。

### M-08 AES-128 密钥被当作媒体内容嗅探，命中即整条加密流无法播放（`确证`，既有）

**位置**：`lib/media/gateway/media_gateway.dart:489-500`；`lib/media/network/media_response_policy.dart:74-91`；`lib/media/hls/hls_manifest.dart:142-147`

`#EXT-X-KEY` 的 URI 与普通资源走同一套 `map()` 注册与 `guardMediaBody` 校验。`_validatePrefix` 会把首字节为 `<`(0x3C)、`MZ`、`0x7F`+「elf」的负载判为非媒体。16 字节随机密钥首字节命中 `<` 的概率约 0.4%。

**影响**：单条流的密钥一旦命中，该请求 502，播放器无法解密，表现为「这个频道偶尔整条放不出来」，且密钥不变就永久复现。

**修复**：登记时标记 `key` 类型，密钥请求跳过内容嗅探，只做长度上限。

### M-09 历史查询在 `LIMIT` 之后才做内容过滤（`确证`，既有）

**位置**：`lib/features/library/data/history_repository.dart:30-41`

`recentWorks()` 先 `LIMIT 50`、`all()` 先 `LIMIT 500`，再在 Dart 侧 `where(recordAllowed)`。启用监管/成人过滤时，若窗口内恰好都是受限记录，更早的合法记录永远不出现，首页「继续观看」与历史页显示为空。

**修复**：在 SQL 层完成可判定的过滤；至少在过滤后为空且行数达到 LIMIT 时自动扩大范围重查。

### M-10 续播保存无脏检查：每 4 秒两次事务，历史页同步全量重载（`确证`，既有）

**位置**：`lib/features/playback/application/playback_controller.dart:47-50`、`:1003-1016`；`lib/features/library/data/history_repository.dart:64-99`；`lib/features/library/presentation/history_page.dart:23-34`

`_saveTimer` 每 4 秒调用 `save()`，`save()` 不比较位置或播放状态，`policy.requireItem` 后固定执行 `rememberContent`（一次事务 + `INSERT OR REPLACE content_label`）与 `watch_history` upsert（第二次事务）。`HistoryPage` 直接 `setState(_load)`，无防抖、无可见性判断。

**影响**：暂停画面停留时仍每 4 秒写两次库、把该集顶到历史首位（用户并未观看），并按 `watch_history` + `content_records` 两个域各触发一次 500 行 LEFT JOIN 重查；播放器压栈期间历史页仍 mounted，持续消耗 CPU/DB。

**修复**：记录上次落库的 `(position, duration, episode)`，仅在变化超阈值或状态切换（暂停/切集/退出/seek 落定）时写；历史页加防抖与 `visible` 判断（可复用发现页的 generation 模式）。

### M-11 富文本阅读恢复滚动失败后 `_resumeOffset` 永不清理（`确证`，既有）

**位置**：`lib/features/books/presentation/rich_reader_page.dart:781-797`、`:270-286`

`_restoreScroll` 在 `maxScrollExtent == 0 && _resumeOffset > 0` 时直接 return，`_resumeOffset` 保持原值；`_save()` 使用 `offset: _resumeOffset ?? _lastScrollOffset`，于是本会话内每 3 秒都把**旧偏移**写回 `rich_position_*`，覆盖用户真实滚动位置，下次在小窗口打开会跳到旧位置。

**触发**：在小窗口保存了 `offset > 0`，随后在内容一屏放得下的大窗口打开同一本书。

**修复**：进入恢复回调后无论成功与否都清空 `_resumeOffset`；`_save` 优先 `_lastScrollOffset`。

### M-12 下载换源在开始下载前串行等待，最长 45 秒（`确证`，既有）

**位置**：`lib/features/downloads/application/download_scheduler.dart:202-209`；`lib/features/downloads/application/download_failover.dart:63-73`

开启 `multiSourceDownload` 后，只要 `_activeSources` 已包含该源，任务在 `_attempt` **之前**先走 `failover.find()`：遍历所有候选源、每源 8 秒、总截止 45 秒。同一作品的第 2 集起、甚至不同作品的同源任务都会先空转，`downloadConcurrency` 实际失效；找不到候选时必然走满截止时间。

**修复**：预检只使用已缓存/已知候选，或把上限压到 3-5 秒；更稳妥的是立即开下，仅在失败后再换源。

### M-13 Android 短暂 `inactive` 会永久暂停下载（`确证`，需设备验证，既有）

**位置**：`lib/app/product_app.dart:258-273`；`lib/features/downloads/application/download_scheduler.dart:125-134`

`didChangeAppLifecycleState` 用 `state == resumed` 二值化，`inactive`（通知栏下拉、权限弹窗、来电、分屏失焦）也会触发 `setForeground(false)` → 对全部 token `pause()` 并落库 `paused`；回到 `resumed` 只 `kick()`，不恢复 paused 任务。生命周期暂停与用户主动暂停共用同一状态，无法区分。

**修复**：为生命周期暂停保留「自动恢复」标记（内存集合，或 `paused + autoResume`），仅在 `paused/hidden` 且超过短超时才真正落库暂停。

### M-14 直播源已提交成功，复检失败仍写「更新失败，保留旧列表」（`确证`，既有）

**位置**：`lib/features/live/data/live_repository.dart:153-161`、`:256-260`

`importText` 已完成 `db.atomic` 提交并把 `error` 置 NULL，随后 `await verifyUpdates?.call(...)`；该调用抛出非取消类异常时会冒泡到 `import` 的 catch，写入「更新失败，保留旧列表」。而新列表实际已生效，订阅管理页的信息与真实数据相反。

**修复**：区分「提交前失败」与「提交后复检失败」，后者写「频道已更新，复检未完成」；或在 `importText` 内部自行承担复检错误。

### M-15 监管下可免密关闭「后台检测源可用性」，并停掉书源抽查（`确证`，需产品确认）

**位置**：`lib/features/settings/application/settings_controller.dart:288-327`；`lib/app/app_services.dart:214`；`lib/features/settings/presentation/settings_page.dart:273-277`、`:432-437`

`_update` 的授权只挂在 `_checkAdultFilter` 上：仅 `filterAdult=false`、`contentFilter/filterOcr/filterAsr/filterKeywords=false`、`filterSkipSeconds`、`filterStrategy` 会触发授权。`backgroundProbe`、`bookSiteAutoCheck` 等**不校验密码**。

`lib/features/books/application/book_site_monitor.dart:57` 与 `lib/features/books/data/book_supervised_site_scan.dart:103` 的 `_allowed` 都要求 `backgroundProbe`，因此监管期间唯一的书源网页抽查（发现/隔离成人、博彩书源的自动化证据来源）可被无密码永久关闭，重启后仍不运行。同仓 `LanAccessStore._change`（`lan_access_store.dart:62-66`）和 `book_sources_page.dart:855-862` 对同类开关都会走 `SensitiveOperation.settings` 验证——**同一语义存在两套实现**。

**修复**：让 `backgroundProbe`/`bookSiteAutoCheck` 与 LAN 访问一致地走 `runSensitive(settings)`；若确认「只有成人过滤受保护」，则应删除 `app_services.dart:214` 的注入并在 UI 注明，避免两套语义并存。

---

## 三、轻微

| 编号 | 位置 | 问题 | 建议 |
| --- | --- | --- | --- |
| L-01 | `rich_reader_page.dart:818-821` | 章节搜索摘要用 `substring` 直接按码元截断，起点/终点落在代理对中间时产生孤立代理，摘要出现替换字符（同文件 `reader_tools.dart:384-388` 已有边界处理，此处遗漏） | 复用 `_textBoundary` 等价逻辑 |
| L-02 | `music_library_panel.dart:209-305` | 播放历史（上限 200）与离线（上限 500）用 `Column` + `for` 一次性构建全部 `Card`，外层是 `SingleChildScrollView`，每次通知整表重建 | 改 `ListView.builder`/`SliverList` |
| L-03 | `music_preflight.dart:126`、`:145` | 7 秒 deadline 在入队前启动，`_probe` 走 `RequestPriority.background`（全局并发 4、同源 2），一次并发 12 个候选时尾部候选把排队时间算进超时，被记为 `null` 并负缓存 25 秒，表现为「明明有别的源却换源失败」 | 期限只覆盖实际请求阶段，或换源探测用 `interactive` |
| L-04 | `download_output.dart:140-148` | `name == 'output.mp4' && name != entry` 中 `name` 已是该实体自身的 basename，条件恒真，会删除任务目录顶层任何 `output.mp4`（当前导出走 `.save-*` 子目录，暂无实际破坏） | 改为 `name != p.basename(entry)` |
| L-05 | `download_selection.dart:174-198` | 批量入队的 `kick()` 在循环之后；第 N 条创建失败时已创建的 N-1 条停在 `queued`，直到重启或手动继续 | `kick()` 移入 `finally` |
| L-06 | `media_gateway.dart:503-512` | `_close()` 中 `_transfers.cancel()` 未加保护，且位于 `session.close()`/`_server.close()` 之前；`CancellationToken.cancel()` 会重抛首个监听器异常，一旦发生则端口不释放、`_closing` 缓存失败 future | `try/catch` + `finally` 保证释放 |
| L-07 | `metadata_domain.dart:4-17`、`live_page.dart:48-51` | `MetadataDomain.live` **没有任何写入方**（全仓无 `setMetadata(..., MetadataDomain.live)`），所有 `live_state:*`/`live_list_enabled:*` 仍以「未知域」发布。过滤器对直播数据完全失效，`music_download:*`（`music_downloads.dart:167`，随 500ms 进度回调写入，约 2 次/秒）、`music_provider`、`music_recommendation:*` 仍会唤醒直播页做完整 `channels()`，「消除无关直播刷新」的目标未达成 | 把直播写入改为 `setMetadata(..., live)`；并为 `music_download:*` 等高频键补域或合并写 |
| L-08 | `tmp/` | `flutter analyze` 的 15 条问题全部来自未跟踪的 `tmp/audit_probe*.dart`，会污染门禁输出 | 删除临时文件或加入 `analysis_options` 排除 |
| L-09 | `assets/fonts/` | `NotoSansSC.ttf`(17.7 MB)、`NotoSerifSC.ttf`(25.1 MB) 已不进包，但仍占仓库 42.8 MB；仅 `tool/generate_content_filter_fixtures.py` 使用 | 若保留用于夹具，建议移到 `tool/fixtures/` 并在文档注明；否则移除 |
| L-10 | `book_store.dart:413-439` | `writeImported` 用 `db.batch` 写入后不发布变更通知；同仓 `book_site_revision.dart:88`、`book_site_observed_sources.dart:138` 都在 batch 之后显式 `db.changed(tables: {'app_meta'})`。当前由导入路径末尾的 `policy.refresh()` 兜底，若导入在写完后抛异常，或未来新增纯 db 监听者，就会静默不同步 | batch 之后补 `db.changed(tables: {'app_meta'})` |

---

## 四、已核对未发现问题的区域

以下区域经过逐行或调用链核对，**未发现缺陷**，列此便于交叉验证与后续回归基线：

- **监管与内容边界**：`itemAllowed/liveNameAllowed/channelAllowed/sourceAllowed/sourceIdAllowed` 在搜索、发现、详情、续播、历史、下载、离线书籍、书源、广播、音乐各入口均有最终放行调用；未找到「先展示后校验」的窗口或可稳定利用的 TOCTOU。恢复码路径仅允许 `SensitiveOperation.supervision`，轮换后旧 grant 与旧码同时失效。密码失败计数与退避跨重启保留。
- **通知机制**：`_ChangeBatch` 合并、`untracked` 向上传播、`_metadataStatement` 用 `total_changes()/changes()` 判定精确性均正确（实测 `INSERT OR REPLACE` 计 1、触发器计 2，判定符合预期）；`changesFor` 的空域语义只会过度通知，不会漏通知。
- **缓存与 pin**：`pin/unpin/retainPins` 对 `cacheBytes` 的增删对称；`_makeRoom` 跳过活动 lease 与受保护项；`pinnedResourcesFor` 的分块占位符与 owner 快照语义正确。
- **播放展示层（本轮改动）**：`player_page` 的 `ListenableBuilder` 覆盖了 `PlaybackSurface` 全部内容，`Video` 仅通过 `child` 稳定；`fit` 变化走 `setState` 换新 child；`engine` 为 final，`engine.video` 稳定。未发现漏订阅或字段漏选。
- **阅读器排版**：`reader_pagination` 的代理对处理、`end <= start` 兜底、`indexForOffset/pixelsForOffset` 二分边界、`ReaderViewport` 的 generation 取消均正确。
- **字体迁移（本轮改动）**：`appFontPreference` 把已退役的 `notoSans/notoSerif` 归一为 `system`，`validAppFont` 允许旧备份通过校验，`readerFontFamily` 对未知字体回退系统字体；未发现升级路径上的下拉框断言或缺失字形。
- **单实例与文件打开**：`ApplicationOwnership` 锁、`LocalOpenChannel` 的随机 token 与回环校验、`pins` 路径校验未发现绕过。
- **原生输入校验**：`probe_sampler` 的协议/格式白名单、`hls_manifest` 的变量与 URI 属性计数校验、`ts_timestamps` 的 188 对齐前置校验均有效。

---

## 五、建议修复顺序

1. **S-01 续播半瘫痪**——影响「继续观看」主路径，且会持续覆盖历史进度；改动集中在一个文件，建议先补回归测试再修。
2. **S-02 / S-03 下载数据丢失**——两者都会让用户已下载的内容不可恢复，建议一起改：删除顺序 + 检查点身份。
3. **M-05 / M-06 缓存完整性**——配额失真与分片毒化会长期累积，且与磁盘满这种「正好会发生」的场景耦合。
4. **M-07 / M-08 检测与播放的可复现失败**——一处是条件写反，一处是概率性但不可自愈。
5. **M-02 / M-03 / M-04 状态与通知失配**——都是「无关事件打断当前工作」，用户可感知。
6. **M-09 / M-10 性能与正确性**——与项目本轮的「减少额外工作」目标直接相关，建议纳入下一批性能任务卡。
7. 其余中等与轻微项可按模块排期。

## 附录 A 本次执行的验证

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `flutter analyze` | 15 条，全部在 `tmp/`（14 info + 1 warning），`lib`/`test` 无问题 |
| 全量测试 | `flutter test` | **1552 通过、12 跳过、退出码 0**（约 2 分 12 秒），日志 `build/code-review-tests.log` |
| 模块边界 | `dart run tool/check_module_boundaries.dart` | 515 文件通过，2 条既有播放装配例外 |
| 源码规模 | `dart run tool/check_source_size.dart` | 退出码 1，104 条超限（test 74、tool 28、integration_test 1、**lib 0**），基线 `build/source-size.log` |
| 缓存计量语义 | SQLite 实测 | `INSERT OR REPLACE` → `total_changes` 与 `changes()` 均为 1；带触发器 → 2 与 1，`exact` 判定按预期降级 |

## 附录 B 建议补充的回归测试

- 续播三条拒绝路径：12 秒无时长、目标超过时长、seek 失败——断言 `_resume` 已清空、`toggle()` 可用、`save()` 写入当前而非旧位置。
- 音乐：`_advance` 在 `_record` 期间按暂停，断言下一首不自动播放。
- 下载：`repository.remove` 抛错后，任务可重新下载；URL 变化但 `ETag` 相同时 `.part` 不被删除。
- 缓存：`metadata.put` 抛错后目录无孤立 `.bin`；空 body 写入被拒绝。
- 直播：预检取消后频道健康状态回到取消前。
- 书源：并发 `app_meta` 写入下 `_reloadSources` 不清空列表。


## 附录 C 逐项复核与修复（2026-11-18）

本轮先固定本地备份提交 `5ca18b6` 与分支 `zn/backup-before-review-fixes-20261118`，再回读调用链、注入异常及运行回归。起点受跟踪代码已全部提交，因此该提交是空的备份标记，内容与 `007c2e1` 相同；原有 `.workbuddy/`、`tmp/` 保留。原报告副本在 `build/review-feedback-20261118/CODE-REVIEW-original.md`。

最终口径：28 项逐项核查，**25 项确认或部分确认并修复，3 项原缺陷判断撤销**（M-07、L-04、L-09）；L-04 仅做防御性路径规范化。原文的严重程度和“全部确证”不能直接沿用；以下表格说明实际范围。

| 编号 | 复核结论 | 实际处理与边界 |
| --- | --- | --- |
| S-01 | 确认 | 三条拒绝路径清空等待续播状态并保留原位置，继续发布播放快照；成功的显式播放命令或手动 seek 后接受实际进度。超时、资源过短、seek 失败和播放命令抛错均有回归，未接受前仍保留旧续播点。 |
| S-02 | 确认 | 先原子提交任务删除及目录/pin 清理日志，再释放 pin 和删目录；启动补偿提交后中断。事务失败保留完成文件和 pin；完成文件缺失可重新入队。 |
| S-03 | 部分确认 | MP4 仅允许同 origin/path 的签名 query 变化且强 ETag 匹配时条件续传；跨主机/路径仍重下，不能把 ETag 当全局身份。HLS 只在新 root 清单内容指纹一致时复用 revision，分片 URL/请求头身份不归一化，轮换分片地址仍独立下载。 |
| M-01 | 确认 | 切歌推进增加独立票据，暂停/停止撤销等待历史落盘的推进；真实 SQLite 阻塞期间暂停后不自动下一首。 |
| M-02 | 确认 | 新增 books 域并标记 BookStore 的 books_* 写入；书源页按域订阅，四次读失效后保留仍允许的旧项并重试。未知/raw/batch 副作用仍保守通知。 |
| M-03 | 确认但收窄建议 | 重复相同策略快照且书籍仍允许时不打断下载/富文本阅读；真实策略变化、来源限制及关闭仍取消。下载最终证据与 generation 校验保留；人工证据复核 tracker 每次 refresh 的撤销语义完整保留。 |
| M-04 | 确认但收窄建议 | 同一请求仅证据过期时不预先停用，取消后保留原状态；请求地址/请求头签名变化或未知时仍立即写 pending/停用，避免旧证据放行新请求。 |
| M-05 | 确认 | 索引提交失败删除已 rename 的 bin，删除失败则保守计量并标 invalid；启动删除未索引/未保护孤儿并扣除缺失文件。损坏索引行对应文件及离线引用仍隔离保留，不误删为孤儿。 |
| M-06 | 部分确认 | 拒绝空资源，交叉校验已声明 Content-Length 和 Content-Range 的实际长度。协议层截断本已由 Dart 流报错；无长度证据且正常结束的非空响应，无法普遍识别服务端语义上的缺尾，撤销原文泛化断言。 |
| M-07 | **误报，撤销** | `visual=true,audio=true` 时 `!visual || !audio` 为 false，未缓存时会继续 probe。原报告把 return 条件解释反了；不改 ProbeSampler，保留现有轨道探测。 |
| M-08 | 确认 | HLS KEY/SESSION-KEY 使用独立 capability 路由，受同一网络/取消策略约束，要求 200 与 16 字节、禁止缓存；不做媒体前缀嗅探。相同 URL 的普通分片仍走媒体校验，避免 key 身份污染。 |
| M-09 | 确认 | 按 SQL 批次向更早记录读取，在内容过滤后凑满 50/500 上限，返回前再次放行校验；501 条受限记录遮挡旧合法历史的回归通过。 |
| M-10 | 确认 | 相同媒体/集/位置/时长/播放状态成功保存后去重；内容证据与历史 upsert 同一外层事务。历史页合并通知、隐藏时标脏、显示再查；策略变化先立即过滤现有展示，再延迟合并 DB 查询。保留原保存周期。 |
| M-11 | 确认 | 一屏内容将旧偏移 clamp 到 0 并清空待恢复值，保存实际位置；EPUB widget 回归验证保存 0。 |
| M-12 | 确认但保留功能 | 显式多源分配保留，下载前找备选的总预算缩为 3 秒；失败后的正常换源仍为 45 秒。不是“找不到必然等满 45 秒”，候选耗尽可提前结束。 |
| M-13 | 代码路径确认，设备待验收 | inactive 不触发下载后台暂停；真正后台暂停记录自动恢复集合，回前台串行恢复，用户手动暂停/删除撤销标记并在执行时复查。Android 通知栏/权限弹窗及 TV 实机仍需验证。 |
| M-14 | 确认 | 列表事务提交后复检异常改记“频道已更新，媒体复检未完成”，避免声称保留旧列表；取消继续传播。实际提交后失败回归通过。 |
| M-15 | 确认 | backgroundProbe/bookSiteAutoCheck 更新沿用 SensitiveOperation.settings 授权，并在事务内复查；监管下无授权拒绝，有效授权后成功。未改变恢复码或监管边界。 |
| L-01 | 确认 | 富文本搜索摘要起止位置避开 UTF-16 代理对中间。 |
| L-02 | 确认 | 音乐历史/下载使用 ListView.builder，移除对应外层滚动容器；歌单分支保留自身滚动。 |
| L-03 | 确认排队口径风险 | 媒体换源探测提升为 interactive，避免被后台 4 许可池的排队消耗期限；保留 7 秒总预算、同源/全局上限，不承诺任意拥塞下无超时。 |
| L-04 | **原判断不成立** | entry 是 task.localPath 的相对文件名，可等于 output.mp4，条件并非恒真。没有复现实际删除已完成输出；仅将比较改为 p.basename(entry) 统一路径表达。 |
| L-05 | 确认 | 批量创建任务的 kick 放在 finally，部分创建失败仍调度已入队项。 |
| L-06 | 确认异常路径 | 网关尽力取消全部会话并 finally 释放 socket/注册信息，结束后再抛首个监听异常；注入抛错监听器后同端口重新绑定通过。 |
| L-07 | 确认 | 直播健康/开关写入标记 live 域，音乐下载/偏好/推荐使用独立精确域；未知、触发器及未覆盖原始写入继续全量回退，不将 unknown 当空域。 |
| L-08 | 确认门禁污染 | analysis_options 排除 tmp/**，原有探针和用户临时文件保留。 |
| L-09 | **不构成缺陷，保留** | BUILD 已明确两套 Noto 源字体供合成夹具使用且不进 Flutter 包；属于已解释的仓库素材，不擅自删除或迁移。 |
| L-10 | 确认 | writeImported 的 batch 包在 atomic 内并于提交后通知 app_meta，回滚不通知；不把无法精确归因的 batch 伪标为精确域。 |

### 本轮验证与限制

原附录 A 属于修复前快照；本轮证据如下。

| 检查 | 本轮结果与证据 |
| --- | --- |
| 新增异常路径 | 真实 SQLite、临时目录、受控 localhost HTTP、widget/假播放器覆盖续播三种拒绝、删除失败/中断恢复、签名轮换、缓存失败、随机密钥、音乐暂停、历史过滤、重复策略、授权及 EPUB 位置；`build/review-fixes-targeted3.log` 31 项、`build/review-fixes-targeted4.log` 46 项、`build/review-fixes-targeted5.log` 25 项、`build/review-fixes-targeted6.log` 20 项分别通过，不能相加当作唯一测试总数。 |
| 全量 Flutter | 最终 **1579 项通过、12 项跳过、退出 0**，`build/review-fixes-full-final2.log`；包含最后补充的播放命令抛错保留恢复点回归。此前 1578 项通过日志亦保留。 |
| 静态分析 | 全仓 `flutter analyze --no-pub` 无问题（`build/review-fixes-analyze-final2.log`），随后播放小修与对应测试 `dart analyze` 无问题（`build/review-fixes-playback-analyze.log`）。 |
| 模块/规模 | 515 文件模块边界通过；规模仍退出 1、104 条既有债务，按文件/函数身份与起点比较无新增，无新增 lib 超限。`build/review-feedback-20261118/size-comparison.json`；未放宽门禁。 |
| Windows 原生 | 串行三组 **5 项业务回归通过**：PDF 原生渲染/搜索/导航、EPUB 排版/章节位置、音乐下载离线重开/历史、直播 WAV/HLS/请求头/换线。`build/review-fixes-native-final.log` 与 `.dart_tool/native-0149f8de/`；日志测试计数含 tearDownAll，未把它算作业务用例。 |
| Windows 构建 | 普通入口 `flutter pub get` + `flutter build windows --release --no-pub` 通过；最后播放小修后最终 Release 再次成功（`build/review-fixes-windows-release-final.log`）。PDFium 库/归档及 mpv/ANGLE 归档均通过既有摘要校验。 |

47 个本轮 Dart 文件格式不变，差异空白检查通过；7 份受保护插件注册/依赖/本机文件均已恢复并逐字节核对起点，945 份最终源码/配置/测试输入在最终验证及构建期间摘要一致。证据汇总 `build/review-feedback-20261118/final-verification.json`；Windows 应用在 `build/windows/x64/runner/Release/`。

早期全量 `build/review-fixes-full.log` 的 4 条失败，以及早期定向夹具/静态分析失败均保留，未改写为成功。人工证据复核和显式多源分配冲突已收敛回原契约；空资源回归更新为拒绝空载荷。原生日志的 integration_test 插件检测提示保留，Flutter driver 最终退出 0 并报告测试通过。

Windows 使用本机合成媒体，不能代表真实公网媒体/书源或 Android/TV 设备；本轮未重建 Android 包、未新增通知栏/权限弹窗/后台恢复的设备验收，未做功耗或长时测量。未改变原生依赖版本、网络访问或内容过滤边界；不发布、不推送。

## 附录 D 修复后场景自查（2026-11-18）

基线为上一轮修复提交 `2410600`。按用户补充的“部分章节失败、播放防误触锁仍随手机旋转”沿实际调用链再查取消、并发、退出及状态落盘，以下均有源码依据；网络下载不能保证任意书源始终成功，本次确保失败可识别、结果可恢复且不重复下载已有有效内容。

| 场景 | 核查与修复 |
| --- | --- |
| 锁定后仍响应旋转 | 确认。原防误触仅屏蔽触摸/键盘，未修改 Android 的 auto/sensor landscape 方向请求。增加临时 `SCREEN_ORIENTATION_LOCKED`，成功后才更新锁定 UI；解锁恢复偏好，退出恢复 system，不把临时锁写入设置。方向请求串行，全屏重应用保留锁定，失败可重试；锁定切换期间返回等待结果后解锁，销毁后的迟到操作不会再次发起锁定。TV 保持既有方向行为。 |
| 下载中部分章节异常 | 确认。逐章普通异常原本只累计计数，最终仍为 completed；改为 partial，持久保存安全的章节失败提示，管理页重开仍能查看失败章节并重试未完成部分。成功章节沿既有有效来源证据校验复用，正文过滤失败与网络失败分别保存，重试仍受策略/来源门禁约束。 |
| 下载结果落盘失败 | 确认。失败/过滤原因与成功后移除续传计划在同一事务提交；写失败保留计划、明确提示状态未保存，并把完成/部分完成改为失败以便重试。原因读取未完成时不覆盖旧记录，暂停重试保留前次失败。 |
| 打开详情时重复策略通知中断下载 | 确认上一轮 M-03 的另一个调用者遗漏。详情页只在快照变化或详情仍待复查时重新验证；相同快照且书籍仍允许不暂停下载。正在进行的详情观察仍每次通知撤销，真实策略撤销仍由协调器立即取消，未放宽人工复核语义。 |
| 旧下载完成结果覆盖新任务 | 确认异步窗口。详情页结果读取增加任务代次校验；新任务已接入时，旧查询不再回写目录/离线状态或弹旧提示。 |

新增回归包括三章中间失败后重建仓库只请求缺章、SQLite trigger 拒绝结果写入后零网络重试、暂停保留失败、320 像素屏幕中千章目录末章失败展示、详情页在真实挂起章节请求期间重复 refresh，以及方向顺序/失败重试。Windows 原生新增真实 `PlayerPage` 交互，注入方向适配器覆盖锁定失败、重试、锁定中返回和退出恢复；同时重跑既有原生播放/暂停/防误触回归。它验证页面与平台调用协作，不等于 Android 传感器验收。

本轮证据根为 `build/selfcheck-20261118/`，日志 `build/selfcheck-*.log`。原生首轮因新夹具漏导入 `PlaybackRequest` 编译失败，已修正并成功重跑；早期定向夹具及静态分析失败日志保留，不计为通过。

Android 设备验证仍有阻碍：`adb devices -l` 无设备；已有 AVD 启动报 `WHPX: Failed to setup partition, hr=80070005` / `failed to initialize WHPX`，详见证据根 `emulator-{out,error}.log`。未改主机虚拟化配置、未清设备数据；真实手机四向旋转、后台恢复及 TV 交互仍待设备验收。

| 检查 | 本轮最终结果 |
| --- | --- |
| 全量 Flutter | `flutter test --no-pub --reporter expanded`：**1587 通过、12 跳过、退出 0**；`build/selfcheck-full-tests.log`。 |
| 静态与边界 | `flutter analyze --no-pub` 无问题、515 文件模块边界通过；`build/selfcheck-analyze-complete.log`、`selfcheck-boundaries.log`。 |
| 源码规模 | 退出 1，104 条既有超限，按文件/函数身份比对无新增；`build/selfcheck-size-final.log` 及证据根 `size-comparison.json`，未放宽门禁。 |
| Windows 原生 | `./tool/run_windows_native.ps1 -TestFiles @('integration_test/player_page_lock_native_test.dart','integration_test/playback_touch_native_test.dart')` 两组 **2 项业务用例通过**；driver 退出 0，原有 integration_test 插件检测提示保留，不把 tearDownAll 计为业务用例。 |
| Android 编译 | 在 `android/` 执行 `./gradlew.bat ':app:compileDebugKotlin' '--offline' '-Ptarget-platform=android-arm64' '-Ptarget=lib/main.dart' '-PZERO_PLAYER_DEVICE_TEST=true' '--max-workers=4'` 成功；`build/selfcheck-android-kotlin-final.log`。首轮未引用参数被 PowerShell 拆成 `.dart` 任务导致失败，已修正；未将失败日志改写为通过。本轮未生成 Android APK。 |
| Windows Release | 普通 `flutter pub get` 后 `flutter build windows --release --no-pub` 成功；`build/selfcheck-pub-get.log`、`selfcheck-windows-release.log`。PDFium 固定库/归档及 mpv/ANGLE 归档摘要通过；应用位于 `build/windows/x64/runner/Release/`。 |
| 保护与收尾 | 7 份插件注册/依赖/本机文件恢复后与起点逐字节一致，1239 份最终构建输入摘要一致；14 个本轮 Dart 文件格式无变化、差异空白检查通过。汇总 `build/selfcheck-20261118/final-verification.json`；本地提交，不推送或发布，保留 `.workbuddy/`、`tmp/`。 |
