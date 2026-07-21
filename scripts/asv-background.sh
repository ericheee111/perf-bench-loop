#!/usr/bin/env bash
#
# asv-background.sh — Launch an ASV run in the background on the server.
#
# Writes a stable run directory so other tools (wait-for-asv.sh, compare-asv.py)
# know exactly where to look. The run is detached with nohup; this script
# returns immediately after launching.
#
# Usage:
#   asv-background.sh <RUN_DIR> <ASV_CMD...>
#
# Arguments:
#   RUN_DIR    Directory to create for this run. Will be created if missing.
#              Typically a relative path under the project root, e.g.
#              .asv-runs/20260721-143000
#   ASV_CMD... The ASV command and its arguments to run, e.g.
#              `asv run --quick` or `asv run --branch=HEAD`.
#
# Files written to RUN_DIR:
#   pid         PID of the background ASV process (written immediately)
#   run.log     Full stdout+stderr of the ASV command
#   exit_code   Exit code of the ASV command (written when run finishes)
#   done        Empty marker file, touched when run finishes
#
# Output:
#   Prints the absolute path of RUN_DIR on stdout. Nothing else on stdout.
#   Diagnostic messages go to stderr.
#
# Exit status:
#   0 if the background job was launched successfully.
#   Non-zero if RUN_DIR is missing or the launch failed.
#
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: asv-background.sh <RUN_DIR> <ASV_CMD...>" >&2
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

# Launch ASV detached. The inner bash:
#   - disables errexit for the ASV call so we always capture the exit code
#   - writes exit_code and touches done regardless of success/failure
#   - the marker file is the signal wait-for-asv.sh is blocking on
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
