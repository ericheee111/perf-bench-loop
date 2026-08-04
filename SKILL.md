---
name: perf-bench-loop
description: Run long-running ASV (airspeed velocity) benchmarks on a remote server to validate performance optimizations, wait without agent polling, and compare a baseline commit with a candidate commit. Supports config-driven project setup, publication gate, preflight validation, unified orchestration, and optional progress probing. Use when the task explicitly involves ASV, airspeed velocity, or an ASV performance regression check. Do not use for generic pytest, remote tests, or arbitrary remote commands. Covers both one-shot validation and automatic fix-until-pass loops (max 3 iterations).
---

# Perf Bench Loop

## Why this skill exists

The expensive mistake this skill prevents: letting the main agent poll a multi-hour benchmark run. Every poll is a high-reasoning forward pass that reads the same half-finished log and produces no value. A 3-hour run polled every minute can burn more tokens in waiting than in actual development.

This skill enforces a strict separation:

- **High-reasoning main agent** does only what it's good at: analyzing code, writing the optimization, interpreting a finished comparison table, and deciding the next change.
- **A shell** does the waiting. One tool call blocks on the remote `done` file for hours; the main agent doesn't think during that time and spends zero tokens.
- **A low-model subagent** reads long raw logs only when something went wrong and the comparison table can't be produced. The main agent never reads raw benchmark logs directly.

The result: token cost of waiting drops from "hours of high-reasoning polling" to "one shell call + optionally one low-model subagent call".

## How this skill runs in different agents

The workflow below is agent-agnostic. The only piece that differs across host agents is **how the probe subagent is dispatched** in Phase 4's probe mode, and **how the failure-diagnosis subagent is dispatched** in Phase 5's failure branch.

### ZCode (no usage limit)

- **Probe**: main agent calls `probe-asv.sh` directly via the Bash tool. No subagent needed — Bash execution costs no reasoning tokens; only reading the ≤20-line result costs a little. Optionally, dispatch a GLM-5-Turbo subagent if you want the main agent turn to stay even shorter.
- **Failure diagnosis**: dispatch the `Agent` tool with `model: "haiku"` (or GLM-5-Turbo) and `subagent_type: "general-purpose"`.

### Codex (usage-limited)

- **Probe**: dispatch the `asv_monitor` custom agent (pinned to a lightweight model — Terra or Luna — via `.codex/agents/asv-monitor.toml`). The toml's `developer_instructions` covers both probe and failure-diagnosis tasks; the main agent specifies which in its dispatch prompt.
- **Failure diagnosis**: same `asv_monitor` subagent, different prompt.
- **First-run**: copy `.codex/agents/asv-monitor.toml` from `references/codex-setup.md` into the project. Replace the `model` placeholder with your lightweight tier.

Everywhere else, the workflow is identical: the same scripts, the same `compare-asv.py`, the same wait pattern.

## When to use

Two modes, decided by the user's phrasing:

- **Validation mode (default)** — user says things like "跑 asv 验证这次改动", "check if this caused a regression", "validate the optimization". Run ASV once, report the comparison, stop. Don't modify code based on results unless the user then asks.
- **Iteration mode** — user says things like "优化这个函数直到 asv 通过", "iterate until no regression", "自动改到性能达标". Same loop, but on regression the main agent analyzes the table, proposes a fix, and re-runs. **Hard cap: 3 iterations.** After 3 failures, stop and report — don't keep burning server time on a stuck optimization.

If the user's intent is ambiguous, default to validation mode and ask before iterating.

## Config-driven project setup

This skill is project-agnostic. All project-specific values (SSH host, container, repo path, conda env, compiler, benchmark suites, protected paths, branch/remote) live in a **config file** at `<project-root>/.perf-bench-loop/config.sh`.

- Copy `config.example.sh` from this skill's repo to `.perf-bench-loop/config.sh` in the project root.
- Fill in the values for your project.
- The config is `source`d by `publish_candidate.sh`, `preflight.sh`, and `run_remote_asv.sh`.
- **Do not commit `.perf-bench-loop/` to the project repo.** Add it to `.git/info/exclude` or the project's `.gitignore`.

If `.perf-bench-loop/config.sh` is missing, the scripts will error out and tell you to create it.

## Workflow

### Phase 0 — Takeover check (run this first, every time)

Before doing anything else, check whether you're being asked to *continue* an in-flight ASV workflow that started before this skill was available. This is the single most common cause of the skill being silently ignored.

Symptoms that you're in a takeover situation:
- The user says "continue", "继续", "接着做", "pick up where you left off", or refers to a run that's already started.
- You already have context about a driver script you wrote earlier in the session (`run_focused_asv_*.sh`, a custom wrapper, etc.).
- You already have a run directory path in context that you didn't create via this skill's scripts.
- `AGENTS.md` in the project contains ASV-related instructions that predate this skill (e.g. "use a subagent to poll asv", "check the log every 60s").

If any of these apply, do **not** silently continue the old workflow. Instead:

1. **Surface the conflict to the user.** Say explicitly: "I see an in-flight ASV run / custom driver / conflicting AGENTS.md instruction from before the skill was installed. The skill's workflow is incompatible with continuing it as-is. Here are the options."
2. **Audit the existing run directory** (if one exists): does it have the four files this skill expects — `pid`, `run.log`, `exit_code`, `done`? Are they on the benchmark machine's filesystem (inside the container, if applicable), or only on the ssh host?
    - If the run is already finished (`done` exists and `exit_code` is readable): skip to Phase 5 with that run dir.
    - If the run is still in flight but its files are at the wrong layer: tell the user the old run can't be safely monitored, and ask whether to (a) wait manually, or (b) kill it and relaunch through the skill.
    - If the run dir doesn't match the skill's layout at all: tell the user.
3. **Check `AGENTS.md` for conflicting instructions.** If it tells you to poll, to use a subagent for monitoring, or to write your own ASV driver, those instructions conflict with this skill. Tell the user which lines conflict and ask whether to update `AGENTS.md` to defer to this skill.
4. Only after the conflict is resolved should you proceed to Phase 1.

### Phase 1 — Prepare

Gather and verify before touching anything:

1. **Config file** — check `<project-root>/.perf-bench-loop/config.sh` exists. If not, copy `config.example.sh` from this skill's repo and guide the user to fill it in. Verify `PBL_BRANCH`, `PBL_REMOTE`, `PBL_SSH_HOST`, `PBL_REMOTE_REPO`, `PBL_ASV_DIR`, `PBL_LOG_DIR` are non-empty.
2. **Local test command** — what to run locally for the fast gate in Phase 2. Ask if not obvious from the project (`pytest -x` is a reasonable default for Python projects; never assume).
3. **Suite or focused selector** — which benchmark suite to run. Either a named suite from config (`--suite owned`) or a focused selector (`--benchmark foo.bar`). Ask the user which.

**First-run setup:** the skill's scripts need to be accessible on both the local machine and the benchmark machine.

- **Local**: the scripts live in this skill's `scripts/` directory. If the skill is installed via the standard agentskills.io layout, they're at `<skill-dir>/scripts/`.
- **Benchmark machine**: deploy ALL of these to a **fixed location outside the project source tree** (e.g. `~/.local/share/perf-bench-loop/` or `/home/<user>/tools/perf-bench-loop/`):
  - `asv-background.sh`
  - `wait-for-asv.sh`
  - `probe-asv.sh`
  - `compare-asv.py`
  - `validate-asv-selection.py`
  - `expected_cases.py`

  `run_remote_asv.sh`, `preflight.sh`, and `publish_candidate.sh` run locally; the others run on the benchmark machine. `expected_cases.py` must be alongside both `validate-asv-selection.py` and `compare-asv.py`.

Run directories should also live outside the project tree (e.g. `/home/<user>/bench-runs/<timestamp>`).

**Line endings matter.** If you edit or copy these scripts on Windows, they may end up with CRLF (`\r\n`) line endings. Linux containers will fail with `env: 'bash\r': No such file or directory`. After pushing to a Linux target, convert with `sed -i 's/\r$//'` on each script. Verify with `head -1 <script> | od -c | tail -1`.

### Phase 2 — Implement and run the local fast gate

Main agent work, high reasoning.

1. Make the optimization the user asked for.
2. Run the **local fast test** (from Phase 1) before any ASV involvement. This is seconds-to-minutes and catches the bulk of silly mistakes. ASV is hours-level; don't waste a server run on code that fails locally.
3. If the fast test fails, fix it and re-run. Do not proceed until local tests are green.
4. **Publish project code** (if the change affects project source/tests): call `publish_candidate.sh` to commit, push, and align the remote validation mirror. This is the publication gate — it refuses protected paths, pre-staged changes, missing Git identity, stale branches, and force-pushes.

   ```bash
   scripts/publish_candidate.sh \
       --message "PERF: describe the optimization" \
       --path src/path/to/changed_file.py
   ```

   The helper sources `.perf-bench-loop/config.sh`, fetches the remote, stages only the explicit `--path` arguments, commits, pushes non-force, and aligns the remote mirror so its HEAD equals the candidate. It prints `CANDIDATE_READY=<sha>` on success.

   If the project's `AGENTS.md` defines a standing authorization for publication, do not ask for confirmation. If not, ask the user before publishing.

### Phase 3 — Launch the remote ASV run

**Use `run_remote_asv.sh`.** Do not write your own driver script. This script orchestrates the full sequence: preflight → validate selectors → launch → wait → compare. One Bash call.

Two modes:

**Standard mode** (default — no progress visibility):

```bash
scripts/run_remote_asv.sh \
    --baseline "$BASELINE" --candidate "$CANDIDATE" \
    --suite owned
```

This blocks until the comparison table is ready. One Bash call, regardless of whether ASV takes 5 minutes or 5 hours. The main agent spends zero tokens during the wait.

**Probe mode** (progress visibility):

```bash
# Run in background so the main agent isn't blocked
scripts/run_remote_asv.sh --probe \
    --baseline "$BASELINE" --candidate "$CANDIDATE" \
    --suite owned
```

This launches ASV and returns immediately, printing:
- `RUN_DIR`: the remote run directory path
- `VIA`: the exec prefix for reaching the ASV machine
- `EXPECTED_CASES_FILE`: for the compare step later
- `RESULTS_DIR`: for the compare step later
- `BASELINE` / `CANDIDATE`: full SHAs
- The exact `probe-asv.sh` and `compare-asv.py` commands to run later

Store these. You'll use them in Phase 4 and Phase 5.

**All validation happens BEFORE launching ASV.** `run_remote_asv.sh` calls `preflight.sh` (sync + env validation) and `validate-asv-selection.py` (selector validation) before launching ASV. If either fails, ASV is not started.

### Phase 4 — Wait / Probe

**Standard mode**: you're already done. `run_remote_asv.sh` blocked in Phase 3 and returned the comparison table. Skip to Phase 5.

**Probe mode**: ASV is running in the background on the remote. You need to poll progress. The frequency is up to you — use your judgment based on expected run duration. Short runs (~10 min): probe every ~1 min. Long runs (~hours): probe every ~5 min.

- **ZCode**: call `probe-asv.sh` directly via Bash:

  ```bash
  scripts/probe-asv.sh \
      --via 'ssh <host> docker exec -i <container>' \
      --run-dir '<remote-run-dir>'
  ```

  Returns ≤20 lines: `STATE`, `ELAPSED`, `PID_ALIVE`, `LAST_LOG_LINE`, `EXIT_CODE`, `RUN_DIR`. Costs essentially nothing (Bash execution, no reasoning tokens).

- **Codex**: dispatch the `asv_monitor` subagent (pinned to Terra/Luna). Pass the exec prefix and run dir. The subagent calls `probe-asv.sh` and returns a ≤100-word summary.

**Do not poll more frequently than the run's progress warrants.** ASV progress doesn't change minute-by-minute on long runs. Every probe is a round-trip, even if it's cheap.

When `probe-asv.sh` reports `STATE: done`, proceed to Phase 5.

### Phase 5 — Read the result

**Standard mode**: `run_remote_asv.sh` already printed the comparison table and returned an exit code. Check the exit code:

- `0` — all cases pass the policy. Report success.
- `1` — ≥1 case violates the policy (regression or no improvement). Read the table. In iteration mode, analyze and loop back to Phase 2.
- `2` — data incomplete or unreliable. Do NOT modify code. Diagnose: check if selectors were wrong, environment failed, or expected cases are missing.
- `30` — preflight failed. Fix the environment, not the code.
- `64` — config/argument error. Fix the arguments.

**Probe mode**: when `probe-asv.sh` reports `STATE: done`, run `compare-asv.py` yourself using the command that Phase 3 printed:

```bash
scripts/compare-asv.py \
    --results-dir '<results-dir>' \
    --baseline <sha> --candidate <sha> \
    --expected-cases-file '<expected-cases-file>' \
    --threshold 5 --policy no-regression
```

The exit codes are the same as standard mode (0/1/2).

**Failure path (ASV exit ≥2, wrapper-died, or compare returns 2):**

Something went wrong — environment failure, ASV crash, missing baseline. The raw `run.log` may be long. **Do not read it directly.** Dispatch a low-model subagent:

- **ZCode**: `Agent` tool with `model: "haiku"`, `subagent_type: "general-purpose"`.
- **Codex**: spawn `asv_monitor` (the same toml covers both probe and failure-diagnosis — specify "TASK B: FAILURE DIAGNOSIS" in the prompt).

Pass the prompt from `references/monitor-prompt.md`, filling in the exec prefix and run directory. The subagent reads the log, classifies the failure, and returns a ≤200-word summary. The main agent acts on the summary, never on the raw log.

### Phase 6 — Decide and (maybe) iterate

Read the comparison table and exit code.

- **Exit 0** (all cases pass): report success. Include the table. Stop. In iteration mode, this is the success exit.
- **Exit 1** (policy violation):
  - In **validation mode**: report the regression with the table, suggest likely causes, stop.
  - In **iteration mode**: if iteration count < 3, analyze the table, decide on a fix, go back to Phase 2. If iteration count == 3, stop — three failed attempts means the approach is probably wrong.
- **Exit 2** (incomplete data): do NOT iterate. Diagnose the problem — check selectors, environment, expected cases. Re-run after fixing the root cause.

When reporting, always include: the comparison table, the run directory path, the path to the full log on the server, and (if iteration mode) which iteration this was out of 3.

Read `references/coverage-discipline.md` for the generic methodology on coverage expansion, parameter-level rigor, threshold semantics, and reporting contracts. Project-specific benchmark scope belongs in the project's `AGENTS.md`.

## Common mistakes

- **Continuing a pre-skill workflow after installing the skill mid-session.** Run Phase 0 first. If you were already running an ASV task with custom rules, "continue" does not mean the skill takes over.
- **Writing your own ASV driver script.** Use `run_remote_asv.sh`. If it doesn't fit your case, add a flag to it — don't fork the concept.
- **Polling the run from the main agent.** Use `probe-asv.sh` (probe mode) or let `run_remote_asv.sh` block (standard mode). One call, not a loop.
- **Reading the raw ASV log from the main agent.** Use `compare-asv.py` for the structured answer, or dispatch a low-model subagent for failure diagnosis.
- **Checking files at the wrong layer in a container setup.** If ASV runs in `ssh host docker exec container`, then `done`, `run.log`, `exit_code` all live *inside the container*. Always use the `--via` prefix that reaches the ASV machine.
- **Skipping the local fast gate.** ASV runs are hours. Local tests are seconds. Always run Phase 2.
- **Guessing the config values.** Wrong host = connection failure, wrong suite = wasted run. Read `.perf-bench-loop/config.sh`.
- **Treating `asv continuous` exit 1 as a failure.** Exit 1 means a regression was detected — that's a valid result. Only exit ≥2 is an ASV failure.
- **Retrying blindly on ASV failure.** A non-zero exit (other than 1) is usually an environment problem, not a code regression. Read the failure summary and fix the root cause.
- **Putting scripts or run directories inside the project source tree.** Deploy scripts to a fixed path outside the repo, and put run directories outside the repo too.
- **Skipping selector validation before launch.** `run_remote_asv.sh` does this automatically via `validate-asv-selection.py`. If you're launching ASV manually (bypassing `run_remote_asv.sh`), always run the validator first.
- **Committing `.perf-bench-loop/config.sh` to the project repo.** It contains project-specific paths and may contain sensitive host info. Add to `.git/info/exclude` or `.gitignore`.

## References

- `[coverage-discipline.md](references/coverage-discipline.md)` — generic ASV validation methodology: coverage expansion order, parameter-level rigor, threshold semantics, specialization safety, reporting contract.
- `[monitor-prompt.md](references/monitor-prompt.md)` — prompt template for the low-model failure-diagnosis subagent (Phase 5 failure branch).
- `[codex-setup.md](references/codex-setup.md)` — `.codex/agents/asv-monitor.toml` for Codex. Pins a lightweight model (Terra/Luna) and read-only sandbox. Covers both probe and failure-diagnosis tasks.
- `scripts/run_remote_asv.sh` — unified orchestration: preflight → validate → launch → wait → compare. Run with `--help` for usage.
- `scripts/publish_candidate.sh` — config-driven publication gate: commit, push, align remote mirror. Run with `--help` for usage.
- `scripts/preflight.sh` — config-driven remote environment validation. Run standalone or called by `run_remote_asv.sh`.
- `scripts/probe-asv.sh` — single-snapshot progress check. Returns immediately with STATE/ELAPSED/LAST_LOG_LINE.
- `scripts/asv-background.sh` — launch ASV in background, write status files. Deploy to benchmark machine.
- `scripts/wait-for-asv.sh` — block on `done` marker (the token saver). Runs locally via `--via`.
- `scripts/compare-asv.py` — parse ASV results, emit markdown comparison table. Run with `--help` for options.
- `scripts/validate-asv-selection.py` — pre-check `-b` selectors, write expected-cases JSONL. Run on benchmark machine.
- `scripts/expected_cases.py` — shared JSONL read/write module. Not run directly.
- `config.example.sh` — template for `.perf-bench-loop/config.sh`. Copy and fill in project values.
