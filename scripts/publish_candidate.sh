#!/usr/bin/env bash
#
# publish_candidate.sh — Config-driven publication gate.
#
# Sources .perf-bench-loop/config.sh from the project root, then:
#   1. Validates branch, remote, Git identity, no pre-staged changes.
#   2. Refuses protected paths (PBL_PROTECTED_PATHS) even if passed via --path.
#   3. Stages only explicit --path arguments (literal pathspecs).
#   4. Commits and non-force-pushes to PBL_REMOTE/PBL_BRANCH.
#   5. [if PBL_CONTAINER set] Aligns the remote validation mirror via SSH+docker.
#   6. Verifies remote HEAD == candidate.
#
# Never runs `git config`, amends a published candidate, or force-pushes.
# Never stages local Agent configuration or protected paths.
#
# Usage:
#   publish_candidate.sh --message "PERF: describe" --path foo.py [--path bar.pyx] [--dry-run]
#
# Options:
#   --message MSG    Commit message (required)
#   --path PATH      Explicit repo-relative path to stage (required, repeatable)
#   --dry-run        Validate and print intended actions without mutation
#   -h, --help       Show this help
#
# Exit status:
#   0  Candidate published and mirror aligned (or dry-run passed).
#   2  Validation failure (wrong branch, dirty, protected path, etc.).
#   20 SSH/docker transport failure during mirror alignment.
#   30 Remote mirror alignment failure (dirty remote, pull failed, mismatch).
#   64 Usage error.
#
set -euo pipefail

message=""
dry_run=0
paths=()

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
        --message) need_value "$@"; message="$2"; shift 2 ;;
        --path)    need_value "$@"; paths+=("$2"); shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$message" ] || die "--message is required"
[ "${#paths[@]}" -gt 0 ] || die "at least one --path is required"

# ── Load config ────────────────────────────────────────────────────────
# Find project root (nearest .git), then load .perf-bench-loop/config.sh.
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a Git repository"
config_file="$root/.perf-bench-loop/config.sh"
[ -f "$config_file" ] || die "config not found: $config_file
  Copy config.example.sh from the perf-bench-loop repo to .perf-bench-loop/config.sh
  and fill in your project's values."

# shellcheck disable=SC1090
source "$config_file"

# Validate required config fields.
[ -n "${PBL_BRANCH:-}" ] || die "config PBL_BRANCH is empty"
[ -n "${PBL_REMOTE:-}" ] || die "config PBL_REMOTE is empty"
[ -n "${PBL_SSH_HOST:-}" ] || die "config PBL_SSH_HOST is empty"
[ -n "${PBL_REMOTE_REPO:-}" ] || die "config PBL_REMOTE_REPO is empty"

branch="$PBL_BRANCH"
remote_name="$PBL_REMOTE"
# Protected paths: default to empty array if not set.
protected_paths=("${PBL_PROTECTED_PATHS[@]}")

# Validate branch/remote names (defensive against config typos).
[[ "$remote_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unsafe remote name: $remote_name"
[[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "unsafe branch: $branch"

# ── Check protected paths ──────────────────────────────────────────────
is_protected() {
    local p="$1"
    for prot in "${protected_paths[@]}"; do
        # Match as path prefix: "tools/agent" protects "tools/agent/foo.sh".
        if [[ "$p" == "$prot" || "$p" == "$prot"/* ]]; then
            return 0
        fi
    done
    return 1
}

pathspecs=()
for path in "${paths[@]}"; do
    # Strip trailing CR (Windows CRLF defense).
    path=$(printf '%s' "$path" | sed 's/\r$//')
    [ -n "$path" ] || die "empty path after CR stripping"
    # Reject unsafe pathspecs.
    [ "$path" != "-" ] || die "unsafe path: $path"
    [ "$path" != "." ] || die "path must be explicit, not '.'"
    [[ ! "$path" == /* ]] || die "path must be repo-relative, not absolute: $path"
    [[ ! "$path" == ../* ]] || die "path must not escape repo: $path"
    [[ ! "$path" == */../* ]] || die "path must not escape repo: $path"
    # Check protected paths.
    if is_protected "$path"; then
        die "protected path cannot be published: $path"
    fi
    pathspecs+=(":(literal)$path")
done

# ── Validate git state ─────────────────────────────────────────────────
current_branch=$(git -C "$root" branch --show-current)
[ "$current_branch" == "$branch" ] || \
    die "current branch must be $branch, got ${current_branch:-detached HEAD}"

git -C "$root" remote get-url "$remote_name" >/dev/null 2>&1 || \
    die "Git remote unavailable: $remote_name"

remote_ref="refs/remotes/$remote_name/$branch"
git -C "$root" show-ref --verify --quiet "$remote_ref" || \
    die "remote branch unavailable: $remote_name/$branch; run 'git fetch $remote_name $branch' first"

local_head=$(git -C "$root" rev-parse HEAD)
remote_head=$(git -C "$root" rev-parse "$remote_ref")
[ "$local_head" == "$remote_head" ] || \
    die "local $branch must equal $remote_name/$branch before publication; sync before editing"

# Git identity must already work — never run git config.
git -C "$root" var GIT_AUTHOR_IDENT >/dev/null 2>&1 || \
    die "Git author identity unavailable; do not run git config automatically"
git -C "$root" var GIT_COMMITTER_IDENT >/dev/null 2>&1 || \
    die "Git committer identity unavailable; do not run git config automatically"

# No pre-staged changes.
if ! git -C "$root" diff --cached --quiet; then
    die "staged changes already exist; unstage or commit them before publication"
fi

git -C "$root" diff --check -- "${pathspecs[@]}"

printf 'publication_paths:'
printf ' %q' "${paths[@]}"
printf '\n'
printf 'publication_branch=%q remote=%q\n' "$branch" "$remote_name"

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' 'dry-run: no fetch, add, commit, push, or mirror-sync executed'
    exit 0
fi

# ── Fetch and verify remote unchanged ──────────────────────────────────
git -C "$root" fetch --prune "$remote_name" || die "git fetch failed before publication"
remote_head_after=$(git -C "$root" rev-parse "$remote_ref")
[ "$remote_head_after" == "$remote_head" ] || \
    die "remote $remote_name/$branch changed during publication; rerun after synchronizing"

# ── Stage, commit, push ────────────────────────────────────────────────
git -C "$root" add -- "${pathspecs[@]}"
if git -C "$root" diff --cached --quiet; then
    die "no task changes were staged; refusing empty commit"
fi
git -C "$root" diff --cached --check

printf 'staged_paths_begin\n'
git -C "$root" diff --cached --name-only
printf 'staged_paths_end\n'

git -C "$root" commit -m "$message"
candidate=$(git -C "$root" rev-parse HEAD)
printf 'COMMIT_CREATED=%s\n' "$candidate"

# Verify staged paths are clean after commit.
[ -z "$(git -C "$root" status --porcelain -- "${pathspecs[@]}")" ] || \
    die "published task paths still contain uncommitted changes after commit"

git -C "$root" push "$remote_name" "HEAD:$branch"
pushed=$(git -C "$root" ls-remote "$remote_name" "refs/heads/$branch" | awk 'NR==1 {print $1}')
[ "$pushed" == "$candidate" ] || die "remote branch does not equal candidate after push"
printf 'PUSH_COMPLETE remote=%s branch=%s candidate=%s\n' "$remote_name" "$branch" "$candidate"

# ── Remote mirror alignment (optional, only if container configured) ───
# When PBL_CONTAINER is set, align the remote validation mirror so its HEAD
# equals the candidate. This is the recoverable mirror alignment: divergent
# commits are preserved under refs/agent-backups/ before force-aligning.
if [ -z "${PBL_CONTAINER:-}" ]; then
    printf 'CANDIDATE_READY=%s\n' "$candidate"
    printf '%s\n' "mirror sync skipped (PBL_CONTAINER not set)"
    exit 0
fi

command -v ssh >/dev/null 2>&1 || die "ssh executable not found"

# Build the SSH command with shell-escaped argv for the remote bash script.
# Passing as positional args avoids quoting issues with special characters.
printf -v remote_command '%q ' \
    bash -s -- \
    "$PBL_CONTAINER" "$PBL_REMOTE_REPO" "$remote_name" "$branch" "$candidate"
remote_command=${remote_command% }

set +e
ssh "$PBL_SSH_HOST" "$remote_command" <<'REMOTE_HOST'
set -euo pipefail

container=$1; shift
remote_repo=$1; shift
remote_name=$1; shift
branch=$1; shift
candidate=$1; shift

command -v docker >/dev/null 2>&1 || {
    printf 'error: docker executable not found on SSH host\n' >&2
    exit 20
}
docker inspect "$container" >/dev/null 2>&1 || {
    printf 'error: Docker container unavailable: %s\n' "$container" >&2
    exit 21
}

docker exec -i "$container" bash -s -- \
    "$remote_repo" "$remote_name" "$branch" "$candidate" <<'REMOTE_CONTAINER'
set -euo pipefail

remote_repo=$1; shift
remote_name=$1; shift
branch=$1; shift
candidate=$1; shift

fail() {
    printf 'REMOTE_PULL_FAIL: %s\n' "$*" >&2
    exit 30
}

[ -d "$remote_repo" ] || fail "repository directory missing: $remote_repo"
git -C "$remote_repo" rev-parse --git-dir >/dev/null 2>&1 || fail "not a Git repository"
[ -z "$(git -C "$remote_repo" status --porcelain)" ] || fail "test repository is dirty"
git -C "$remote_repo" remote get-url "$remote_name" >/dev/null 2>&1 || fail "remote unavailable: $remote_name"

git -C "$remote_repo" fetch --prune "$remote_name" || fail "git fetch failed"
remote_ref="refs/remotes/$remote_name/$branch"
git -C "$remote_repo" show-ref --verify --quiet "$remote_ref" || \
    fail "remote branch unavailable: $remote_name/$branch"

sync_timestamp=$(date +%Y%m%d_%H%M%S)
preserve_if_unreachable() {
    label=$1
    commit=$2
    [ -n "$commit" ] || return 0
    if git -C "$remote_repo" merge-base --is-ancestor "$commit" "$remote_ref"; then
        return 0
    fi
    short=$(git -C "$remote_repo" rev-parse --short=12 "$commit") || \
        fail "cannot abbreviate backup commit: $commit"
    backup_ref="refs/agent-backups/$branch/${sync_timestamp}-${label}-${short}"
    git -C "$remote_repo" update-ref "$backup_ref" "$commit" || \
        fail "cannot preserve divergent commit: $commit"
    printf 'REMOTE_BACKUP_CREATED ref=%s commit=%s\n' "$backup_ref" "$commit"
}

current_head=$(git -C "$remote_repo" rev-parse HEAD)
preserve_if_unreachable head "$current_head"
if git -C "$remote_repo" show-ref --verify --quiet "refs/heads/$branch"; then
    local_branch_head=$(git -C "$remote_repo" rev-parse "refs/heads/$branch")
    if [ "$local_branch_head" != "$current_head" ]; then
        preserve_if_unreachable branch "$local_branch_head"
    fi
fi

git -C "$remote_repo" switch -C "$branch" "$remote_name/$branch" || \
    fail "cannot align validation mirror branch: $branch"
git -C "$remote_repo" branch --set-upstream-to="$remote_name/$branch" "$branch" >/dev/null 2>&1 || \
    fail "cannot set tracking branch: $remote_name/$branch"
git -C "$remote_repo" pull --ff-only "$remote_name" "$branch" || \
    fail "git pull --ff-only failed"

head=$(git -C "$remote_repo" rev-parse HEAD)
[ "$head" == "$candidate" ] || fail "pulled HEAD ($head) does not equal candidate ($candidate)"
[ -z "$(git -C "$remote_repo" status --porcelain)" ] || fail "test repository became dirty"
printf 'REMOTE_PULL_COMPLETE remote=%s branch=%s candidate=%s\n' "$remote_name" "$branch" "$candidate"
REMOTE_CONTAINER
REMOTE_HOST
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'remote mirror alignment failed with status %d\n' "$status" >&2
    exit "$status"
fi

printf 'CANDIDATE_READY=%s\n' "$candidate"
