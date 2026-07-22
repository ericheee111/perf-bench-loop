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
#   --via EXEC_PREFIX      Command prefix that reaches the machine where ASV
#                          actually runs, as a single string. It is split on
#                          whitespace into an argv array (NOT eval'd), so no
#                          shell metacharacters are interpreted. Examples:
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
#   On wrapper death (pid gone but no done marker), prints:
#   STATE: wrapper-died
#
# Exit status:
#   0  Run finished normally (done appeared, exit_code is a valid integer).
#      Check printed EXIT_CODE for ASV's own status.
#   2  Run directory not found on the ASV machine.
#   3  Timed out before `done` appeared.
#   4  Wrapper process died (pid no longer alive) before `done` appeared.
#   5  Transport failure or corrupt run state (done exists but exit_code
#      is missing/non-integer, or the transport command itself failed).
#   64 Usage error (missing/blank --via, missing --run-dir, etc.).
#
set -euo pipefail

via=""
run_dir=""
poll_interval=90
timeout_secs=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --via)
            if [ "$#" -lt 2 ]; then
                echo "error: --via requires an argument" >&2
                exit 64
            fi
            via="$2"; shift 2 ;;
        --run-dir)
            if [ "$#" -lt 2 ]; then
                echo "error: --run-dir requires an argument" >&2
                exit 64
            fi
            run_dir="$2"; shift 2 ;;
        --poll-interval)
            if [ "$#" -lt 2 ]; then
                echo "error: --poll-interval requires an argument" >&2
                exit 64
            fi
            poll_interval="$2"; shift 2 ;;
        --timeout)
            if [ "$#" -lt 2 ]; then
                echo "error: --timeout requires an argument" >&2
                exit 64
            fi
            timeout_secs="$2"; shift 2 ;;
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

# Split --via into an argv array using read -ra. This is NOT eval — no shell
# metacharacters are interpreted, no command substitution happens. The string
# is simply split on whitespace into array elements, then passed as separate
# argv entries to the command.
read -ra via_arr <<< "$via"

# A blank --via (empty string or whitespace only) is a usage error, not a
# transport error. Catch it explicitly so the caller gets exit 64, not a
# confusing "command not found" or silent success.
if [ "${#via_arr[@]}" -eq 0 ]; then
    echo "error: --via is blank; provide a command prefix like 'ssh <host>'" >&2
    exit 64
fi

# Build the timeout wrapper array if requested. Using an array (not a string)
# so the timeout command and its argument are separate argv entries.
timeout_arr=()
if [ "$timeout_secs" -gt 0 ]; then
    timeout_arr=(timeout "$timeout_secs")
fi

# Validate the run directory exists ON THE ASV MACHINE.
# Distinguish transport errors (ssh connection refused, host unreachable)
# from "directory not found" (transport works but path is wrong).
# A transport error typically has exit code 255 (ssh) or 126/127 (command
# not found). We capture stderr to help diagnose.
set +e
"${via_arr[@]}" test -d "$run_dir" 2>/tmp/wait-via-err
via_check_rc=$?
set -e

if [ "$via_check_rc" -ne 0 ]; then
    # Check if it's a transport error (ssh returns 255, command not found
    # returns 127, permission denied returns 126, connection refused can
    # return 125) vs a genuine "directory not found" (test returns 1).
    if [ "$via_check_rc" -ge 125 ]; then
        echo "error: transport failure (exit $via_check_rc) reaching the ASV machine via: $via" >&2
        echo "  stderr: $(cat /tmp/wait-via-err 2>/dev/null | head -1)" >&2
        rm -f /tmp/wait-via-err
        exit 5
    fi
    # Otherwise it's a genuine "directory not found"
    echo "error: run directory not found on the ASV machine: $run_dir" >&2
    echo "  (checked via: $via)" >&2
    echo "  If ASV runs in a container, --run-dir must be the path INSIDE the container," >&2
    echo "  and --via must include the docker exec hop." >&2
    rm -f /tmp/wait-via-err
    exit 2
fi
rm -f /tmp/wait-via-err

# Single call to the ASV machine. The remote shell script is passed via
# heredoc with QUOTED delimiter (<<'REMOTE') so NO local variable expansion
# happens inside it — the script is literal text. Parameters (run_dir,
# poll_interval) are passed as argv to the remote bash via -- "$run_dir"
# "$poll_interval", which is safe against injection.
#
# The remote script:
#   1. Loops checking for `done` AND pid liveness simultaneously.
#   2. If done appears → success, print exit code.
#   3. If pid dies before done → wrapper-died, exit 4.
#   4. If timeout fires → exit 124 (converted to 3 below).
set +e
"${via_arr[@]}" "${timeout_arr[@]}" bash -s -- "$run_dir" "$poll_interval" <<'REMOTE'
run_dir="$1"
poll_interval="$2"

while [ ! -f "$run_dir/done" ]; do
    # Check if the wrapper process is still alive. If it died without
    # writing `done`, something killed it (container restart, OOM, kill).
    pid_file="$run_dir/pid"
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            echo "STATE: wrapper-died"
            echo "PID: $pid"
            exit 4
        fi
    fi
    sleep "$poll_interval"
done

echo "RUN_DIR:"
echo "$run_dir"
echo "EXIT_CODE:"
# Read exit_code. If the file is missing or contains a non-integer value,
# the run is corrupt — `done` appeared but the wrapper didn't write a valid
# exit code. Report corrupt-run (exit 5) so the caller doesn't treat it as
# a normal completion.
exit_code_file="$run_dir/exit_code"
if [ ! -f "$exit_code_file" ]; then
    echo "STATE: corrupt-run"
    echo "DETAIL: done marker exists but exit_code file is missing"
    exit 5
fi
exit_code_val=$(cat "$exit_code_file" 2>/dev/null)
if ! echo "$exit_code_val" | grep -qE '^-?[0-9]+$'; then
    echo "STATE: corrupt-run"
    echo "DETAIL: exit_code file contains non-integer: '$exit_code_val'"
    exit 5
fi
echo "$exit_code_val"
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
