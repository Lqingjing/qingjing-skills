# my-skills

可复用的 Agent Skills。当前发布候选仅包含 learning-gap-repair v0.1。

| 技能 | 已验收范围 | 用途 |
|---|---|---|
| [learning-gap-repair](skills/learning-gap-repair/) | Codex CLI app-server 原生显式调用；具体证据与限制见测试记录 | 根据学习表现补足必要缺口，按需检查，再返回原任务 |

[安装与使用](skills/learning-gap-repair/README.md) · [验收记录](skills/learning-gap-repair/tests/results.md) · [实际输入输出](skills/learning-gap-repair/tests/runs.jsonl)

它是一组可复用的教学交互约束，不保证优于普通 AI 或改善长期学习效果。当前 Windows 自动加载存在正文乱码问题，首版仅支持已验收的原生显式调用范围；其他宿主未验收。

旧候选 concept-theme-expansion 已调整为 learning-gap-repair。若曾安装旧版，请核对并停用旧安装，避免重复触发。

本发布副本不包含其他未验收技能、私人学习系统、原始课程资料或本地测试宿主。

## 许可

自有内容采用 [MIT License](LICENSE)。第三方来源链接所指内容保留其各自权利；本仓库不分发原始教材或题库。
