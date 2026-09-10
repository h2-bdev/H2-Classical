#!/usr/bin/env bash
# Extract the verdict from a fastchess SPRT log. ~15 lines out.
#
# This exists because reading the raw log costs ~16k tokens for a 380-game run
# (and a gauntlet log is ~284k), of which 75% is "Started game N / Finished
# game N". The decision needs six lines. Never read the log directly; read this.
#
# It also makes the health checks unskippable. A run with time losses is not a
# result -- one corrupted run in this project's history reported 94.5% where the
# clean rerun gave 0.45%, and two design decisions were built on it first.
#
# Usage:
#   tools/sprt_report.sh                 # newest tools/sprt_*.log
#   tools/sprt_report.sh path/to.log

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="${1:-$(ls -t "$SCRIPT_DIR"/sprt_*.log 2>/dev/null | head -1)}"
[[ -n "$LOG" && -f "$LOG" ]] || { echo "sprt_report: no log found" >&2; exit 2; }

echo "log: $LOG"
echo

# --- health: any failure here invalidates the numbers below -----------------
tl=$(grep -ci "loses on time" "$LOG")
# NOT a bare grep for "crash": fastchess prints a summary line "Crashed: 0",
# which a substring match counts as a crash and reports a clean run as broken.
# Sum the reported counts instead, and look for real disconnects separately.
cr=$(awk '/Crashed:/ {for(i=1;i<=NF;i++) if($i=="Crashed:") s+=$(i+1)} END{print s+0}' "$LOG")
dc=$(grep -ciE "disconnect|terminated abnormally|stall" "$LOG")
il=$(grep -ci "illegal move" "$LOG")
pv=$(grep -ci "Bestmove does not match" "$LOG")
games=$(grep -c "^Finished game" "$LOG")
cr=$(( cr + dc ))

printf 'health   time-losses=%s  crashes=%s  illegal=%s  pv-warnings=%s\n' "$tl" "$cr" "$il" "$pv"

# Attribute time losses. Split evenly across both engines => the machine
# stalled (OS descheduling), not a time-management bug. One-sided => the
# engine under test. This distinction decides whether to rerun or to debug.
if [[ "$tl" -gt 0 ]]; then
    # Portable awk only -- BSD awk (macOS) has no 3-argument match().
    # Line shape: Finished game N (dev vs base): 1-0 {Black loses on time (21308ms overrun)}
    awk '/loses on time/ {
        p1 = index($0, "("); p2 = index($0, ")")
        pair = substr($0, p1 + 1, p2 - p1 - 1)          # "dev vs base"
        split(pair, side, " vs ")
        if ($0 ~ /White loses on time/) c[side[1]]++; else c[side[2]]++
        n = split($0, seg, "(")                          # last "(" starts the overrun
        tail = seg[n]; sub(/ms.*/, "", tail)
        if (tail + 0 > mx) mx = tail + 0
    } END {
        printf "         attribution:"
        for (e in c) printf " %s=%d", e, c[e]
        printf "   worst overrun %.1fs\n", mx / 1000
    }' "$LOG"
fi
if [[ "$tl" -gt 0 || "$cr" -gt 0 || "$il" -gt 0 ]]; then
    rate=$(awk -v t="$tl" -v g="$games" 'BEGIN{printf "%.2f", (g>0)?100*t/g:0}')
    echo "         *** INVALID: ${rate}% of games lost on time / crashed."
    echo "         *** Do not use these numbers. Drop CONCURRENCY to 2 and rerun."
fi
echo

# --- the result block ------------------------------------------------------
if ! grep -q "Results of" "$LOG"; then
    echo "no result block yet ($games games finished so far)"
    exit 0
fi
awk '/Results of/{buf=""; c=1} c&&c++<=6{buf=buf $0 "\n"} END{printf "%s", buf}' "$LOG"

# --- interpret the LLR against its bounds ----------------------------------
# Parsed with awk, not sed: BSD sed (macOS) has no \? in basic regex, so the
# obvious sed one-liner silently matches nothing and the verdict disappears.
# Line shape: "LLR: 0.90 (30.5%) (-2.94, 2.94) [0.00, 10.00]"
llr_line=$(grep "LLR:" "$LOG" | tail -1)
llr=$(awk -F'[(), ]+' '{print $2}' <<<"$llr_line")
upper=$(awk -F'[(), ]+' '{print $5}' <<<"$llr_line")

if [[ -n "$llr" && -n "$upper" ]]; then
    echo
    awk -v l="$llr" -v u="$upper" -v g="$games" 'BEGIN{
        if (l >=  u) { print "VERDICT: H1 ACCEPTED -- the patch is better. Keep it."; exit }
        if (l <= -u) { print "VERDICT: H0 ACCEPTED -- not an improvement. Revert it."; exit }
        printf "VERDICT: INCONCLUSIVE at %d games (LLR %.2f of +/-%.2f).\n", g, l, u
        print  "         Trending " (l>0 ? "positive" : (l<0 ? "negative" : "flat")) \
               ", but this is not yet a claim. Needs roughly " int(g*(u/(l>0?l:0.5))) " games at this rate."
    }'
fi
