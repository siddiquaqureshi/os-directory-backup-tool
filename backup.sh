#!/usr/bin/env bash
# backup.sh - OWNER: Siddiqua - main CLI menu
# Run with:  ./backup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/logger.sh"          # Kaneeza
source "$SCRIPT_DIR/lib/permissions.sh"     # Kaneeza
source "$SCRIPT_DIR/lib/incremental.sh"     # Kaneeza
source "$SCRIPT_DIR/lib/backup_engine.sh"   # Tahira
source "$SCRIPT_DIR/lib/restore.sh"         # Siddiqua

# Ask the user for a source directory; result goes into global SRC_DIR
ask_source_dir() {
    local input
    read -rp "Enter the directory to back up: " input
    input="${input/#\~/$HOME}"

    if [[ -z "$input" ]]; then
        echo "ERROR: path cannot be empty."; return 1
    fi
    if [[ ! -d "$input" ]]; then
        echo "ERROR: '$input' is not a directory or does not exist."
        log_msg ERROR "Invalid source directory: $input"
        return 1
    fi
    if [[ ! -r "$input" ]]; then
        echo "ERROR: no read permission for '$input'."
        log_msg ERROR "No read permission: $input"
        return 1
    fi
    SRC_DIR="$(cd "$input" && pwd)"    # absolute path, no trailing slash
    return 0
}

view_logs() {
    if [[ ! -s "$LOG_FILE" ]]; then
        echo "No log entries yet."; return
    fi
    echo
    echo "  1) Last 20 entries"
    echo "  2) Full log (press q to quit)"
    echo "  3) Errors only"
    echo "  4) Statistics"
    echo "  5) Backup summaries only"
    read -rp "Choose [1-5]: " l
    case "$l" in
        1) echo; tail -n 20 "$LOG_FILE" ;;
        2) less "$LOG_FILE" ;;
        3) echo; grep '\[ERROR\]' "$LOG_FILE" || echo "No errors logged." ;;
        4) echo; log_stats ;;
        5) echo; { grep ' SUMMARY ' "$LOG_FILE" || echo "No operations logged yet."; } | tail -n 20 ;;
        *) echo "Invalid option." ;;
    esac
}

pause() { echo; read -rp "Press Enter to return to the menu..." _; }

show_menu() {
    clear
    echo "=============================================="
    echo "     MULTI-LEVEL DIRECTORY BACKUP TOOL"
    echo "=============================================="
    echo "  1) Full backup"
    echo "  2) Incremental backup"
    echo "  3) View log history"
    echo "  4) Restore from backup"
    echo "  5) Exit"
    echo "=============================================="
}

main() {
    local opt
    while true; do
        show_menu
        read -rp "Enter your choice [1-5]: " opt || { echo; exit 0; }
        case "$opt" in
            1)
                if ask_source_dir; then full_backup "$SRC_DIR"; fi
                pause ;;
            2)
                if ask_source_dir; then incremental_backup "$SRC_DIR"; fi
                pause ;;
            3)
                view_logs
                pause ;;
            4)
                restore_menu
                pause ;;
            5)
                echo "Goodbye!"
                log_msg INFO "Session ended"
                exit 0 ;;
            *)
                echo "Invalid choice. Please enter a number from 1 to 5."
                sleep 1 ;;
        esac
    done
}

log_msg INFO "Session started"
main
