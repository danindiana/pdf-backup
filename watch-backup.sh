#!/usr/bin/env bash
# watch-backup.sh — passive ETA + throughput monitor for pdf-backup
# Run in a separate terminal: ./watch-backup.sh
# Refreshes every INTERVAL seconds. No root required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

INTERVAL=${1:-10}   # seconds between refreshes, default 10

# Expected total from dry run (bytes, SI). Update if re-run with different filter.
EXPECTED_BYTES=2930000000000   # 2.93T bytes from dry-run stats

# ── helpers ─────────────────────────────────────────────────────────────────
bytes_to_human() {
    local b=$1
    if   (( b >= 1099511627776 )); then printf "%.2f TiB" "$(echo "scale=2; $b/1099511627776" | bc)"
    elif (( b >= 1073741824    )); then printf "%.2f GiB" "$(echo "scale=2; $b/1073741824"    | bc)"
    elif (( b >= 1048576       )); then printf "%.2f MiB" "$(echo "scale=2; $b/1048576"       | bc)"
    else printf "%d B" "$b"
    fi
}

secs_to_human() {
    local s=$1
    local d=$(( s/86400 )) h=$(( (s%86400)/3600 )) m=$(( (s%3600)/60 )) sec=$(( s%60 ))
    if   (( d > 0 )); then printf "%dd %dh %dm" $d $h $m
    elif (( h > 0 )); then printf "%dh %dm" $h $m
    elif (( m > 0 )); then printf "%dm %ds" $m $sec
    else printf "%ds" $sec
    fi
}

# ── state ────────────────────────────────────────────────────────────────────
START_TS=$(date +%s)
PREV_BYTES=0
PREV_TS=$START_TS

clear
while true; do
    NOW=$(date +%s)

    # --- disk usage ---
    read -r USED_BYTES AVAIL_BYTES < <(df --block-size=1 "$DEST" 2>/dev/null | awk 'NR==2{print $3, $4}')
    USED_BYTES=${USED_BYTES:-0}

    # --- file count ---
    PDF_COUNT=$(find "$DEST" -name "*.pdf" 2>/dev/null | wc -l)

    # --- rsync process ---
    RSYNC_PID=""
    if [[ -f "$PID_FILE" ]]; then
        P=$(cat "$PID_FILE")
        kill -0 "$P" 2>/dev/null && RSYNC_PID="$P"
    fi

    # --- throughput (bytes written since last sample) ---
    ELAPSED_INTERVAL=$(( NOW - PREV_TS ))
    THROUGHPUT=0
    if (( ELAPSED_INTERVAL > 0 && USED_BYTES > PREV_BYTES )); then
        THROUGHPUT=$(( (USED_BYTES - PREV_BYTES) / ELAPSED_INTERVAL ))
    fi
    PREV_BYTES=$USED_BYTES
    PREV_TS=$NOW

    # --- ETA ---
    TOTAL_ELAPSED=$(( NOW - START_TS ))
    ETA_STR="unknown"
    PCT=0
    if (( EXPECTED_BYTES > 0 && USED_BYTES > 0 )); then
        PCT=$(( USED_BYTES * 100 / EXPECTED_BYTES ))
        REMAINING=$(( EXPECTED_BYTES - USED_BYTES ))
        if (( THROUGHPUT > 0 )); then
            ETA_SECS=$(( REMAINING / THROUGHPUT ))
            ETA_STR=$(secs_to_human $ETA_SECS)
        elif (( TOTAL_ELAPSED > 0 && USED_BYTES > 0 )); then
            # fallback: avg rate since session start
            AVG=$(( USED_BYTES / TOTAL_ELAPSED ))
            if (( AVG > 0 )); then
                ETA_SECS=$(( REMAINING / AVG ))
                ETA_STR="~$(secs_to_human $ETA_SECS) (avg rate)"
            fi
        fi
    fi

    # --- iostat snapshot (1-second sample) ---
    IOSTAT=$(iostat -d -k 1 1 sda md0 2>/dev/null | awk '
        /^sda/  {printf "sda (dest):  read %6.1f KB/s  write %6.1f KB/s\n", $3, $4}
        /^md0/  {printf "md0 (src):   read %6.1f KB/s  write %6.1f KB/s\n", $3, $4}
    ')

    # --- draw ---
    tput cup 0 0   # move to top without full clear (avoids flicker)
    printf "╔══════════════════════════════════════════════════╗\n"
    printf "║           pdf-backup live monitor                ║\n"
    printf "╚══════════════════════════════════════════════════╝\n"
    printf " Updated:    %s  (every %ds)\n" "$(date '+%H:%M:%S')" "$INTERVAL"
    printf " rsync:      %s\n" "${RSYNC_PID:+RUNNING (PID $RSYNC_PID)}"
    [[ -z "$RSYNC_PID" ]] && printf " rsync:      STOPPED\n"
    printf "\n"
    printf " ── Progress ────────────────────────────────────\n"
    printf " Written:    %s / %s  (%d%%)\n" \
        "$(bytes_to_human $USED_BYTES)" "$(bytes_to_human $EXPECTED_BYTES)" "$PCT"
    # progress bar
    BAR_WIDTH=48
    FILLED=$(( PCT * BAR_WIDTH / 100 ))
    EMPTY=$(( BAR_WIDTH - FILLED ))
    printf " [%s%s]\n" "$(printf '█%.0s' $(seq 1 $FILLED) 2>/dev/null)" \
                        "$(printf '░%.0s' $(seq 1 $EMPTY)  2>/dev/null)"
    printf " PDFs:       %d files\n" "$PDF_COUNT"
    printf " Avail left: %s\n" "$(bytes_to_human $AVAIL_BYTES)"
    printf "\n"
    printf " ── Throughput ──────────────────────────────────\n"
    printf " Current:    %s/s\n" "$(bytes_to_human $THROUGHPUT)"
    printf " Runtime:    %s\n"   "$(secs_to_human $TOTAL_ELAPSED)"
    printf " ETA:        %s\n"   "$ETA_STR"
    printf "\n"
    printf " ── I/O (kernel, 1s sample) ─────────────────────\n"
    printf "%s\n" "$IOSTAT"
    printf "\n"
    printf " Ctrl-C to exit\n"
    printf "                                                    \n"

    sleep "$INTERVAL"
done
