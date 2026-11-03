#!/usr/bin/env bash
# lib/restore.sh - OWNER: Siddiqua - restore module
# Public function: restore_menu

# Fill the global ARCHIVES array with all .tar.gz files (oldest first)
_load_archives() {
    ARCHIVES=()
    while IFS= read -r f; do
        ARCHIVES+=("$f")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' | sort)
}

# Print numbered list of archives with size and date
_show_archives() {
    local i=1 f size date
    printf '\n%-4s %-50s %-8s %s\n' "No." "Archive" "Size" "Created"
    printf -- '------------------------------------------------------------------------------------\n'
    for f in "${ARCHIVES[@]}"; do
        size="$(du -h "$f" | cut -f1)"
        date="$(date -r "$f" '+%Y-%m-%d %H:%M')"
        printf '%-4s %-50s %-8s %s\n' "$i" "$(basename "$f")" "$size" "$date"
        i=$((i + 1))
    done
    echo
}

restore_menu() {
    echo
    echo "=========== RESTORE FROM BACKUP ==========="

    _load_archives
    if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
        echo "No backups found in: $BACKUP_DIR"
        echo "Run a backup first (options 1 or 2)."
        return 1
    fi
    _show_archives

    # ---- 1. choose archive ----
    local choice archive
    read -rp "Enter archive number to restore (0 to cancel): " choice
    [[ "$choice" == "0" ]] && { echo "Restore cancelled."; return 0; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ARCHIVES[@]} )); then
        echo "ERROR: invalid selection."
        log_msg ERROR "Restore: invalid archive selection '$choice'"
        return 1
    fi
    archive="${ARCHIVES[$((choice - 1))]}"

    # ---- 2. verify archive integrity ----
    echo "Checking archive integrity..."
    if ! gzip -t "$archive" 2>/dev/null || ! tar -tzf "$archive" >/dev/null 2>&1; then
        echo "ERROR: archive is corrupted or unreadable: $(basename "$archive")"
        log_msg ERROR "Restore: corrupted archive $archive"
        return 1
    fi
    echo "Archive is OK."

    # ---- 3. choose destination ----
    local default_dest dest
    default_dest="$HOME/restored_$(date '+%Y%m%d_%H%M%S')"
    read -rp "Restore to which directory? [$default_dest]: " dest
    dest="${dest:-$default_dest}"
    dest="${dest/#\~/$HOME}"

    if [[ -e "$dest" && ! -d "$dest" ]]; then
        echo "ERROR: $dest exists and is not a directory."
        log_msg ERROR "Restore: destination $dest is not a directory"
        return 1
    fi
    if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
        echo "WARNING: $dest is not empty. Existing files with the same name will be overwritten."
        local ow
        read -rp "Continue? (y/n): " ow
        [[ "$ow" =~ ^[Yy]$ ]] || { echo "Restore cancelled."; return 0; }
    fi
    if ! mkdir -p "$dest" 2>/dev/null || [[ ! -w "$dest" ]]; then
        echo "ERROR: cannot create or write to $dest"
        log_msg ERROR "Restore: cannot write to $dest"
        return 1
    fi

    # ---- 4. full or partial restore ----
    local mode member=""
    echo
    echo "  1) Restore everything in this archive"
    echo "  2) Restore one specific file/folder from this archive"
    read -rp "Choose [1-2]: " mode
    case "$mode" in
        1) ;;
        2)
            echo "Archive contents (first 40 entries):"
            tar -tzf "$archive" | head -n 40
            echo "..."
            read -rp "Enter the exact path to restore (as shown above): " member
            if [[ -z "$member" ]] || ! tar -tzf "$archive" "$member" >/dev/null 2>&1; then
                echo "ERROR: '$member' was not found in the archive."
                log_msg ERROR "Restore: '$member' not found in $archive"
                return 1
            fi
            ;;
        *) echo "ERROR: invalid option."; return 1 ;;
    esac

    # ---- 5. extract (-p keeps permissions; --same-owner only works as root) ----
    local opts=(-xzp)
    if [[ $EUID -eq 0 ]]; then
        opts+=(--same-owner)
    else
        echo "Note: not running as root, so original file ownership cannot be restored"
        echo "      (permissions are still preserved). Use 'sudo ./backup.sh' for ownership."
    fi

    echo "Restoring..."
    local count
    if [[ -n "$member" ]]; then
        tar "${opts[@]}" -f "$archive" -C "$dest" "$member"
    else
        tar "${opts[@]}" -f "$archive" -C "$dest"
    fi

    if [[ $? -eq 0 ]]; then
        count="$(find "$dest" -type f | wc -l)"
        echo "SUCCESS: restored to $dest ($count files now in destination)"
        log_msg INFO "Restore: $(basename "$archive") -> $dest ${member:+(only $member)}"
    else
        echo "ERROR: restore failed."
        log_msg ERROR "Restore FAILED: $archive -> $dest"
        return 1
    fi
}
