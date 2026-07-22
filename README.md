# perf-bench-loop

English | **[简体中文](README.zh-CN.md)**

A dual-ecosystem agent skill that runs [ASV (airspeed velocity)](https://asv.readthedocs.io/) benchmarks on a remote server to validate performance optimizations — designed to minimize the token waste that comes from letting a high-reasoning agent poll a multi-hour benchmark run.

Works in both **Codex** and **ZCode / Claude Code**, since they share the [agentskills.io](https://agentskills.io) skill format.

## The problem this skill solves

When you ask an agent to "optimize this function and validate with asv," the naive flow is:

1. Agent makes the change.
2. Agent launches `asv run` on the server (takes hours).
3. **Agent polls the log every minute to see if it's done.** ← this is the waste
4. Agent reads the result and decides what to do next.

Step 3 is the killer. Every poll is a high-reasoning forward pass that reads a half-finished log and produces no value. A 3-hour `asv run` polled every minute can burn more tokens in *waiting* than in actual development.

## How this skill fixes it

Strict three-way separation:

- **High-reasoning main agent** — only does what it's good at: writing the optimization, interpreting a finished comparison table, deciding the next change.
- **A shell** — does the waiting. One tool call blocks on the remote `done` file for hours; the main agent spends zero tokens during the wait.
- **A low-model subagent** — reads long raw logs *only* when something went wrong and the comparison table can't be produced. The main agent never reads raw ASV logs directly.

Result: token cost of waiting drops from "hours of high-reasoning polling" to "one shell call + optionally one cheap subagent call."

## Workflow (6 phases)

1. **Prepare** — confirm SSH host, ASV command, local test command. Deploy helper scripts to a fixed path outside the project source tree on first use.
2. **Implement + local fast gate** — make the optimization, run fast local tests (seconds) before touching ASV (hours).
3. **Launch remote ASV** — start `asv run` in the background on the server, write `pid`/`run.log`/`exit_code`/`done` to a stable run directory, return immediately.
4. **Wait** — one call to `wait-for-asv.sh` SSHes to the server and blocks on the `done` marker. One tool call, regardless of whether ASV takes 5 minutes or 5 hours. **The main agent does not poll.**
5. **Read the result** — on success, `compare-asv.py` produces a markdown before/after table (exit code 0/1/2 = pass / policy violation / incomplete). It uses `expected-cases.txt` (from `validate-asv-selection.py`) to ensure only fresh data appears — stale data from the shared results file is excluded. On failure, dispatch a low-model subagent to read the log and return a ≤200-word summary.
6. **Decide and (maybe) iterate** — on regression in iteration mode, analyze the table and loop back to Phase 2. Hard cap: 3 iterations.

## Installation

This skill follows the standard agentskills.io layout. The skill directory (`perf-bench-loop/`) goes into a skills discovery path:

| Client | Project-level | User-level |
|---|---|---|
| Codex | `<project>/.agents/skills/` | `~/.agents/skills/` |
| ZCode | `<project>/.agents/skills/` | `~/.agents/skills/` |
| Claude Code | `<project>/.claude/skills/` | `~/.claude/skills/` |

For cross-client use, install in both `.agents/skills/` and `.claude/skills/`, or use a symlink pointing to one canonical copy.

**The helper scripts** (`asv-background.sh`, `wait-for-asv.sh`) should be deployed to a **fixed path outside the project source tree** on the benchmark machine (e.g. `~/.local/share/perf-bench-loop/`), not committed into the project. This avoids polluting `git status`, especially for forks of upstream projects. See SKILL.md Phase 1 "First-run setup" for details.

### Codex additional setup

On first use in a Codex environment, also drop the toml from [`references/codex-setup.md`](references/codex-setup.md) into `~/.codex/agents/asv-monitor.toml` (user-global) or `<project>/.codex/agents/asv-monitor.toml` (project-local). This pins the log-reading subagent to a lightweight model + read-only sandbox so Codex doesn't default to a flagship model for log reading.

ZCode/Claude Code needs no such file — the main agent dispatches the subagent with `model: "haiku"` directly at call time.

## Files

```
perf-bench-loop/
├── SKILL.md                       Main entry point — the 6-phase workflow
├── scripts/
│   ├── asv-background.sh          Launch ASV in background, write status files
│   ├── wait-for-asv.sh            SSH + block on `done` marker (the token saver)
│   ├── compare-asv.py             Parse ASV results.json, emit markdown table
│   ├── validate-asv-selection.py  Pre-check -b selectors, write expected-cases.jsonl
│   └── expected_cases.py          Shared JSONL read/write for expected-cases
└── references/
    ├── monitor-prompt.md          Prompt template for the low-model log reader
    └── codex-setup.md             .codex/agents/asv-monitor.toml for Codex
```

## Usage examples

**Validation mode** (one-shot, no auto-iteration):

> I just optimized `_compress` in `src/foo.py`. Run asv on bench01 to check for regressions.

**Iteration mode** (auto-fix until passing, max 3 attempts):

> Optimize `BatchProcessor.merge` in `src/bar.py` until asv passes. Try at most 3 times.

The skill triggers on phrases like "asv", "airspeed velocity", "benchmark this change", "check for perf regression", "跑基准", "性能优化验证", "看看有没有回归".

## Requirements

- Local: `bash`, `python3`, `ssh`, `git`
- Remote (server where ASV runs): `asv` installed, the project checked out, `ssh` access from local machine
- Host agent: Codex, ZCode, or Claude Code (any agent that loads agentskills.io-format skills)

## License

MIT — see [LICENSE](LICENSE).
