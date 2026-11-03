#!/usr/bin/env bash
# config.sh - shared settings for the whole project (all 3 members use this)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"     # where .tar.gz archives are stored
LOG_DIR="$PROJECT_ROOT/logs"           # where logs are stored
LOG_FILE="$LOG_DIR/backup.log"         # single log file

mkdir -p "$BACKUP_DIR" "$LOG_DIR"
