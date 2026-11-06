#!/usr/bin/env bash
# tahira_backup_engine.sh - OWNER: Tahira - Core Directory & Compression Engine
#
# PUBLIC FUNCTIONS (contract used by backup.sh - names/arguments unchanged):
#   full_backup        /absolute/path/to/source_dir
#   incremental_backup /absolute/path/to/source_dir
# EXTRA helpers (optional, can be used from the menu / demo):
#   traverse_directory /path     - recursive tree view + file/folder counts
#
# Uses from other modules / config.sh:
#   $BACKUP_DIR   where archives are stored      (config.sh)
#   log_msg LEVEL "message"                      (lib/logger.sh - Kaneeza)
#
# Archive layout: the source folder name is the top-level entry, e.g.
#   Documents/            <- restore.sh relies on this layout
#   Documents/a/b/file.txt
# Naming: full_<dir>_<YYYYmmdd_HHMMSS>.tar.gz / incr_<dir>_<YYYYmmdd_HHMMSS>.tar.gz
#
# Return codes: 0 = success (or nothing to do), 1 = error.


# ---------------------------------------------------------------------------
# Standalone support: if the other modules are not loaded, use safe defaults
# so this file works completely on its own (and still works inside the project).
# ---------------------------------------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
if ! declare -F log_msg >/dev/null; then
    LOG_FILE="${LOG_FILE:-$BACKUP_DIR/backup.log}"
    log_msg() {
        local level="$1"; shift
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
    }
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Make sure the backup storage folder exists and is writable.
_engine_prepare_storage() {
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null || [[ ! -w "$BACKUP_DIR" ]]; then
        echo "ERROR: cannot write to backup directory: $BACKUP_DIR"
        log_msg ERROR "Backup directory not writable: $BACKUP_DIR"
        return 1
    fi
    return 0
}

# Check the source folder (menu already checks, but the engine must be safe
# on its own too, e.g. if someone calls it from another script).
_engine_check_source() {
    local src="$1"
    if [[ -z "$src" || ! -d "$src" ]]; then
        echo "ERROR: '$src' is not a directory."
        log_msg ERROR "Engine: invalid source directory '$src'"
        return 1
    fi
    if [[ ! -r "$src" || ! -x "$src" ]]; then
        echo "ERROR: no read/access permission for '$src'."
        log_msg ERROR "Engine: no permission on '$src'"
        return 1
    fi
    return 0
}

# Marker file = "time of the last successful backup of this source".
# The path hash keeps /home/a/docs and /home/b/docs from sharing one marker.
_engine_marker() {
    local src="$1" base hash
    base="$(basename "$src")"
    hash="$(printf '%s' "$src" | cksum | cut -d' ' -f1)"
    echo "$BACKUP_DIR/.last_${base}_${hash}"
}

# Unique archive path:  <type>_<dir>_<timestamp>.tar.gz
# (adds _1, _2 ... if two backups are made in the same second)
_engine_archive_name() {
    local type="$1" base="$2" ts path n=0
    ts="$(date '+%Y%m%d_%H%M%S')"
    path="$BACKUP_DIR/${type}_${base}_${ts}.tar.gz"
    while [[ -e "$path" ]]; do
        n=$((n + 1))
        path="$BACKUP_DIR/${type}_${base}_${ts}_${n}.tar.gz"
    done
    echo "$path"
}

# If the backup folder lives INSIDE the source (e.g. user backs up the whole
# project folder), we must not put our own archives into the archive.
# Prints the path relative to the source's parent (e.g. "proj/backups") or nothing.
_engine_exclude_path() {
    local src="$1" base
    base="$(basename "$src")"
    if [[ "$BACKUP_DIR" == "$src"/* ]]; then
        echo "$base/${BACKUP_DIR#$src/}"
    fi
}

# Print the tar error text (if any) into the log, one line each.
_engine_log_tar_errors() {
    local errfile="$1" line
    [[ -s "$errfile" ]] || return 0
    while IFS= read -r line; do
        log_msg ERROR "tar: $line"
    done < "$errfile"
}

# ---------------------------------------------------------------------------
# Recursive directory traversal
# ---------------------------------------------------------------------------
# traverse_directory <dir>
# Walks the tree recursively (function calls itself for every sub-folder),
# prints an indented tree and sets:
#   TRAVERSE_FILES  - number of files (symlinks included)
#   TRAVERSE_DIRS   - number of sub-directories
#   TRAVERSE_DEPTH  - deepest nesting level found
TRAVERSE_FILES=0
TRAVERSE_DIRS=0
TRAVERSE_DEPTH=0

_traverse_rec() {
    local dir="$1" depth="$2" indent="" i entry
    local old_null old_dot
    old_null="$(shopt -p nullglob)"; old_dot="$(shopt -p dotglob)"

    (( depth > TRAVERSE_DEPTH )) && TRAVERSE_DEPTH=$depth
    for ((i = 1; i < depth; i++)); do indent+="    "; done

    shopt -s nullglob dotglob          # include hidden files, no literal '*'
    local entries=("$dir"/*)
    eval "$old_null"; eval "$old_dot"

    for entry in "${entries[@]}"; do
        if [[ -L "$entry" ]]; then
            echo "${indent}|-- $(basename "$entry")  (link)"
            TRAVERSE_FILES=$((TRAVERSE_FILES + 1))
        elif [[ -d "$entry" ]]; then
            echo "${indent}|-- $(basename "$entry")/"
            TRAVERSE_DIRS=$((TRAVERSE_DIRS + 1))
            if [[ -r "$entry" && -x "$entry" ]]; then
                _traverse_rec "$entry" $((depth + 1))     # <-- recursion
            else
                echo "${indent}    (permission denied)"
                log_msg WARN "Traverse: permission denied on $entry"
            fi
        else
            echo "${indent}|-- $(basename "$entry")"
            TRAVERSE_FILES=$((TRAVERSE_FILES + 1))
        fi
    done
}

traverse_directory() {
    local dir="${1%/}"
    _engine_check_source "$dir" || return 1
    TRAVERSE_FILES=0; TRAVERSE_DIRS=0; TRAVERSE_DEPTH=0
    echo "$(basename "$dir")/"
    _traverse_rec "$dir" 1
    echo "------------------------------------------"
    echo "Folders: $TRAVERSE_DIRS   Files: $TRAVERSE_FILES   Max depth: $TRAVERSE_DEPTH"
}

# ---------------------------------------------------------------------------
# FULL BACKUP
# ---------------------------------------------------------------------------
full_backup() {
    local src="${1%/}"
    local base parent archive errfile excl files dirs size
    local -a tar_opts

    _engine_check_source "$src" || return 1
    _engine_prepare_storage     || return 1

    base="$(basename "$src")"; parent="$(dirname "$src")"
    archive="$(_engine_archive_name full "$base")"
    errfile="$(mktemp)"
    excl="$(_engine_exclude_path "$src")"

    # Count what we are about to archive (find walks every nested level).
    files="$(find "$src" -type f -o -type l 2>/dev/null | wc -l)"
    dirs="$(find "$src" -mindepth 1 -type d 2>/dev/null | wc -l)"

    echo "Backing up '$src' ($files files, $dirs sub-folders) ..."
    log_msg INFO "Full backup started: $src ($files files, $dirs folders)"

    # Take the timestamp BEFORE archiving so files edited while the backup
    # runs are picked up by the next incremental backup.
    local stamp; stamp="$(mktemp "$BACKUP_DIR/.stamp.XXXXXX")"

    tar_opts=(-czpf "$archive" -C "$parent")
    [[ -n "$excl" ]] && tar_opts+=(--exclude="$excl")
    tar "${tar_opts[@]}" "$base" 2>"$errfile"
    local rc=$?

    # tar: 0 = ok, 1 = some file changed/unreadable while reading, 2 = fatal
    if [[ $rc -ge 2 ]]; then
        echo "ERROR: full backup failed."
        _engine_log_tar_errors "$errfile"
        log_msg ERROR "Full backup FAILED for $src (tar exit code $rc)"
        rm -f "$archive" "$errfile" "$stamp"
        return 1
    fi
    if [[ $rc -eq 1 ]]; then
        echo "WARNING: some files could not be read or changed during backup (see log)."
        _engine_log_tar_errors "$errfile"
        log_msg WARN "Full backup of $src finished with warnings"
    fi

    mv -f "$stamp" "$(_engine_marker "$src")"
    rm -f "$errfile"
    size="$(du -h "$archive" | cut -f1)"
    log_msg INFO "Full backup of $src -> $archive ($files files, $dirs folders, $size)"
    echo "Full backup created: $archive"
    echo "  Files: $files   Folders: $dirs   Archive size: $size"
    return 0
}

# ---------------------------------------------------------------------------
# INCREMENTAL BACKUP
# ---------------------------------------------------------------------------
incremental_backup() {
    local src="${1%/}"
    local base parent archive marker listfile errfile excl count size stamp rc

    _engine_check_source "$src" || return 1
    _engine_prepare_storage     || return 1

    base="$(basename "$src")"; parent="$(dirname "$src")"
    marker="$(_engine_marker "$src")"

    if [[ ! -f "$marker" ]]; then
        echo "No previous backup found - running a full backup instead."
        log_msg INFO "Incremental requested for $src but no previous backup: running full"
        full_backup "$src"
        return
    fi

    excl="$(_engine_exclude_path "$src")"
    listfile="$(mktemp)"
    errfile="$(mktemp)"

    # Files/links modified since the last backup (all nested levels).
    # Paths are relative to $parent, so they start with "<base>/".
    if [[ -n "$excl" ]]; then
        ( cd "$parent" && find "$base" \( -path "$excl" -prune \) -o \
            \( \( -type f -o -type l \) -newer "$marker" -print0 \) ) > "$listfile" 2>/dev/null
    else
        ( cd "$parent" && find "$base" \( -type f -o -type l \) -newer "$marker" -print0 ) \
            > "$listfile" 2>/dev/null
    fi
    count="$(tr -cd '\0' < "$listfile" | wc -c)"

    if [[ "$count" -eq 0 ]]; then
        echo "No files changed since last backup."
        log_msg INFO "Incremental backup of $src: nothing changed"
        rm -f "$listfile" "$errfile"
        return 0
    fi

    # Also store every folder entry (no contents) so folder permissions
    # are preserved when restoring.
    if [[ -n "$excl" ]]; then
        ( cd "$parent" && find "$base" \( -path "$excl" -prune \) -o \
            \( -type d -print0 \) ) >> "$listfile" 2>/dev/null
    else
        ( cd "$parent" && find "$base" -type d -print0 ) >> "$listfile" 2>/dev/null
    fi

    archive="$(_engine_archive_name incr "$base")"
    echo "Incremental backup of '$src' ($count changed files) ..."
    log_msg INFO "Incremental backup started: $src ($count changed files)"

    stamp="$(mktemp "$BACKUP_DIR/.stamp.XXXXXX")"

    tar -czpf "$archive" -C "$parent" --no-recursion --null -T "$listfile" 2>"$errfile"
    rc=$?

    if [[ $rc -ge 2 ]]; then
        echo "ERROR: incremental backup failed."
        _engine_log_tar_errors "$errfile"
        log_msg ERROR "Incremental backup FAILED for $src (tar exit code $rc)"
        rm -f "$archive" "$listfile" "$errfile" "$stamp"
        return 1
    fi
    if [[ $rc -eq 1 ]]; then
        echo "WARNING: some files could not be read or changed during backup (see log)."
        _engine_log_tar_errors "$errfile"
        log_msg WARN "Incremental backup of $src finished with warnings"
    fi

    mv -f "$stamp" "$marker"
    rm -f "$listfile" "$errfile"
    size="$(du -h "$archive" | cut -f1)"
    log_msg INFO "Incremental backup of $src ($count files) -> $archive ($size)"
    echo "Incremental backup created: $archive ($count files, $size)"
    return 0
}

# ---------------------------------------------------------------------------
# Run directly (not sourced):  ./tahira_backup_engine.sh full|incr|tree <dir>
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$1" in
        full) full_backup "$(cd "$2" 2>/dev/null && pwd)" ;;
        incr) incremental_backup "$(cd "$2" 2>/dev/null && pwd)" ;;
        tree) traverse_directory "$2" ;;
        *) echo "Usage: $0 {full|incr|tree} <directory>"; exit 1 ;;
    esac
fi
