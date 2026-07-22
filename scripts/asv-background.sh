#!/usr/bin/env bash
#
# asv-background.sh — Launch an ASV run in the background, write status files
# to a stable run directory, and return immediately.
#
# This script runs ON THE SAME MACHINE AS ASV (i.e. inside the container if
# you use containers). It does NOT handle ssh or docker exec itself — the
# caller wraps it. See SKILL.md Phase 3 for the wrapping pattern.
#
# Usage:
#   asv-background.sh <RUN_DIR> <ASV_CMD...>
#
# Arguments:
#   RUN_DIR    Directory to create for this run. Will be created if missing.
#              MUST be on a filesystem visible to the ASV process — i.e. if
#              ASV runs inside a container, RUN_DIR must be a path inside
#              that container (typically a bind-mount if you want the host
#              to see the files too). A relative path is resolved against
#              $PWD at launch time.
#   ASV_CMD... The ASV command and its arguments to run, e.g.
#              `run --quick` or `run --branch=HEAD`. The leading `asv` is
#              added by this script — pass only the subcommand and flags.
#
# Files written to RUN_DIR:
#   pid         PID of the background ASV process (written immediately)
#   run.log     Full stdout+stderr of the ASV command
#   exit_code   Exit code of the ASV command (written when run finishes)
#   done        Empty marker file, touched when run finishes (atomic signal)
#
# Output:
#   Prints the absolute path of RUN_DIR on stdout. Nothing else on stdout.
#   Diagnostic messages go to stderr.
#
# Exit status:
#   0 if the background job was launched successfully.
#   64 on usage error.
#   Non-zero if the launch failed.
#
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: asv-background.sh <RUN_DIR> <ASV_CMD...>" >&2
    echo "" >&2
    echo "RUN_DIR must be on a filesystem visible to the ASV process." >&2
    echo "If ASV runs in a container, RUN_DIR must be inside that container." >&2
    exit 64
fi

run_dir="$1"
shift

# Resolve to an absolute path so the detached process can find it regardless
# of working directory changes. $PWD is used deliberately (not readlink -f)
# so the path matches what the caller expects on both Linux and macOS.
case "$run_dir" in
    /*) abs_run_dir="$run_dir" ;;
    *)  abs_run_dir="$PWD/$run_dir" ;;
esac

mkdir -p "$abs_run_dir"

# Refuse to reuse a non-empty run directory. A stale `done` marker from a
# previous run would make wait-for-asv.sh return immediately with the old
# result. Don't auto-delete — the directory might belong to a still-running
# job. Error out and let the caller pick a new timestamp.
if [ -n "$(ls -A "$abs_run_dir" 2>/dev/null)" ]; then
    echo "error: run directory is not empty: $abs_run_dir" >&2
    echo "  This usually means a timestamp collision or a reused path." >&2
    echo "  Pick a new run directory with a unique timestamp." >&2
    exit 1
fi

# Launch ASV detached. The inner bash:
#   - disables errexit for the ASV call so we always capture the exit code
#   - redirects asv stdout+stderr into run.log INSIDE run_dir (same fs layer
#     as the ASV process, so the write always lands even in a container)
#   - writes exit_code and touches done regardless of success/failure
#   - the `done` marker is the atomic signal wait-for-asv.sh blocks on
#
# Why the writes are ordered run.log -> exit_code -> done: a reader polling
# for `done` is guaranteed that run.log and exit_code are already flushed.
nohup bash -c '
    set +e
    run_dir="$1"
    shift
    asv "$@" >"$run_dir/run.log" 2>&1
    rc=$?
    printf "%s\n" "$rc" >"$run_dir/exit_code"
    touch "$run_dir/done"
    exit "$rc"
' _ "$abs_run_dir" "$@" >/dev/null 2>&1 &

pid=$!
printf "%s\n" "$pid" >"$abs_run_dir/pid"

# Echo the absolute run directory on stdout for the caller to capture.
printf "%s\n" "$abs_run_dir"
