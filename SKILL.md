---
name: perf-bench-loop
description: Run long-running ASV (airspeed velocity) benchmarks on a remote server to validate performance optimizations, wait without agent polling, and compare a baseline commit with a candidate commit. Use only when the task explicitly involves ASV, airspeed velocity, or an ASV performance regression check. Do not use for generic pytest, remote tests, or arbitrary remote commands. Covers both one-shot validation and automatic fix-until-pass loops (max 3 iterations).
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

### Phase 0 — Takeover check (run this first, every time)

Before doing anything else, check whether you're being asked to *continue* an in-flight ASV workflow that started before this skill was available. This is the single most common cause of the skill being silently ignored.

Symptoms that you're in a takeover situation:
- The user says "continue", "继续", "接着做", "pick up where you left off", or refers to a run that's already started.
- You already have context about a driver script you wrote earlier in the session (`run_focused_asv_*.sh`, a custom wrapper, etc.).
- You already have a run directory path in context that you didn't create via `asv-background.sh`.
- `AGENTS.md` in the project contains ASV-related instructions that predate this skill (e.g. "use a subagent to poll asv", "check the log every 60s").

If any of these apply, do **not** silently continue the old workflow. That workflow was built without this skill's constraints and will keep burning tokens the way it already was. Instead:

1. **Surface the conflict to the user.** Say explicitly: "I see an in-flight ASV run / custom driver / conflicting AGENTS.md instruction from before the skill was installed. The skill's workflow is incompatible with continuing it as-is. Here are the options." Don't bury this.
2. **Audit the existing run directory** (if one exists): does it have the four files this skill expects — `pid`, `run.log`, `exit_code`, `done`? Are they on the benchmark machine's filesystem (inside the container, if applicable), or only on the ssh host?
    - If the run is already finished (`done` exists and `exit_code` is readable at the right layer): skip to Phase 5 with that run dir. Don't relaunch.
    - If the run is still in flight but its files are at the wrong layer (e.g. `done` is inside a container but you'd check from the ssh host): you cannot monitor it with `wait-for-asv.sh`. Tell the user the old run can't be safely monitored by the skill, and ask whether to (a) wait for it manually, or (b) kill it and relaunch through the skill.
    - If the run dir doesn't match the skill's layout at all (custom driver, no `done` marker): it cannot be monitored by the skill. Tell the user.
3. **Check `AGENTS.md` for conflicting instructions.** If `AGENTS.md` tells you to poll, to use a subagent for monitoring, or to write your own ASV driver, those instructions predate and conflict with this skill. Do not follow both. Tell the user exactly which lines conflict and ask whether to update `AGENTS.md` to defer to this skill. (The skill's scripts are more reliable than ad-hoc AGENTS.md rules — they handle container layers, atomic `done` markers, and structured result parsing that hand-written rules usually get wrong.)
4. Only after the conflict is resolved (user confirmed, AGENTS.md updated, old run either finished/killed/relaunched) should you proceed to Phase 1.

The reason this phase exists: a skill loaded mid-session inherits an execution context that was built without it. The agent's momentum carries the old workflow forward and the new skill's instructions lose every collision. Forcing an explicit takeover check breaks that momentum.

### Phase 1 — Prepare

Gather the following before touching anything. Don't guess any of it — every missing piece can waste an entire ASV run.

1. **SSH host** — check in this order: (a) explicitly in the user's current message, (b) the project config file `.perf-bench-loop/host` (single line), (c) ask the user. Never invent a host.
2. **Remote project root** — where the benchmark config lives on the benchmark machine (e.g. `asv.conf.json` for ASV). Ask if unclear.
3. **Container or other hop (if any)** — does the benchmark run directly on the SSH host, or inside a container / another environment? If there's an intermediate hop (e.g. `docker exec <container>`), you need the full command chain that reaches the benchmark machine. Ask the user; don't assume.
4. **Environment activation (if any)** — does the benchmark tool need a conda env, virtualenv, module load, or other activation before it's on PATH? If so, get the exact activation command. `docker exec` defaults to a non-login shell, so conda hooks won't load automatically — the activation command must be explicit.
5. **Benchmark command** — the subcommand and flags. For ASV, e.g. `continuous --factor 1.05 <base> HEAD`, `run --branch=HEAD`. Ask the user every time. `asv-background.sh` currently prepends `asv` itself, so pass only the ASV subcommand and flags. **Do not use `--quick`** for runs whose results you want to compare — ASV does not save results from quick runs, so compare-asv.py will find nothing. Use `--quick` only for early smoke testing (does the benchmark even run without errors?).
6. **Local test command** — what to run locally for the fast gate in Phase 2. Ask if not obvious from the project (`pytest -x` is a reasonable default for Python projects; never assume).

**First-run setup:** the skill's scripts (`asv-background.sh`, `wait-for-asv.sh`) need to be accessible on the benchmark machine. Deploy them to a **fixed location outside the project source tree** (e.g. `~/.local/share/perf-bench-loop/` or `/home/<user>/tools/perf-bench-loop/` on the benchmark machine), not inside the project's `scripts/` directory. This avoids polluting the project's `git status` — especially important for forks of upstream projects where stray files complicate PRs. Use `scp` or `rsync` to push them, `chmod +x`, and record the deployment path for use in Phase 3.

Run directories should also live outside the project tree (e.g. `/home/<user>/bench-runs/<timestamp>`), for the same reason.

**Line endings matter.** If you edit or copy these scripts on Windows, they may end up with CRLF (`\r\n`) line endings. Linux containers will fail with `env: 'bash\r': No such file or directory` — the `\r` breaks the shebang. After pushing to a Linux target, convert with `sed -i 's/\r$//'` on each script (run on the benchmark machine), or push via `scp` from a source that already has LF endings. Verify with `head -1 <script> | od -c | tail -1` — the line should end in `\n`, not `\r \n`.

Optional: write `.perf-bench-loop/host` in the project root so future sessions skip step 1's question.

### Phase 2 — Implement and run the local fast gate

Main agent work, high reasoning.

1. Make the optimization the user asked for.
2. Run the **local fast test** (from Phase 1, item 6) before any ASV involvement. This is seconds-to-minutes and catches the bulk of silly mistakes — a broken import, a wrong signature, a test that doesn't even pass functionally. ASV is hours-level; don't waste a server run on code that fails `pytest`.
3. If the fast test fails, fix it and re-run. Do not proceed to Phase 3 until local tests are green.

### Phase 3 — Launch the remote ASV run

Goal: start ASV in the background on the server and return immediately. Do not wait here.

**Critical: use `asv-background.sh` from this skill.** Do not write your own driver script. Every custom driver we've seen reintroduces the bugs this skill exists to prevent — wrong redirect target, missing `done` marker, log written to a layer the host can't read. The skill's script handles all of that. If it doesn't fit your setup, the right fix is a flag on the skill's script, not a new script.

1. Decide the **exec prefix** — the command chain that reaches the machine where ASV actually runs. This is the single most important decision in the whole workflow, because every later phase reuses it. Build it from the information gathered in Phase 1:
    - **Direct SSH**: `ssh <ssh-host>`
    - **SSH + container**: `ssh <ssh-host> docker exec -i <container>` (ASV runs inside `<container>`; the run directory must be a path visible inside that container)
    - **SSH + container + env activation**: if ASV needs a conda env / virtualenv, the activation belongs in the *launch* command (Phase 3), not in `--via` (Phase 4). `--via` only needs to reach the container's filesystem for waiting/reading files; the env is only needed to run `asv` itself.
2. Pick a run directory path **outside the project source tree** (see Phase 1 first-run setup), e.g. `<bench-runs-root>/<YYYYMMDD-HHMMSS>`. This path must be valid **on the benchmark machine** (inside the container if you use one).
3. Launch via the background script, wrapped in your exec prefix. Use the deployment path from Phase 1 (not a project-relative path):

   ```bash
   # Direct SSH
   ssh <ssh-host> 'cd <remote-project-root> && <script-deploy-path>/asv-background.sh \
     "<bench-runs-root>/<timestamp>" <asv-subcommand-and-flags...>'

   # SSH + container + env activation
   ssh <ssh-host> "docker exec <container> bash -lc \
     '<env-activation> && cd <remote-project-root> && \
      <script-deploy-path>/asv-background.sh <bench-runs-root>/<timestamp> \
      <asv-subcommand-and-flags...>'"
   ```

   The `bash -lc` + env-activation wrapper is needed when the exec target (e.g. `docker exec`) defaults to a non-login shell that doesn't load env hooks. If there's no env activation, drop that wrapper and run the script directly.
4. Record two things: the **run directory path as the ASV machine sees it** (for Phase 4/5 `--run-dir`), and the **exec prefix for reaching the ASV machine's filesystem** (for Phase 4 `--via` — this does *not* include env activation, since waiting only does file operations).
5. **Verify the remote HEAD matches the candidate commit.** This is critical: if the remote repo hasn't pulled your latest changes, ASV will benchmark the wrong code and produce a misleading comparison. Run: `<exec-prefix> bash -lc "cd <remote-project-root> && git rev-parse HEAD"` and confirm it matches the candidate commit hash you expect. If it doesn't match, stop and tell the user — the remote needs to be updated (git fetch/checkout/pull) before running ASV.
6. Verify the launch took: use the exec prefix (without `eval`) to check the pid file exists. For example: `ssh <host> docker exec <container> test -f <run-dir>/pid` should succeed within a few seconds. If not, the launch failed — do not proceed to waiting.

You're now done for this phase. The ASV run is running detached.

### Phase 4 — Wait (this is where the tokens get saved)

**Do not poll.** Do not run `ssh ... ps`. Do not run `ssh ... tail run.log` in a loop. Do not spawn a subagent "to check every 60 seconds." Every one of those is a high-reasoning forward pass burning tokens for no progress — and a polling subagent is worse, not better: it's still polling, just relocated.

Instead, make one call to the wait script with the same `--via` prefix and `--run-dir` you recorded in Phase 3:

```bash
./scripts/wait-for-asv.sh \
  --via '<exec-prefix-from-phase-3>' \
  --run-dir '<run-dir-as-asv-machine-sees-it>' \
  [--poll-interval 90] [--timeout 0]
```

Examples:

```bash
# Direct SSH
./scripts/wait-for-asv.sh --via 'ssh <ssh-host>' \
  --run-dir '<remote-project-root>/bench-runs/<timestamp>'

# SSH + container (note the -i, required for stdin/heredoc passthrough)
./scripts/wait-for-asv.sh --via 'ssh <ssh-host> docker exec -i <container>' \
  --run-dir '<remote-project-root>/bench-runs/<timestamp>'
```

The `-i` on `docker exec` is not optional in the container case: `wait-for-asv.sh` feeds its wait-loop script via a heredoc on stdin, and without `-i` docker exec won't read stdin, so the loop never starts and the command hangs. Env activation (conda etc.) is not in `--via` because the wait loop only does `test`/`cat`/`tail` on files — no need for the ASV environment.

What this does: the exec prefix reaches the ASV machine, where a shell loop blocks on the `done` marker (and simultaneously checks pid liveness — if the wrapper process dies without writing `done`, it returns `STATE: wrapper-died` immediately instead of hanging forever). When `done` appears, it prints `RUN_DIR:` + the path and `EXIT_CODE:` + the ASV exit code. It does **not** print the log — the main agent uses `compare-asv.py` for structured results, or dispatches the monitor subagent if it needs the raw log. Returning 300 lines of log on every run would waste tokens.

The ASV exit code is passed through as-is. This matters: `asv continuous` returns exit 1 when it detects a performance change — that is a **valid result**, not a failure. Don't treat exit 1 from ASV as "something went wrong." The script's own exit codes are: 0 = run finished (check the printed ASV exit code for its meaning), 2 = run dir not found, 3 = timed out, 4 = wrapper died.

The `--via` redesign is deliberate. The previous version took a bare `SSH_HOST` and ran the wait loop on the ssh host's filesystem. In containerized setups (`ssh host docker exec container`) the `done` marker and `run.log` live *inside the container* and are invisible from the host — so the wait would either error out or hang forever. `--via` makes the hop chain explicit so every check runs at the right layer. If you find yourself wanting to "just check quickly with a raw ssh+tail," stop: that's the polling anti-pattern, and in a container setup it'll read the wrong layer anyway.

This single step is the difference between the skill being worth it and not.

### Phase 5 — Read the result

**First, check Phase 4's own exit code** (not the ASV exit code printed inside the output):

- **4 (wrapper-died)**: The ASV process was killed before finishing (container restart, OOM, manual kill). The run produced no usable results. Dispatch the monitor subagent (see below) to read the partial log and diagnose, then decide whether to relaunch.
- **3 (timed-out)**: The run exceeded `--timeout`. Either raise the timeout or investigate why ASV is stuck. Dispatch the monitor subagent to check the log tail.
- **2 (run dir not found)**: Shouldn't happen if Phase 3 succeeded; re-verify the path and `--via`.
- **0 (run finished)**: The ASV run completed. The printed ASV exit code tells you what kind of completion — see below.

**When Phase 4 returns 0 (run finished), the ASV exit code can be:**
- `0` — ASV ran to completion with no threshold-crossing change detected (for `asv continuous`) or just finished normally (for `asv run`).
- `1` — `asv continuous` detected a performance change (regression OR improvement). **This is a valid result, not a failure.** Proceed to compare-asv.py to see the details.
- Other non-zero — ASV itself errored (environment failure, build failure, benchmark crash). This is a real failure; dispatch the monitor subagent.

**Normal path (ASV exit 0 or 1): run compare-asv.py.**

```bash
./scripts/compare-asv.py --results-dir <results-dir-on-asv-machine> \
  --baseline <commit-hash> --candidate <commit-hash> \
  [--machine <name>] [--environment <env-name>] \
  [--threshold 5] [--policy no-regression]
```

**Finding the results directory:** ASV stores results in the directory named by `results_dir` in `asv.conf.json` — often `results/` relative to the asv_bench directory, **not** `.asv/results/` (that's a common misconception). Check `asv.conf.json` if unsure. The results directory must be accessible from where you run compare-asv.py; if it's on the remote server, rsync it down or run the script over SSH.

The script prints a markdown table with one row per parameter case (parameterized benchmarks are NOT merged — each parameter combination gets its own row):

```
| benchmark | baseline | candidate | ratio | status |
|-----------|----------|-----------|-------|--------|
| suite.foo(2, 'count') | 16.0 ms | 8.16 ms | 0.51 | IMPROVED ✅ |
| suite.bar(4, 'var') | 46.3 ms | 32.4 ms | 0.70 | PASS ✅ |
```

Exit codes: `0` = all cases pass the policy, `1` = at least one case fails, `2` = couldn't compare (missing results, ambiguous machine/env, commit not found).

The main agent reads this table and the exit code. That's the entire result-reading step for normal runs.

**Failure path (ASV exit non-zero/non-one, or compare-asv.py returns 2, or wrapper-died):**

Something went wrong — environment failure, ASV crash, missing baseline. The raw `run.log` may be long. **Do not read it directly.** Dispatch a low-model subagent:

- Dispatch a **low-model subagent** (the whole point is to not burn high-reasoning tokens on log reading). The exact dispatch method depends on your host agent:
    - **Codex**: spawn the `asv_monitor` custom agent defined in `.codex/agents/asv-monitor.toml` (if that file isn't in the project yet, copy it from `references/codex-setup.md` first). The toml already pins a lightweight model and read-only sandbox, so you don't specify those at dispatch time.
    - **ZCode / Claude Code**: use the `Agent` tool with `model: "haiku"` and `subagent_type: "general-purpose"`.
- Pass the prompt from `references/monitor-prompt.md`, filling in the exec prefix and run directory.
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

- **Continuing a pre-skill workflow after installing the skill mid-session.** If you were already running an ASV task with custom rules in `AGENTS.md` and the skill gets installed mid-flight, "continue" does not mean the skill takes over. Your existing context has a custom driver, a run dir at the wrong layer, and a polling habit — all of which will persist unless you explicitly run Phase 0 and break them. This is the #1 reason the skill appears to "not work" in Codex.
- **Writing your own ASV driver script.** "I'll just write a small `run_focused_asv_*.sh`" is how every regression of this skill starts. Custom drivers reintroduce the exact bugs the skill's scripts fix: log redirected to the wrong layer, no atomic `done` marker, exit code lost. If the skill's script doesn't fit your case, add a flag to it — don't fork the concept.
- **Polling the run from the main agent, or "delegating" polling to a subagent.** This is the anti-pattern the whole skill exists to kill. `sleep 60 && ssh ... tail` in a loop means every minute of a 3-hour run costs a forward pass. A subagent doing the same thing every 60s is *not* cheaper in the way that matters — it's still polling, and it still wakes the main agent to report. Use `wait-for-asv.sh`. One call, blocking, no subagent.
- **Reading the raw ASV log from the main agent.** A full `asv run` log can be tens of thousands of lines. Loading it into the main agent's context is both expensive and unfocused. Use `compare-asv.py` for the structured answer, or dispatch a low-model subagent for failure diagnosis.
- **Checking files at the wrong layer in a container setup.** If ASV runs in `ssh host docker exec container`, then `done`, `run.log`, `exit_code` all live *inside the container*. `ssh host cat /tmp/run.log` reads the host filesystem, not the container's — it'll be empty even though ASV ran fine. Always use the `--via` prefix that reaches the ASV machine, and `--run-dir` as the path inside that machine.
- **Skipping the local fast gate.** ASV runs are hours. Local tests are seconds. Catching a typo at the local stage saves an entire wasted server run. Always run Phase 2.
- **Guessing the SSH host or ASV command.** These vary per project and per run. Wrong host = connection failure, wrong command = wasted run. Ask.
- **Treating `asv continuous` exit 1 as a failure.** `asv continuous` returns exit 1 when it detects a performance change (regression *or* improvement) — that's a valid comparison result, not a crash. Only treat it as a failure if compare-asv.py also can't produce results (exit 2) or the log shows a traceback/build error. The skill's `wait-for-asv.sh` passes the ASV exit code through without judging it; don't second-guess that in the main agent.
- **Retrying blindly on ASV failure.** A non-zero exit code (other than `asv continuous`'s 1) is usually an environment problem (missing dependency, conda env issue, disk full), not a code regression. Read the failure summary and fix the root cause before re-running. Re-running the same broken command 3 times just burns server time.
- **Putting scripts or run directories inside the project source tree.** This pollutes `git status` and complicates PRs, especially for forks of upstream projects. Deploy scripts to a fixed path outside the repo (e.g. `~/.local/share/perf-bench-loop/`), and put run directories outside the repo too (e.g. `~/bench-runs/`).

## References

- `[monitor-prompt.md](references/monitor-prompt.md)` — load this when dispatching the low-model subagent in Phase 5's failure branch. It's the prompt template.
- `[codex-setup.md](references/codex-setup.md)` — load this on first use in Codex. It contains the `.codex/agents/asv-monitor.toml` file to drop into the project so the low-model monitor subagent has a pinned lightweight model and read-only sandbox. ZCode/Claude Code users can ignore this file.
- `scripts/asv-background.sh` — run with no args to see usage. Deploy to a fixed path on the benchmark machine.
- `scripts/wait-for-asv.sh` — run with no args to see usage. Runs locally; reaches the ASV machine via `--via`.
- `scripts/compare-asv.py` — run with `--help` for full options. Runs locally on the results directory (rsync it down or run over SSH).
