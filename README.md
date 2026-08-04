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

## Config-driven project setup

This skill is project-agnostic. All project-specific values live in a config file at `<project-root>/.perf-bench-loop/config.sh`:

- SSH host, container name, repo/ASV/log paths
- Conda environment, compiler toolchain, env exports
- Benchmark suites (named selector groups)
- Protected paths (files that must never be published)
- Branch, remote, ASV comparison factor/threshold/policy

Copy `config.example.sh` to `.perf-bench-loop/config.sh` in your project root and fill in the values. The config is **not committed** to the project repo.

## Workflow (6 phases)

1. **Prepare** — verify `.perf-bench-loop/config.sh` exists, deploy helper scripts to the benchmark machine on first use.
2. **Implement + local fast gate** — make the optimization, run fast local tests (seconds) before touching ASV (hours). Publish project code via `publish_candidate.sh`.
3. **Launch remote ASV** — call `run_remote_asv.sh` (standard mode blocks; `--probe` mode returns immediately for progress polling).
4. **Wait / Probe** — standard mode: blocked inside `run_remote_asv.sh`. Probe mode: call `probe-asv.sh` periodically (ZCode: direct Bash; Codex: Terra/Luna subagent).
5. **Read the result** — `compare-asv.py` produces a markdown before/after table (exit 0/1/2 = pass / policy violation / incomplete). On failure, dispatch a low-model subagent to read the log.
6. **Decide and (maybe) iterate** — on regression in iteration mode, analyze the table and loop back to Phase 2. Hard cap: 3 iterations.

## Files

```
perf-bench-loop/
├── SKILL.md                       Main entry point — the 6-phase workflow
├── config.example.sh              Template for .perf-bench-loop/config.sh
├── scripts/
│   ├── run_remote_asv.sh          Unified orchestration: preflight→launch→wait→compare
│   ├── publish_candidate.sh       Config-driven publication gate: commit, push, mirror sync
│   ├── preflight.sh               Config-driven remote environment validation
│   ├── probe-asv.sh               Single-snapshot progress check (≤20 lines)
│   ├── asv-background.sh          Launch ASV in background, write status files
│   ├── wait-for-asv.sh            SSH + block on `done` marker (the token saver)
│   ├── compare-asv.py             Parse ASV results.json, emit markdown table
│   ├── validate-asv-selection.py  Pre-check -b selectors, write expected-cases.jsonl
│   └── expected_cases.py          Shared JSONL read/write for expected-cases
├── references/
│   ├── coverage-discipline.md     Generic ASV validation methodology
│   ├── monitor-prompt.md          Prompt template for the low-model log reader
│   └── codex-setup.md             .codex/agents/asv-monitor.toml for Codex
└── tests/
    └── test_behavior.py           Behavior tests for all scripts
```

## Installation

This skill follows the standard agentskills.io layout. The skill directory (`perf-bench-loop/`) goes into a skills discovery path:

| Client | Project-level | User-level |
|---|---|---|
| Codex | `<project>/.agents/skills/` | `~/.agents/skills/` |
| ZCode | `<project>/.agents/skills/` | `~/.agents/skills/` |
| Claude Code | `<project>/.claude/skills/` | `~/.claude/skills/` |

For cross-client use, install in both `.agents/skills/` and `.claude/skills/`, or use a symlink pointing to one canonical copy.

**Project config**: copy `config.example.sh` to `<project-root>/.perf-bench-loop/config.sh` and fill in the values. Add `.perf-bench-loop/` to `.git/info/exclude` or `.gitignore` — it should not be committed.

**Helper scripts** (`asv-background.sh`, `wait-for-asv.sh`, `probe-asv.sh`, `compare-asv.py`, `validate-asv-selection.py`, `expected_cases.py`) should be deployed to a **fixed path outside the project source tree** on the benchmark machine (e.g. `~/.local/share/perf-bench-loop/`).

### Codex additional setup

On first use in a Codex environment, also drop the toml from [`references/codex-setup.md`](references/codex-setup.md) into `<project>/.codex/agents/asv-monitor.toml`. This pins the probe/log-reading subagent to a lightweight model (Terra/Luna) + read-only sandbox.

ZCode/Claude Code needs no such file — the main agent dispatches the subagent with `model: "haiku"` directly at call time.

## Usage examples

**Validation mode** (one-shot, no auto-iteration):

> I just optimized `_compress` in `src/foo.py`. Run asv on bench01 to check for regressions.

**Iteration mode** (auto-fix until passing, max 3 attempts):

> Optimize `BatchProcessor.merge` in `src/bar.py` until asv passes. Try at most 3 times.

**Probe mode** (progress visibility):

> Run asv with progress checks. I want to see how far along it is.

The skill triggers on phrases like "asv", "airspeed velocity", "benchmark this change", "check for perf regression", "跑基准", "性能优化验证", "看看有没有回归".

## Requirements

- Local: `bash`, `python3`, `ssh`, `git`
- Remote (server where ASV runs): `asv` installed, the project checked out, `ssh` access from local machine
- Project config: `.perf-bench-loop/config.sh` (copy from `config.example.sh`)
- Host agent: Codex, ZCode, or Claude Code (any agent that loads agentskills.io-format skills)

## License

MIT — see [LICENSE](LICENSE).
