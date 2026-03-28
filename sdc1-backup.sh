#!/usr/bin/env bash
# sdc1-backup.sh — backup sdc1's secondary PDF archive (files/files/) to /mnt/pdf_backup
#
# Source: /dev/sdc1 → files/files/  (1.46M PDFs, 4.2T, domain-organized)
# Dest:   /mnt/pdf_backup/sdc1_files/
#
# Runs AFTER the primary backup (monolithic_pdf_folder) has completed and
# space is confirmed available. Uses the same --max-size filter.
#
# Usage: sudo ./sdc1-backup.sh [--dry-run]
# Stop:  Ctrl-C or kill the process (--partial keeps progress)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

SOURCE_DEV=/dev/sdc1
SOURCE_MNT=/mnt/tmp_sdc1_backup
SOURCE_DIR="$SOURCE_MNT/files/files"
DEST_DIR="$DEST/sdc1_files"
LOG_FILE=/var/log/pdf-backup/sdc1-rsync.log
PID_FILE=/var/run/sdc1-backup.pid

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1 && echo "[INFO] DRY RUN — no files written"

if [[ $EUID -ne 0 ]]; then echo "[ERROR] Run as root" >&2; exit 1; fi

if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[ERROR] sdc1-backup already running (PID $OLD_PID)" >&2; exit 1
    fi
    rm -f "$PID_FILE"
fi

# --- check available space before mounting ---
AVAIL=$(df --block-size=1 "$DEST" | awk 'NR==2{print $4}')
NEEDED=4200000000000   # ~4.2T worst case (no filter)
# With MAX_FILE_SIZE=10M the actual transfer will be much less, but warn if tight
if (( AVAIL < 200000000000 )); then   # warn if <200G free
    echo "[WARN] Only $(numfmt --to=iec-i --suffix=B $AVAIL) free on $DEST — may not have room"
    echo "       Complete primary backup first, then re-run"
    read -r -p "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]] || exit 1
fi

# --- mount sdc1 read-only ---
mkdir -p "$SOURCE_MNT"
if ! mountpoint -q "$SOURCE_MNT"; then
    mount -o ro "$SOURCE_DEV" "$SOURCE_MNT"
    echo "[INFO] Mounted $SOURCE_DEV at $SOURCE_MNT (read-only)"
fi
mkdir -p "$DEST_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# --- rsync ---
RSYNC_FLAGS=(
    --archive
    --partial
    --append-verify
    --progress
    --stats
    --human-readable
    --max-size="$MAX_FILE_SIZE"
    --exclude="*.tmp"
)
[[ $DRY_RUN -eq 1 ]] && RSYNC_FLAGS+=(--dry-run)

cleanup() {
    rm -f "$PID_FILE"
    # unmount only if we mounted it
    mountpoint -q "$SOURCE_MNT" && umount "$SOURCE_MNT" && rmdir "$SOURCE_MNT" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] sdc1-backup exiting"
}
trap cleanup EXIT

{
    echo "========================================"
    echo "sdc1-backup started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Source: $SOURCE_DIR"
    echo "  Dest:   $DEST_DIR"
    echo "  Filter: --max-size=$MAX_FILE_SIZE"
    df -h "$DEST" | tail -1 | awk '{printf "  Dest free: %s of %s\n", $4, $2}'
    echo "========================================"
} | tee -a "$LOG_FILE"

rsync "${RSYNC_FLAGS[@]}" "$SOURCE_DIR/" "$DEST_DIR/" 2>&1 | tee -a "$LOG_FILE" &
RSYNC_PID=$!
echo "$RSYNC_PID" > "$PID_FILE"
echo "[INFO] rsync PID $RSYNC_PID — monitor: tail -f $LOG_FILE"

wait "$RSYNC_PID"
EXIT=$?

{
    echo "========================================"
    echo "sdc1-backup finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Exit: $EXIT"
    df -h "$DEST" | tail -1 | awk '{printf "  Dest used: %s of %s\n", $3, $2}'
    [[ $EXIT -eq 0 ]] && echo "  Status: COMPLETE" || echo "  Status: ERROR ($EXIT)"
    echo "========================================"
} | tee -a "$LOG_FILE"

exit $EXIT
