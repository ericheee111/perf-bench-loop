#!/usr/bin/env bash
#
# wait-for-asv.sh — Block until a remote ASV run finishes, then print its
# exit code and the tail of its log.
#
# This is the single most important script in the skill for token savings.
# It turns "hours of main-agent polling" into one tool call: the shell does
# the waiting on the remote host, and the main agent only wakes up once the
# run is done. Whatever the wall-clock duration of the ASV run, this script
# costs exactly one tool invocation.
#
# Usage:
#   wait-for-asv.sh <SSH_HOST> <REMOTE_RUN_DIR> [POLL_INTERVAL_SECONDS]
#
# Arguments:
#   SSH_HOST                SSH destination, e.g. `bench01` or `user@host`.
#                           Any valid ssh target (relies on ~/.ssh/config).
#   REMOTE_RUN_DIR          Absolute path on the remote host where
#                           asv-background.sh wrote its files.
#   POLL_INTERVAL_SECONDS   Optional. Seconds between checks of the `done`
#                           marker. Default 90. Don't set this below 60 —
#                           the point is to wait, not to poll aggressively.
#
# Output (stdout, machine-parseable):
#   EXIT_CODE:
#   <integer exit code>
#   FINAL_LOG:
#   <last 300 lines of run.log>
#
# Exit status:
#   0 if the run finished and we read the results, regardless of whether
#     ASV itself succeeded. Check the printed EXIT_CODE for ASV's status.
#   Non-zero on SSH failure, missing run directory, or timeout.
#
# Notes:
#   - The SSH connection stays open for the whole wait. Use ControlMaster
#     in ~/.ssh/config if you're worried about reconnects; this script
#     relies on a single persistent ssh invocation.
#   - If you need a hard timeout, wrap this script in `timeout(1)`.
#   - The script deliberately does NOT print progress updates. Silence is
#     the goal; any output would wake the main agent and cost tokens.
#
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: wait-for-asv.sh <SSH_HOST> <REMOTE_RUN_DIR> [POLL_INTERVAL_SECONDS]" >&2
    exit 64
fi

ssh_host="$1"
remote_run_dir="$2"
poll_interval="${3:-90}"

if ! [[ "$poll_interval" =~ ^[0-9]+$ ]] || [ "$poll_interval" -lt 1 ]; then
    echo "error: POLL_INTERVAL_SECONDS must be a positive integer, got '$poll_interval'" >&2
    exit 64
fi

# Validate the run directory exists on the remote before entering the wait
# loop. Otherwise we'd wait forever on a non-existent path.
if ! ssh "$ssh_host" "test -d '$remote_run_dir'"; then
    echo "error: remote run directory does not exist: $remote_run_dir" >&2
    exit 2
fi

# Single SSH call. The remote shell blocks on the `done` marker; we pay
# for one ssh invocation regardless of how long the wait takes. Silence
# during the wait is intentional.
ssh "$ssh_host" bash -s "$remote_run_dir" "$poll_interval" <<'REMOTE'
set -eu
run_dir="$1"
poll_interval="$2"

# Wait for the done marker. No output during the wait — silence saves tokens.
while [ ! -f "$run_dir/done" ]; do
    sleep "$poll_interval"
done

# Done. Emit machine-parseable output.
echo "EXIT_CODE:"
cat "$run_dir/exit_code" 2>/dev/null || echo "unknown"

echo "FINAL_LOG:"
tail -n 300 "$run_dir/run.log" 2>/dev/null || true
REMOTE
