#!/usr/bin/env bash
# Tier 0 gate: build + perft + bench signature. ~2 minutes, zero credits.
#
# This is the cheapest gate and it runs first on purpose -- if it fails you
# never spend smoke-test, SPRT, or analysis effort on a broken change.
#
# Output is deliberately ~10 lines. Everything verbose goes to tools/gate.log;
# read that only if this script tells you to.
#
# Usage:
#   tools/gate.sh                  # build, perft, bench; record the signature
#   tools/gate.sh --expect-noop    # FAIL if bench moved (refactors must be bit-identical)
#   tools/gate.sh --expect-change  # FAIL if bench did NOT move (real search/eval changes must)
#   tools/gate.sh --was 1703779    # compare against an explicit signature
#
# The previous signature is remembered in tools/.last_bench, so --expect-noop /
# --expect-change work without passing --was.
#
# Exit: 0 = all gates pass. 1 = a gate failed. 2 = usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG="$SCRIPT_DIR/gate.log"
LAST="$SCRIPT_DIR/.last_bench"

cd "$ENGINE_DIR" || exit 2

expect="any"
was=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-noop)   expect="noop" ;;
        --expect-change) expect="change" ;;
        --was)           was="${2:-}"; shift ;;
        -h|--help)       sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               echo "gate: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# Read the binary name from the Makefile -- it is the only authoritative source.
# Do NOT guess by probing build/ for known names: build/ accumulates stale
# binaries (a pre-rename `carelesschess` from July, `cc-1c`, `globebot`...), and
# a probe loop silently benchmarked a two-week-old binary and reported PASS.
BIN="$(awk -F':=' '/^BIN[[:space:]]*:=/ {gsub(/[[:space:]]/,"",$2); print $2}' Makefile)"
[[ -n "$BIN" ]] || { echo "gate: cannot read BIN from Makefile" >&2; exit 2; }

[[ -n "$was" ]] || was="$(cat "$LAST" 2>/dev/null || true)"

: > "$LOG"
fail=0
step() { printf '%-22s %s\n' "$1" "$2"; }

# --- 1. build (clean: the Makefile has no header dependency tracking, so a
#         stale LTO link after a header edit can segfault) -------------------
if make clean >>"$LOG" 2>&1 && make -j8 >>"$LOG" 2>&1; then
    step "build" "OK"
else
    step "build" "FAIL   -> see $LOG"
    echo; echo "gate: FAILED at build"; exit 1
fi

[[ -x "$BIN" ]] || { step "binary" "FAIL   missing $BIN"; exit 1; }

# --- 2. perft (the movegen correctness gate) -------------------------------
if make perft >>"$LOG" 2>&1 && grep -q "All perft positions passed" "$LOG"; then
    step "perft" "OK     $(grep -c '\[PASS\]' "$LOG") positions"
else
    step "perft" "FAIL"
    grep '\[FAIL\]' "$LOG" | head -5
    echo; echo "gate: FAILED at perft -- movegen is broken, nothing else is meaningful"
    exit 1
fi

# --- 3. bench signature ----------------------------------------------------
bench="$("./$BIN" bench 2>>"$LOG" | awk '/Nodes searched/ {print $4}')"
if [[ -z "$bench" ]]; then
    step "bench" "FAIL   could not parse -> see $LOG"
    exit 1
fi

if [[ -z "$was" ]]; then
    step "bench" "$bench  (no previous signature recorded)"
else
    delta=$(( bench - was ))
    pct=$(awk -v d="$delta" -v w="$was" 'BEGIN{printf "%+.1f", 100*d/w}')
    if [[ "$delta" -eq 0 ]]; then
        step "bench" "$bench  (unchanged)"
    else
        step "bench" "$bench  (was $was, $(printf '%+d' "$delta"), ${pct}%)"
    fi

    case "$expect" in
        noop)
            if [[ "$delta" -ne 0 ]]; then
                step "expect-noop" "FAIL   signature moved; this was supposed to be bit-identical"
                fail=1
            else
                step "expect-noop" "OK"
            fi ;;
        change)
            if [[ "$delta" -eq 0 ]]; then
                step "expect-change" "FAIL   signature identical; the change had no effect on search"
                fail=1
            else
                step "expect-change" "OK"
            fi ;;
    esac
fi

echo "$bench" > "$LAST"
echo
if [[ "$fail" -eq 0 ]]; then
    echo "gate: PASS -- safe to smoke test (tools/smoke.sh)"
else
    echo "gate: FAILED -- do not proceed to matches"
fi
exit "$fail"
