# Multi-Level Directory Backup Tool

A menu-driven Bash tool for Linux that backs up whole folder trees into compressed `.tar.gz` archives. It supports full and incremental backups, keeps file permissions, ownership and timestamps, restores archives, and logs everything it does.

## Team

| Member | Responsibility | Files |
|---|---|---|
| Siddiqua Sarwar (Group Leader) | CLI menu and restore module | `backup.sh`, `lib/restore.sh` |
| Tahira | Directory traversal and compression engine | `lib/backup_engine.sh` |
| Kaneeza Batool | Permissions, incremental filtering and logging | `lib/permissions.sh`, `lib/incremental.sh`, `lib/logger.sh` |

## Requirements

- Linux (target: Ubuntu) with Bash 4+
- GNU `tar`, `gzip`, `find`, `stat`, `awk` (installed by default on Ubuntu)
- Root (`sudo`) only if you also need to restore file **ownership**

## Getting started

```bash
git clone <repo-url> os-directory-backup-tool
cd os-directory-backup-tool
chmod +x backup.sh config.sh lib/*.sh
./backup.sh
```

> Keep the project on the Linux file system (for example your home folder). VirtualBox/VMware
> shared folders and Windows drives ignore `chmod`/`chown`, so permission tests won't work there.

## Menu

```
1) Full backup           - archive the whole folder tree
2) Incremental backup    - archive only what changed since the last backup
3) View log history      - last 20 entries, full log, errors only, statistics, summaries
4) Restore from backup   - pick an archive, restore all or one file/folder
5) Exit
```

## Project layout

```
backup.sh              main menu (entry point)
config.sh              shared settings: backups/ and logs/ locations
lib/
  backup_engine.sh     full + incremental backup, recursive traversal, archive naming
  restore.sh           archive selection, integrity check, extraction
  permissions.sh       permission/ownership checks, manifests, post-restore verification
  incremental.sh       timestamp comparison / change detection
  logger.sh            timestamped logging, operation summaries, statistics
backups/               archives and metadata (created automatically, not in git)
logs/backup.log        activity log (created automatically, not in git)
```

## How it works

### Full backup
1. Checks that the source exists and warns about files that can't be read.
2. Records a snapshot of every entry: type, mode, owner, group, mtime and size.
3. Creates `backups/full_<folder>_<YYYYmmdd_HHMMSS>.tar.gz` with `tar -czpf`. The `-p` option keeps permissions.
4. Saves a permission manifest (`.perms`) next to the archive and stores the snapshot as the index for the next incremental backup.

### Incremental backup
Compares the folder now with the index saved by the last backup, path by path:

| Result | Meaning | Backed up? |
|---|---|---|
| NEW | file did not exist before (also files moved in with an old date) | yes |
| MODIFIED | modification time or size changed | yes |
| PERMS | only permissions/owner changed | yes |
| DELETED | file was removed | recorded in `.deleted` |
| UNCHANGED | nothing changed | no |

Both states are written as sorted lines (path, type, mtime, size, mode, owner) and compared with `diff`. Lines that are the same on both sides are unchanged files, so `diff` prints only what changed. `stat` is used to read and show timestamps, permissions and owners.

This catches more than a plain `find -newer`: it also finds moved/copied files that keep an old date, `chmod`/`chown`-only changes, and deletions. If no earlier backup exists, a full backup runs instead.

### Restore
1. Lists the archives, checks the chosen one with `gzip -t` and `tar -t`.
2. Restores everything, or one file or folder, into the chosen destination.
3. Compares the restored files with the archive's `.perms` manifest and repairs any mode, owner or timestamp that differs (`chmod`/`chown`/`touch`).
   Owners can only be checked and restored when running as root.

### Logging
Every action is written to `logs/backup.log`:

```
2026-11-09 13:52:20 [INFO] START op=full_backup source=/home/user/Docs user=user
2026-11-09 13:52:28 [INFO] SUMMARY op=full_backup status=SUCCESS files=12 dirs=3 errors=0 duration=7s archive=...
2026-11-09 13:55:02 [ERROR] tar: Docs/secret.txt: Cannot open: Permission denied
```

Levels are `INFO`, `WARN` and `ERROR`. The log rotates automatically once it is larger than 1 MB (`backup.log.1` … `backup.log.5`).

## Files in `backups/`

| File | Purpose |
|---|---|
| `full_<dir>_<time>.tar.gz` | full backup archive |
| `incr_<dir>_<time>.tar.gz` | incremental backup archive |
| `<archive>.perms` | permissions, owners and timestamps of the archived entries |
| `<archive>.deleted` | files deleted since the previous backup |
| `.index_<dir>_<hash>` | state of the last backup (used for change detection) |
| `.last_<dir>_<hash>` | time of the last backup |

## Running modules on their own

```bash
./lib/backup_engine.sh tree  ~/Docs                  # show the folder tree with counts
./lib/backup_engine.sh full  ~/Docs                  # full backup without the menu
./lib/incremental.sh   check ~/Docs                  # change report + the diff it is based on
./lib/incremental.sh   compare file1 file2           # compare two files' timestamps (stat)
./lib/permissions.sh   show ~/Docs/a.txt ~/Docs      # stat: permissions, owner, mtime
./lib/permissions.sh   check ~/Docs                  # list unreadable files
./lib/permissions.sh   verify backups/<name>.perms ~/restore_dir --fix
./lib/logger.sh        stats                         # log statistics
```

## Quick test

```bash
mkdir -p ~/testdata/Docs/a/b
echo hello > ~/testdata/Docs/public.txt
echo secret > ~/testdata/Docs/a/private.txt && chmod 600 ~/testdata/Docs/a/private.txt
./backup.sh            # 1) Full backup of ~/testdata/Docs, then 4) Restore to ~/restore1
ls -lR ~/restore1      # modes match the original
```

Then change, delete or `chmod` a file and run **2) Incremental backup** to see the change report.

## Notes

- If you run the tool with `sudo`, root will own `backups/` and `logs/`. To use it as a normal user again, run `sudo chown -R $USER backups logs`.
- `.gitattributes` keeps `.sh` files on Linux (LF) line endings so the scripts also work when the repository is edited on Windows.
