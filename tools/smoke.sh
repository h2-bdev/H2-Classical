#!/usr/bin/env bash
# Tier 1 smoke test: does the engine RUN correctly? ~13 min at the defaults
# (40 games @30+0, concurrency 3 -> ~13 waves of up to 60s), zero credits.
#
# WHAT THIS CAN TELL YOU: crashes, illegal moves, time forfeits, and
# catastrophic (worse than about -100 Elo) regressions.
#
# WHAT THIS CANNOT TELL YOU: whether the change is an improvement. At 40 games
# the confidence interval is roughly +/-70 Elo, so a typical +10 Elo feature is
# invisible here. This project already carries two features ("razoring",
# "Lazy SMP 2-thread") that were quick-gated at 20-30 games, read as positive,
# and are STILL not real claims -- see TODO.md. Do not repeat that: a smoke
# pass means "safe to SPRT", never "keep it".
#
# Usage:
#   tools/smoke.sh                      # 40 games vs tools/baselines/latest
#   GAMES=60 BASE=spsa2-base tools/smoke.sh
#
# Env: GAMES=40  TC=30+0  CONCURRENCY=3  HASH=64  BASE=latest  PREFIX=cc
#
# Exit: 0 = safe to proceed. 1 = broken or severely regressed. 2 = setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FASTCHESS="$SCRIPT_DIR/fastchess/fastchess"
BASELINES="$SCRIPT_DIR/baselines"
BOOK="${BOOK:-$SCRIPT_DIR/books/8moves_v3.pgn}"
PREFIX="${PREFIX:-cc}"

GAMES="${GAMES:-40}"
TC="${TC:-30+0}"
CONCURRENCY="${CONCURRENCY:-3}"   # measured safe on this 8-core M3; >4 fabricates time losses
HASH="${HASH:-64}"
BASE="${BASE:-latest}"

# From the Makefile, not by probing build/ -- see the note in gate.sh. build/
# holds stale pre-rename binaries and picking one silently tests the wrong engine.
DEV="$ENGINE_DIR/$(awk -F':=' '/^BIN[[:space:]]*:=/ {gsub(/[[:space:]]/,"",$2); print $2}' "$ENGINE_DIR/Makefile")"
[[ -x "$DEV" ]] || { echo "smoke: no engine binary at $DEV -- run make first" >&2; exit 2; }
[[ -x "$FASTCHESS" ]] || { echo "smoke: fastchess not built at $FASTCHESS" >&2; exit 2; }

base_bin="$BASELINES/$PREFIX-$BASE"
if [[ "$BASE" == "latest" ]]; then
    link="$(readlink "$BASELINES/latest" 2>/dev/null || true)"
    [[ -n "$link" ]] || { echo "smoke: no baseline -- run tools/sprt.sh snapshot <tag>" >&2; exit 2; }
    base_bin="$BASELINES/$link"
fi
[[ -x "$base_bin" ]] || { echo "smoke: baseline not found: $base_bin" >&2; exit 2; }

LOG="$SCRIPT_DIR/smoke_$(date +%Y%m%d-%H%M%S).log"
rounds=$(( GAMES / 2 )); (( rounds < 1 )) && rounds=1

echo "smoke: $DEV"
echo "       vs $(basename "$base_bin")   ${GAMES} games @ $TC, concurrency $CONCURRENCY"
echo "       log: $LOG"
echo

"$FASTCHESS" \
    -engine "cmd=$DEV" "name=dev" \
    -engine "cmd=$base_bin" "name=base" \
    -each "tc=$TC" "proto=uci" "option.Hash=$HASH" "option.Threads=1" \
    -rounds "$rounds" -games 2 -repeat -concurrency "$CONCURRENCY" \
    -openings "file=$BOOK" format=pgn order=random plies=16 \
    -resign movecount=4 score=700 twosided=true \
    -draw movenumber=40 movecount=10 score=8 \
    -ratinginterval "$GAMES" -pgnout "file=${LOG%.log}.pgn" \
    > "$LOG" 2>&1

# --- verdict: health first, score second -----------------------------------
tl=$(grep -ci "loses on time" "$LOG")
cr=$(grep -ciE "disconnect|crash|terminated|stall" "$LOG")
il=$(grep -ci "illegal move" "$LOG")
pv=$(grep -ci "Bestmove does not match" "$LOG")

line=$(grep "Games:" "$LOG" | tail -1)
played=$(sed -n 's/.*Games: *\([0-9]*\).*/\1/p' <<<"$line")
wins=$(sed -n 's/.*Wins: *\([0-9]*\).*/\1/p' <<<"$line")
loss=$(sed -n 's/.*Losses: *\([0-9]*\).*/\1/p' <<<"$line")
draw=$(sed -n 's/.*Draws: *\([0-9]*\).*/\1/p' <<<"$line")

echo "health"
printf '  %-16s %s\n' "time losses" "$tl"   # any non-zero invalidates the run
printf '  %-16s %s\n' "crashes"     "$cr"
printf '  %-16s %s\n' "illegal moves" "$il"
printf '  %-16s %s%s\n' "PV warnings" "$pv" "$( ((pv>0)) && echo '   (pre-existing; see TODO)' )"
echo
echo "score (NOT an Elo measurement -- see header)"
printf '  %s\n' "${line:-unavailable}"

fail=0
[[ "$cr" -gt 0 ]] && { echo; echo "smoke: FAIL -- engine crashed or disconnected"; fail=1; }
[[ "$il" -gt 0 ]] && { echo; echo "smoke: FAIL -- illegal move emitted"; fail=1; }
if [[ "$tl" -gt 0 ]]; then
    echo; echo "smoke: FAIL -- $tl time losses. Either time management regressed or the"
    echo "       machine is oversubscribed; drop CONCURRENCY to 2 and rerun before"
    echo "       blaming the engine."
    fail=1
fi

if [[ -n "${played:-}" && "$played" -gt 0 && "$fail" -eq 0 ]]; then
    pct=$(awk -v w="$wins" -v d="$draw" -v n="$played" 'BEGIN{printf "%.1f", 100*(w+0.5*d)/n}')
    bad=$(awk -v p="$pct" 'BEGIN{print (p < 35) ? 1 : 0}')
    if [[ "$bad" -eq 1 ]]; then
        echo; echo "smoke: FAIL -- scored ${pct}%, a severe regression. Diagnose before SPRT."
        fail=1
    fi
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "smoke: PASS -- ran clean. This says NOTHING about strength."
    echo "       Next: TC=8+0.08 CONCURRENCY=3 ROUNDS=1500 tools/sprt.sh"
fi
exit "$fail"
