# 2026-11-19 代码审查证据

对应 [代码审查报告](../CODE-AUDIT-2026-11-19.md)，基线 `d30f4a8c839e53d5e03b669bd05cc5907e75d940`。

这里的 `.dart.txt` 是可重放的审查探针快照，使用文本扩展名，避免把已知失败用例混入项目默认测试或改变产品构建。所有期望均为正确行为；基线执行得到 **12 项失败、0 项通过、退出 1**，用于证明缺陷存在。它们不是修复完成的证明。

## 内容与验证范围

- [audit_regressions_test.dart.txt](audit_regressions_test.dart.txt)：AUD-01 至 AUD-09。实际调用 HLS 解析、HTTP/缓存、书籍仓库、书架 widget、音乐/听书/电台控制器和 MP4 传输。播放引擎采用既有 FakePlayerEngine。AUD-08 透传媒体校验，仅验证字节身份/拼接；AUD-09 使用合成容量填充，不把填充行当作合法私密密文读取。
- [export_audit_test.dart.txt](export_audit_test.dart.txt)：AUD-10、AUD-11、AUD-12。生产 Dart exporter 和 DownloadsPage 实际运行；方法通道模拟原生编码/探测成功，文件选择器控制返回时机。AUD-12 使用 IOOverrides 固定竞争窗口，之后执行真实 Windows rename。不能替代 FFmpeg 媒体兼容性及 Android 系统保存验收。
- [confirmed-reproductions-final.log.txt](confirmed-reproductions-final.log.txt)：最终串行运行的完整输出。12 个失败均到达对应的业务契约断言/预期拒绝位置；夹具构造与清理没有额外失败。日志中的 HttpClient 通用提示来自导出 widget 的 binding，导出测试不发送 HTTP；真正的 Range 复现文件显式取消 Flutter 的假 HTTP 覆盖并访问本机受控服务。

## 重放

在项目根目录使用既有 Flutter 环境运行以下 PowerShell 命令。所有文件只写入 build 证据目录或独立系统临时目录；不使用业务数据库，不访问公网媒体。

```powershell
New-Item -ItemType Directory -Path build/code-audit-20261119 -Force | Out-Null
Copy-Item docs/implementation/audit-2026-11-19/audit_regressions_test.dart.txt build/code-audit-20261119/audit_regressions_test.dart
Copy-Item docs/implementation/audit-2026-11-19/export_audit_test.dart.txt build/code-audit-20261119/export_audit_test.dart
flutter test --no-pub --concurrency=1 --reporter expanded build/code-audit-20261119/audit_regressions_test.dart build/code-audit-20261119/export_audit_test.dart
```

源码中的 `../../test_support/` 导入以复制后的 build 目录层级为准。仅核查某项时可附加 `--plain-name 'AUD-XX'`。修复后应按实际正确语义更新并迁入项目正式回归测试，再验证通过；不要为了让基线探针变绿而把期望改成缺陷行为。

原有全量测试日志仍在 `build/code-audit-20261119/full-tests.log`：**1630 项通过、12 项跳过、退出 0**。静态分析 `flutter analyze --no-pub` 本轮退出 0，输出 `No issues found!`。build 中其他早期日志包含夹具调试记录，不作为确认依据。
