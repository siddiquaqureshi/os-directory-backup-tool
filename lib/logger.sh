#!/usr/bin/env bash
# lib/logger.sh - OWNER: Kaneeza Batool - Automated Logging System
#
# Records timestamped activity, file counts and error statuses for every
# operation of the backup tool.
#
# PUBLIC FUNCTIONS
#   log_msg LEVEL "message"            (CONTRACT used by every module - unchanged)
#                                      LEVEL = INFO | WARN | ERROR | DEBUG
#   log_op_start  OPERATION SOURCE     start timing an operation (backup/restore)
#   log_op_end    OPERATION STATUS FILES DIRS ERRORS [ARCHIVE]
#                                      write one SUMMARY line (counts + status + duration)
#   log_errors_from_file FILE CONTEXT  copy every line of a captured stderr file
#                                      into the log as ERROR entries; prints count
#   log_run CONTEXT cmd args...        run a command, log its exit status and
#                                      any error output, return its exit code
#   log_stats                          print statistics from the log file
#   log_rotate                         rotate the log when it grows too large
#
# Log line format (view_logs in backup.sh greps for "[ERROR]"):
#   2026-11-09 14:03:12 [INFO] Full backup started: /home/u/docs (12 files, 3 folders)
#   2026-11-09 14:03:13 [INFO] SUMMARY op=full_backup status=SUCCESS files=12 dirs=3 errors=0 duration=1s source=/home/u/docs archive=...
#
# Settings (all optional, config.sh normally sets LOG_FILE):
#   LOG_FILE        log file path          (default: ./logs/backup.log)
#   LOG_MAX_BYTES   rotate above this size (default: 1 MB)
#   LOG_KEEP        rotated copies to keep (default: 5)
#   LOG_ECHO=1      also print WARN/ERROR lines to the terminal (stderr)

# Run directly (./lib/logger.sh stats): use the project's log file
if [[ "${BASH_SOURCE[0]}" == "$0" && -z "$LOG_FILE" && -f "$(dirname "${BASH_SOURCE[0]}")/../config.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
fi
LOG_FILE="${LOG_FILE:-$(pwd)/logs/backup.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
LOG_KEEP="${LOG_KEEP:-5}"
LOG_ECHO="${LOG_ECHO:-0}"

_LOG_FAILED_ONCE=0          # so "cannot write log" is only reported once
declare -A _LOG_OP_START    # operation name -> start time (epoch seconds)

# ---------------------------------------------------------------------------
# log_msg LEVEL "message"
# ---------------------------------------------------------------------------
log_msg() {
    local level="${1^^}"; shift
    local msg="$*" line

    case "$level" in
        INFO|WARN|ERROR|DEBUG) ;;
        WARNING) level="WARN" ;;
        *) msg="(unknown level '$level') $msg"; level="INFO" ;;
    esac

    # Keep every entry on a single line so grep/tail work correctly.
    msg="${msg//$'\n'/ | }"
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg"

    if ! { mkdir -p "$(dirname "$LOG_FILE")" && printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null; then
        if [[ $_LOG_FAILED_ONCE -eq 0 ]]; then
            echo "WARNING: cannot write to log file: $LOG_FILE" >&2
            _LOG_FAILED_ONCE=1
        fi
        return 1
    fi

    if [[ "$LOG_ECHO" == "1" && ( "$level" == "WARN" || "$level" == "ERROR" ) ]]; then
        echo "$line" >&2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Log rotation: backup.log -> backup.log.1 -> backup.log.2 ... (oldest deleted)
# ---------------------------------------------------------------------------
log_rotate() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size i
    size="$(wc -c < "$LOG_FILE" 2>/dev/null)" || return 0
    (( size > LOG_MAX_BYTES )) || return 0

    rm -f "$LOG_FILE.$LOG_KEEP"
    for ((i = LOG_KEEP - 1; i >= 1; i--)); do
        [[ -f "$LOG_FILE.$i" ]] && mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
    done
    mv -f "$LOG_FILE" "$LOG_FILE.1"
    log_msg INFO "Log rotated (previous log saved as $(basename "$LOG_FILE").1, size ${size} bytes)"
}

# ---------------------------------------------------------------------------
# Operation summaries (timestamped activity + file counts + error status)
# ---------------------------------------------------------------------------

# log_op_start OPERATION SOURCE
log_op_start() {
    local op="$1" src="$2"
    _LOG_OP_START["$op"]="$(date +%s)"
    log_msg INFO "START op=$op source=$src user=$(id -un 2>/dev/null || echo unknown)"
}

# log_op_end OPERATION STATUS FILES DIRS ERRORS [ARCHIVE]
#   STATUS = SUCCESS | WARNING | FAILED
log_op_end() {
    local op="$1" status="${2^^}" files="${3:-0}" dirs="${4:-0}" errors="${5:-0}" archive="$6"
    local start="${_LOG_OP_START[$op]}" now duration level=INFO

    now="$(date +%s)"
    if [[ -n "$start" ]]; then duration="$((now - start))s"; else duration="unknown"; fi
    unset '_LOG_OP_START[$op]'

    case "$status" in
        SUCCESS) level=INFO ;;
        WARNING|WARN) status=WARNING; level=WARN ;;
        *) status=FAILED; level=ERROR ;;
    esac

    log_msg "$level" "SUMMARY op=$op status=$status files=$files dirs=$dirs errors=$errors duration=$duration${archive:+ archive=$archive}"
}

# log_errors_from_file FILE CONTEXT
#   Each non-empty line of FILE becomes one ERROR entry. Prints the count.
log_errors_from_file() {
    local file="$1" context="${2:-command}" line count=0
    if [[ -s "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            log_msg ERROR "$context: $line"
            count=$((count + 1))
        done < "$file"
    fi
    echo "$count"
}

# log_run CONTEXT command [args...]
#   Runs the command (its normal output still goes to the terminal), logs the
#   exit status and the error output, and returns the command's exit code.
log_run() {
    local context="$1"; shift
    local errfile rc n
    errfile="$(mktemp)"
    "$@" 2> >(tee "$errfile" >&2)
    rc=$?
    wait 2>/dev/null          # let tee finish writing
    if [[ $rc -eq 0 ]]; then
        log_msg INFO "$context: OK ($*)"
    else
        n="$(log_errors_from_file "$errfile" "$context")"
        log_msg ERROR "$context: FAILED with exit code $rc ($n error lines) ($*)"
    fi
    rm -f "$errfile"
    return $rc
}

# ---------------------------------------------------------------------------
# log_stats - summary of everything recorded in the log
# ---------------------------------------------------------------------------
log_stats() {
    if [[ ! -s "$LOG_FILE" ]]; then
        echo "No log entries yet."
        return 0
    fi

    awk '
        { total++ }
        /\[INFO\]/  { info++ }
        /\[WARN\]/  { warn++ }
        /\[ERROR\]/ { err++ }
        / SUMMARY / {
            ops++
            for (i = 1; i <= NF; i++) {
                split($i, kv, "=")
                if (kv[1] == "op")     op = kv[2]
                if (kv[1] == "status") st = kv[2]
                if (kv[1] == "files")  f  = kv[2]
            }
            count[op]++; status[st]++; files += f
            last = $1 " " $2 "  " op " (" st ")"
        }
        END {
            printf "Log file        : %s\n", FILENAME
            printf "First entry     : %s\n", first
            printf "Total entries   : %d  (INFO %d, WARN %d, ERROR %d)\n", total, info, warn, err
            printf "Operations      : %d  (SUCCESS %d, WARNING %d, FAILED %d)\n", ops, status["SUCCESS"], status["WARNING"], status["FAILED"]
            for (o in count) printf "   %-20s %d\n", o, count[o]
            printf "Files processed : %d\n", files
            if (last != "") printf "Last operation  : %s\n", last
        }
        NR == 1 { first = $1 " " $2 }
    ' "$LOG_FILE"
}

# Rotate once when the logger is loaded (start of every session).
log_rotate

# ---------------------------------------------------------------------------
# Run directly:  ./lib/logger.sh stats | test
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$1" in
        stats) log_stats ;;
        test)
            log_op_start demo "/tmp/demo"
            log_msg INFO  "This is an info message"
            log_msg WARN  "This is a warning"
            log_msg ERROR "This is an error"
            log_op_end demo SUCCESS 10 2 0 "/tmp/demo.tar.gz"
            tail -n 6 "$LOG_FILE"
            ;;
        *) echo "Usage: $0 {stats|test}"; exit 1 ;;
    esac
fi
