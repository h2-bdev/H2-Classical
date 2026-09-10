#!/usr/bin/env bash
# Time-boxed SPRT: run tools/sprt.sh for SECONDS, then stop it and report.
#
# Why this exists: sprt.sh runs to an SPRT bound or ROUNDS, which is open-ended.
# A fixed wall-clock budget needs the match stopped from outside.
#
# A long `sleep` is NOT a reliable timer on this machine -- a scheduled datagen
# stop overran its deadline by 87s and never fired (see the bravoblue-selftrain
# memory). So this polls against an absolute deadline instead of sleeping once.
#
# Usage: SECS=900 TAG=helperfix [sprt.sh env vars...] tools/sprt_timed.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SECS="${SECS:-900}"
TAG="${TAG:-untagged}"
LOG="$SCRIPT_DIR/sprt_${TAG}.log"

# Refuse to start if a match is already running -- two fastchess jobs on 8 cores
# corrupt each other's time measurements. Note the deliberate `;` not `&&`:
# grep -c prints 0 and EXITS 1 on no match, so `&&` would skip the whole run
# and look successful.
running=$(pgrep -c fastchess 2>/dev/null); [ -z "$running" ] && running=0
if [ "$running" -gt 0 ]; then
    echo "refusing to start: $running fastchess process(es) already running" >&2
    exit 3
fi

echo "sprt_timed: tag=$TAG budget=${SECS}s log=$LOG"
"$SCRIPT_DIR/sprt.sh" > "$LOG" 2>&1 &
runner=$!

# Confirm the match ACTUALLY started. sprt.sh has died before launching a
# single game while the wrapper still exited 0 (bash 3.2 + set -u on an empty
# array); a wrapper that reports success for zero games is worse than useless.
sleep 15
if ! pgrep -x fastchess > /dev/null 2>&1; then
    echo "sprt_timed: FAILED -- no fastchess process 15s after launch. Log says:" >&2
    tail -5 "$LOG" >&2
    kill "$runner" 2>/dev/null
    exit 4
fi

deadline=$(( $(date +%s) + SECS ))
while kill -0 "$runner" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 10
done

if kill -0 "$runner" 2>/dev/null; then
    echo "sprt_timed: budget reached, stopping match"
    # sprt.sh exec's fastchess, so the runner PID *is* fastchess. SIGINT lets
    # fastchess flush its final result block; SIGKILL would truncate the log.
    kill -INT "$runner" 2>/dev/null
    for _ in $(seq 1 15); do kill -0 "$runner" 2>/dev/null || break; sleep 1; done
    kill -9 "$runner" 2>/dev/null
    pkill -9 fastchess 2>/dev/null
else
    echo "sprt_timed: match ended on its own before the budget"
fi

wait "$runner" 2>/dev/null
echo "sprt_timed: done -> $LOG"
