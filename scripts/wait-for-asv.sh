#!/usr/bin/env bash
#
# wait-for-asv.sh — Block until an ASV run finishes, then print its exit
# code and the tail of its log. One tool call, regardless of run duration.
#
# This is the single most important script in the skill for token savings.
# It turns "hours of main-agent polling" into one call: the shell does the
# waiting, and the main agent only wakes up once the run is done.
#
# Usage:
#   wait-for-asv.sh --via <EXEC_PREFIX> --run-dir <RUN_DIR> [options]
#
# Required:
#   --via EXEC_PREFIX      Quoted command prefix that reaches the machine
#                          where ASV actually runs. Examples:
#                            "ssh bench01"
#                            "ssh kpserver docker exec container"
#                          Everything after the prefix runs ON the ASV
#                          machine. The prefix is split with eval, so quote
#                          arguments that contain spaces.
#   --run-dir RUN_DIR      Absolute path on the ASV machine where
#                          asv-background.sh wrote its files. Must be the
#                          same path asv-background.sh sees (i.e. inside
#                          the container if you use one).
#
# Optional:
#   --poll-interval SECS   Seconds between checks of the `done` marker.
#                          Default 90. Don't set below 60.
#   --timeout SECS         Hard timeout. 0 = no timeout. Default 0.
#
# Output (stdout, machine-parseable):
#   EXIT_CODE:
#   <integer exit code>
#   FINAL_LOG:
#   <last 300 lines of run.log>
#
# Exit status:
#   0  Run finished, results read. Check printed EXIT_CODE for ASV's status.
#   2  Run directory not found on the ASV machine, or couldn't exec prefix.
#   3  Timed out before `done` appeared.
#   64 Usage error.
#
# Why --via instead of a bare SSH_HOST:
#   The original design assumed `ssh <host>` reaches the ASV machine
#   directly. In containerized setups (ssh host -> docker exec container)
#   the run directory lives INSIDE the container and is invisible from the
#   host's filesystem. A bare `ssh host test -d /tmp/run` would fail even
#   though the directory exists inside the container. --via lets the caller
#   supply the full hop chain so every check runs at the right layer.
#
set -euo pipefail

via=""
run_dir=""
poll_interval=90
timeout_secs=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --via)          via="$2"; shift 2 ;;
        --run-dir)      run_dir="$2"; shift 2 ;;
        --poll-interval) poll_interval="$2"; shift 2 ;;
        --timeout)      timeout_secs="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

if [ -z "$via" ] || [ -z "$run_dir" ]; then
    echo "usage: wait-for-asv.sh --via <EXEC_PREFIX> --run-dir <RUN_DIR> [--poll-interval SECS] [--timeout SECS]" >&2
    echo '  --via "ssh bench01"  or  --via "ssh kpserver docker exec container"' >&2
    exit 64
fi

if ! [[ "$poll_interval" =~ ^[0-9]+$ ]] || [ "$poll_interval" -lt 1 ]; then
    echo "error: --poll-interval must be a positive integer, got '$poll_interval'" >&2
    exit 64
fi
if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]]; then
    echo "error: --timeout must be a non-negative integer, got '$timeout_secs'" >&2
    exit 64
fi

# Build the timeout wrapper if requested. Runs inside the remote shell.
timeout_cmd=""
if [ "$timeout_secs" -gt 0 ]; then
    timeout_cmd="timeout ${timeout_secs}"
fi

# Validate the run directory exists ON THE ASV MACHINE (not the ssh host's
# filesystem). This is the bug the --via redesign fixes: previously the
# check ran on the ssh host and failed for container paths.
if ! eval "$via test -d '$run_dir'"; then
    echo "error: run directory not found on the ASV machine: $run_dir" >&2
    echo "  (checked via: $via)" >&2
    echo "  If ASV runs in a container, --run-dir must be the path INSIDE the container," >&2
    echo "  and --via must include the docker exec hop." >&2
    exit 2
fi

# Single call to the ASV machine. The remote shell blocks on `done`; we pay
# for one invocation regardless of how long the wait takes. Silence during
# the wait is intentional — any output would wake the main agent and cost
# tokens.
#
# We pass a script via stdin (heredoc) so quoting is predictable. The
# $run_dir and $poll_interval are substituted locally (single quotes in the
# heredoc would prevent that); they come from validated integers/paths above.
eval "$via $timeout_cmd bash -s" <<REMOTE
set -eu
run_dir="$run_dir"
poll_interval="$poll_interval"

while [ ! -f "\$run_dir/done" ]; do
    sleep "\$poll_interval"
done

echo "EXIT_CODE:"
cat "\$run_dir/exit_code" 2>/dev/null || echo "unknown"

echo "FINAL_LOG:"
tail -n 300 "\$run_dir/run.log" 2>/dev/null || true
REMOTE
