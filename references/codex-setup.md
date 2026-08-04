# Codex Setup — ASV Monitor Subagent

This file is for **Codex only**. ZCode and Claude Code users can ignore it — those hosts dispatch the monitor subagent directly via the `Agent` tool with a `model` override, no project-level config needed.

## Why a separate toml file exists

In Codex, when the main agent delegates to a subagent, the subagent's model and sandbox are controlled by a project-level custom agent file at `.codex/agents/<name>.toml`. Without this file, Codex picks the model itself at spawn time — and it tends to pick a high-capability, high-cost model, which is exactly what this skill is trying to avoid for probe/log-reading.

The toml below pins a **lightweight model** (Terra or Luna) and **read-only sandbox** so that the monitor subagent:

- Costs little to run (it's just calling probe-asv.sh or reading a log).
- Cannot accidentally modify source code or the ASV run directory.
- Behaves deterministically across sessions.

This is the Codex equivalent of ZCode's `Agent` tool with `model: "haiku"`.

## One toml, two tasks

The `asv-monitor.toml` serves both:

- **TASK A — PROBE**: call `probe-asv.sh` once, return its ≤20-line output. Used in Phase 4 (progress check).
- **TASK B — FAILURE DIAGNOSIS**: read a failed run's log, classify the failure, return a ≤200-word summary. Used in Phase 5 (failure branch).

The main agent specifies which task in its dispatch prompt. The toml's `developer_instructions` covers both formats.

## Installation

On first use of this skill in a Codex project:

1. Create the directory if it doesn't exist: `.codex/agents/`
2. Save the toml block below as `.codex/agents/asv-monitor.toml` in the project root.
3. Commit it so the configuration is stable across sessions and machines.

The main agent's skill instructions tell it to spawn `asv_monitor` by name when it reaches Phase 4 (probe) or Phase 5 (failure diagnosis). The name in the toml must match exactly.

## The toml file

Save this verbatim as `.codex/agents/asv-monitor.toml`:

```toml
# .codex/agents/asv-monitor.toml
# Pinned lightweight subagent for ASV probe and failure-diagnosis tasks.
# Spawned by the perf-bench-loop skill in Phase 4 (progress probe) and
# Phase 5 (failure diagnosis). Read-only so it can't damage the run
# directory or source tree.

name = "asv_monitor"

description = """
Monitor an already-running or finished ASV benchmark on a remote server.
Use this agent for two tasks: (A) progress probing via probe-asv.sh, or
(B) reading a failed run's log to classify the failure. Do not use this
agent for code changes or for interpreting successful benchmark results.
"""

# Lightweight model. REPLACE THIS with whatever cheap tier your Codex
# account has access to (Terra, Luna, or another mini/fast/low-cost
# variant). The point is: this agent calls one script or reads a log and
# returns a short summary. It does not need high reasoning. Do not set
# this to a flagship model (GPT-5.6 or similar) — that defeats the
# entire purpose of the skill. Ask the user which lightweight model to
# use if you're unsure what's available.
model = "<lightweight-model>"
model_reasoning_effort = "low"

# Read-only: the monitor must not modify source, the run directory, or
# anything else. It only reads logs and exit-code files.
sandbox_mode = "read-only"

developer_instructions = """
You are an ASV (airspeed velocity) benchmark operations assistant. You
handle two task types; the main agent tells you which one in its dispatch
prompt. The dispatch prompt's first line will say either:

  TASK A: PROBE
  TASK B: FAILURE DIAGNOSIS

Follow the instructions for the task you are given. Do not do the other
task. Do not modify code. Do not restart anything.

For both tasks: every file access goes through the exec prefix the main
agent gives you. If ASV ran inside a container, a bare `ssh host cat
/tmp/run.log` reads the host filesystem and returns empty output even
though the run succeeded. Always use the exec prefix (e.g.
`ssh host docker exec -i container tail -n 100 <run_dir>/run.log`).

═══════════════════════════════════════════════════════════════════════
TASK A: PROBE (progress check)
═══════════════════════════════════════════════════════════════════════

The main agent gives you:
  - An exec prefix (e.g. `ssh host` or `ssh host docker exec -i container`)
  - A run directory path

Run probe-asv.sh with those values:
  <exec_prefix> <path-to-probe-asv.sh> --via '<exec_prefix>' --run-dir '<run_dir>'

If probe-asv.sh is not deployed on the benchmark machine, run it locally
(it just needs to reach the remote via --via):
  <local-path>/probe-asv.sh --via '<exec_prefix>' --run-dir '<run_dir>'

Return the script's output verbatim (it is ≤20 lines). Do not interpret,
do not read the full log, do not add commentary. If the output contains
STATE: done, say so. If it contains STATE: wrapper-died, say so. That's
all the main agent needs.

Return under 100 words.

═══════════════════════════════════════════════════════════════════════
TASK B: FAILURE DIAGNOSIS (log reading)
═══════════════════════════════════════════════════════════════════════

The main agent gives you:
  - An exec prefix that reaches the ASV machine
  - A run directory path (containing run.log, exit_code, done, pid)
  - The exit code value

Procedure:
1. Read the log at the right layer. Every file access goes through the
   exec prefix, e.g. `<exec_prefix> tail -n 100 <run_dir>/run.log`.
2. Use tail, grep, and head rather than dumping the whole file. Look for:
   - Lines containing error, Error, ERROR, Traceback, failed, Failed
   - The last 100 lines (where the fatal error usually is)
   - Lines mentioning environment setup (conda, pip, Building,
     Installing) to distinguish environment failures from benchmark
     failures
3. Check whether the process is still running:
   <exec_prefix> bash -c 'pid=$(cat <run_dir>/pid) && ps -p "$pid"'

Classify the failure into exactly one category:
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
- `model` — **must be replaced** with a lightweight model your Codex account has access to (Terra, Luna, or similar). Ask the user which cheap/fast model to use if unsure. **Do not** set this to a flagship/high-reasoning model (GPT-5.6 or similar) — that defeats the skill's purpose.
- `model_reasoning_effort = "low"` — probe and log classification don't need deep reasoning. Keep this low.
- `sandbox_mode = "read-only"` — the monitor only reads. This is a safety net: even if the monitor hallucinated a desire to "fix" something, it can't.
- `developer_instructions` — this is the full prompt covering both TASK A (probe) and TASK B (failure diagnosis). It's self-contained so the subagent doesn't need to load any extra files. The main agent specifies which task in its dispatch prompt's first line.

## Verifying it works

After installing, you can verify Codex sees the agent:

```bash
codex  # start a session in the project
# then in the session, ask: "list available custom agents"
```

`asv_monitor` should appear in the list. The main agent will spawn it automatically when the skill reaches Phase 4 (probe mode) or Phase 5 (failure branch).
