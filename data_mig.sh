#!/bin/bash

###############################################################################
# HPC Data Migration Script (Git + /tmp launcher compatible)
###############################################################################

set -o pipefail

# -----------------------------------------------------------------------------
# Inputs (from launcher or CLI)
# -----------------------------------------------------------------------------
SOURCE="${1:-}"
DEST="${2:-}"
PARALLEL_JOBS="${3:-10}"

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------
if [[ -z "$SOURCE" || -z "$DEST" ]]; then
    echo "Usage: $0 <source> <destination> [parallel_jobs]"
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source does not exist: $SOURCE"
    exit 1
fi

mkdir -p "$DEST"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="/tmp/migration_${TIMESTAMP}.log"

START_TIME=$(date +%s)
INTERRUPTED=0

BYTE_FILE="/tmp/mig_bytes_${TIMESTAMP}.tmp"
: > "$BYTE_FILE"

echo "==================================================" | tee -a "$LOGFILE"
echo "DATA MIGRATION STARTED" | tee -a "$LOGFILE"
echo "Start Time        : $(date)" | tee -a "$LOGFILE"
echo "Source            : $SOURCE" | tee -a "$LOGFILE"
echo "Destination       : $DEST" | tee -a "$LOGFILE"
echo "Parallel Jobs     : $PARALLEL_JOBS" | tee -a "$LOGFILE"
echo "Log File          : $LOGFILE" | tee -a "$LOGFILE"
echo "==================================================" | tee -a "$LOGFILE"

# -----------------------------------------------------------------------------
# Size formatting
# -----------------------------------------------------------------------------
format_size() {
    awk -v b="$1" '
    BEGIN {
        mb=b/1024/1024
        gb=b/1024/1024/1024
        tb=b/1024/1024/1024/1024

        if (tb>=1) printf "%.2f TB", tb
        else if (gb>=1) printf "%.2f GB", gb
        else printf "%.2f MB", mb
    }'
}

# -----------------------------------------------------------------------------
# Cleanup (handles interrupt too)
# -----------------------------------------------------------------------------
cleanup() {

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    [[ $DURATION -le 0 ]] && DURATION=1

    TOTAL_BYTES=$(awk '{sum+=$1} END {print sum}' "$BYTE_FILE")
    TOTAL_BYTES=${TOTAL_BYTES:-0}

    TOTAL_SIZE=$(format_size "$TOTAL_BYTES")

    SPEED_MBPS=$(echo "$TOTAL_BYTES / $DURATION / 1024 / 1024" | bc -l 2>/dev/null)
    SPEED_MBPS=${SPEED_MBPS:-0}

    echo "==================================================" | tee -a "$LOGFILE"

    if [[ $INTERRUPTED -eq 1 ]]; then
        echo "MIGRATION INTERRUPTED (Ctrl+C detected)" | tee -a "$LOGFILE"
    else
        echo "MIGRATION COMPLETED" | tee -a "$LOGFILE"
    fi

    echo "End Time            : $(date)" | tee -a "$LOGFILE"
    echo "Total Duration      : $DURATION seconds" | tee -a "$LOGFILE"
    printf "Total Data Transfer : %s\n" "$TOTAL_SIZE" | tee -a "$LOGFILE"
    printf "Average Speed       : %.2f MB/s\n" "$SPEED_MBPS" | tee -a "$LOGFILE"
    echo "Log File            : $LOGFILE" | tee -a "$LOGFILE"
    echo "==================================================" | tee -a "$LOGFILE"

    echo "Log saved at: $LOGFILE"
}

trap cleanup EXIT
trap 'INTERRUPTED=1; exit 130' INT TERM

# -----------------------------------------------------------------------------
# Build file list (top-level only)
# -----------------------------------------------------------------------------
LIST=$(mktemp)
find "$SOURCE" -mindepth 1 -maxdepth 1 > "$LIST"

TOTAL_ITEMS=$(wc -l < "$LIST")
echo "Total items found: $TOTAL_ITEMS" | tee -a "$LOGFILE"

# -----------------------------------------------------------------------------
# Get size
# -----------------------------------------------------------------------------
get_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}'
}

# -----------------------------------------------------------------------------
# Copy function with retry
# -----------------------------------------------------------------------------
copy_item() {

    ITEM="$1"
    NAME=$(basename "$ITEM")

    SIZE=$(get_size "$ITEM")

    for retry in 1 2 3; do

        rsync -aHAX --partial --append-verify \
            --info=progress2 \
            "$ITEM" "$DEST"/ >> "$LOGFILE" 2>&1

        STATUS=$?

        if [[ $STATUS -eq 0 ]]; then
            echo "$SIZE" >> "$BYTE_FILE"
            echo "SUCCESS: $NAME" >> "$LOGFILE"
            exit 0
        fi

        echo "FAILED: $NAME (Attempt $retry)" >> "$LOGFILE"
        sleep 2
    done

    echo "ERROR: $NAME failed after 3 attempts" >> "$LOGFILE"
    exit 1
}

export DEST LOGFILE BYTE_FILE
export -f copy_item get_size format_size

# -----------------------------------------------------------------------------
# Run parallel migration
# -----------------------------------------------------------------------------
echo "Migration started..." | tee -a "$LOGFILE"

cat "$LIST" | xargs -I{} -P "$PARALLEL_JOBS" bash -c 'copy_item "$@"' _ {}

rm -f "$LIST"
