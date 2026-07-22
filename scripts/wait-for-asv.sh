#!/usr/bin/env bash
#
# wait-for-asv.sh — Block until an ASV run finishes, then print its exit
# code and run directory. One tool call, regardless of run duration.
#
# This is the single most important script in the skill for token savings.
# It turns "hours of main-agent polling" into one call: the shell does the
# waiting, and the main agent only wakes up once the run is done.
#
# IMPORTANT: this script treats ALL exit codes from ASV as valid completions.
# `asv continuous` returns exit 1 when it detects a performance change —
# that is a valid comparison result, NOT a failure. The script does not
# decide whether the run "succeeded"; it only reports that it finished and
# passes the exit code through. The main agent uses compare-asv.py (for
# result files) or the monitor subagent (for log failures) to interpret.
#
# Usage:
#   wait-for-asv.sh --via <EXEC_PREFIX> --run-dir <RUN_DIR> [options]
#
# Required:
#   --via EXEC_PREFIX      Quoted command prefix that reaches the machine
#                          where ASV actually runs. Examples:
#                            "ssh <host>"
#                            "ssh <host> docker exec -i <container>"
#   --run-dir RUN_DIR      Absolute path on the ASV machine where
#                          asv-background.sh wrote its files.
#
# Optional:
#   --poll-interval SECS   Seconds between checks of the `done` marker and
#                          pid liveness. Default 90. Don't set below 60.
#   --timeout SECS         Hard timeout in seconds. 0 = no timeout (but pid
#                          liveness is still checked). Default 0.
#
# Output (stdout, machine-parseable):
#   RUN_DIR:
#   <run-dir path>
#   EXIT_CODE:
#   <integer exit code from ASV>
#
#   On success (done appeared), the script does NOT print the log. The main
#   agent should use compare-asv.py for structured results, or dispatch the
#   monitor subagent if it needs to read the raw log. Returning 300 lines of
#   log on every run would waste tokens — that's exactly what the skill
#   exists to prevent.
#
#   On wrapper death (pid gone but no done marker), prints:
#   STATE: wrapper-died
#
# Exit status:
#   0  Run finished normally (done appeared). Check printed EXIT_CODE for
#      ASV's own status — it may be 0 (no change) or 1 (change detected by
#      `asv continuous`), both are valid.
#   2  Run directory not found on the ASV machine.
#   3  Timed out before `done` appeared.
#   4  Wrapper process died (pid no longer alive) before `done` appeared.
#   64 Usage error.
#
set -euo pipefail

via=""
run_dir=""
poll_interval=90
timeout_secs=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --via)           via="$2"; shift 2 ;;
        --run-dir)       run_dir="$2"; shift 2 ;;
        --poll-interval) poll_interval="$2"; shift 2 ;;
        --timeout)       timeout_secs="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

if [ -z "$via" ] || [ -z "$run_dir" ]; then
    echo "usage: wait-for-asv.sh --via <EXEC_PREFIX> --run-dir <RUN_DIR> [--poll-interval SECS] [--timeout SECS]" >&2
    echo '  --via "ssh <host>"  or  --via "ssh <host> docker exec -i <container>"' >&2
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

# Validate the run directory exists ON THE ASV MACHINE.
if ! eval "$via test -d '$run_dir'"; then
    echo "error: run directory not found on the ASV machine: $run_dir" >&2
    echo "  (checked via: $via)" >&2
    echo "  If ASV runs in a container, --run-dir must be the path INSIDE the container," >&2
    echo "  and --via must include the docker exec hop." >&2
    exit 2
fi

# Build the timeout wrapper if requested.
timeout_cmd=""
if [ "$timeout_secs" -gt 0 ]; then
    timeout_cmd="timeout ${timeout_secs}"
fi

# Single call to the ASV machine. The remote shell:
#   1. Loops checking for `done` AND pid liveness simultaneously.
#   2. If done appears → success, print exit code.
#   3. If pid dies before done → wrapper-died, exit 4.
#   4. If timeout fires → exit 124 (converted to 3 below).
#
# Silence during the wait is intentional — output wakes the main agent.
# We use a subshell + kill 0 pattern to ensure the sleep is cleaned up on
# timeout. The remote script captures its own exit code so we can
# distinguish timeout (124) from normal completion.
set +e
eval "$via $timeout_cmd bash -s" <<REMOTE
run_dir="$run_dir"
poll_interval="$poll_interval"

while [ ! -f "\$run_dir/done" ]; do
    # Check if the wrapper process is still alive. If it died without
    # writing `done`, something killed it (container restart, OOM, kill).
    pid_file="\$run_dir/pid"
    if [ -f "\$pid_file" ]; then
        pid=\$(cat "\$pid_file" 2>/dev/null)
        if [ -n "\$pid" ] && ! kill -0 "\$pid" 2>/dev/null; then
            echo "STATE: wrapper-died"
            echo "PID: \$pid"
            exit 4
        fi
    fi
    sleep "\$poll_interval"
done

echo "RUN_DIR:"
echo "\$run_dir"
echo "EXIT_CODE:"
cat "\$run_dir/exit_code" 2>/dev/null || echo "unknown"
exit 0
REMOTE
rc=$?
set -e

# GNU timeout returns 124 on timeout. Convert to our documented exit 3.
if [ "$rc" -eq 124 ]; then
    echo "STATE: timed-out"
    exit 3
fi
# Pass through other exit codes (0 = normal, 4 = wrapper-died, etc.)
exit "$rc"
