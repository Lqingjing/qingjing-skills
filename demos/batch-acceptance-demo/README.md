# 批次采集验收工具链 · 离线演示

这个候选包保留批次监督、按题号续接、源证据关联、有效验收保护和覆盖报告的核心流程。演示采集器生成自编条目和 XML，演示收尾器生成覆盖报告。所有运行数据都写到测试临时目录。

## 运行

在 Windows PowerShell 中进入本目录，执行：

```powershell
python -B .\test_demo.py
```

预期输出四行 PASS。测试覆盖非连续题号、内容待补与目视未知、重跑失败后的验收保护，以及满额但源证据缺失。测试退出后清理临时目录。可选环境变量 BATCH_DEMO_TMP 指定已有的可写临时目录。

## 文件与输出

- run_batch.ps1 是从原监督脚本整理出的离线入口。它从批次目录的子目录查找 bulk.py、finalize.py 和 batch-config.json，通过 BATCH_CONFIG 指定配置位置。
- batch-config.example.json 演示章名、应有题数及实际题号。测试会复制它作为临时配置。
- bulk.py、finalize.py、fixture_io.py 是自编演示组件。test_demo.py 负责生成临时工作区并检查结果。
- 输出中的 batch_attempt.json 表示最近一次结果，batch_result.json 表示最近一次有效验收。有效验收引用独立 coverage 快照。

运行环境和第三方边界见 [依赖说明](DEPENDENCIES.md)。既有验收的脱敏摘要见 [验收摘要](ACCEPTANCE.md)。
