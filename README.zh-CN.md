# perf-bench-loop

**[English](README.md)** | 简体中文

一个双生态（Codex + ZCode/Claude Code）通用的 agent skill，用于在远端服务器跑 [ASV (airspeed velocity)](https://asv.readthedocs.io/) benchmark 来验证性能优化——核心目的是消除"让高推理 agent 轮询数小时 benchmark 运行"造成的 token 浪费。

由于 Codex、ZCode、Claude Code 都遵循 [agentskills.io](https://agentskills.io) 开放标准，本 skill 在三个环境里都能直接加载。

## 这个 skill 要解决的问题

当你让 agent "优化这个函数并用 asv 验证" 时，默认流程是：

1. Agent 改代码。
2. Agent 在服务器上启动 `asv run`（要跑几小时）。
3. **Agent 每分钟轮询一次日志看跑完没。** ← 浪费就在这里
4. Agent 读结果，决定下一步。

第 3 步是致命的。每次轮询都是一次高推理 forward pass，读的还是半成品日志，产不出任何价值。一次 3 小时的 `asv run` 如果每分钟轮询一次，光"等待"这一环节烧掉的 token 可能比实际开发还多。

## 这个 skill 怎么解决

严格的三层分工：

- **高推理主代理**——只做它擅长的事：写优化代码、读最终的对比表、决定下一步改动。
- **shell**——负责等待。一次工具调用在远端阻塞等 `done` 文件，几小时都行；等待期间主代理零 token 消耗。
- **低模型子代理**——**只在出问题时**读长日志（对比表生成不出来的时候）。主代理永远不直接读原始 ASV 日志。

效果：等待环节的 token 成本从"数小时的高推理轮询"降到"一次 shell 调用 + 可选一次廉价子代理调用"。

## 工作流（6 个 Phase）

1. **准备**——确认 SSH host、asv 命令、本地测试命令。首次使用时把辅助脚本复制到项目里。
2. **实现 + 本地快测**——做优化，先跑本地快速测试（秒级），再上 ASV（小时级）。
3. **启动远端 ASV**——在服务器后台启动 `asv run`，把 `pid`/`run.log`/`exit_code`/`done` 写到稳定的运行目录，立即返回。
4. **等待**——一次调用 `wait-for-asv.sh`，SSH 到远端阻塞等 `done` 标记。**一次工具调用**，无论 ASV 跑 5 分钟还是 5 小时。**主代理不轮询。**
5. **读结果**——成功路径下，`compare-asv.py` 生成 markdown before/after 对比表（exit code 0/1/2 = 通过 / 策略违规 / 数据不完整）。它使用 `expected-cases.txt`（由 `validate-asv-selection.py` 生成）确保只显示本轮数据——共享结果文件里的旧数据被排除。失败路径下，派低模型子代理读日志，返回 ≤200 字摘要。
6. **决策与（可能的）迭代**——迭代模式下遇到回归，分析对比表回到 Phase 2。硬上限：3 次迭代。

## 安装

本 skill 遵循标准 agentskills.io 布局。skill 目录（`perf-bench-loop/`）放到 skills 发现路径：

| 客户端 | 项目级 | 用户级 |
|---|---|---|
| Codex | `<project>/.agents/skills/` | `~/.agents/skills/` |
| ZCode | `<project>/.agents/skills/` | `~/.agents/skills/` |
| Claude Code | `<project>/.claude/skills/` | `~/.claude/skills/` |

跨客户端使用时，在 `.agents/skills/` 和 `.claude/skills/` 都安装，或用软链接指向同一份。

### Codex 额外配置

在 Codex 项目里首次使用时，还需要把 [`references/codex-setup.md`](references/codex-setup.md) 里的 toml 内容放到 `.codex/agents/asv-monitor.toml`。这个 toml 把读日志的子代理固定到轻量模型 + 只读沙箱，避免 Codex 默认用旗舰模型去读日志。

ZCode/Claude Code 不需要这个文件——主代理在调用时直接用 `model: "haiku"` 指定低模型即可。

## 文件结构

```
perf-bench-loop/
├── SKILL.md                       主入口——6 阶段工作流
├── scripts/
│   ├── asv-background.sh          后台启动 ASV，写状态文件
│   ├── wait-for-asv.sh            SSH + 阻塞等 `done` 标记（省 token 核心）
│   ├── compare-asv.py             解析 ASV results.json，生成 markdown 对比表
│   └── validate-asv-selection.py  预检 -b selector，写 expected-cases.txt
└── references/
    ├── monitor-prompt.md          低模型日志读取子代理的 prompt 模板
    └── codex-setup.md             Codex 用的 .codex/agents/asv-monitor.toml
```

## 用法示例

**验证模式**（单次，不自动迭代）：

> 我刚优化了 `src/foo.py` 里的 `_compress` 函数。在 bench01 上跑 asv 看看有没有回归。

**迭代模式**（自动改到通过，最多 3 次）：

> 优化 `src/bar.py` 里的 `BatchProcessor.merge` 直到 asv 通过，最多试 3 次。

skill 的触发关键词包括："asv"、"airspeed velocity"、"benchmark this change"、"check for perf regression"、"跑基准"、"性能优化验证"、"看看有没有回归"。

## 依赖

- 本地：`bash`、`python3`、`ssh`、`git`
- 远端（跑 ASV 的服务器）：已装 `asv`、项目已 checkout、本地能 ssh 上去
- Host agent：Codex、ZCode 或 Claude Code（任何能加载 agentskills.io 格式 skill 的 agent）

## 许可证

MIT——见 [LICENSE](LICENSE)。
