# 网络漫画内置源首轮安全盘点（2026-11-15）

范围：`assets/catalogs/books/legado/catalog.json.bz2` 的 `bookSourceType=2` 记录。静态读取随包 JSON，并对 87 个可解析 HTTPS 主机的根路径执行 HEAD 抽查，禁止跳转且不读取正文；未在浏览器打开这些站点、执行来源脚本或下载其媒体。本报告不能证明任何当前域名安全、可读或确有木马。

| 类别 | 发现 | 处理边界 |
| --- | --- | --- |
| 明确成人标记 | 153 条漫画记录中 10 条带有明确的 `🔞`、十八禁、肉漫、性感美女或嘿咻标签，或使用对应来源主机。包括 18mh.cc、ikanhm.top、lcmhx.asia、roum26.xyz、jpxgyw.cc、nvyoumh01.top；另有 `api.acg.gd` 的一条来源名称带 `🔞`。 | `adultComicSource` 在成人过滤开启时屏蔽这些漫画源；监管模式现有 `kindAllowed` 已整体屏蔽漫画。 |
| 需要人工内容审查 | 韩漫、写真、BL、聚合等名称本身不足以判定全站成人内容，不能据此断言安全。 | 保持目录项默认停用；逐源核查分类、目录和实际样本后再决定是否纳入成人源证据。 |
| 解析与请求风险 | 153 条中 118 条正文规则含脚本标记，28 条原始源地址为 HTTP，2 条源地址不是 HTTP(S)。 | 本应用的来源导入限制公网 HTTPS，旧 HTTP 地址按既有规则升级 HTTPS；脚本规则需逐条真实验证，不能因源包标签“校验可用”视为本应用可用。 |
| 异常跳转 | 2026-11-15 09:54（北京时间）的无跳转 HEAD 抽查显示：`www.jpxgyw.cc` → `http://surveymrs.com`（302）、`www.yeseimg.com` → `http://survey-twist.com`（302）、`www.kukk.net` → `https://esp-framework.com/`（301）、`www.bdido.com` → `https://www.hugedomains.com/domain_profile.cfm?d=bdido.com`（302）。 | 这四个旧来源主机按 `quarantinedComicSource` 隔离，不把跳转目标当作漫画内容或自动跟随。该证据说明来源失配/不可信，不能据此单独断言存在木马或博彩。 |
| 恶意站点嫌疑 | 随包元数据没有博彩、木马、挂马等明确标签；域名可能已易主。 | 不对可疑网站运行 JavaScript 或加载第三方资源；发现博彩/仿冒或可执行下载时，再记录具体 URL、响应码和时间，供强制封禁清单复核。 |

原始记录中 87 个主机可用于 HTTPS 根路径抽查，另外两条来源地址不是 HTTP(S)。HEAD 原始结果保存在本机忽略目录 `build/comic-head-audit.json`。`BookStore` 对从目录导入的来源默认停用；启用来源时由 `BooksRepository.sourceAllowed` 再检查内容策略。网络目标校验限制公网 HTTPS 与源主机/声明媒体主机。上述机制降低了自动访问风险，但不构成网站信誉鉴定。

下一轮应在隔离环境中对候选站点做无脚本、禁止跳转的文本响应检查，逐源记录搜索、目录、章节及图片的结果。对已确认的恶意主机，附响应或可信威胁情报证据后加入独立的强制拒绝清单；不能把网络错误、过期规则或内容成人性质直接等同于恶意站点。
