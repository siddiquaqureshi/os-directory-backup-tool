#!/usr/bin/env bash
# lib/backup_engine.sh - OWNER: Tahira (this is a PLACEHOLDER so the menu runs now)
#
# CONTRACT (keep these function names and arguments):
#   full_backup        /absolute/path/to/source_dir
#   incremental_backup /absolute/path/to/source_dir
# Archives must be saved in $BACKUP_DIR and end with .tar.gz
# Naming used here: full_<dir>_<YYYYmmdd_HHMMSS>.tar.gz / incr_<dir>_<...>.tar.gz

full_backup() {
    local src="$1"
    local base parent ts archive
    base="$(basename "$src")"; parent="$(dirname "$src")"
    ts="$(date '+%Y%m%d_%H%M%S')"
    archive="$BACKUP_DIR/full_${base}_${ts}.tar.gz"

    if tar -czpf "$archive" -C "$parent" "$base"; then
        touch "$BACKUP_DIR/.last_${base}"
        log_msg INFO "Full backup of $src -> $archive"
        echo "Full backup created: $archive"
    else
        log_msg ERROR "Full backup FAILED for $src"
        echo "ERROR: full backup failed."
        return 1
    fi
}

incremental_backup() {
    local src="$1"
    local base parent ts archive marker
    base="$(basename "$src")"; parent="$(dirname "$src")"
    marker="$BACKUP_DIR/.last_${base}"

    if [[ ! -f "$marker" ]]; then
        echo "No previous backup found - running a full backup instead."
        full_backup "$src"
        return
    fi

    ts="$(date '+%Y%m%d_%H%M%S')"
    archive="$BACKUP_DIR/incr_${base}_${ts}.tar.gz"

    local count
    count="$(cd "$parent" && find "$base" -type f -newer "$marker" | wc -l)"
    if [[ "$count" -eq 0 ]]; then
        echo "No files changed since last backup."
        log_msg INFO "Incremental backup of $src: nothing changed"
        return 0
    fi

    if (cd "$parent" && find "$base" -type f -newer "$marker" -print0 \
            | tar --null -czpf "$archive" -T -); then
        touch "$marker"
        log_msg INFO "Incremental backup of $src ($count files) -> $archive"
        echo "Incremental backup created: $archive ($count files)"
    else
        log_msg ERROR "Incremental backup FAILED for $src"
        echo "ERROR: incremental backup failed."
        return 1
    fi
}
