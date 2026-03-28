#!/usr/bin/env bash
# verify.sh — compare source and destination after a backup run
# Checks file counts and total bytes under the same --max-size filter.
# Usage: sudo ./verify.sh [--spot-check N]
#   --spot-check N   MD5-verify N randomly sampled files (slow but thorough)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

SPOT_CHECK=0
SPOT_N=0
if [[ "${1:-}" == "--spot-check" ]]; then
    SPOT_CHECK=1
    SPOT_N="${2:-100}"
fi

# convert MAX_FILE_SIZE (e.g. 50M) to bytes for find -size
parse_max_bytes() {
    local raw="$1"
    local num="${raw//[^0-9]/}"
    local unit="${raw//[0-9]/}"
    case "${unit^^}" in
        K) echo $((num * 1024)) ;;
        M) echo $((num * 1024 * 1024)) ;;
        G) echo $((num * 1024 * 1024 * 1024)) ;;
        *) echo "$num" ;;
    esac
}
MAX_BYTES=$(parse_max_bytes "$MAX_FILE_SIZE")

echo "=== pdf-backup verification ==="
echo "  Source:       $SOURCE"
echo "  Destination:  $DEST"
echo "  Max file size: $MAX_FILE_SIZE ($MAX_BYTES bytes)"
echo "  Started:      $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "[1/3] Counting source files (files <= $MAX_FILE_SIZE)..."
SRC_COUNT=$(find "$SOURCE" -type f -name "*.pdf" -size "-${MAX_FILE_SIZE}" 2>/dev/null | wc -l)
SRC_BYTES=$(find "$SOURCE" -type f -name "*.pdf" -size "-${MAX_FILE_SIZE}" -printf "%s\n" 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "  Source PDFs:  $SRC_COUNT files, $(numfmt --to=iec-i --suffix=B "$SRC_BYTES")"

echo "[2/3] Counting destination files..."
DEST_COUNT=$(find "$DEST" -type f -name "*.pdf" 2>/dev/null | wc -l)
DEST_BYTES=$(find "$DEST" -type f -name "*.pdf" -printf "%s\n" 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "  Dest PDFs:    $DEST_COUNT files, $(numfmt --to=iec-i --suffix=B "$DEST_BYTES")"

echo ""
MISSING=$((SRC_COUNT - DEST_COUNT))
if [[ $MISSING -le 0 ]]; then
    echo "  [OK] File count matches (source <= dest)"
else
    echo "  [WARN] $MISSING files present in source but not yet in destination"
fi

BYTE_DIFF=$((SRC_BYTES - DEST_BYTES))
if [[ $BYTE_DIFF -le 0 ]]; then
    echo "  [OK] Byte total matches"
else
    echo "  [WARN] $(numfmt --to=iec-i --suffix=B "$BYTE_DIFF") not yet transferred"
fi

if [[ $SPOT_CHECK -eq 1 ]]; then
    echo ""
    echo "[3/3] Spot-checking $SPOT_N random files (MD5 comparison)..."
    PASS=0
    FAIL=0
    SKIP=0
    while IFS= read -r src_path; do
        rel="${src_path#$SOURCE/}"
        dest_path="$DEST/$rel"
        if [[ ! -f "$dest_path" ]]; then
            ((SKIP++)) || true
            continue
        fi
        src_md5=$(md5sum "$src_path" | cut -d' ' -f1)
        dst_md5=$(md5sum "$dest_path" | cut -d' ' -f1)
        if [[ "$src_md5" == "$dst_md5" ]]; then
            ((PASS++)) || true
        else
            echo "  [MISMATCH] $rel"
            echo "    src: $src_md5"
            echo "    dst: $dst_md5"
            ((FAIL++)) || true
        fi
    done < <(find "$SOURCE" -type f -name "*.pdf" -size "-${MAX_FILE_SIZE}" 2>/dev/null | shuf -n "$SPOT_N")

    echo "  Spot check: $PASS passed, $FAIL failed, $SKIP skipped (not in dest yet)"
else
    echo "[3/3] Skipping spot-check (pass --spot-check N to enable)"
fi

echo ""
echo "=== Verification complete: $(date '+%Y-%m-%d %H:%M:%S') ==="
