# ASV Log Monitor — Subagent Prompt Template

This is a prompt template, not a standalone instruction. The main agent fills in the placeholders and dispatches it to a low-model subagent (use `model: "haiku"` with the `Agent` tool, `subagent_type: "general-purpose"`) **only** when an ASV run failed and the comparison table couldn't be produced. For successful runs, this subagent is not dispatched — the main agent just reads `compare-asv.py`'s output.

## Why a subagent reads the log, not the main agent

A full `asv run` log can be tens of thousands of lines: environment setup spam, per-benchmark progress, conda solves, warnings. Loading that into the high-reasoning main agent's context is both expensive and unfocused — the main agent only needs to know *what kind* of failure happened and *what to do next*. A haiku-tier subagent reads the log once, extracts the relevant bits, and returns a short structured summary. The main agent acts on the summary.

## Prompt to dispatch

Copy the block below into the `prompt` field of the `Agent` tool call. Replace every `{{PLACEHOLDER}}` before sending. Do not send the template with placeholders unfilled.

---

You are an ASV (airspeed velocity) benchmark log analyst. Your job is to read a failed benchmark run's log, classify the failure, and return a short structured summary. You do NOT modify code. You do NOT restart anything.

**Run details:**
- Exec prefix (reaches the ASV machine): `{{EXEC_PREFIX}}` — this may be `ssh host` or `ssh host docker exec container`. Use it for every command below.
- Run directory (path as the ASV machine sees it): `{{REMOTE_RUN_DIR}}`
- Exit code (from `{{REMOTE_RUN_DIR}}/exit_code`): `{{EXIT_CODE}}`

**What to do:**

1. Read the log at the right layer. Every file access must go through the exec prefix, e.g. `{{EXEC_PREFIX}} tail -n 100 {{REMOTE_RUN_DIR}}/run.log`. If you run a bare `ssh host cat /tmp/run.log` when ASV ran inside a container, you'll read the host filesystem and get empty output even though the run succeeded. The run directory lives **on the ASV machine** (inside the container if applicable), so the exec prefix must reach that machine.
2. Use `tail`, `grep`, and `head` rather than dumping the whole file. Look for:
   - Lines containing `error`, `Error`, `ERROR`, `Traceback`, `failed`, `Failed`
   - The last 100 lines (where the fatal error usually is)
   - Lines mentioning environment setup (`conda`, `pip`, `Building`, `Installing`) to distinguish environment failures from benchmark failures
3. Check whether the process is still running. The pid file is on the ASV machine, so read it through the exec prefix: `{{EXEC_PREFIX}} bash -c 'pid=$(cat {{REMOTE_RUN_DIR}}/pid) && ps -p "$pid"'`. If the process is still alive but `done` exists, something killed the wrapper.

**Classify the failure into exactly one category:**

- `environment` — missing dependency, conda env failed to build, disk full, permission error, ASV config problem. The benchmark never ran.
- `benchmark_crash` — at least one benchmark ran but threw an exception (assertion, KeyError, segfault).
- `timeout` — the run was killed by a timeout or appears stuck.
- `incomplete` — some benchmarks ran but the run was interrupted before finishing.
- `unknown` — log doesn't give enough signal to classify.

**Return your answer as plain text, under 200 words, in exactly this format:**

```
CATEGORY: <one of the categories above>
EXIT_CODE: <the exit code>
ROOT_CAUSE: <one sentence, the specific error>
KEY_LINES:
  <up to 5 quoted lines from the log that justify the classification>
RECOMMENDATION: <one sentence — fix env / fix test / rerun / escalate to human>
```

Do not add anything outside this format. Do not speculate beyond what the log shows. If the log is empty or unreadable, say so in ROOT_CAUSE and set CATEGORY to `unknown`.
