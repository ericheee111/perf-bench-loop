---
name: asv-optimize-loop
description: Run ASV (airspeed velocity) benchmarks on a remote server to validate performance optimizations, auto-generate before/after comparison, and optionally iterate on code changes until no regression. Use whenever the user mentions asv, airspeed velocity, benchmarking a perf change, checking for performance regressions, validating an optimization, or asks to "run asv", "跑基准", "性能优化验证", "看看有没有回归". Covers both one-shot validation and automatic fix-until-pass loops.
---

# ASV Optimize Loop

## Why this skill exists

The expensive mistake this skill prevents: letting the main agent poll a multi-hour ASV run. Every poll is a high-reasoning forward pass that reads the same half-finished log and produces no value. A 3-hour `asv run` polled every minute can burn more tokens in waiting than in actual development.

This skill enforces a strict separation:

- **High-reasoning main agent** does only what it's good at: analyzing code, writing the optimization, interpreting a finished comparison table, and deciding the next change.
- **A shell** does the waiting. One tool call blocks on the remote `done` file for hours; the main agent doesn't think during that time and spends zero tokens.
- **A low-model subagent** reads long raw logs only when something went wrong and the comparison table can't be produced. The main agent never reads raw ASV logs directly.

The result: token cost of waiting drops from "hours of high-reasoning polling" to "one shell call + optionally one low-model subagent call".

## How this skill runs in different agents

The workflow below is agent-agnostic. The only piece that differs across host agents is **how a low-model subagent is dispatched** in Phase 5's failure branch. Two supported hosts:

- **Codex**: a project-level custom agent at `.codex/agents/asv-monitor.toml` pins a lightweight model and `read-only` sandbox. The main agent spawns it via the standard subagent mechanism. See `references/codex-setup.md` for the toml file to drop into the project.
- **ZCode / Claude Code**: dispatch via the `Agent` tool with `model: "haiku"` (or whichever cheap tier is available) and `subagent_type: "general-purpose"`.

Everywhere else, the workflow is identical: the same scripts, the same `compare-asv.py`, the same wait pattern. Pick the host-appropriate dispatch method when you reach Phase 5; don't worry about it before then.

## When to use

Two modes, decided by the user's phrasing:

- **Validation mode (default)** — user says things like "跑 asv 验证这次改动", "check if this caused a regression", "validate the optimization". Run ASV once, report the comparison, stop. Don't modify code based on results unless the user then asks.
- **Iteration mode** — user says things like "优化这个函数直到 asv 通过", "iterate until no regression", "自动改到性能达标". Same loop, but on regression the main agent analyzes the table, proposes a fix, and re-runs. **Hard cap: 3 iterations.** After 3 failures, stop and report — don't keep burning server time on a stuck optimization.

If the user's intent is ambiguous, default to validation mode and ask before iterating.

## Workflow

### Phase 1 — Prepare

Gather four pieces of information before touching anything. Don't guess any of them.

1. **SSH host** — check in this order: (a) explicitly in the user's current message, (b) the project config file `.asv-codex/host` (single line, e.g. `bench01` or `user@host:port`), (c) ask the user. Never invent a host.
2. **Remote project root** — where `asv.conf.json` lives on the server. Usually mirrors the local repo path. Ask if unclear.
3. **ASV command** — ask the user every time, even if you think you remember. Default suggestion is `asv run`, but projects often use `asv run --quick`, `asv run --branch=HEAD`, or a wrapper like `make bench`. Confirm the exact command.
4. **Local test command** — what to run locally for the fast gate in Phase 2. Ask if not obvious from the project (`pytest -x` is a reasonable default for Python projects; never assume).

**First-run setup:** if the remote project doesn't already have `scripts/asv-background.sh` and `scripts/wait-for-asv.sh`, copy them from this skill's `scripts/` directory into the project's `scripts/` folder and commit them. They are meant to live with the project so the run directory layout is stable across sessions. Use `scp` or `rsync` to push them, then `chmod +x`.

Optional: write `.asv-codex/host` in the project root so future sessions skip step 1's question.

### Phase 2 — Implement and run the local fast gate

Main agent work, high reasoning.

1. Make the optimization the user asked for.
2. Run the **local fast test** (from Phase 1.4) before any ASV involvement. This is seconds-to-minutes and catches the bulk of silly mistakes — a broken import, a wrong signature, a test that doesn't even pass functionally. ASV is hours-level; don't waste a server run on code that fails `pytest`.
3. If the fast test fails, fix it and re-run. Do not proceed to Phase 3 until local tests are green.

### Phase 3 — Launch the remote ASV run

Goal: start ASV in the background on the server and return immediately. Do not wait here.

1. Pick a run directory name: `.asv-runs/<YYYYMMDD-HHMMSS>` under the remote project root.
2. Launch via the background script over SSH:

   ```bash
   ssh <host> 'cd <remote-project-root> && ./scripts/asv-background.sh \
     ".asv-runs/<timestamp>" <asv-command...>'
   ```

   The script starts ASV with `nohup`, writes `pid` immediately, and will write `run.log`, `exit_code`, and `done` as the run progresses.
3. Record the run directory. You'll need it in Phase 4 and 5.

You're now done for this phase. The ASV run is running detached on the server.

### Phase 4 — Wait (this is where the tokens get saved)

**Do not poll.** Do not run `ssh ... ps`. Do not run `ssh ... tail run.log` in a loop. Every one of those is a high-reasoning forward pass burning tokens for no progress.

Instead, make one call to the wait script:

```bash
./scripts/wait-for-asv.sh <host> <remote-project-root>/.asv-runs/<timestamp> [poll-interval]
```

What this does: SSHes to the remote, enters a shell loop `while [ ! -f done ]; do sleep 90; done`, then prints `EXIT_CODE:` + the exit code and `FINAL_LOG:` + the last 300 lines of `run.log`. The shell does the waiting. The main agent is idle for the entire duration of the ASV run — one tool call, one forward pass to dispatch it, one forward pass to read its output, regardless of whether ASV took 5 minutes or 5 hours.

This single step is the difference between the skill being worth it and not.

### Phase 5 — Read the result

Branch on the exit code from Phase 4.

**Exit code 0 (ASV completed normally):**

Call `compare-asv.py` to get a structured comparison. Don't read the raw log.

```bash
./scripts/compare-asv.py --results-dir <remote-results-dir> [--baseline <hash>] [--candidate <hash>]
```

(If the results live on the remote server, run this over SSH or rsync the `.asv/results/` directory down first — `compare-asv.py` works on local files.)

The script prints a markdown table:

```
| benchmark | baseline | candidate | change | significant |
|-----------|----------|-----------|--------|-------------|
| suite.foo | 1.23 ms  | 1.18 ms   | -4.1%  | yes         |
```

And exits with: `0` = no regression, `1` = regression present, `2` = couldn't compare (missing baseline, environment mismatch, etc.).

The main agent reads this table and the exit code. That's the entire result-reading step.

**Exit code non-zero, or compare-asv.py returns 2:**

Something went wrong — environment failure, ASV crash, missing baseline. The raw `run.log` may be long. **Do not read it directly.** Dispatch a low-model subagent:

- Dispatch a **low-model subagent** (the whole point is to not burn high-reasoning tokens on log reading). The exact dispatch method depends on your host agent:
    - **Codex**: spawn the `asv_monitor` custom agent defined in `.codex/agents/asv-monitor.toml` (if that file isn't in the project yet, copy it from `references/codex-setup.md` first). The toml already pins a lightweight model and read-only sandbox, so you don't specify those at dispatch time.
    - **ZCode / Claude Code**: use the `Agent` tool with `model: "haiku"` and `subagent_type: "general-purpose"`.
- Pass the prompt from `references/monitor-prompt.md`, filling in the run directory and SSH host.
- The subagent reads the log, classifies the failure, and returns a ≤200-word summary.
- The main agent acts on the summary, never on the raw log.

This is the only place a subagent gets dispatched. For successful runs it never happens.

### Phase 6 — Decide and (maybe) iterate

Read the comparison table and decide.

- **No regression** (compare-asv.py exit 0, or all changes are improvements / within noise): report success to the user. Include the table. Stop. In iteration mode, this is also the success exit.
- **Regression** (exit 1, one or more benchmarks got meaningfully slower):
  - In **validation mode**: report the regression with the table, suggest likely causes, stop. Don't modify code unless the user asks.
  - In **iteration mode**: if iteration count < 3, analyze the table (which benchmarks regressed, by how much, how that maps to what you just changed), decide on a fix, go back to Phase 2. If iteration count == 3, stop and report — three failed attempts means the approach is probably wrong and a human should look.

When reporting, always include: the comparison table, the run directory path, the path to the full log on the server, and (if iteration mode) which iteration this was out of 3.

## Common mistakes

- **Polling the run from the main agent.** This is the anti-pattern the whole skill exists to kill. `sleep 60 && ssh ... tail` in a loop means every minute of a 3-hour run costs a high-reasoning forward pass. Use `wait-for-asv.sh`. One call.
- **Reading the raw ASV log from the main agent.** A full `asv run` log can be tens of thousands of lines. Loading it into the main agent's context is both expensive and unfocused. Use `compare-asv.py` for the structured answer, or dispatch a low-model subagent for failure diagnosis.
- **Skipping the local fast gate.** ASV runs are hours. Local tests are seconds. Catching a typo at the local stage saves an entire wasted server run. Always run Phase 2.
- **Guessing the SSH host or ASV command.** These vary per project and per run. Wrong host = connection failure, wrong command = wasted run. Ask.
- **Retrying blindly on ASV failure.** A non-zero exit code is usually an environment problem (missing dependency, conda env issue, disk full), not a code regression. Read the failure summary and fix the root cause before re-running. Re-running the same broken command 3 times just burns server time.
- **Forgetting to copy the scripts to the project on first run.** The scripts live in this skill to be portable, but the project needs its own copy in `scripts/` so the run-directory layout is stable. Don't keep calling them from the skill directory long-term — copy once, commit, move on.

## References

- `[monitor-prompt.md](references/monitor-prompt.md)` — load this when dispatching the low-model subagent in Phase 5's failure branch. It's the prompt template.
- `[codex-setup.md](references/codex-setup.md)` — load this on first use in Codex. It contains the `.codex/agents/asv-monitor.toml` file to drop into the project so the low-model monitor subagent has a pinned lightweight model and read-only sandbox. ZCode/Claude Code users can ignore this file.
- `scripts/asv-background.sh` — run with no args to see usage. Copies into the target project's `scripts/` directory.
- `scripts/wait-for-asv.sh` — run with no args to see usage. Copies into the target project's `scripts/` directory.
- `scripts/compare-asv.py` — run with `--help` for full options. Stays in the skill directory; can be invoked locally or over SSH.
