#!/usr/bin/env bash
# pdf-backup.sh — suspend/resume rsync from RAID0 PDF archive to pdf_backup drive
# Usage: sudo ./pdf-backup.sh [--dry-run]
# Stop safely: ./stop.sh   (leaves partial files intact for next resume)
# Observe:     ./status.sh  (run in a separate terminal)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    echo "[INFO] DRY RUN mode — no files will be written"
fi

# --- guards ---
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Must run as root (sudo ./pdf-backup.sh)" >&2
    exit 1
fi

if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[ERROR] pdf-backup is already running (PID $OLD_PID). Use ./stop.sh to stop it." >&2
        exit 1
    else
        echo "[WARN] Stale PID file found (PID $OLD_PID is dead). Removing."
        rm -f "$PID_FILE"
    fi
fi

# --- setup ---
mkdir -p "$(dirname "$LOG_FILE")"

# --- build rsync command ---
RSYNC_FLAGS=(
    --archive           # preserve perms, timestamps, symlinks, owner, group
    --partial           # keep partial files in-place on interruption (resume-safe)
    --append-verify     # on resume: append remaining bytes, then checksum whole file
    --progress          # per-file progress
    --stats             # summary stats at end
    --human-readable
    --max-size="$MAX_FILE_SIZE"
    --exclude="*.tmp"
)

if [[ $DRY_RUN -eq 1 ]]; then
    RSYNC_FLAGS+=(--dry-run)
fi

if [[ -n "$RSYNC_EXTRA_FLAGS" ]]; then
    # shellcheck disable=SC2206
    RSYNC_FLAGS+=($RSYNC_EXTRA_FLAGS)
fi

# --- logging preamble ---
{
    echo "========================================"
    echo "pdf-backup started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Source:       $SOURCE"
    echo "  Destination:  $DEST"
    echo "  Max file size: $MAX_FILE_SIZE"
    echo "  Dry run:      $DRY_RUN"
    df -h "$DEST" | tail -1 | awk '{printf "  Dest free:    %s of %s (%s used)\n", $4, $2, $5}'
    echo "========================================"
} | tee -a "$LOG_FILE"

# --- run rsync, write PID, trap cleanup ---
cleanup() {
    rm -f "$PID_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] pdf-backup process exiting (PID $$)" | tee -a "$LOG_FILE"
}
trap cleanup EXIT

# launch rsync; tee output to log; write rsync PID so stop.sh can kill it
rsync "${RSYNC_FLAGS[@]}" "$SOURCE/" "$DEST/" 2>&1 | tee -a "$LOG_FILE" &
RSYNC_PID=$!
echo "$RSYNC_PID" > "$PID_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] rsync running (PID $RSYNC_PID)" | tee -a "$LOG_FILE"
echo "[INFO] Monitor:  sudo ./status.sh"
echo "[INFO] Stop:     sudo ./stop.sh"
echo "[INFO] Log:      tail -f $LOG_FILE"

wait "$RSYNC_PID"
RSYNC_EXIT=$?

{
    echo "========================================"
    echo "pdf-backup finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  rsync exit code: $RSYNC_EXIT"
    df -h "$DEST" | tail -1 | awk '{printf "  Dest used:    %s of %s (%s)\n", $3, $2, $5}'
    if [[ $RSYNC_EXIT -eq 0 ]]; then
        echo "  Status: COMPLETE — run ./verify.sh to confirm"
    elif [[ $RSYNC_EXIT -eq 24 ]]; then
        echo "  Status: PARTIAL (some source files vanished mid-transfer — safe to re-run)"
    else
        echo "  Status: ERROR (exit $RSYNC_EXIT) — check log above"
    fi
    echo "========================================"
} | tee -a "$LOG_FILE"

exit $RSYNC_EXIT
