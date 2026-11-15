# 听书渠道核对（2026-11-14）

本项目的渠道需在 Windows 与 Android/TV 上以相同规则工作。内置前需用本项目的客户端逐项验证发现或搜索、详情、完整目录、音频地址、容器校验和离线解码；去重以站点和实际媒体链路为准，不能把不同 JAR 的同一站点算作多个渠道。上游 README 所称“可用”仅是上游测试结果。

| 仓库 | 发布形式与候选 | 当前结论 |
| --- | --- | --- |
| [liaozhu913/tingshu-ting29-source](https://github.com/liaozhu913/tingshu-ting29-source) | `external_sources.json` 指向 JAR；29听书、恋听、乐听、麒麟、275、有听、听13、爱听书 | 上游报告搜索与播放测试；本机 29 移动站返回 429。恋听桌面站返回 403，移动站可查书与目录，但动态 `/glink` 音频未通过本项目校验。275 可读取目录，但样本播放页依赖会话，给出的音频为 HTTP 且 HTTPS 证书失败。恋听与 freefly22 重复；听13、爱听书依赖 WebView 嗅探。均未达到本项目内置条件。 |
| [kang532155241/tingshu-jars](https://github.com/kang532155241/tingshu-jars) | eprendre、shun、bxb100 三组 JAR 及订阅描述 | 与下方备份及 wsl201 的包名重复，缺少可直接导入的静态规则及逐站验证结果。 |
| [freefly22/tingshu-free-jar](https://github.com/freefly22/tingshu-free-jar) | 多版本 JAR 和部分 Java 源码；懒人、恋听、喜马拉雅等 | 恋听按站点去重；博看有声与喜马拉雅公开免费音轨已独立移植并原生验证。懒人搜索要求登录；喜马拉雅部分搜索结果已下架，目录会明确报错。 |
| [m1ngzer/tingshu-sources](https://github.com/m1ngzer/tingshu-sources) | Kotlin 源码、JAR、书音FM／听友候选 | 书音FM已按公开接口独立适配，并通过本项目 Windows 原生搜索、目录、下载、离线解码；听友音频链路未验证。 |
| [zihao-wangx/tingshu-backup](https://github.com/zihao-wangx/tingshu-backup) | APK 与 9 个 JAR 备份 | 属于插件备份，eprendre、shun、bxb100 与其他仓库重叠；上游也不保证长期可用。不直接作为内置渠道。 |
| [wsl201/ts](https://github.com/wsl201/ts) | eprendre、shun、sound 的 JAR／订阅 | 前两组与上述备份重叠；订阅 JSON 不是书目或可执行的声明式规则。 |

`external_sources.json` 只有 `entry_package`、`download_url` 等插件元数据，不能用 Legado JSON 解析。应用明确禁止 JAR 执行，导入订阅描述或含 `classes.dex` 的 JAR 时会提示格式不兼容。若上游提供标准 RSS/Atom 或静态 HTML/Legado 规则，可走现有渠道导入、检测、手动启用流程。

直连下载六个仓库的 `main` 快照，22 个 JAR 文件按 SHA-256 去重后为 17 个不同二进制：`sources_by_eprendre.jar` 在 kang、zihao、wsl 三处完全相同（`4977474ac62040bda4bc36d5101e6d20bd56e5511434b8ea520a0eae5f752c0b`）；`sources_by_shun.jar` 在同三处完全相同（`85e3558865b665684897a58867d0b6deb910607823b210f96b1d9c1c09a9a8cb`）；`my_sound_01.jar` 在 zihao 与 wsl 完全相同（`f38693a8971601aa506b1ae9498ad7c41bc5c0801a0a9249e5e3d5ba7678fafc`）。kang 与 zihao 的 bxb100 同名 JAR 哈希不同，不能按文件名误判为字节重复。文件未打包入本项目。

## JAR 静态拆解与导入结果

2026-11-14 将 17 个不同 JAR 仅作为 ZIP/DEX 数据读取，用 Androguard 分析类、方法和字符串；未加载或执行任何插件。`sources_by_ting29.jar` 有 30 个 DEX 类，包含 Ting29、LianTingWang、I275、LeTing、Qilin、Ting15 及 WebView 嗅探类；`free_all_v12.jar` 有 43 个类，包含 BoKanYouSheng、ShuYinFM、KuWo、LanRen、XiMaLaYa、YunTu 和 TingYou 等；`sources_by_eprendre.jar` 有 68 个类，含多个名称前缀为 `Delete` 的已废弃入口；`sources_by_shun.jar` 有 33 个类。部分备份 JAR 实际是音乐、视频、网盘或 ASMR 插件，不能算作听书站点数。

- **已移植并原生验证**：书音FM（m1ngzer 公开源码协议）、博看有声和喜马拉雅免费音轨（freefly22 JAR 中 BoKanYouSheng、XiMaLaYa 的公开接口协议）。只纳入本项目自己实现的 HTTPS 请求与解析规则。博看有声使用 `es.bookan.com.cn` 搜索、`api.bookan.com.cn` 分类及目录，音频只接受 `audio.bookan.com.cn`；上游给出 HTTP 文件地址时仅尝试同域 HTTPS，样本返回 206 和标准 M4A。喜马拉雅使用独立的搜索、分类、目录和播放接口，书目与音轨均过滤付费标记，音频只接受 `aod.cos.tx.xmcdn.com`，HTTP 地址仅升级同域 HTTPS；样本返回 206 和 MP3。三个中文渠道的分类、发现、搜索、详情、目录、下载和离线解码均通过 Windows 原生专项（`.dart_tool/native-e89f5cf9/audio_channels_native_test.log`）。
- **已解析、未收录**：恋听网可按 DEX 中 `_c`、`_b`、`_p`、`_cp` 元数据向 `/glink` 提交请求并取得地址，但样本 CDN `pp.ting55.com` 的 HTTPS 证书主机名不匹配；275 听书样本媒体只提供 HTTP，HTTPS 证书失败；29 移动站返回 429。酷我 FM 的 JAR 规则依赖 HTTP 搜索及音频转换接口；云图有声也依赖 HTTP 接口。听友 FM 规则含加密负载及设备标识，尚无本项目可验证的自由音频链路。上述渠道不通过放宽 TLS、执行 JAR 或绕过认证方式收录。

目前内置为 [verified.json](../../assets/catalogs/books/verified.json) 中的书音FM、博看有声、喜马拉雅免费有声、Gutenberg 公版朗读及两路机核播客。书音FM通过 `POST` 获取书目、分类与目录；其 `GET` 搜索在实测中出现跨关键词缓存，因此不使用。2026-11-14 用“西游记”样本取得 182 章目录、完整 19,593,734 字节 MP3；“三国演义”样本验证博看有声 M4A 和喜马拉雅免费 MP3。三个中文渠道均通过本项目 Windows 原生分类、发现、搜索、详情、目录、下载、校验及离线解码（`.dart_tool/native-e89f5cf9/audio_channels_native_test.log`）。喜马拉雅搜索仍可能列出已下架专辑，例如本次 `30515044` 的目录返回 `ret=924`，不能由搜索成功推断每个专辑可播。懒人接口实测返回 `apiStatus=485`，要求登录；LibriVox 的书目和目录可读取，但 Archive.org 章节媒体域本机连接超时，均未收录。其他作品、Android/TV 和长期稳定性尚未验收。Gutenberg 近期有大文件传输中断记录，不能据旧记录宣称当前全链路稳定。

## 全部 JAR 逐包清单

2026-11-14 再次下载六仓库 `main` 快照，核对其中全部 22 个 JAR 的完整 SHA-256；以下 17 行是字节去重后的完整集合。每包均读取 ZIP 中的 `classes.dex`，列举顶层类和硬编码接口域名，未加载或运行插件。表中哈希为 SHA-256 前 16 位，完整哈希可由本地审计目录 `.dart_tool/tingshu_audit/` 复算。**导入**指将验证通过的渠道协议重新实现到应用，并非安装 JAR 字节码。

| 哈希前缀 | 仓库文件及重复关系 | DEX 顶层入口与处理结果 |
| --- | --- | --- |
| `8d22b651938a4527` | liaozhu913 `sources_by_ting29.jar` | 29、恋听、275、乐听、麒麟、听15、听13、爱听书；29 返回 429，恋听与 shun/free 重复且媒体证书错误，275 HTTPS 证书错误，听13／爱听书需 WebView 嗅探；未导入。 |
| `7c32596beaf556a8` | kang `sources_by_bxb100.jar` | Quark 网盘入口；非听书站点，未导入。 |
| `4977474ac62040bd` | kang、zihao、wsl `sources_by_eprendre.jar` 完全相同 | 68 类，含博看、喜马拉雅、懒人、酷我及大量 `Delete*` 废弃入口；博看和喜马拉雅按站点去重后已独立导入，其他入口见下文候选边界。 |
| `85e3558865b66568` | kang、zihao、wsl `sources_by_shun.jar` 完全相同 | 33 类，含恋听、悦听、听中国、麒麟、全民、有听等；恋听等与其他包重复，仍需 HTTPS 媒体链路验证，未按包导入。 |
| `738cec6a2443af16` | freefly22 `free_all_v7.jar` | 24 类，懒人、喜马拉雅、恋听、念听、有听等；为后续版本的同站点旧实现，按渠道去重。 |
| `09e540d82198ae6c` | freefly22 `free_all_v8.jar` | 28 类，增加博看、酷我、云图等；博看已从更新版本协议独立导入，其他按站点合并。 |
| `e4f928a3099e8078` | freefly22 `free_all_v10.jar` | 36 类，增加书音FM、悦听吧等；书音已按 m1ngzer 源码独立导入；悦听吧原接口为 HTTP，HTTPS 请求回退 HTTP。 |
| `645ef23e96bdc0a2` | freefly22 `free_all_v11.jar` | 39 类，博看、书音、酷我 FM、悦听吧等；前两者已去重导入。 |
| `acd19484fd3d2821` | freefly22 `free_all_v12.jar` | 43 类，博看、书音、喜马拉雅、听友、酷我 FM、悦听吧等；前三者已独立导入，听友使用加密负载及设备标识，未完成免费音频验证。 |
| `ff488c1d8df08b00` | m1ngzer `sources_by_m1ngzer.jar` | 书音FM、听友 FM；书音已独立导入，听友与 free v12 同站点合并。 |
| `d8e24be8db2f58f6` | zihao `english.jar` | LibriVox、Lit2Go、AudiobookLabs、Audiobooks；LibriVox 媒体域连接超时，AudiobookLabs 搜索返回 526。Lit2Go 书目／章节及 MP3 Range 在独立请求中可用，但应用 Windows 原生书目请求连续两次超时，故撤回试接入，未内置。 |
| `adf70c080f854c5d` | zihao `my_music.jar` | 网易云、51Music、VBus 等音乐入口；非听书包，未导入。 |
| `f38693a8971601aa` | zihao、wsl `my_sound_01.jar` 完全相同 | Itingshu、Laobai、Mting、Qmtsw、Ts230、Ysts、Yuetingba；多为旧网站或 WebView 嗅探协议，未达到本项目完整 HTTPS 音频验收。 |
| `1d9b65bdef129ac3` | zihao `my_video.jar` | AcFun、樱花、短剧等视频入口；非听书包，未导入。 |
| `3410cc23946b3b8a` | zihao `sources_by_bxb100.jar` | Quark 网盘入口，与 kang 同名但哈希不同；均非听书站点。 |
| `926598d1005bd252` | zihao `sources_by_kyloasmr.jar` | ASMR、猫耳、AudioMack 等；非有声书目录包，未导入。 |
| `9555bc6906a8ff6e` | zihao `videosource.jar` | 南瓜、九州、樱花等视频入口；非听书包，未导入。 |

仅凭 DEX 类存在、首页返回 200 或上游声称可播，不能保证本应用能获取完整目录并下载解码。未通过验收的插件保留审计结论，不能通过运行未知 JAR、放宽证书校验、调用 HTTP 媒体或绕过登录来充作已导入渠道。
