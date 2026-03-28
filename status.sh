#!/usr/bin/env bash
# status.sh — observe a running pdf-backup in a separate terminal
# Run this anytime: ./status.sh
# It shows live log tail, disk usage, and rsync process state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

echo "=== pdf-backup STATUS === $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# --- process state ---
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "[RUNNING] rsync PID: $PID"
        echo "  CPU/Mem: $(ps -p "$PID" -o %cpu,%mem,etime --no-headers 2>/dev/null || echo 'n/a')"
    else
        echo "[STOPPED] PID file exists but PID $PID is not running (stale)"
    fi
else
    echo "[STOPPED] No PID file — pdf-backup is not running"
fi

echo ""

# --- disk usage ---
echo "=== Disk usage ==="
df -h "$DEST" 2>/dev/null
echo ""
# --- file counts ---
echo "=== File counts ==="
DEST_COUNT=$(find "$DEST" -name "*.pdf" 2>/dev/null | wc -l)
echo "  PDFs in destination: $DEST_COUNT"
echo ""

# --- recent log lines ---
if [[ -f "$LOG_FILE" ]]; then
    echo "=== Last 30 log lines ($LOG_FILE) ==="
    tail -30 "$LOG_FILE"
else
    echo "[INFO] No log file yet at $LOG_FILE"
fi

echo ""
echo "--- Live tail (Ctrl-C to exit): tail -f $LOG_FILE"
