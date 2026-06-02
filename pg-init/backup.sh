#!/bin/bash
# PITR base backup — daily at 3:00 AM (via sleep alignment, no cron needed)

BACKUP_DIR="/var/lib/postgresql/data/basebackup"
RETENTION_DAYS=7
TARGET_HOUR=3   # 3:00 AM daily

mkdir -p "$BACKUP_DIR"
chown postgres:postgres "$BACKUP_DIR" 2>/dev/null

while true; do
  # Calculate seconds until next 3:00 AM
  NOW_SEC=$(( $(date +%s) ))
  TODAY_TARGET=$(date -d "$(date +%Y-%m-%d) $TARGET_HOUR:00:00" +%s 2>/dev/null)

  if [ "$NOW_SEC" -ge "$TODAY_TARGET" ]; then
    # Already past 3:00 AM today, aim for tomorrow 3:00 AM
    NEXT_RUN=$(date -d "tomorrow $TARGET_HOUR:00:00" +%s 2>/dev/null)
  else
    NEXT_RUN=$TODAY_TARGET
  fi

  WAIT_SEC=$(( NEXT_RUN - NOW_SEC ))
  echo "[$(date)] Next backup at $(date -d @$NEXT_RUN), sleeping ${WAIT_SEC}s ($(( WAIT_SEC / 3600 ))h)"

  sleep $WAIT_SEC

  # Do the backup
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"

  echo "[$(date)] Starting base backup to $BACKUP_PATH"

  su - postgres -c "PGPASSWORD=source_pass pg_basebackup \
    -h pg-source \
    -U source_user \
    -D '$BACKUP_PATH' \
    -Fp -Xs -P" 2>&1

  if [ $? -eq 0 ]; then
    echo "[$(date)] Base backup completed: $BACKUP_PATH"
  else
    echo "[$(date)] Base backup FAILED"
    rm -rf "$BACKUP_PATH"
  fi

  find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null
  echo "[$(date)] Cleaned up backups older than $RETENTION_DAYS days"
done
