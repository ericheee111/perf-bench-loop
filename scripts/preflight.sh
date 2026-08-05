#!/usr/bin/env bash
#
# preflight.sh — Config-driven remote environment validation.
#
# Sources .perf-bench-loop/config.sh, then:
#   1. [if PBL_SYNC_REMOTE==1] Aligns the remote validation mirror.
#   2. Validates baseline/candidate commits exist remotely.
#   3. Activates Conda + toolchain ephemerally (never writes persistent config).
#   4. Validates GCC version, architecture, required tools.
#   5. Prints PREFLIGHT_COMPLETE.
#
# Does NOT run ASV. Use run_remote_asv.sh (which calls this internally) or
# call this standalone for environment-only checks.
#
# Usage:
#   preflight.sh --baseline REF --candidate REF [--no-sync] [--dry-run]
#
# Options:
#   --baseline REF    Baseline commit ref (required)
#   --candidate REF   Candidate commit ref (required)
#   --no-sync         Skip mirror synchronization (historical diagnostics)
#   --dry-run         Print config and intended actions without SSH
#   -h, --help        Show this help
#
# Exit status:
#   0  Preflight passed.
#   2  Config or argument validation failure.
#   20 SSH/docker transport failure.
#   30 Preflight failure (dirty remote, missing commit, wrong GCC, etc.).
#   64 Usage error.
#
set -euo pipefail

baseline=""
candidate=""
sync_remote=1
dry_run=0

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

need_value() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline)  need_value "$@"; baseline="$2"; shift 2 ;;
        --candidate) need_value "$@"; candidate="$2"; shift 2 ;;
        --no-sync)   sync_remote=0; shift ;;
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

branch="$PBL_BRANCH"
remote_name="$PBL_REMOTE"
container="${PBL_CONTAINER:-}"
repo="$PBL_REMOTE_REPO"
asv_dir="$PBL_ASV_DIR"
log_dir="$PBL_LOG_DIR"

[ "${PBL_SYNC_REMOTE:-1}" == "0" ] && sync_remote=0

# ── Build exec prefix ──────────────────────────────────────────────────
if [ -n "$container" ]; then
    exec_prefix_args=(ssh "$PBL_SSH_HOST" docker exec -i "$container")
else
    exec_prefix_args=(ssh "$PBL_SSH_HOST")
fi

# ── Print config summary ───────────────────────────────────────────────
printf 'mode=%s\n' "$([ "$dry_run" -eq 1 ] && printf dry-run || printf preflight)"
printf 'exec_prefix=%s\n' "${exec_prefix_args[*]}"
printf 'repo=%q asv_dir=%q log_dir=%q\n' "$repo" "$asv_dir" "$log_dir"
printf 'conda_env=%q conda_exe=%q\n' "${PBL_CONDA_ENV:-}" "${PBL_CONDA_EXE:-}"
printf 'toolchain_enable=%q\n' "${PBL_TOOLCHAIN_ENABLE:-}"
printf 'expected_gcc_major=%q expected_arch=%q\n' "${PBL_EXPECTED_GCC_MAJOR:-}" "${PBL_EXPECTED_ARCH:-}"
printf 'remote=%q branch=%q sync_remote=%q\n' "$remote_name" "$branch" "$sync_remote"
printf 'baseline=%q candidate=%q\n' "$baseline" "$candidate"

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' 'dry-run: no SSH command executed'
    exit 0
fi

command -v ssh >/dev/null 2>&1 || die "ssh executable not found"

# ── Run remote preflight ───────────────────────────────────────────────
# Config values are passed as positional argv to the remote bash script.
# Arrays (PBL_ENV_EXPORTS, PBL_REQUIRED_TOOLS) are joined with ',' (not
# spaces or ';') so they survive SSH argv serialization without word-
# splitting. printf %q does not escape ',', making it safe end-to-end.
env_exports_str="${PBL_ENV_EXPORTS[*]:-}"
env_exports_str="${env_exports_str// /,}"
required_tools_str="${PBL_REQUIRED_TOOLS[*]:-}"
required_tools_str="${required_tools_str// /,}"

set +e
# Build the remote command with printf %q so every argument is shell-escaped.
# This is critical for arguments containing '=' (like env exports) — SSH
# would otherwise treat "VAR=value" as an env-var assignment instead of a
# positional parameter.
printf -v remote_cmd '%q ' \
    bash -s -- \
    "$repo" "$asv_dir" "$log_dir" \
    "${PBL_CONDA_EXE:-}" "${PBL_CONDA_ENV:-}" \
    "${PBL_TOOLCHAIN_ENABLE:-}" \
    "${PBL_EXPECTED_GCC_MAJOR:-}" "${PBL_EXPECTED_ARCH:-}" \
    "$env_exports_str" "$required_tools_str" \
    "$remote_name" "$branch" "$sync_remote" \
    "$baseline" "$candidate"
remote_cmd=${remote_cmd% }

"${exec_prefix_args[@]}" "$remote_cmd" <<'REMOTE'
set -euo pipefail

repo=$1; shift
asv_dir=$1; shift
log_dir=$1; shift
conda_exe=$1; shift
conda_env=$1; shift
toolchain_enable=$1; shift
expected_gcc_major=$1; shift
expected_arch=$1; shift
env_exports_str=$1; shift
required_tools_str=$1; shift
remote_name=$1; shift
branch=$1; shift
sync_remote=$1; shift
baseline=$1; shift
candidate=$1; shift

# Re-split ','-joined arrays (separator chosen to survive printf %q + SSH).
env_exports=()
[ -n "$env_exports_str" ] && IFS=',' read -ra env_exports <<< "$env_exports_str"
required_tools=()
[ -n "$required_tools_str" ] && IFS=',' read -ra required_tools <<< "$required_tools_str"

fail() {
    printf 'PREFLIGHT_FAIL: %s\n' "$*" >&2
    exit 30
}

pass() {
    printf 'PREFLIGHT_PASS: %s\n' "$*"
}

[ -d "$repo" ] || fail "repository directory missing: $repo"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || fail "not a Git repository: $repo"
pass "Git repository"

[ -d "$asv_dir" ] || fail "ASV directory missing: $asv_dir"
pass "ASV directory"

# ── Mirror synchronization ─────────────────────────────────────────────
if [ "$sync_remote" == "1" ]; then
    # Check for tracked-file modifications only. Untracked files (??) are
    # allowed — they don't interfere with git switch/pull and may be
    # project-local helper scripts the user keeps in the validation mirror.
    # `|| true` prevents set -e from exiting when grep finds no matches
    # (i.e. all files are untracked, which is the clean case).
    status_before=$(git -C "$repo" status --porcelain | grep -v '^??' || true)
    [ -z "$status_before" ] || fail "test repository is dirty; refusing fetch/switch/pull"
    git -C "$repo" remote get-url "$remote_name" >/dev/null 2>&1 || \
        fail "Git remote unavailable: $remote_name"

    git -C "$repo" fetch --prune "$remote_name" || fail "git fetch failed"
    remote_ref="refs/remotes/$remote_name/$branch"
    git -C "$repo" show-ref --verify --quiet "$remote_ref" || \
        fail "remote branch unavailable: $remote_name/$branch"

    sync_timestamp=$(date +%Y%m%d_%H%M%S)
    preserve_if_unreachable() {
        label=$1
        commit=$2
        [ -n "$commit" ] || return 0
        if git -C "$repo" merge-base --is-ancestor "$commit" "$remote_ref"; then
            return 0
        fi
        short=$(git -C "$repo" rev-parse --short=12 "$commit") || \
            fail "cannot abbreviate backup commit: $commit"
        backup_ref="refs/agent-backups/$branch/${sync_timestamp}-${label}-${short}"
        git -C "$repo" update-ref "$backup_ref" "$commit" || \
            fail "cannot preserve divergent commit: $commit"
        printf 'REMOTE_BACKUP_CREATED ref=%s commit=%s\n' "$backup_ref" "$commit"
    }

    current_head=$(git -C "$repo" rev-parse HEAD)
    preserve_if_unreachable head "$current_head"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        local_branch_head=$(git -C "$repo" rev-parse "refs/heads/$branch")
        if [ "$local_branch_head" != "$current_head" ]; then
            preserve_if_unreachable branch "$local_branch_head"
        fi
    fi

    git -C "$repo" switch -C "$branch" "$remote_name/$branch" || \
        fail "cannot align validation mirror branch: $branch"
    git -C "$repo" branch --set-upstream-to="$remote_name/$branch" "$branch" >/dev/null 2>&1 || \
        fail "cannot set tracking branch: $remote_name/$branch"
    git -C "$repo" pull --ff-only "$remote_name" "$branch" || \
        fail "git pull --ff-only failed"
    printf 'REMOTE_SYNC_COMPLETE remote=%s branch=%s\n' "$remote_name" "$branch"
else
    pass "remote synchronization disabled by --no-sync"
fi

# ── Commit validation ──────────────────────────────────────────────────
git -C "$repo" cat-file -e "${baseline}^{commit}" 2>/dev/null || \
    fail "baseline commit unavailable: $baseline"
git -C "$repo" cat-file -e "${candidate}^{commit}" 2>/dev/null || \
    fail "candidate commit unavailable: $candidate"

if [ "$sync_remote" == "1" ]; then
    pulled_head=$(git -C "$repo" rev-parse HEAD)
    candidate_commit=$(git -C "$repo" rev-parse "${candidate}^{commit}")
    [ "$pulled_head" == "$candidate_commit" ] || \
        fail "pulled $branch HEAD ($pulled_head) does not equal candidate ($candidate_commit)"
    [ -z "$(git -C "$repo" status --porcelain | grep -v '^??' || true)" ] || \
        fail "test repository became dirty after synchronization"
    pass "test repository HEAD equals candidate"
fi
pass "baseline and candidate commits"

# ── Environment activation (ephemeral) ─────────────────────────────────
if [ -n "$conda_exe" ]; then
    [ -x "$conda_exe" ] || fail "Conda executable missing or not executable: $conda_exe"
    conda_base=$("$conda_exe" info --base 2>/dev/null) || fail "cannot determine Conda base"
    conda_sh="$conda_base/etc/profile.d/conda.sh"
    [ -f "$conda_sh" ] || fail "Conda initialization script missing: $conda_sh"
    # shellcheck disable=SC1090
    source "$conda_sh"
    [ -n "$conda_env" ] || fail "PBL_CONDA_EXE set but PBL_CONDA_ENV empty"
    conda activate "$conda_env" || fail "cannot activate Conda environment: $conda_env"
    [ -n "${CONDA_PREFIX:-}" ] || fail "Conda activation did not set CONDA_PREFIX"
    pass "Conda environment: $CONDA_PREFIX"
fi

if [ -n "$toolchain_enable" ]; then
    [ -f "$toolchain_enable" ] || fail "toolchain enable script missing: $toolchain_enable"
    # Activate after Conda so Conda cannot overwrite the compiler PATH.
    # shellcheck disable=SC1090
    source "$toolchain_enable"
    pass "ephemeral compiler-toolchain activation"
fi

for exp in "${env_exports[@]}"; do
    export "$exp"
done

# ── Compiler validation ────────────────────────────────────────────────
if [ -n "$expected_gcc_major" ]; then
    cc=$(command -v gcc || true)
    [ -n "$cc" ] || fail "gcc is unavailable"
    cc_version=$("$cc" -dumpfullversion -dumpversion 2>/dev/null || true)
    [ -n "$cc_version" ] || fail "cannot read GCC version from $cc"
    cc_major=${cc_version%%.*}
    [ "$cc_major" == "$expected_gcc_major" ] || \
        fail "GCC major mismatch: expected $expected_gcc_major, got $cc_version"
    pass "GCC $cc_version: $cc"
fi

# ── Architecture validation ────────────────────────────────────────────
if [ -n "$expected_arch" ]; then
    arch=$(uname -m)
    [ "$arch" == "$expected_arch" ] || \
        fail "architecture mismatch: expected $expected_arch, got $arch"
    pass "architecture: $arch"
fi

# ── Required tools validation ──────────────────────────────────────────
for tool in "${required_tools[@]}"; do
    if [ "$tool" == "build" ]; then
        python -c 'import build' >/dev/null 2>&1 || fail "Python package 'build' is unavailable"
    else
        command -v "$tool" >/dev/null 2>&1 || fail "$tool is unavailable in the activated environment"
    fi
done
[ "${#required_tools[@]}" -gt 0 ] && pass "required tools: ${required_tools[*]}"

printf 'python=%s\n' "$(command -v python)"
python --version
printf 'asv=%s\n' "$(command -v asv)"
asv --version
printf 'remote_head=%s\n' "$(git -C "$repo" rev-parse HEAD)"
printf 'remote_status_begin\n'
git -C "$repo" status --short
printf 'remote_status_end\n'
printf 'PREFLIGHT_COMPLETE\n'
REMOTE
rc=$?
set -e

exit "$rc"
