#!/usr/bin/env bash
# lib/logger.sh - OWNER: Kaneeza (this is a PLACEHOLDER so the menu runs now)
#
# CONTRACT (keep this function name and arguments):
#   log_msg LEVEL "message"      LEVEL = INFO | WARN | ERROR

log_msg() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}
