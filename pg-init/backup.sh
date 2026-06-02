#!/bin/bash
# PITR base backup — monthly on the 1st at 3:00 AM

BACKUP_DIR="/var/lib/postgresql/data/basebackup"
RETENTION_COUNT=3    # keep last 3 monthly backups
TARGET_HOUR=3        # 3:00 AM

mkdir -p "$BACKUP_DIR"
chown postgres:postgres "$BACKUP_DIR" 2>/dev/null

while true; do
  NOW_SEC=$(date +%s)
  Y=$(date +%Y)
  M=$(date +%-m)
  D=$(date +%-d)

  # Find next 1st-of-month at 3:00 AM
  if [ "$D" -eq 1 ]; then
    # Today is the 1st, check if still before 3:00 AM
    TODAY_TARGET=$(date -d "$Y-$(printf '%02d' $M)-01 $TARGET_HOUR:00:00" +%s)
    if [ "$NOW_SEC" -lt "$TODAY_TARGET" ]; then
      # Haven't passed 3AM yet — run today
      NEXT_RUN=$TODAY_TARGET
    else
      # Already past — next month
      [ "$M" -eq 12 ] && M=0 && Y=$((Y + 1))
      NEXT_RUN=$(date -d "$Y-$(printf '%02d' $((M + 1)))-01 $TARGET_HOUR:00:00" +%s)
    fi
  else
    # Not the 1st — next month
    [ "$M" -eq 12 ] && M=0 && Y=$((Y + 1))
    NEXT_RUN=$(date -d "$Y-$(printf '%02d' $((M + 1)))-01 $TARGET_HOUR:00:00" +%s)
  fi

  WAIT_SEC=$(( NEXT_RUN - NOW_SEC ))
  echo "[$(date)] Next backup at $(date -d @$NEXT_RUN), sleeping ${WAIT_SEC}s ($(( WAIT_SEC / 86400 ))d)"

  sleep $WAIT_SEC

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

  # Keep only the last N backups
  ls -dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n +$((RETENTION_COUNT + 1)) | xargs rm -rf 2>/dev/null
  echo "[$(date)] Keeping last $RETENTION_COUNT backups"
done
