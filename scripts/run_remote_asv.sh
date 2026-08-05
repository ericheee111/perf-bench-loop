#!/usr/bin/env bash
#
# run_remote_asv.sh — Unified orchestration: preflight → launch → wait → compare.
#
# One Bash call from the agent. Standard mode blocks until the comparison
# table is ready. --probe mode launches and returns immediately with the
# run directory + exec prefix, so the agent can poll progress with
# probe-asv.sh and run compare-asv.py itself when done.
#
# Sources .perf-bench-loop/config.sh for all project-specific values.
#
# Usage:
#   run_remote_asv.sh --baseline REF --candidate REF --suite NAME [options]
#
# Required:
#   --baseline REF      Baseline commit ref
#   --candidate REF     Candidate commit ref
#   --suite NAME        Named selector group from config (PBL_SUITES_<NAME>)
#
# Options:
#   --benchmark SEL     Focused ASV selector; repeatable, appended to suite
#   --factor NUMBER     ASV comparison factor (overrides config PBL_FACTOR)
#   --no-sync           Skip mirror synchronization (historical diagnostics)
#   --probe             Launch and return immediately; agent polls with
#                       probe-asv.sh and runs compare-asv.py when done
#   --dry-run           Print intended commands without SSH
#   -h, --help          Show this help
#
# Exit status (standard mode):
#   0   Preflight passed, ASV ran, all cases pass the comparison policy.
#   1   Comparison data is reliable but ≥1 case violates the policy.
#   2   Data incomplete/unreliable (expected case missing, ASV exit ≥2).
#   30  Preflight failed.
#   64  Usage/config error.
#
# Exit status (--probe mode):
#   0   Launched successfully. Agent must poll and run compare-asv.py.
#   30  Preflight failed.
#   64  Usage/config error.
#
set -euo pipefail

baseline=""
candidate=""
suite=""
factor_override=""
sync_remote=1
probe_mode=0
dry_run=0
custom_benchmarks=()

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 64
}

need_value() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline)  need_value "$@"; baseline="$2"; shift 2 ;;
        --candidate) need_value "$@"; candidate="$2"; shift 2 ;;
        --suite)     need_value "$@"; suite="$2"; shift 2 ;;
        --benchmark) need_value "$@"; custom_benchmarks+=("$2"); shift 2 ;;
        --factor)    need_value "$@"; factor_override="$2"; shift 2 ;;
        --no-sync)   sync_remote=0; shift ;;
        --probe)     probe_mode=1; shift ;;
        --dry-run)   dry_run=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$baseline" ] || die "--baseline is required"
[ -n "$candidate" ] || die "--candidate is required"
[[ "$baseline" =~ ^[A-Za-z0-9][A-Za-z0-9._/@+~^:-]*$ ]] || die "unsafe baseline ref: $baseline"
[[ "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9._/@+~^:-]*$ ]] || die "unsafe candidate ref: $candidate"

# ── Load config ────────────────────────────────────────────────────────
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a Git repository"
config_file="$root/.perf-bench-loop/config.sh"
[ -f "$config_file" ] || die "config not found: $config_file
  Copy config.example.sh from the perf-bench-loop repo to .perf-bench-loop/config.sh
  and fill in your project's values."

# shellcheck disable=SC1090
source "$config_file"

[ -n "${PBL_BRANCH:-}" ] || die "config PBL_BRANCH is empty"
[ -n "${PBL_REMOTE:-}" ] || die "config PBL_REMOTE is empty"
[ -n "${PBL_SSH_HOST:-}" ] || die "config PBL_SSH_HOST is empty"
[ -n "${PBL_REMOTE_REPO:-}" ] || die "config PBL_REMOTE_REPO is empty"
[ -n "${PBL_ASV_DIR:-}" ] || die "config PBL_ASV_DIR is empty"
[ -n "${PBL_LOG_DIR:-}" ] || die "config PBL_LOG_DIR is empty"
[ -n "${PBL_FACTOR:-}" ] || die "config PBL_FACTOR is empty"

[ "${PBL_SYNC_REMOTE:-1}" == "0" ] && sync_remote=0

# ── Resolve suite selectors ────────────────────────────────────────────
benchmarks=()
if [ ${#custom_benchmarks[@]} -gt 0 ]; then
    benchmarks=("${custom_benchmarks[@]}")
fi

if [ -n "$suite" ]; then
    suite_var="PBL_SUITES_$(echo "$suite" | tr '[:lower:]' '[:upper:]')"
    if ! declare -p "$suite_var" >/dev/null 2>&1; then
        die "suite '$suite' not found in config: expected array $suite_var"
    fi
    eval "suite_benchmarks=(\"\${${suite_var}[@]}\")"
    if [ ${#suite_benchmarks[@]} -eq 0 ]; then
        die "suite '$suite' ($suite_var) is empty in config"
    fi
    benchmarks+=("${suite_benchmarks[@]}")
fi

[ ${#benchmarks[@]} -gt 0 ] || die "no benchmarks selected: use --suite NAME or --benchmark SEL"

factor="$factor_override"
[ -n "$factor" ] || factor="$PBL_FACTOR"
[[ "$factor" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--factor must be numeric: $factor"

threshold="${PBL_THRESHOLD:-5}"
policy="${PBL_POLICY:-no-regression}"
container="${PBL_CONTAINER:-}"
repo="$PBL_REMOTE_REPO"
asv_dir="$PBL_ASV_DIR"
log_dir="$PBL_LOG_DIR"

# ── Build exec prefix ──────────────────────────────────────────────────
if [ -n "$container" ]; then
    exec_prefix="ssh $PBL_SSH_HOST docker exec -i $container"
    exec_prefix_args=(ssh "$PBL_SSH_HOST" docker exec -i "$container")
else
    exec_prefix="ssh $PBL_SSH_HOST"
    exec_prefix_args=(ssh "$PBL_SSH_HOST")
fi

# ── Print config summary ───────────────────────────────────────────────
printf 'mode=%s\n' "$([ "$probe_mode" -eq 1 ] && printf probe || printf standard)"
printf 'exec_prefix=%s\n' "$exec_prefix"
printf 'repo=%q asv_dir=%q\n' "$repo" "$asv_dir"
printf 'baseline=%q candidate=%q factor=%q\n' "$baseline" "$candidate" "$factor"
printf 'threshold=%q policy=%q\n' "$threshold" "$policy"
printf 'benchmarks:'
printf ' %q' "${benchmarks[@]}"
printf '\n'

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' 'dry-run: no SSH command executed'
    exit 0
fi

# Locate sibling scripts (same directory as this script).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preflight_script="$script_dir/preflight.sh"
wait_script="$script_dir/wait-for-asv.sh"

# ── Helper: find remote script dir ─────────────────────────────────────
# Returns the remote directory where perf-bench-loop scripts are deployed.
remote_script_dir() {
    "${exec_prefix_args[@]}" bash -s <<'REMOTE_FIND'
        for d in "$HOME/.local/share/perf-bench-loop" "$HOME/tools/perf-bench-loop" /opt/perf-bench-loop; do
            if [ -f "$d/asv-background.sh" ] && [ -f "$d/compare-asv.py" ]; then
                printf "%s\n" "$d"
                exit 0
            fi
        done
        exit 1
REMOTE_FIND
}

# ── Step 1: Preflight ──────────────────────────────────────────────────
printf 'STEP: preflight START\n'
preflight_args=(--baseline "$baseline" --candidate "$candidate")
[ "$sync_remote" -eq 0 ] && preflight_args+=(--no-sync)

set +e
bash "$preflight_script" "${preflight_args[@]}"
preflight_rc=$?
set -e

if [ "$preflight_rc" -ne 0 ]; then
    printf 'STEP: preflight FAIL rc=%d\n' "$preflight_rc" >&2
    exit "$preflight_rc"
fi
printf 'STEP: preflight PASS\n'

# ── Step 2: Resolve commits + find results dir ─────────────────────────
printf 'STEP: resolve START\n'

# Resolve baseline/candidate to full SHAs on the remote, and find results_dir.
# Single round-trip: one SSH call captures both.
# Use printf %q for safe SSH argv serialization.
printf -v resolve_cmd '%q ' bash -s -- "$repo" "$asv_dir" "$baseline" "$candidate"
resolve_cmd=${resolve_cmd% }

set +e
remote_info=$("${exec_prefix_args[@]}" "$resolve_cmd" <<'REMOTE_RESOLVE'
set -euo pipefail
repo="$1"; asv_dir="$2"; baseline="$3"; candidate="$4"

b=$(git -C "$repo" rev-parse "${baseline}^{commit}" 2>/dev/null || true)
c=$(git -C "$repo" rev-parse "${candidate}^{commit}" 2>/dev/null || true)
[ -n "$b" ] || { printf 'error: cannot resolve baseline %s\n' "$baseline" >&2; exit 2; }
[ -n "$c" ] || { printf 'error: cannot resolve candidate %s\n' "$candidate" >&2; exit 2; }

conf="$asv_dir/asv.conf.json"
[ -f "$conf" ] || { printf 'error: asv.conf.json missing at %s\n' "$conf" >&2; exit 2; }
rd=$(python3 -c "import json; print(json.load(open('$conf')).get('results_dir','results'))" 2>/dev/null || echo 'results')
case "$rd" in
    /*) ;;
    *)  rd="$asv_dir/$rd" ;;
esac

printf 'BASELINE_SHA=%s\n' "$b"
printf 'CANDIDATE_SHA=%s\n' "$c"
printf 'RESULTS_DIR=%s\n' "$rd"
REMOTE_RESOLVE
)
resolve_rc=$?
set -e

if [ "$resolve_rc" -ne 0 ]; then
    printf 'STEP: resolve FAIL rc=%d\n' "$resolve_rc" >&2
    exit 2
fi

# Parse the output.
baseline_sha=$(echo "$remote_info" | grep '^BASELINE_SHA=' | cut -d= -f2)
candidate_sha=$(echo "$remote_info" | grep '^CANDIDATE_SHA=' | cut -d= -f2)
results_dir=$(echo "$remote_info" | grep '^RESULTS_DIR=' | cut -d= -f2)

[ -n "$baseline_sha" ] || { printf 'STEP: resolve FAIL (empty baseline_sha)\n' >&2; exit 2; }
[ -n "$candidate_sha" ] || { printf 'STEP: resolve FAIL (empty candidate_sha)\n' >&2; exit 2; }
[ -n "$results_dir" ] || { printf 'STEP: resolve FAIL (empty results_dir)\n' >&2; exit 2; }

printf 'STEP: resolve PASS baseline=%s candidate=%s results_dir=%s\n' \
    "$baseline_sha" "$candidate_sha" "$results_dir"

# ── Step 3: Find remote script dir ─────────────────────────────────────
set +e
rscript_dir=$(remote_script_dir)
find_rc=$?
set -e

if [ "$find_rc" -ne 0 ] || [ -z "$rscript_dir" ]; then
    printf 'error: perf-bench-loop scripts not deployed on benchmark machine.\n' >&2
    printf '  Deploy asv-background.sh, compare-asv.py, validate-asv-selection.py,\n' >&2
    printf '  expected_cases.py to one of:\n' >&2
    printf '    $HOME/.local/share/perf-bench-loop/\n' >&2
    printf '    $HOME/tools/perf-bench-loop/\n' >&2
    printf '    /opt/perf-bench-loop/\n' >&2
    exit 2
fi
printf 'remote_script_dir=%s\n' "$rscript_dir"

# ── Step 4: Validate selectors ─────────────────────────────────────────
printf 'STEP: validate_selectors START\n'

# Build the ASV args as an array so each -b selector is a separate argv
# element. Passing them as a single space-joined string would break under
# printf %q (escaped spaces prevent word-splitting on the remote).
asv_cmd_args=(continuous --factor "$factor" "$baseline" "$candidate")
for b in "${benchmarks[@]}"; do
    asv_cmd_args+=(-b "$b")
done

bench_runs_root="$log_dir/bench-runs"
timestamp=$(date +%Y%m%d_%H%M%S)
run_dir="$bench_runs_root/${timestamp}"
expected_cases_file="$bench_runs_root/${timestamp}.expected-cases.jsonl"

# Pass each ASV arg as a separate positional parameter. The remote script
# collects them via "$@" after the first 3 fixed args.
printf -v validate_cmd '%q ' \
    bash -s -- \
    "$rscript_dir" "$results_dir" "$expected_cases_file" \
    "${asv_cmd_args[@]}"
validate_cmd=${validate_cmd% }

set +e
"${exec_prefix_args[@]}" "$validate_cmd" <<'REMOTE_VALIDATE'
set -euo pipefail
rscript_dir="$1"; results_dir="$2"; expected_cases_file="$3"; shift 3
# Remaining args ($@) are the ASV subcommand + flags (continuous --factor ... -b sel ...).

bj="$results_dir/benchmarks.json"
if [ ! -f "$bj" ]; then
    printf 'benchmarks.json not found at %s; refreshing...\n' "$bj" >&2
    asv run --bench just-discover 2>/dev/null || true
    [ -f "$bj" ] || { printf 'error: benchmarks.json still missing\n' >&2; exit 2; }
fi

# Run the validator. It imports expected_cases.py from its own directory.
# Pass ASV args via "$@" so -b selectors are parsed correctly.
cd "$rscript_dir"
python3 ./validate-asv-selection.py \
    --benchmarks-file "$bj" \
    --output-file "$expected_cases_file" \
    -- "$@"
REMOTE_VALIDATE
validate_rc=$?
set -e

if [ "$validate_rc" -ne 0 ]; then
    printf 'STEP: validate_selectors FAIL rc=%d\n' "$validate_rc" >&2
    exit 2
fi
printf 'STEP: validate_selectors PASS\n'
printf 'expected_cases_file=%s\n' "$expected_cases_file"

# ── Step 5: Launch ASV in background ───────────────────────────────────
printf 'STEP: launch START\n'

# Create run directory on remote (must be empty for asv-background.sh).
"${exec_prefix_args[@]}" bash -s -- "$run_dir" <<'REMOTE_MKDIR'
mkdir -p "$1"
REMOTE_MKDIR
set +e
"${exec_prefix_args[@]}" bash -s -- "$run_dir" <<'REMOTE_CHECK_EMPTY'
[ -z "$(ls -A "$1" 2>/dev/null)" ]
REMOTE_CHECK_EMPTY
empty_rc=$?
set -e
if [ "$empty_rc" -ne 0 ]; then
    printf 'STEP: launch FAIL (run dir not empty: %s)\n' "$run_dir" >&2
    exit 2
fi

# Build env activation prefix for the remote ASV command.
env_activation=""
if [ -n "${PBL_CONDA_EXE:-}" ]; then
    env_activation+="source \$(${PBL_CONDA_EXE} info --base)/etc/profile.d/conda.sh && conda activate ${PBL_CONDA_ENV:-} && "
fi
if [ -n "${PBL_TOOLCHAIN_ENABLE:-}" ]; then
    env_activation+="source ${PBL_TOOLCHAIN_ENABLE} && "
fi
for exp in "${PBL_ENV_EXPORTS[@]:-}"; do
    [ -n "$exp" ] && env_activation+="export $exp && "
done

# Build ASV command args for asv-background.sh (it prepends `asv`).
# We pass them as positional args to avoid quoting issues through SSH.
asv_cmd_args=(continuous --factor "$factor" "$baseline" "$candidate")
for b in "${benchmarks[@]}"; do
    asv_cmd_args+=(-b "$b")
done

# Join env exports with ',' (survives printf %q + SSH, unlike spaces).
env_exports_str="${PBL_ENV_EXPORTS[*]:-}"
env_exports_str="${env_exports_str// /,}"

# Launch via remote asv-background.sh, with env activation wrapper.
# All parameters passed as positional args to avoid SSH quoting issues.
# Build printf %q-escaped command string for the remote bash.
printf -v launch_cmd '%q ' \
    bash -s -- \
    "$asv_dir" "$rscript_dir" "$run_dir" \
    "${PBL_CONDA_EXE:-}" "${PBL_CONDA_ENV:-}" \
    "${PBL_TOOLCHAIN_ENABLE:-}" \
    "$env_exports_str" \
    "${asv_cmd_args[@]}"
launch_cmd=${launch_cmd% }

set +e
"${exec_prefix_args[@]}" "$launch_cmd" <<'REMOTE_LAUNCH'
set -euo pipefail
asv_dir="$1"; shift
rscript_dir="$1"; shift
run_dir="$1"; shift
conda_exe="$1"; shift
conda_env="$1"; shift
toolchain_enable="$1"; shift
env_exports_str="$1"; shift
# Remaining args are the ASV subcommand + flags.

# Activate env (ephemeral).
if [ -n "$conda_exe" ]; then
    conda_base=$("$conda_exe" info --base 2>/dev/null)
    source "$conda_base/etc/profile.d/conda.sh"
    conda activate "$conda_env"
fi
if [ -n "$toolchain_enable" ]; then
    source "$toolchain_enable"
fi
# Export env vars (comma-separated, split safely).
if [ -n "$env_exports_str" ]; then
    IFS=',' read -ra env_exports <<< "$env_exports_str"
    for exp in "${env_exports[@]}"; do
        export "$exp"
    done
fi

cd "$asv_dir"
bash "$rscript_dir/asv-background.sh" "$run_dir" "$@"
REMOTE_LAUNCH
launch_rc=$?
set -e

if [ "$launch_rc" -ne 0 ]; then
    printf 'STEP: launch FAIL rc=%d\n' "$launch_rc" >&2
    exit 2
fi
printf 'STEP: launch PASS\n'
printf 'run_dir=%s\n' "$run_dir"

# ── Step 6a: Probe mode — return immediately ───────────────────────────
if [ "$probe_mode" -eq 1 ]; then
    printf '\nPROBE_MODE_ACTIVE\n'
    printf 'RUN_DIR: %s\n' "$run_dir"
    printf 'VIA: %s\n' "$exec_prefix"
    printf 'EXPECTED_CASES_FILE: %s\n' "$expected_cases_file"
    printf 'RESULTS_DIR: %s\n' "$results_dir"
    printf 'BASELINE: %s\n' "$baseline_sha"
    printf 'CANDIDATE: %s\n' "$candidate_sha"
    printf '\n# Progress probe:\n'
    printf "probe-asv.sh --via '%s' \\\n" "$exec_prefix"
    printf "             --run-dir '%s'\n" "$run_dir"
    printf '\n# When STATE: done, run compare:\n'
    printf "compare-asv.py --results-dir '%s' \\\n" "$results_dir"
    printf "               --baseline %s --candidate %s \\\n" "$baseline_sha" "$candidate_sha"
    printf "               --expected-cases-file '%s' \\\n" "$expected_cases_file"
    printf "               --threshold %s --policy %s\n" "$threshold" "$policy"
    exit 0
fi

# ── Step 6b: Standard mode — wait for completion ───────────────────────
printf 'STEP: wait START\n'
set +e
"$wait_script" --via "$exec_prefix" --run-dir "$run_dir"
wait_rc=$?
set -e

if [ "$wait_rc" -eq 4 ]; then
    printf 'STEP: wait FAIL (wrapper-died)\n' >&2
    printf 'ASV_FAILED exit=wrapper-died run_dir=%s\n' "$run_dir"
    printf 'Dispatch monitor subagent to read %s/run.log\n' "$run_dir"
    exit 2
fi
if [ "$wait_rc" -eq 3 ]; then
    printf 'STEP: wait FAIL (timed-out)\n' >&2
    exit 2
fi
if [ "$wait_rc" -ne 0 ]; then
    printf 'STEP: wait FAIL rc=%d\n' "$wait_rc" >&2
    exit 2
fi

# Read ASV exit code from the remote.
set +e
printf -v read_cmd '%q ' bash -s -- "$run_dir"
read_cmd=${read_cmd% }
asv_exit=$("${exec_prefix_args[@]}" "$read_cmd" <<'REMOTE_READ'
cat "$1/exit_code" 2>/dev/null
REMOTE_READ
)
read_rc=$?
set -e

if [ "$read_rc" -ne 0 ] || ! echo "$asv_exit" | grep -qE '^-?[0-9]+$'; then
    printf 'STEP: wait FAIL (cannot read exit_code)\n' >&2
    exit 2
fi
printf 'STEP: wait PASS asv_exit=%s\n' "$asv_exit"

# ASV exit 0 or 1 = valid result, proceed to compare.
# ASV exit ≥2 = failure.
if [ "$asv_exit" -ge 2 ]; then
    printf 'STEP: compare SKIP (ASV failed exit=%d)\n' "$asv_exit" >&2
    printf 'ASV_FAILED exit=%d run_dir=%s\n' "$asv_exit" "$run_dir"
    printf 'Dispatch monitor subagent to read %s/run.log\n' "$run_dir"
    exit 2
fi

# ── Step 7: Compare results ────────────────────────────────────────────
printf 'STEP: compare START\n'

# Run compare-asv.py on the remote (it needs access to the results dir).
printf -v compare_cmd '%q ' \
    bash -s -- \
    "$rscript_dir" "$results_dir" "$baseline_sha" "$candidate_sha" \
    "$expected_cases_file" "$threshold" "$policy"
compare_cmd=${compare_cmd% }

set +e
"${exec_prefix_args[@]}" "$compare_cmd" <<'REMOTE_COMPARE'
set -euo pipefail
rscript_dir="$1"; shift
results_dir="$1"; shift
baseline="$1"; shift
candidate="$1"; shift
expected_cases_file="$1"; shift
threshold="$1"; shift
policy="$1"; shift

cd "$rscript_dir"
python3 ./compare-asv.py \
    --results-dir "$results_dir" \
    --baseline "$baseline" \
    --candidate "$candidate" \
    --expected-cases-file "$expected_cases_file" \
    --threshold "$threshold" \
    --policy "$policy"
REMOTE_COMPARE
compare_rc=$?
set -e

printf 'STEP: compare DONE rc=%d\n' "$compare_rc"

# Pass through compare-asv.py's exit code (0=pass, 1=policy violation, 2=incomplete).
exit "$compare_rc"
