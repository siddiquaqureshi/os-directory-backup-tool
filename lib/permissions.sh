#!/usr/bin/env bash
# lib/permissions.sh - OWNER: Kaneeza Batool - Permission & Ownership Retention
#
# tar -p keeps permissions inside the archive, but nothing CHECKS that they
# really survive the backup -> restore round trip. This module does that:
#
#   1. Before a backup  : perm_check_source  - finds files tar cannot read
#   2. With every backup: perm_save_manifest - stores mode/owner/group/mtime of
#                         every entry in "<archive>.perms" (next to the archive)
#   3. After a restore  : perm_verify        - compares the restored tree with
#                         the manifest and (optionally) repairs it with
#                         chmod / chown / touch
#
# PUBLIC FUNCTIONS
#   perm_snapshot      SOURCE_DIR OUTFILE [EXCLUDE]  write metadata snapshot (shared format)
#   perm_show          PATH...                 stat: mode, owner, mtime of each path
#   perm_check_source  SOURCE_DIR              pre-backup readability check
#   perm_manifest_path ARCHIVE                 -> /path/full_x_2026....perms
#   perm_save_manifest SOURCE_DIR ARCHIVE [EXCLUDE]  snapshot saved next to the archive
#   perm_verify        MANIFEST DEST_DIR [--fix]
#                                              compare restored files with manifest
#
# SNAPSHOT FORMAT (tab separated, one entry per line, lines starting with # are
# comments). Paths are relative to the source's PARENT, exactly like the paths
# inside the tar archive ("Documents/a/b.txt"), so a restored tree in DEST can
# be checked as DEST/<path>.
#   type  mode  uid  gid  user  group  mtime  size  path
#   f     644   1000 1000 ali   ali    1762...  120   Documents/a/b.txt
# type: f = file, d = directory, l = symlink, o = other (fifo/socket/device)
#
# Uses: log_msg (lib/logger.sh). Requires GNU find/stat (Linux, Git Bash).

if ! declare -F log_msg >/dev/null; then
    # standalone (no logger.sh): only warnings and errors go to the screen
    log_msg() { [[ "$1" == INFO ]] || printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2; }
fi

# ---------------------------------------------------------------------------
# perm_snapshot SOURCE_DIR OUTFILE
#   Returns 0 on success. Names containing a TAB or NEWLINE cannot be stored
#   in this line format: they are skipped and reported with a WARN.
# ---------------------------------------------------------------------------
#   Optional EXCLUDE (3rd argument): a path relative to the source's parent
#   (e.g. "proj/backups") that is left out together with everything below it -
#   same meaning as the engine's tar --exclude.
perm_snapshot() {
    local src="${1%/}" out="$2" excl="$3" base parent skipped
    local -a prune=()
    if [[ -z "$src" || ! -d "$src" ]]; then
        echo "ERROR: perm_snapshot: '$src' is not a directory." >&2
        log_msg ERROR "Permissions: snapshot failed, '$src' is not a directory"
        return 1
    fi
    base="$(basename "$src")"; parent="$(dirname "$src")"
    [[ -n "$excl" ]] && prune=( -path "$excl" -prune -o )

    {
        echo "# backup-tool metadata snapshot v1"
        echo "# source=$src"
        echo "# created=$(date '+%Y-%m-%d %H:%M:%S') by=$(id -un 2>/dev/null)"
        echo "# type	mode	uid	gid	user	group	mtime	size	path"
        # %y type, %m octal mode, %U/%G numeric ids, %u/%g names,
        # %T@ mtime (epoch, with fractions), %s size, %p path
        ( cd "$parent" && find "$base" "${prune[@]}" \
            ! -name $'*\t*' ! -name $'*\n*' \
            -printf '%y\t%m\t%U\t%G\t%u\t%g\t%T@\t%s\t%p\n' 2>/dev/null ) |
        awk -F'\t' 'BEGIN { OFS = "\t" }
            { if ($1 != "f" && $1 != "d" && $1 != "l") $1 = "o"; print }'
    } > "$out" || {
        log_msg ERROR "Permissions: cannot write snapshot file $out"
        return 1
    }

    skipped="$( ( cd "$parent" && find "$base" "${prune[@]}" \( -name $'*\t*' -o -name $'*\n*' \) -print0 2>/dev/null ) | tr -cd '\0' | wc -c)"
    if (( skipped > 0 )); then
        log_msg WARN "Permissions: $skipped entries with TAB/NEWLINE in their name not recorded in snapshot"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# perm_show PATH...
#   Uses `stat` to print the permission bits, owner/group and modification
#   time of each path - the metadata this module preserves:
#     -rw-------  600  ali:ali (1000:1000)  2026-11-09 13:52:20  Docs/a/private.txt
# ---------------------------------------------------------------------------
perm_show() {
    local p rc=0
    for p in "$@"; do
        stat -c '%A  %a  %U:%G (%u:%g)  %.19y  %n' -- "$p" 2>/dev/null || {
            echo "  (cannot stat '$p')"; rc=1; }
    done
    return $rc
}

# ---------------------------------------------------------------------------
# perm_check_source SOURCE_DIR
#   Lists everything tar would fail on (unreadable files, folders that cannot
#   be entered) and special files. Return: 0 = all readable, 1 = problems found
#   (backup can still run, those entries will just be missing).
# ---------------------------------------------------------------------------
perm_check_source() {
    local src="${1%/}" unreadable special n_bad n_special
    if [[ -z "$src" || ! -d "$src" ]]; then
        echo "ERROR: '$src' is not a directory."
        log_msg ERROR "Permissions: check failed, '$src' is not a directory"
        return 1
    fi

    unreadable="$(find "$src" \( \( -type f ! -readable \) -o \( -type d \( ! -readable -o ! -executable \) \) \) -print 2>/dev/null)"
    special="$(find "$src" \( -type p -o -type s -o -type b -o -type c \) -print 2>/dev/null)"
    n_bad=0; n_special=0
    [[ -n "$unreadable" ]] && n_bad="$(printf '%s\n' "$unreadable" | wc -l)"
    [[ -n "$special" ]] && n_special="$(printf '%s\n' "$special" | wc -l)"

    echo "Permission check for '$src':"
    if (( n_bad > 0 )); then
        echo "  WARNING: $n_bad item(s) cannot be read and will NOT be backed up:"
        local -a first10
        mapfile -t first10 < <(printf '%s\n' "$unreadable" | head -n 10)
        perm_show "${first10[@]}" | sed 's/^/    /'      # stat: mode + owner
        (( n_bad > 10 )) && echo "    ... ($((n_bad - 10)) more, see log)"
        while IFS= read -r f; do log_msg WARN "Permissions: not readable: $f"; done <<< "$unreadable"
    else
        echo "  OK: every file and folder is readable."
    fi
    if (( n_special > 0 )); then
        echo "  NOTE: $n_special special file(s) (fifo/socket/device) found."
        log_msg INFO "Permissions: $n_special special files in $src"
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "  NOTE: not running as root - ownership (chown) can be recorded but"
        echo "        only restored by root. Modes (chmod) are always preserved."
    fi

    log_msg INFO "Permissions: source check $src - unreadable=$n_bad special=$n_special"
    (( n_bad == 0 ))
}

# ---------------------------------------------------------------------------
# Manifest stored next to the archive:  full_docs_2026....tar.gz -> ....perms
# (restore.sh only lists *.tar.gz, so the manifest never shows up there)
# ---------------------------------------------------------------------------
perm_manifest_path() {
    echo "${1%.tar.gz}.perms"
}

perm_save_manifest() {
    local src="${1%/}" archive="$2" excl="$3" manifest entries
    manifest="$(perm_manifest_path "$archive")"
    if perm_snapshot "$src" "$manifest" "$excl"; then
        entries="$(grep -vc '^#' "$manifest")"
        log_msg INFO "Permissions: manifest saved $manifest ($entries entries)"
        return 0
    fi
    rm -f "$manifest"
    return 1
}

# ---------------------------------------------------------------------------
# perm_verify MANIFEST DEST_DIR [--fix]
#   Compares every entry of the manifest that exists in DEST_DIR:
#     mode   always checked (files + folders; symlink modes are meaningless)
#     owner  checked when running as root (only root can chown)
#     mtime  checked for regular files (whole seconds)
#   Entries missing from DEST are counted (normal after a partial restore).
#   --fix repairs mismatches with chmod / chown / touch.
#   Sets PERM_CHECKED PERM_MISMATCH PERM_MISSING PERM_FIXED.
#   Return: 0 = everything matches (or was fixed), 1 = mismatches remain.
# ---------------------------------------------------------------------------
PERM_CHECKED=0; PERM_MISMATCH=0; PERM_MISSING=0; PERM_FIXED=0

perm_verify() {
    local manifest="$1" dest="${2%/}" fix=0 check_owner=0
    local current report type path want_mode want_uid want_gid want_mtime issues
    [[ "$3" == "--fix" ]] && fix=1
    [[ $EUID -eq 0 ]] && check_owner=1
    PERM_CHECKED=0; PERM_MISMATCH=0; PERM_MISSING=0; PERM_FIXED=0

    if [[ ! -f "$manifest" ]]; then
        echo "No permission manifest found ($manifest) - skipping verification."
        log_msg WARN "Permissions: no manifest $manifest, verification skipped"
        return 1
    fi
    if [[ ! -d "$dest" ]]; then
        echo "ERROR: restore folder '$dest' does not exist."
        log_msg ERROR "Permissions: verify failed, '$dest' is not a directory"
        return 1
    fi

    # Snapshot of what is currently in DEST, same format and relative paths.
    current="$(mktemp)"; report="$(mktemp)"
    ( cd "$dest" && find . -mindepth 1 ! -name $'*\t*' ! -name $'*\n*' \
        -printf '%y\t%m\t%U\t%G\t%u\t%g\t%T@\t%s\t%P\n' 2>/dev/null ) > "$current"

    # Join manifest with current state by path. Output for each manifest entry:
    #   MISSING <tab> path    or    BAD <tab> type mode uid gid mtime issues path
    awk -F'\t' -v OFS='\t' -v owner="$check_owner" '
        FNR == NR { cur[$9] = $0; next }          # first file: current DEST state
        /^#/ { next }
        {
            checked++
            if (!($9 in cur)) { print "MISSING", $9; next }
            split(cur[$9], c, "\t")
            issues = ""
            if ($1 != "l" && $2 != c[2])               issues = issues "mode(" c[2] "->" $2 ") "
            if (owner == 1 && ($3 != c[3] || $4 != c[4])) issues = issues "owner(" c[3] ":" c[4] "->" $3 ":" $4 ") "
            if ($1 == "f" && int($7) != int(c[7]))      issues = issues "mtime "
            sub(/ $/, "", issues)
            if (issues != "") print "BAD", $1, $2, $3, $4, int($7), issues, $9
        }
        END { print "CHECKED", checked + 0 }
    ' "$current" "$manifest" > "$report"

    PERM_CHECKED="$(awk -F'\t' '$1 == "CHECKED" { print $2 }' "$report")"
    PERM_MISSING="$(grep -c '^MISSING' "$report")"
    PERM_MISMATCH="$(grep -c '^BAD' "$report")"

    echo "Permission verification: $PERM_CHECKED entries checked against $(basename "$manifest")"
    if (( PERM_MISMATCH > 0 )); then
        echo "  $PERM_MISMATCH entr(y/ies) differ from the original:"
        grep '^BAD' "$report" | head -n 15 | awk -F'\t' '{ printf "    %-40s %s\n", $8, $7 }'
        (( PERM_MISMATCH > 15 )) && echo "    ... ($((PERM_MISMATCH - 15)) more, see log)"
    fi

    # Repair: files/links first, then folders deepest-first (so a folder that
    # loses write/exec permission is changed only after its contents).
    if (( fix == 1 && PERM_MISMATCH > 0 )); then
        local -a repaired=()
        while IFS=$'\t' read -r _ type want_mode want_uid want_gid want_mtime issues path; do
            local target="$dest/$path" ok=1
            if [[ "$issues" == *mode* ]]; then
                chmod "$want_mode" "$target" 2>/dev/null || ok=0
            fi
            if [[ "$issues" == *owner* ]]; then
                chown -h "$want_uid:$want_gid" "$target" 2>/dev/null || ok=0
            fi
            if [[ "$issues" == *mtime* ]]; then
                touch -h -d "@$want_mtime" "$target" 2>/dev/null || ok=0
            fi
            if (( ok )); then
                PERM_FIXED=$((PERM_FIXED + 1))
                repaired+=("$target")
                log_msg INFO "Permissions: repaired $path ($issues)"
            else
                log_msg ERROR "Permissions: could not repair $path ($issues)"
            fi
        done < <(grep '^BAD' "$report" | awk -F'\t' '{ print ($2 == "d" ? 1 : 0) "\t" $0 }' |
                 sort -t$'\t' -k1,1n -k9,9r | cut -f2-)
        echo "  Repaired $PERM_FIXED of $PERM_MISMATCH. Now (stat):"
        perm_show "${repaired[@]:0:15}" | sed "s|$dest/||; s/^/    /"
    else
        grep '^BAD' "$report" | while IFS=$'\t' read -r _ _ _ _ _ _ issues path; do
            log_msg WARN "Permissions: mismatch $path ($issues)"
        done
    fi

    (( PERM_MISSING > 0 )) && echo "  $PERM_MISSING entr(y/ies) from the manifest are not in '$dest' (normal for a partial restore)."
    (( check_owner == 0 )) && echo "  (ownership not compared - run as root to check/restore owners)"

    local remaining=$((PERM_MISMATCH - PERM_FIXED))
    if (( remaining == 0 )); then
        echo "  RESULT: permissions and timestamps preserved correctly."
        log_msg INFO "Permissions: verify $dest OK - checked=$PERM_CHECKED mismatched=$PERM_MISMATCH fixed=$PERM_FIXED missing=$PERM_MISSING"
    else
        echo "  RESULT: $remaining entr(y/ies) still differ. Use --fix (or run as root for owners)."
        log_msg WARN "Permissions: verify $dest - checked=$PERM_CHECKED mismatched=$PERM_MISMATCH fixed=$PERM_FIXED missing=$PERM_MISSING"
    fi

    rm -f "$current" "$report"
    (( remaining == 0 ))
}

# ---------------------------------------------------------------------------
# Run directly:
#   ./lib/permissions.sh show     <path>...
#   ./lib/permissions.sh check    <dir>
#   ./lib/permissions.sh snapshot <dir> <outfile>
#   ./lib/permissions.sh verify   <manifest> <restore_dir> [--fix]
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$1" in
        show)     shift; perm_show "$@" ;;
        check)    perm_check_source "$2" ;;
        snapshot) perm_snapshot "$(cd "$2" 2>/dev/null && pwd)" "$3" && echo "Snapshot written to $3" ;;
        verify)   perm_verify "$2" "$3" "$4" ;;
        *) echo "Usage: $0 {show <path>... | check <dir> | snapshot <dir> <out> | verify <manifest> <dir> [--fix]}"; exit 1 ;;
    esac
fi
