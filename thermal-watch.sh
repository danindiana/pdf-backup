#!/usr/bin/env bash
# thermal-watch.sh — poll SMART temps on RAID drives, log warnings
# Run in background: sudo ./thermal-watch.sh &
# Or: sudo ./thermal-watch.sh | tee -a /var/log/pdf-backup/thermal.log
#
# Exits cleanly on SIGTERM/SIGINT.

INTERVAL=${1:-60}   # seconds between polls, default 60

WARN_C=47           # log WARNING above this celsius
CRIT_C=50           # log CRITICAL above this

DRIVES=(sda sdc sdg)
LOG=/var/log/pdf-backup/thermal.log

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

trap 'log "thermal-watch stopping"; exit 0' SIGTERM SIGINT

log "thermal-watch started (interval=${INTERVAL}s, warn>=${WARN_C}C, crit>=${CRIT_C}C)"

while true; do
    for dev in "${DRIVES[@]}"; do
        temp=$(smartctl -A /dev/$dev 2>/dev/null | awk '/^194/{print $10+0}')
        [[ -z "$temp" ]] && continue

        if (( temp >= CRIT_C )); then
            log "CRITICAL /dev/$dev temp=${temp}C (>=${CRIT_C}C threshold)"
        elif (( temp >= WARN_C )); then
            log "WARNING  /dev/$dev temp=${temp}C (>=${WARN_C}C threshold)"
        else
            log "OK       /dev/$dev temp=${temp}C"
        fi
    done
    sleep "$INTERVAL"
done
