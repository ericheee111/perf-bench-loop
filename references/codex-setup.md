# Codex Setup — ASV Monitor Subagent

This file is for **Codex only**. ZCode and Claude Code users can ignore it — those hosts dispatch the monitor subagent directly via the `Agent` tool with a `model` override, no project-level config needed.

## Why a separate toml file exists

In Codex, when the main agent delegates to a subagent, the subagent's model and sandbox are controlled by a project-level custom agent file at `.codex/agents/<name>.toml`. Without this file, Codex picks the model itself at spawn time — and it tends to pick a high-capability, high-cost model, which is exactly what this skill is trying to avoid for log-reading.

The toml below pins a **lightweight model** and **read-only sandbox** so that the monitor subagent:

- Costs little to run (it's just reading a log and classifying errors).
- Cannot accidentally modify source code or the ASV run directory.
- Behaves deterministically across sessions.

This is the Codex equivalent of ZCode's `Agent` tool with `model: "haiku"`.

## Installation

On first use of this skill in a Codex project:

1. Create the directory if it doesn't exist: `.codex/agents/`
2. Save the toml block below as `.codex/agents/asv-monitor.toml` in the project root.
3. Commit it so the configuration is stable across sessions and machines.

The main agent's skill instructions tell it to spawn `asv_monitor` by name when it reaches Phase 5's failure branch. The name in the toml must match exactly.

## The toml file

Save this verbatim as `.codex/agents/asv-monitor.toml`:

```toml
# .codex/agents/asv-monitor.toml
# Pinned lightweight subagent for reading failed ASV logs.
# Spawned by the perf-bench-loop skill when an ASV run fails and the
# comparison table can't be produced. Read-only so it can't damage the
# run directory or source tree.

name = "asv_monitor"

description = """
Monitor an already-running or finished ASV benchmark on a remote server.
Use this agent after the main agent has launched ASV and needs a
low-cost pass over the run log to classify a failure. Do not use this
agent for code changes or for interpreting successful benchmark results.
"""

# Lightweight model. REPLACE THIS with whatever cheap tier your Codex
# account has access to (a mini / fast / low-cost variant). The point is:
# this agent reads a log and returns a 200-word summary. It does not need
# high reasoning. Do not set this to a flagship model — that defeats the
# entire purpose of the skill. Ask the user which lightweight model to use
# if you're unsure what's available.
model = "<lightweight-model>"
model_reasoning_effort = "low"

# Read-only: the monitor must not modify source, the run directory, or
# anything else. It only reads logs and exit-code files.
sandbox_mode = "read-only"

developer_instructions = """
You are an ASV (airspeed velocity) benchmark log analyst.

Your sole job: read a failed benchmark run's log, classify the failure,
and return a short structured summary. You do NOT modify code. You do
NOT restart anything. You do NOT propose fixes to the codebase — only
classify and recommend the next step at a high level.

When spawned, you will be given:
- An exec prefix that reaches the ASV machine — this may be `ssh host`
  or `ssh host docker exec container`. Use it for every command.
- A run directory path (as the ASV machine sees it, containing run.log,
  exit_code, done, pid)
- The exit code value

Procedure:
1. Read the log at the right layer. Every file access goes through the
   exec prefix, e.g. `<exec_prefix> tail -n 100 <run_dir>/run.log`. If
   ASV ran inside a container, a bare `ssh host cat /tmp/run.log` reads
   the host filesystem and returns empty output even though the run
   succeeded. The run directory lives on the ASV machine.
2. Use tail, grep, and head rather than dumping the whole file. Look for:
   - Lines containing error, Error, ERROR, Traceback, failed, Failed
   - The last 100 lines (where the fatal error usually is)
   - Lines mentioning environment setup (conda, pip, Building,
     Installing) to distinguish environment failures from benchmark
     failures
3. Check whether the process is still running. The pid file is on
   the ASV machine, so read it through the exec prefix:
   <exec_prefix> bash -c 'pid=$(cat <run_dir>/pid) && ps -p "$pid"'
4. Classify the failure into exactly one category:
   - environment     — missing dep, conda env failed, disk full,
                       permission error, ASV config problem
   - benchmark_crash — at least one benchmark ran but threw an exception
   - timeout         — run was killed by a timeout or appears stuck
   - incomplete      — some benchmarks ran but the run was interrupted
   - unknown         — log doesn't give enough signal to classify

Return your answer as plain text, under 200 words, in exactly this
format:

CATEGORY: <one of the categories above>
EXIT_CODE: <the exit code>
ROOT_CAUSE: <one sentence, the specific error>
KEY_LINES:
  <up to 5 quoted lines from the log that justify the classification>
RECOMMENDATION: <one sentence — fix env / fix test / rerun / escalate
to human>

Do not add anything outside this format. Do not speculate beyond what
the log shows. If the log is empty or unreadable, say so in ROOT_CAUSE
and set CATEGORY to unknown.
"""
```

## Notes on the fields

- `name = "asv_monitor"` — must match what the main agent spawns. The skill instructions refer to `asv_monitor` by this exact name.
- `model` — **must be replaced** with a lightweight model your Codex account has access to. Ask the user which cheap/fast model to use if unsure. **Do not** set this to a flagship/high-reasoning model — that defeats the skill's purpose.
- `model_reasoning_effort = "low"` — log classification doesn't need deep reasoning. Keep this low.
- `sandbox_mode = "read-only"` — the monitor only reads. This is a safety net: even if the monitor hallucinated a desire to "fix" something, it can't.
- `developer_instructions` — this is the full prompt. It's a self-contained version of `references/monitor-prompt.md` so the subagent doesn't need to load any extra files. If you edit one, keep the other in sync.

## Verifying it works

After installing, you can verify Codex sees the agent:

```bash
codex  # start a session in the project
# then in the session, ask: "list available custom agents"
```

`asv_monitor` should appear in the list. The main agent will spawn it automatically when the skill reaches the Phase 5 failure branch — you shouldn't need to invoke it by hand.
