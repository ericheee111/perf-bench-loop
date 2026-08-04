#!/usr/bin/env bash
#
# probe-asv.sh — Single-snapshot status check for a running ASV job.
#
# Returns immediately with a ≤20-line machine-parseable summary. Does NOT
# block (that's wait-for-asv.sh's job). Does NOT read the full log (that's
# the failure-diagnosis subagent's job). Just enough for the main agent to
# decide whether the run is done, still going, or dead.
#
# Usage:
#   probe-asv.sh --via <EXEC_PREFIX> --run-dir <RUN_DIR>
#
# Required:
#   --via EXEC_PREFIX      Command prefix reaching the ASV machine, as a
#                          single whitespace-split string. Examples:
#                            "ssh <host>"
#                            "ssh <host> docker exec -i <container>"
#   --run-dir RUN_DIR      Absolute path on the ASV machine where
#                          asv-background.sh wrote its files.
#
# Output (stdout, machine-parseable, ≤20 lines):
#   STATE: running | done | wrapper-died | corrupt | not-found
#   ELAPSED: <human duration since pid file mtime, or "unknown">
#   PID_ALIVE: yes | no | unknown
#   LAST_LOG_LINE: <last line of run.log, truncated to 200 chars>
#   EXIT_CODE: <integer when STATE=done, empty otherwise>
#   RUN_DIR: <path>
#
# Exit status:
#   0  Probe succeeded (regardless of run state — the probe itself worked).
#      Read STATE to know the run's status.
#   5  Transport failure (couldn't reach the ASV machine).
#   64 Usage error.
#
set -euo pipefail

via=""
run_dir=""

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
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

if [ -z "$via" ] || [ -z "$run_dir" ]; then
    echo "usage: probe-asv.sh --via <EXEC_PREFIX> --run-dir <RUN_DIR>" >&2
    echo '  --via "ssh <host>"  or  --via "ssh <host> docker exec -i <container>"' >&2
    exit 64
fi

# Strip trailing CR from run_dir (defensive against Windows CRLF).
run_dir=$(printf '%s' "$run_dir" | sed 's/\r$//')
if [ -z "$run_dir" ]; then
    echo "error: run_dir is empty after CR stripping" >&2
    exit 64
fi

# Split --via into argv (same mechanism as wait-for-asv.sh).
read -ra via_arr <<< "$via"
if [ "${#via_arr[@]}" -eq 0 ]; then
    echo "error: --via is blank; provide a command prefix like 'ssh <host>'" >&2
    exit 64
fi

# Single round-trip to the ASV machine. All checks in one SSH call to
# minimize latency. The remote script prints exactly the lines we need.
#
# We pass run_dir as argv and use a quoted heredoc so no local expansion
# leaks into the remote script.
set +e
"${via_arr[@]}" bash -s -- "$run_dir" <<'REMOTE'
run_dir="$1"

# Check run dir exists.
if [ ! -d "$run_dir" ]; then
    echo "STATE: not-found"
    echo "ELAPSED: unknown"
    echo "PID_ALIVE: unknown"
    echo "LAST_LOG_LINE: "
    echo "EXIT_CODE: "
    echo "RUN_DIR: $run_dir"
    exit 0
fi

# Determine state.
done_file="$run_dir/done"
pid_file="$run_dir/pid"
exit_code_file="$run_dir/exit_code"
log_file="$run_dir/run.log"

if [ -f "$done_file" ]; then
    # Run finished. Read exit code.
    if [ -f "$exit_code_file" ]; then
        ec=$(cat "$exit_code_file" 2>/dev/null)
        if echo "$ec" | grep -qE '^-?[0-9]+$'; then
            echo "STATE: done"
            echo "EXIT_CODE: $ec"
        else
            echo "STATE: corrupt"
            echo "EXIT_CODE: "
        fi
    else
        echo "STATE: corrupt"
        echo "EXIT_CODE: "
    fi
else
    # Not done — check if wrapper process is alive.
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "STATE: running"
        else
            echo "STATE: wrapper-died"
        fi
    else
        # No pid file yet — maybe asv-background.sh hasn't written it,
        # or the run dir was created manually. Treat as running-ish.
        echo "STATE: running"
    fi
    echo "EXIT_CODE: "
fi

# Elapsed time: use pid file mtime as start, or run dir mtime as fallback.
start_file="$pid_file"
[ -f "$start_file" ] || start_file="$run_dir"
if [ -f "$start_file" ]; then
    # stat -c %Y works on Linux; stat -f %m on macOS/BSD. Try both.
    start_epoch=$(stat -c %Y "$start_file" 2>/dev/null || stat -f %m "$start_file" 2>/dev/null || echo "")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed_secs=$((now_epoch - start_epoch))
        if [ "$elapsed_secs" -lt 0 ]; then
            elapsed_secs=0
        fi
        # Format as human duration.
        if [ "$elapsed_secs" -lt 60 ]; then
            echo "ELAPSED: ${elapsed_secs}s"
        elif [ "$elapsed_secs" -lt 3600 ]; then
            mins=$((elapsed_secs / 60))
            secs=$((elapsed_secs % 60))
            echo "ELAPSED: ${mins}m${secs}s"
        else
            hours=$((elapsed_secs / 3600))
            mins=$(( (elapsed_secs % 3600) / 60 ))
            echo "ELAPSED: ${hours}h${mins}m"
        fi
    else
        echo "ELAPSED: unknown"
    fi
else
    echo "ELAPSED: unknown"
fi

# PID liveness (only meaningful when not done, but report anyway).
if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$pid" ]; then
        if kill -0 "$pid" 2>/dev/null; then
            echo "PID_ALIVE: yes"
        else
            echo "PID_ALIVE: no"
        fi
    else
        echo "PID_ALIVE: unknown"
    fi
else
    echo "PID_ALIVE: unknown"
fi

# Last log line (truncated to 200 chars to keep output small).
if [ -f "$log_file" ]; then
    last_line=$(tail -1 "$log_file" 2>/dev/null | head -c 200)
    echo "LAST_LOG_LINE: $last_line"
else
    echo "LAST_LOG_LINE: "
fi

echo "RUN_DIR: $run_dir"
REMOTE
rc=$?
set -e

# Distinguish transport failure from successful probe.
# ssh returns 255 on transport errors; command-not-found returns 127.
if [ "$rc" -ge 125 ]; then
    echo "error: transport failure (exit $rc) reaching the ASV machine via: $via" >&2
    exit 5
fi

exit 0
