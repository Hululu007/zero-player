# 模块职责与扩展约定

本文描述当前代码和可执行的依赖约束，供修改及后续开放源码时使用。进度、验证结论和后续任务统一记录在 [STATUS.md](STATUS.md)；早期方案见 [技术架构设计](../planning/03-architecture.md)。

## 模块归属

| 目录 | 当前职责 | 依赖约束 |
| --- | --- | --- |
| `lib/app` | 启动、依赖实例与生命周期组合、路由、主题、外壳及部分共享界面组件 | 可以组合业务与基础设施；业务逻辑逐步移出 |
| `lib/core` | 受控网络、数据库连接与事务、平台桥接、文本工具、诊断 | 不得引用 app、features 或 media |
| `lib/media` | 播放器实现、缓存、HLS、回环网关、导出、内容特征机制 | 可以依赖 core，以及 feature/domain 定义的能力接口 |
| `lib/features/*/domain` | 业务值、规则、状态与能力接口 | 可以共享其他领域模型及 core 的网络值/文本工具；不得依赖 app、media、业务 application/data/presentation、core 持久化/平台实现或 UI/数据库/播放器包 |
| `lib/features/*/application` | 用例、调度、会话与业务状态 | 可以调用 data、domain、受控基础设施；不得调用 presentation 或增加 app 依赖 |
| `lib/features/*/data` | 协议适配、解析、存储、文件与相关策略执行 | 不得调用 presentation 或增加 app 依赖 |
| `lib/features/*/presentation` | 页面、交互、Widget 与界面状态 | 当前允许读取 app 的组合服务和共享组件；应将新业务行为放入对应业务用例 |

这是单仓库 Flutter 应用，尚未将业务拆成独立 Dart packages。application 和 data 之间仍存在双向协作，跨业务也有共享的领域及实现依赖；边界检查通过不代表所有模块已经能够单独发布。

## 本轮明确的归属

- `media/cache/segment_index.dart` 是 `SegmentMetadata` 的 SQLite 适配器，归媒体缓存所有；数据库连接和通用事务仍由 `core/persistence/app_database.dart` 提供。缓存恢复、引用保护与离线下载复用这一适配器。
- `features/settings/domain/app_fonts.dart` 是字体选项和字体族映射的唯一声明，供主题、设置校验及备份校验共同引用，不反向依赖应用装配。
- `features/books/data/local_book_library.dart` 负责本地 TXT/EPUB/PDF 的解析、正文/章节策略检查、暂存文件、事务写入及删除。只接收 `BookStore`、文档目录、`ContentPolicy` 和作品授权谓词；不引用 `BooksRepository` 或 `AppServices`，不负责在线源、下载或播放器状态。
- `BooksRepository.importLocal/removeLocalBook/documentFile` 保持现有业务入口，内部委托本地书库。导入在解析前和入库前复核监管状态，保留正文过滤、内容身份、临时目录清理和文档移动失败时的数据库回滚。
- `features/books/data/book_source_import_plan.dart` 是单次来源导入的纯决策模块：接收已安装条目和黑名单快照，维护输入顺序内的去重/计数，决定插入、更新、重复、跳过或人工修订。旧来源键、成人证据继承、订阅/目录归属、版本比较、自定义容量等规则集中于此，不读写数据库或查询实时授权。
- `features/books/data/book_source_importer.dart` 在同一事务内读取快照、逐条执行决策、按 128 条写入、保留被拒绝更新的风险证据并保存目录版本/订阅记录。事务入口、逐条处理、风险等待后、批量写入前及提交前检查取消和授权；目录还校验启动时的成人过滤状态。已知受限规则的人工替换继续强制禁用，并保留原分组、收藏和归属。
- 来源导入只在事务成功返回后向仓库交付统计和待发布证据；`BooksRepository` 负责统一的配置变更租约、准备风险状态、提交后发布证据及刷新观察者。事务失败不能把风险写入或导入计数当成成功发布。网络订阅拉取与文档解析仍复用原受控入口，不属于导入计划的职责。
- `features/books/data/book_source_editor.dart` 负责来源保存/删除、默认恢复、批量启停和黑名单的数据库事务。它接收存储、风险存储、内容策略及来源/漫画准入谓词；批量操作通过查询回调在事务内读取当前可见条目，默认恢复也在事务内读取配置和黑名单。用例保留异步后的授权复核、旧成人标签证据及漫画启用检查，不持有仓库或发布内存通知。
- `BookSourceRiskStore.addEvidence` 统一精确主机记录选择、证据合并与单调版本递增；普通标签只限制来源，根页证据才扩展到精确主机，不能覆盖其他主机或损坏的次记录。调用自身原子执行，也可参加配置/导入/站点检测的外层事务，外层失败时一并回滚。该存储不作授权决策或发布内存状态；调用方在写入前后验证授权和来源版本，仓库仅在外层提交成功后记忆证据。人工复核仍保留版本墓碑，不属于普通配置编辑。
- `features/books/data/book_source_access.dart` 的 `BookSourceAccess` 独占已发布的来源条目、风险记录、黑名单及来源 ID/精确主机索引，负责来源/分组准入、风险复核列表和旧复核行重验。仅接收内容策略，不访问数据库、仓库或通知器；对外提供条目查询及判定方法，不交出可变 Map/Set。普通标签限制来源 ID，根页风险可限制同一精确主机的其他 ID/种类，不扩展到兄弟主机；复核墓碑和其他主机记录分别保留。
- `BookSourceAccess.beginReload/publish` 以代次保护完整快照发布；提交后的风险记忆、配置失效、黑名单和暂停都会使旧读取失效，暂停期间拒绝发布，恢复后须重新读取。`BooksRepository.refreshSourceRisks` 继续协调数据库读取、内容版本与作品证据，在同一同步步骤发布配套状态；旧代次被拒绝时须全部重读。作品成人证据复核也使该代次失效，防止旧来源重载顺带恢复已清除的作品证据。
- `features/books/data/book_policy_tracker.dart` 的 `BookPolicyTracker` 独占作品的已提交/待提交证据、观察登记与序号、复核锁、策略修订号及作品通知。元数据转换、证据阻断和有效写入失败后的限制保留在这一模块内完成；只接收内容策略、证据存储及每次观察的来源授权/完整准入回调，不持有仓库、网络客户端或来源快照。待提交证据按单次操作移除，旧快照沿用版本合并规则，不能恢复复核前成人标记。
- `BookPolicyObservation` 为单次观察提供带身份的登记、校验和幂等释放；重复释放不能结束同作品的其他观察。`BookPolicyReviewLease` 排斥同时观察/复核，允许已提交复核在关闭期间发布，结束时释放锁并使作品代次失效；不负责批准复核。仓库仍逐次检查监管授权、来源修订、策略修订、书架身份与证据摘要，并在提交后使来源重载代次失效。关闭时先停止作品模块的新登记，等待已注册复核后再销毁通知器；观察清理在关闭后不再发通知。
- `features/books/data/book_catalog_window.dart` 只负责 4000 项目录窗口的选择：保留续读、离线和待下载章节以及新目录尾章，返回省略数量；必要条目超限时显式失败。`BookStore` 在同一事务内读取受保护条目、选择窗口并保存目录与续读指针，不删除正文或下载。搜索选择/并发聚合和追更协调收拢至既有 discovery part，未新增 part 或放宽依赖边界。
- `media/engine/player_security.dart` 独立持有原生安全初始化状态，只注入属性写入/回读能力；并发调用共享一次校验，失败清空该次状态，后续重试完整检查全部选项。`MediaKitEngine` 在校验完成前不开放媒体。
- `BooksRepository` 继续负责配置变更租约、配置修订号、漫画授权、作品复核事务协作、关闭时等待及跨模块通知顺序；内置来源和下载内容版本仍归原有装配/下载校验协作。配置编辑结果提交后才交给来源准入模块记忆；黑名单提交后先发布限制，再重建完整快照，使离线播放及时暂停。下载校验通过条目查询读取来源，仍自行管理内容版本与租约。收藏和探测健康信息不作为来源配置变更，既有探测租约在写入前及提交前继续复核；探测详情读取及证据记忆由单独步骤负责。
- `features/playback/application/local_video.dart` 通过四个显式能力处理本地播放准备：内容校验、历史查询、文件会话和路径记录。`app/app_services.dart` 组合实际依赖；用例不查询全局服务，也不创建数据库/网络客户端。打开或保存期间授权失效、路径保存失败时关闭已创建的会话，成功后将会话所有权交给请求接收方。
- `features/playback/application/line_probe.dart` 的 `EpisodeProbe` 仅接收来源查询、受控文档/媒体客户端和内容策略。来源等待和解析后复核策略，媒体采样沿用请求头作用域、共享调度和流量上限；每次探测持有独立取消令牌与临时策略监听，结束时解除监听，不关闭调用方的共享客户端。内容策略撤销会中止正在进行的解析/采样，不取消调用方自己的令牌。
- `features/playback/application/playback_request.dart` 独立声明播放请求与媒体种类，使本地播放准备无需导入播放控制器；控制器继续导出该请求作为原有入口的一部分。进程启动待打开路径由 `app/local_open_startup.dart` 保存，由应用启动转发与导航消费，不属于本地视频用例。

## 自动边界检查

在项目根目录运行：

```powershell
dart run tool/check_module_boundaries.dart
flutter test --no-pub test/architecture/module_boundaries_test.dart
```

检查使用 Dart AST 读取所有 `lib/**/*.dart` 的 import、export、条件分支与 URI 形式的 part/part of；同时检查目标存在性，拒绝越出 lib 的相对依赖、跨业务或跨业务层的 part。相对地址与 `package:zero_player/` 均受相同约束。项目本身的约束验证也会随 `flutter test` 执行。

检查当前保留以下 **2 条精确存量依赖**，定义于 `tool/architecture/module_boundaries.dart`；line_probe 与 local_video 的例外已随依赖注入移除：

| 引用方（lib 下） | 存量目标 | 后续收窄方向 |
| --- | --- | --- |
| `features/playback/application/playback_controller.dart` | `app/app_services.dart` | 按解析、播放会话、进度/诊断用途分组注入，先覆盖生命周期及换源回归 |
| 同上 | `app/app_version.dart` | 将诊断元数据作为显式输入 |

例外按“引用文件 → 目标文件”精确匹配，不开放整个目录；移除旧引用后仍留下例外会报错。新引用不能通过复制现有写法绕过检查。变更例外需要解释实际边界和收敛计划，不作为新增功能的默认路径。

此检查针对静态文件依赖，尚不验证所有传递依赖、运行时服务访问、平台原生代码或业务授权正确性。例如 `sources/domain/source_probe_result.dart` 仍引用 core 的 `document_client.dart` 获取失败分类，UI 仍通过 app 组合服务获取依赖；后续应按具体修改将值对象与实现、依赖读取与业务用例逐步分开。

## 修改与扩展流程

1. 先确定所属业务和层。新增渠道通常修改该业务 data 适配与 domain 配置；新增用例放 application；页面只处理交互和结果呈现。
2. 依赖通过构造参数或现有窄接口传入，装配在 app 完成。若只需要一个能力，传入该能力或回调；不新增万能服务定位器或机械生成一套接口/实现。
3. 独立职责应拆为普通 Dart library/class，显式声明依赖。part 仅供同业务同层内确需共享私有状态的实现使用；把长文件换成多个 part 不算完成模块解耦。
4. 网络入口复用受控客户端、取消和请求预算。读取/下载/写入边界继续复核来源、监管和内容策略；不为便于测试或扩展绕过网关、私网限制、漫画准入和本机验证。
5. 运行与修改匹配的定向回归，再运行静态分析、模块边界、规模检查及必要的全量回归。原生平台测试/构建串行执行；设备、实网与真实媒体未验收时记录范围。

规模检查仍采用原有阈值，当前遗留超限继续单独报告；本次未提高阈值或将其结果改为成功。下一步整理优先级见 STATUS.md 的最新工程质量章节。
