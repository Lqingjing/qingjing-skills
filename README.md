# my-skills

可复用的 Agent Skills。

| 技能 | 已验收范围 | 用途 |
|---|---|---|
| [learning-gap-repair](skills/learning-gap-repair/) | Codex CLI app-server 原生显式调用；具体证据与限制见测试记录 | 根据学习表现补足必要缺口，按需检查，再返回原任务 |
| [codex-provider-switch-guard](skills/codex-provider-switch-guard/) | Experimental；隔离合成测试与真实 CLI 离线解析 | OpenAI / DeepSeek 安全切换机制，包含预检、备份、原子写入与选择性恢复 |

[安装与使用](skills/learning-gap-repair/README.md) · [验收记录](skills/learning-gap-repair/tests/results.md) · [实际输入输出](skills/learning-gap-repair/tests/runs.jsonl)

它是一组可复用的教学交互约束，不保证优于普通 AI 或改善长期学习效果。当前 Windows 自动加载存在正文乱码问题，首版仅支持已验收的原生显式调用范围；其他宿主未验收。

旧候选 concept-theme-expansion 已调整为 learning-gap-repair。若曾安装旧版，请核对并停用旧安装，避免重复触发。

[codex-provider-switch-guard 的使用与验证说明](skills/codex-provider-switch-guard/README.md)。本版开放只读状态、备份检查和隔离合成测试。真实 Desktop 双向往返、认证和模型请求尚未验收，生产写入保持禁用。

本仓库不包含私人学习系统、原始课程资料或本地测试宿主。

## 许可

自有内容采用 [MIT License](LICENSE)。第三方来源链接所指内容保留其各自权利；本仓库不分发原始教材或题库。
