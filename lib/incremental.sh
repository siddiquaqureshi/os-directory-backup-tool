#!/usr/bin/env bash
# lib/incremental.sh - OWNER: Kaneeza Batool - Timestamp Comparison for
#                      Incremental Backup Filtering
#
# ALGORITHM
#   After every successful backup an INDEX of the source is saved: one line per
#   entry with type, mode, owner, mtime and size (format of perm_snapshot in
#   lib/permissions.sh). On the next incremental backup a fresh snapshot is
#   compared with that index, path by path:
#
#     path only in new snapshot            -> NEW       (backed up)
#     mtime or size changed                -> MODIFIED  (backed up)
#     only mode / owner / group changed    -> PERMS     (backed up, so the new
#                                                        permissions are kept)
#     path only in old index               -> DELETED   (recorded in a list)
#     everything equal                     -> UNCHANGED (skipped)
#
#   HOW: both sides are written as sorted signature lines
#   (path, type, mtime, size, mode, uid, gid) and compared with `diff`.
#   Identical lines = unchanged entries; diff prints only the changed ones,
#   which are then classified as above. mtime comes from find -printf %T@,
#   the same value `stat -c %Y` shows (see ts_mtime).
#
#   Why not just "find -newer <marker>"? That only looks at mtime, so it misses
#   files moved/copied in with an old mtime (mv, cp -p, tar x), chmod/chown-only
#   changes, and deletions. The index comparison catches all of them.
#
#   If no index exists yet but a reference time does (e.g. Tahira's marker file
#   from an older backup), a fallback is used: an entry is changed when its
#   mtime OR ctime is newer than the reference (ctime also changes on chmod,
#   chown and mv).
#
# PUBLIC FUNCTIONS
#   ts_mtime FILE                       -> mtime in epoch seconds
#   ts_compare FILE_A FILE_B            -> prints NEWER | OLDER | SAME (A vs B)
#   ts_is_newer FILE REF_EPOCH          -> return 0 if FILE changed after REF
#   ts_index_path SOURCE_DIR            -> where the index of this source is kept
#   ts_last_backup_time SOURCE_DIR      -> "YYYY-mm-dd HH:MM:SS" or "never"
#   ts_detect_changes SOURCE_DIR [REF] [EXCLUDE]
#                                       -> compare, fill TS_* counters + lists
#   ts_changed_list SOURCE_DIR OUTFILE [REF] [EXCLUDE]
#                                       -> NUL separated path list for
#                                          tar --null --no-recursion -T OUTFILE
#   ts_save_deleted ARCHIVE             -> "<archive>.deleted" list of removed files
#   ts_take_snapshot SOURCE_DIR [EXCLUDE] -> snapshot before a FULL backup
#   ts_save_manifest ARCHIVE            -> .perms of only what went into an
#                                          incremental archive
#   ts_commit_index SOURCE_DIR [EXCLUDE] -> save the snapshot as the new index
#                                          (call ONLY after the backup succeeded)
#   ts_report                           -> print a short change summary
#   ts_show_diff                        -> the diff behind the last comparison
#
#   EXCLUDE = path relative to the source parent left out (engine's --exclude)
#
# Uses: $BACKUP_DIR (config.sh), log_msg (logger.sh), perm_snapshot (permissions.sh)

_TS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run directly (not from the menu): use the project's backups/ and logs/
if [[ "${BASH_SOURCE[0]}" == "$0" && -f "$_TS_DIR/../config.sh" ]]; then
    source "$_TS_DIR/../config.sh"
    source "$_TS_DIR/logger.sh"
fi
declare -F perm_snapshot >/dev/null || source "$_TS_DIR/permissions.sh"
if ! declare -F log_msg >/dev/null; then
    # standalone (no logger.sh): only warnings and errors go to the screen
    log_msg() { [[ "$1" == INFO ]] || printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2; }
fi
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"

# Results of the last ts_detect_changes
TS_NEW=0; TS_MODIFIED=0; TS_PERMS=0; TS_DELETED=0; TS_UNCHANGED=0; TS_CHANGED=0
TS_MODE=""            # "index" or "reference-time"
TS_SNAPSHOT=""        # temp snapshot taken by ts_detect_changes
TS_CHANGES=""         # temp file: "<STATUS>\t<type>\t<path>" per changed entry
TS_SOURCE=""
TS_DIFF=""            # temp file: raw diff output of the last comparison

# ---------------------------------------------------------------------------
# Basic timestamp helpers
# ---------------------------------------------------------------------------
ts_mtime() {
    stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0
}

_ts_ctime() {
    stat -c %Z -- "$1" 2>/dev/null || stat -f %c -- "$1" 2>/dev/null || echo 0
}

ts_compare() {
    local a b
    a="$(ts_mtime "$1")"; b="$(ts_mtime "$2")"
    if   (( a > b )); then echo NEWER
    elif (( a < b )); then echo OLDER
    else echo SAME
    fi
}

ts_is_newer() {
    local file="$1" ref="$2"
    (( $(ts_mtime "$file") > ref || $(_ts_ctime "$file") > ref ))
}

# Same naming idea as the engine's marker: folder name + hash of full path,
# so /home/a/docs and /home/b/docs get separate indexes.
ts_index_path() {
    local src="${1%/}" hash
    hash="$(printf '%s' "$src" | cksum | cut -d' ' -f1)"
    echo "$BACKUP_DIR/.index_$(basename "$src")_${hash}"
}

ts_last_backup_time() {
    local index; index="$(ts_index_path "$1")"
    if [[ -f "$index" ]]; then
        date -d "@$(ts_mtime "$index")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$index" '+%Y-%m-%d %H:%M:%S'
    else
        echo "never"
    fi
}

_ts_cleanup() {
    [[ -n "$TS_CHANGES" ]] && rm -f "$TS_CHANGES"
    [[ -n "$TS_DIFF" ]] && rm -f "$TS_DIFF"
    TS_CHANGES=""; TS_DIFF=""
}

# Signature lines for diff, sorted by path (C locale = same order everywhere):
#   path  type  mtime  size  mode  uid  gid
_ts_signatures() {
    awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "d" { print $9, $1, $7, $8, $2, $3, $4 }' "$1" |
        LC_ALL=C sort
}

# ts_show_diff - the raw diff output of the last comparison, made readable:
#   - old state   + new state   (mtime as a date, then size, mode, uid:gid)
ts_show_diff() {
    if [[ -z "$TS_DIFF" || ! -s "$TS_DIFF" ]]; then
        echo "No differences (or no comparison done yet)."
        return 0
    fi
    echo "diff of last backup index (-) against the folder now (+):"
    grep '^[<>] ' "$TS_DIFF" | while IFS=$'\t' read -r path type mtime size mode uid gid; do
        printf '  %s %-40s %s  size=%-8s mode=%s owner=%s:%s\n' \
            "$([[ "${path:0:1}" == "<" ]] && echo - || echo +)" "${path:2}" \
            "$(date -d "@${mtime%.*}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$size" "$mode" "$uid" "$gid"
    done
}

# ---------------------------------------------------------------------------
# ts_detect_changes SOURCE_DIR [REFERENCE]
#   REFERENCE (optional, used only when no index exists): a file whose mtime
#   is the last backup time (e.g. the engine's marker) or an epoch number.
#   Return: 0 = compared, 2 = no index and no reference (full backup needed),
#           1 = error.
# ---------------------------------------------------------------------------
ts_detect_changes() {
    local src="${1%/}" ref="$2" excl="$3" index ref_epoch base parent
    local -a prune=()
    TS_NEW=0; TS_MODIFIED=0; TS_PERMS=0; TS_DELETED=0; TS_UNCHANGED=0; TS_CHANGED=0
    _ts_cleanup
    [[ -n "$TS_SNAPSHOT" ]] && rm -f "$TS_SNAPSHOT"
    TS_SOURCE="$src"

    if [[ ! -d "$src" ]]; then
        log_msg ERROR "Incremental: '$src' is not a directory"
        return 1
    fi
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    index="$(ts_index_path "$src")"
    base="$(basename "$src")"; parent="$(dirname "$src")"

    # Snapshot taken BEFORE the archive is written, so anything changed while
    # the backup runs will differ from the index next time.
    TS_SNAPSHOT="$(mktemp)"; TS_CHANGES="$(mktemp)"
    [[ -n "$excl" ]] && prune=( -path "$excl" -prune -o )
    perm_snapshot "$src" "$TS_SNAPSHOT" "$excl" || return 1

    if [[ -f "$index" ]]; then
        TS_MODE="index"
        # 1. Turn the old index and the new snapshot into sorted "signature"
        #    lines:  path  type  mtime  size  mode  uid  gid
        #    (folders left out - the engine always stores them anyway)
        # 2. diff the two signature files: a line that is identical on both
        #    sides means the entry is unchanged, so diff prints only changes:
        #      "< line" = old state of an entry,  "> line" = new state
        # 3. Classify by path: only ">" = NEW, only "<" = DELETED, both = the
        #    entry changed -> MODIFIED (type/mtime/size) or PERMS (mode/owner)
        local old_sig new_sig rc
        old_sig="$(mktemp)"; new_sig="$(mktemp)"
        _ts_signatures "$index"       > "$old_sig"
        _ts_signatures "$TS_SNAPSHOT" > "$new_sig"
        TS_DIFF="$(mktemp)"
        diff "$old_sig" "$new_sig" > "$TS_DIFF"; rc=$?
        if (( rc > 1 )); then          # diff: 0 = same, 1 = different, 2 = error
            log_msg ERROR "Incremental: diff failed comparing index of $src"
            rm -f "$old_sig" "$new_sig"
            return 1
        fi

        awk -v OFS='\t' '
            FNR == NR {                                   # pass 1: diff output
                tag = substr($0, 1, 2); line = substr($0, 3)
                split(line, f, "\t")
                if (tag == "< ") old[f[1]] = line
                if (tag == "> ") new[f[1]] = line
                next
            }
            {                                             # pass 2: new signatures
                split($0, f, "\t"); p = f[1]
                if (!(p in new)) { print "UNCHANGED", f[2], p; next }
                if (!(p in old)) { print "NEW", f[2], p; next }
                split(old[p], o, "\t")
                if (f[2] != o[2] || f[3] != o[3] || f[4] != o[4]) print "MODIFIED", f[2], p
                else print "PERMS", f[2], p
                delete old[p]
            }
            END { for (p in old) { split(old[p], o, "\t"); print "DELETED", o[2], p } }
        ' "$TS_DIFF" "$new_sig" > "$TS_CHANGES"
        rm -f "$old_sig" "$new_sig"
    else
        if [[ -z "$ref" ]]; then
            log_msg INFO "Incremental: no index for $src - full backup required"
            return 2
        fi
        if [[ "$ref" =~ ^[0-9]+$ ]]; then ref_epoch="$ref"
        elif [[ -e "$ref" ]]; then ref_epoch="$(ts_mtime "$ref")"
        else
            log_msg INFO "Incremental: no index and no reference for $src - full backup required"
            return 2
        fi
        TS_MODE="reference-time"
        # mtime (%T@) or ctime (%C@) newer than the reference time
        ( cd "$parent" && find "$base" "${prune[@]}" ! -type d ! -name $'*\t*' ! -name $'*\n*' \
            -printf '%T@\t%C@\t%y\t%p\n' 2>/dev/null ) |
        awk -F'\t' -v OFS='\t' -v ref="$ref_epoch" '
            { t = ($1 > $2 ? $1 : $2)
              print (t > ref ? "MODIFIED" : "UNCHANGED"), ($3 == "f" || $3 == "l" ? $3 : "o"), $4 }
        ' > "$TS_CHANGES"
    fi

    TS_NEW="$(grep -c '^NEW' "$TS_CHANGES")"
    TS_MODIFIED="$(grep -c '^MODIFIED' "$TS_CHANGES")"
    TS_PERMS="$(grep -c '^PERMS' "$TS_CHANGES")"
    TS_DELETED="$(grep -c '^DELETED' "$TS_CHANGES")"
    TS_UNCHANGED="$(grep -c '^UNCHANGED' "$TS_CHANGES")"
    TS_CHANGED=$((TS_NEW + TS_MODIFIED + TS_PERMS))

    log_msg INFO "Incremental: compared $src ($TS_MODE) new=$TS_NEW modified=$TS_MODIFIED perms=$TS_PERMS deleted=$TS_DELETED unchanged=$TS_UNCHANGED"
    return 0
}

# ---------------------------------------------------------------------------
# ts_changed_list SOURCE_DIR OUTFILE [REFERENCE]
#   Writes NUL separated paths (relative to the source's parent, like
#   "Documents/a/b.txt") of every NEW/MODIFIED/PERMS entry, followed by every
#   folder (so folder permissions are kept). Use with:
#       tar -czpf ARCHIVE -C PARENT --no-recursion --null -T OUTFILE
#   Return: 0 = list written (TS_CHANGED may be 0), 2 = full backup needed,
#           1 = error.
# ---------------------------------------------------------------------------
ts_changed_list() {
    local src="${1%/}" out="$2" ref="$3" excl="$4" rc
    ts_detect_changes "$src" "$ref" "$excl"; rc=$?
    (( rc != 0 )) && return $rc

    : > "$out"
    awk -F'\t' '$1 == "NEW" || $1 == "MODIFIED" || $1 == "PERMS" { printf "%s\0", $3 }' "$TS_CHANGES" >> "$out"
    if (( TS_CHANGED > 0 )); then
        awk -F'\t' '!/^#/ && $1 == "d" { printf "%s\0", $9 }' "$TS_SNAPSHOT" >> "$out"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# ts_save_deleted ARCHIVE  - tar cannot store "this file was deleted", so the
# list is written next to the archive:  incr_docs_2026....deleted
# ---------------------------------------------------------------------------
ts_save_deleted() {
    local archive="$1" out
    (( TS_DELETED > 0 )) || return 0
    out="${archive%.tar.gz}.deleted"
    awk -F'\t' '$1 == "DELETED" { print $3 }' "$TS_CHANGES" | sort > "$out"
    log_msg INFO "Incremental: $TS_DELETED deleted entries recorded in $out"
}

# ---------------------------------------------------------------------------
# ts_take_snapshot SOURCE_DIR [EXCLUDE] - for a FULL backup: record the state
# just before archiving; ts_commit_index saves it once the backup succeeded.
# ---------------------------------------------------------------------------
ts_take_snapshot() {
    local src="${1%/}" excl="$2"
    _ts_cleanup
    [[ -n "$TS_SNAPSHOT" ]] && rm -f "$TS_SNAPSHOT"
    TS_SOURCE="$src"; TS_SNAPSHOT="$(mktemp)"
    perm_snapshot "$src" "$TS_SNAPSHOT" "$excl"
}

# ---------------------------------------------------------------------------
# ts_save_manifest ARCHIVE - permission manifest for an INCREMENTAL archive:
# only the entries that went into it (changed files + all folders), so
# perm_verify does not report the unchanged files as missing.
# ---------------------------------------------------------------------------
ts_save_manifest() {
    local archive="$1" manifest
    manifest="$(perm_manifest_path "$archive")"
    awk -F'\t' '
        FNR == NR { if ($1 == "NEW" || $1 == "MODIFIED" || $1 == "PERMS") take[$3] = 1; next }
        /^#/ || $1 == "d" || ($9 in take)
    ' "$TS_CHANGES" "$TS_SNAPSHOT" > "$manifest" || { rm -f "$manifest"; return 1; }
    log_msg INFO "Permissions: manifest saved $manifest ($(grep -vc '^#' "$manifest") entries)"
}

# ---------------------------------------------------------------------------
# ts_commit_index SOURCE_DIR [EXCLUDE] - after a SUCCESSFUL backup, the snapshot taken
# before archiving becomes the new index. For a full backup (no earlier
# ts_detect_changes), a fresh snapshot is taken.
# ---------------------------------------------------------------------------
ts_commit_index() {
    local src="${1%/}" excl="$2" index
    index="$(ts_index_path "$src")"
    mkdir -p "$BACKUP_DIR" 2>/dev/null

    if [[ -n "$TS_SNAPSHOT" && -f "$TS_SNAPSHOT" && "$TS_SOURCE" == "$src" ]]; then
        mv -f "$TS_SNAPSHOT" "$index" || return 1
    else
        perm_snapshot "$src" "$index" "$excl" || return 1
    fi
    TS_SNAPSHOT=""
    _ts_cleanup
    log_msg INFO "Incremental: index updated for $src ($(grep -vc '^#' "$index") entries)"
}

# ---------------------------------------------------------------------------
# ts_report - human readable summary of the last ts_detect_changes
# ---------------------------------------------------------------------------
ts_report() {
    echo "Change detection ($TS_MODE) for '$TS_SOURCE':"
    printf '  New: %d   Modified: %d   Permission-only: %d   Deleted: %d   Unchanged: %d\n' \
        "$TS_NEW" "$TS_MODIFIED" "$TS_PERMS" "$TS_DELETED" "$TS_UNCHANGED"
    if [[ -n "$TS_CHANGES" && -s "$TS_CHANGES" ]]; then
        awk -F'\t' '$1 != "UNCHANGED" { printf "    %-9s %s\n", $1, $3 }' "$TS_CHANGES" | sort -k2 | head -n 20
        (( TS_CHANGED + TS_DELETED > 20 )) && echo "    ... ($((TS_CHANGED + TS_DELETED - 20)) more)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Run directly:
#   ./lib/incremental.sh check  <dir>   show what an incremental backup would take
#                                       (change report + the diff behind it)
#   ./lib/incremental.sh commit <dir>   mark the current state as backed up
#   ./lib/incremental.sh last   <dir>   time of the last indexed backup
#   ./lib/incremental.sh compare <a> <b> compare two files' timestamps (stat)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    dir="$(cd "$2" 2>/dev/null && pwd)"
    case "$1" in
        check)
            ts_detect_changes "$dir"; rc=$?
            if (( rc == 2 )); then echo "No index for '$dir' yet - a full backup is needed."
            elif (( rc == 0 )); then ts_report; echo; ts_show_diff; fi
            _ts_cleanup; rm -f "$TS_SNAPSHOT"
            ;;
        commit) ts_commit_index "$dir" && echo "Index saved: $(ts_index_path "$dir")" ;;
        last)   echo "Last backup of '$dir': $(ts_last_backup_time "$dir")" ;;
        compare)
            stat -c '%y  %n' -- "$2" "$3" || exit 1
            case "$(ts_compare "$2" "$3")" in
                NEWER) echo "RESULT: '$2' is NEWER than '$3'" ;;
                OLDER) echo "RESULT: '$2' is OLDER than '$3'" ;;
                *)     echo "RESULT: both have the SAME modification time" ;;
            esac
            ;;
        *) echo "Usage: $0 {check|commit|last <dir> | compare <file1> <file2>}"; exit 1 ;;
    esac
fi
