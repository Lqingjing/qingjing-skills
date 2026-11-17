# learning-gap-repair

学习时答错了、理由说不通，或者只是想不起一个词：让 Agent 先判断当前证据，再补够继续任务所需的内容。它不会把每个小问题都变成一堂课。

例如，选择了正确病因，却用“下游后果与该病无关”解释选项时，它会修复根因与后果的关系，而不是只判“答对”。需要时给一次小尝试；刚讲过的答案复述正确，不当作独立应用或长期掌握。最后回到你实际提供的学习任务。

这是可复用的教学交互约束，不是新的知识引擎，也不保证优于普通 AI 或提高成绩。无需数据库、脚本、额外依赖或作者的私人系统。

## 安装与调用（Codex）

在本仓库根目录用 PowerShell 执行以下命令，把技能安装到你要使用的项目中。将占位路径换成真实项目路径；若目标已经存在，先备份并核对，不覆盖旧版本。

~~~powershell
$projectPath = 'C:\path\to\your-project'
$skillPath = Join-Path $projectPath '.agents/skills/learning-gap-repair'
if (Test-Path -LiteralPath $skillPath) { throw '目标技能已存在，请先备份核对' }
New-Item -ItemType Directory -Path (Split-Path $skillPath) -Force | Out-Null
Copy-Item -LiteralPath './skills/learning-gap-repair' -Destination $skillPath -Recurse
~~~

在该项目中启动新的 Codex 会话，确认技能列表能发现 learning-gap-repair，然后输入：

~~~text
$learning-gap-repair 我在做这道题……我选……理由是……
请检查卡点，只补够当前任务所需的知识，然后回到……
~~~

可提供题目/段落、自己的回答及理由、可信材料和继续目标；没有这些信息也可提问，但 Agent 不应替你编造。可以明确说“只解释，不验证”或“现在停止”。本次 Windows 自动选择能选中技能，但通过 PowerShell 读取正文出现乱码，未通过完整加载验收。首版请使用技能列表中的原生显式选择（或宿主识别的 $ 调用），不要依赖自动调用；无需修改全局编码配置。

Codex 的发现路径和调用方式参见 [官方 Skills 文档](https://learn.chatgpt.com/docs/build-skills)。本次只验证 Codex CLI；其他宿主兼容性 UNKNOWN。卸载仅移除此项目中安装的技能目录，重新开启会话。

## 三类案例与边界

- [医学机制：根因与后果](examples/example_medicine.md)：来自真实学习状态记录的脱敏改编，不是原始题目或逐字对话。
- [最小干预：20 天与两周](examples/example_minimal.md)：真实记录改编，只测试换算和轻量返回。
- [计算机：锁与循环等待](examples/example_cs.md)：完全构造的跨学科案例。

医学内容仅用于学习，不提供真实患者诊疗决策。不要求读取私人学习库、不写学习数据库、不自动安排复习，也不能恢复未提供的外部文件或旧聊天。这些是执行约束，不构成技术隔离保证；实际文件与工具权限由宿主控制。来源不足、未作答或未验证的能力须保留不确定性。

## 验收

[固定输入与判据](tests/cases.md) · [实际运行与局限](tests/results.md) · [脱敏原始输入输出](tests/runs.jsonl)

SKILL.md 负责执行，示例负责说明，测试文件提供可检查证据，现有结果不应当作学习效果实验；真实学习者的迁移与长期保持效果仍为 UNKNOWN。模型输出有随机性；复现指按相同输入和步骤重跑并用同一判据检查，不保证逐字一致。
