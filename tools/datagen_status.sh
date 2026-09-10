#!/usr/bin/env bash
# Show datagen progress: per-shard position counts, live rate, and ETA.
#
#   tools/datagen_status.sh [outdir]      one snapshot
#   tools/datagen_status.sh -w [outdir]   refresh every 10s
#
# Why this exists rather than `tail -f gen_0.log`: the engine prints progress
# with a CARRIAGE RETURN, not a newline (src/datagen.cpp), so the log is one
# enormous single line and tail shows it as unreadable concatenated garbage
# like "positions 3264258games 39200/264960  positions 3270014".
#
# The shard files are the honest progress signal -- one line per position,
# appended continuously.

set -uo pipefail

WATCH=0
if [[ "${1:-}" == "-w" ]]; then WATCH=1; shift; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${1:-$SCRIPT_DIR/data}"

if [[ ! -d "$OUTDIR" ]]; then
    echo "no such outdir: $OUTDIR" >&2
    exit 2
fi

snapshot() {
    local total=0 n
    # `pgrep -f` on binary+subcommand, not `pgrep -x`: the name alone would also
    # match the Lichess bot's engine process. The [d] bracket is load-bearing --
    # it is a regex matching "datagen" while this script's OWN command line
    # contains the literal "[d]atagen", which does not. Without it pgrep matches
    # itself and reports processes that do not exist (it reported 4 when none
    # were running).
    local alive
    alive=$(pgrep -f "H2-Classical [d]atagen" 2>/dev/null | wc -l | tr -d ' ')

    echo "datagen status  --  $(date '+%H:%M:%S')"
    shopt -s nullglob
    local shards=("$OUTDIR"/part_*.txt)
    shopt -u nullglob
    if [[ ${#shards[@]} -eq 0 ]]; then
        echo "  no shards yet in $OUTDIR"
        return
    fi
    # Show each shard's age. A previous run's shards sit in the same directory
    # with the same part_N.txt names, and a naive `cat part_*.txt` would blend
    # data from a different binary into a new dataset. Anything older than the
    # newest shard by >1h is flagged and EXCLUDED from the run total.
    local newest=0 mt stale_total=0
    local active=()
    for f in "${shards[@]}"; do
        mt=$(stat -f %m "$f" 2>/dev/null || echo 0)
        [[ "$mt" -gt "$newest" ]] && newest=$mt
    done
    for f in "${shards[@]}"; do
        n=$(wc -l < "$f" 2>/dev/null || echo 0)
        mt=$(stat -f %m "$f" 2>/dev/null || echo 0)
        [[ $((newest - mt)) -le 3600 ]] && active+=("$f")
        if [[ $((newest - mt)) -gt 3600 ]]; then
            printf "  %-14s %10d positions   STALE (%s)\n" \
                "$(basename "$f")" "$n" "$(date -r "$mt" '+%b %d %H:%M')"
            stale_total=$((stale_total + n))
        else
            total=$((total + n))
            printf "  %-14s %10d positions\n" "$(basename "$f")" "$n"
        fi
    done
    printf "  %-14s %10d positions\n" "THIS RUN" "$total"
    if [[ "$stale_total" -gt 0 ]]; then
        printf "  %-14s %10d positions  <- from an older run; do NOT cat these\n" \
            "stale" "$stale_total"
        echo "     together with the new ones unless you mean to mix binaries."
    fi
    echo "  processes running: $alive"

    # Games progress, recovered from the \r-delimited log by turning CRs into
    # newlines and taking the final field.
    local g
    g=$(tr '\r' '\n' < "$OUTDIR/gen_0.log" 2>/dev/null | grep -o "games [0-9]*/[0-9]*" | tail -1)
    [[ -n "$g" ]] && echo "  shard 0 progress:  $g"

    # Live rate over a 5s window; only meaningful while processes are alive.
    if [[ "$alive" -gt 0 ]]; then
        local before after rate
        before=$total
        sleep 5
        after=0
        # Only the ACTIVE shards, matching what `before` counted. Summing all
        # shards here while `before` excluded the stale ones made the delta
        # include 761k old positions and reported ~152,000 pos/sec.
        for f in "${active[@]}"; do
            n=$(wc -l < "$f" 2>/dev/null || echo 0)
            after=$((after + n))
        done
        rate=$(( (after - before) / 5 ))
        echo "  rate: ~${rate} positions/sec  (~$((rate * 3600)) /hour, ~$((rate * 86400)) /day)"
        if [[ "$rate" -gt 0 ]]; then
            echo "  to reach 26M (BravoBlue's current set): ~$(( (26000000 - after) / (rate * 3600) )) hours"
        fi
    else
        echo "  (not running -- rate unavailable)"
    fi
}

if [[ "$WATCH" -eq 1 ]]; then
    while true; do
        clear
        snapshot
        sleep 5
    done
else
    snapshot
fi
