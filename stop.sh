#!/usr/bin/env bash
# stop.sh — gracefully stop a running pdf-backup.sh
# rsync is left mid-file; next pdf-backup.sh run will resume via --partial-dir + --append-verify

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

if [[ ! -f "$PID_FILE" ]]; then
    echo "[INFO] No PID file found at $PID_FILE — pdf-backup may not be running."
    exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
    echo "[WARN] PID $PID is not running. Removing stale PID file."
    rm -f "$PID_FILE"
    exit 0
fi

echo "[INFO] Sending SIGTERM to rsync (PID $PID)..."
kill -TERM "$PID"

# wait up to 15s for clean exit
for i in $(seq 1 15); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "[INFO] rsync stopped cleanly."
        rm -f "$PID_FILE"
        exit 0
    fi
    sleep 1
done

echo "[WARN] rsync did not stop after 15s — sending SIGKILL"
kill -KILL "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
echo "[INFO] Killed. Partial files are safe in $PARTIAL_DIR — re-run pdf-backup.sh to resume."
