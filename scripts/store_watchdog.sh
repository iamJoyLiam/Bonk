#!/bin/bash
# store_watchdog.sh — attribute any write to the production SwiftData store to
# a specific process.
#
# WHY THIS EXISTS
#   On 2026-09-23 and 2026-09-29 the live store was found rebuilt from scratch:
#   every table recreated, every primary-key high-water mark reset to zero, and
#   the app's seed data back in place. No in-app code deletes hosts, every
#   released version carries the identical 15-entity schema, and the current
#   test suite proves a clean reopen is lossless. Static analysis has therefore
#   exhausted itself — the only way to name the culprit is to catch it writing.
#
# WHAT IT RECORDS
#   1. Every process that holds default.store / -wal / -shm open, with its
#      binary path and launch time, whenever that set changes.
#   2. The file's size, mtime and inode whenever they change.
#   3. The ZHOSTITEM row count, sampled only when the file actually changed,
#      and the moment that count drops to zero.
#
# The moment a drop is seen, the PID log immediately above it is the answer.
#
# USAGE
#   ./scripts/store_watchdog.sh            # run in the foreground, Ctrl-C to stop
#   ./scripts/store_watchdog.sh --daemon   # detach and keep running
#
# REQUIRES
#   No root and no extra tooling: lsof and sqlite3 ship with macOS. Run it
#   BEFORE reproducing, and leave it running across a launch of the app.

set -uo pipefail

STORE_DIR="$HOME/Library/Application Support"
STORE="$STORE_DIR/default.store"
LOG_DIR="$HOME/Library/Logs/Bonk"
LOG="$LOG_DIR/store-watchdog.log"
INTERVAL="${STORE_WATCHDOG_INTERVAL:-0.5}"

mkdir -p "$LOG_DIR"
[ -f "$STORE" ] || { echo "no store at $STORE" >&2; exit 1; }

log() { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Fingerprint of the store file: size, mtime, inode.
fingerprint() {
    stat -f '%z:%m:%i' "$STORE" 2>/dev/null || echo "missing"
}

# Host rows, read-only. -wal is picked up automatically, so a row that is only
# in the write-ahead log still counts as present.
host_count() {
    sqlite3 "file:$STORE?mode=ro" 'SELECT COUNT(*) FROM ZHOSTITEM' 2>/dev/null || echo "?"
}

# Every process holding the store or its sidecars open.
holders() {
    lsof "$STORE" "$STORE-wal" "$STORE-shm" 2>/dev/null \
        | awk 'NR > 1 { print $1, $2, $9 }' \
        | sort -u
}

# Full identity for a pid, so a recycled pid cannot be mistaken for the culprit.
identify() {
    ps -o lstart= -o comm= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^/  /'
}

log "=== watchdog started (interval ${INTERVAL}s) ==="
log "store=$STORE inode=$(stat -f '%i' "$STORE" 2>/dev/null) hosts=$(host_count)"

LAST_FP=""; LAST_HOLDERS=""; LAST_COUNT=$(host_count)

while true; do
    FP=$(fingerprint)
    HOLDERS=$(holders)

    if [ "$FP" != "$LAST_FP" ]; then
        COUNT=$(host_count)
        log "STORE CHANGED size/mtime/inode=$FP hosts=$COUNT"
        if [ "$COUNT" = "0" ] && [ "$LAST_COUNT" != "0" ] && [ "$LAST_COUNT" != "?" ]; then
            log "!!!! HOSTS WIPED: $LAST_COUNT -> 0 !!!!"
            log "processes holding the store at that moment:"
            if [ -n "$HOLDERS" ]; then
                echo "$HOLDERS" | while read -r name pid path; do
                    log "  HOLDER name=$name pid=$pid path=$path"
                    identify "$pid" >> "$LOG"
                done
            else
                log "  (none — the writer had already closed it; see the holder log below)"
            fi
        fi
        LAST_COUNT="$COUNT"
        LAST_FP="$FP"
    fi

    # Track holders independently of file changes: a destructive migration can
    # open, rewrite and close entirely between two size/mtime observations.
    if [ "$HOLDERS" != "$LAST_HOLDERS" ]; then
        if [ -n "$HOLDERS" ]; then
            log "HOLDERS CHANGED:"
            echo "$HOLDERS" | while read -r name pid path; do
                log "  + $name pid=$pid $path"
            done >> "$LOG"
        else
            log "HOLDERS CHANGED: (none)"
        fi
        LAST_HOLDERS="$HOLDERS"
    fi

    sleep "$INTERVAL"
done
