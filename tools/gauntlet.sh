#!/usr/bin/env bash
# Absolute-strength gauntlet: MC-Nature vs Stockfish 17 pinned at fixed UCI_Elo rungs.
#
# Unlike tools/sprt.sh (which measures dev-vs-own-baseline, i.e. *relative* Elo),
# this brackets the engine against a calibrated external opponent to answer
# "how strong is it, actually?" — no Lichess account required.
#
# Usage:
#   tools/gauntlet.sh                    # default rungs
#   RUNGS="2400 2600 2800" tools/gauntlet.sh
#
# Options (env):
#   RUNGS="2200 2500 2800"   Stockfish UCI_Elo levels to face
#   GAMES=60                 games per rung (even number; colors are swapped)
#   TC=8+0.08                time control
#   CONCURRENCY=6            parallel games (8-core box: leave 2 for the OS)
#   HASH=64                  per-engine hash MB
#   DEV=<path>               engine under test (default build/MC-Nature)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FASTCHESS="$SCRIPT_DIR/fastchess/fastchess"
SF="$SCRIPT_DIR/ref/stockfish/stockfish-macos-m1-apple-silicon"
BOOK="$SCRIPT_DIR/books/8moves_v3.pgn"

DEV="${DEV:-$ENGINE_DIR/build/MC-Nature}"
RUNGS="${RUNGS:-2400 2700 3000}"
GAMES="${GAMES:-60}"
TC="${TC:-8+0.08}"
CONCURRENCY="${CONCURRENCY:-6}"
HASH="${HASH:-64}"

die() { echo "error: $*" >&2; exit 1; }
[[ -x "$FASTCHESS" ]] || die "fastchess not built at $FASTCHESS"
[[ -x "$DEV" ]]       || die "no engine under test at $DEV"
[[ -x "$SF" ]]        || die "no stockfish at $SF"
[[ -f "$BOOK" ]]      || die "no opening book at $BOOK"

# Stockfish's UCI_Elo is only honoured when UCI_LimitStrength is on, and it
# ignores Threads>1 at limited strength, so pin both explicitly per rung.
# TABLEBASE STATE, PINNED (verified 2026-08-15).
# Stockfish's SyzygyPath defaults to <empty>, so the reference engine has NO
# tablebases unless something sets them -- do not assume otherwise. An earlier
# reading that SF was probing TB came from a pipe race (`quit` arriving before
# the search ran, yielding "depth 1 nodes 1 score cp 0" with tbhits 0), and it
# briefly cast doubt on the absolute-strength anchor for no reason.
# Both sides are left TB-free here so the Elo rungs measure engine strength.
# Set SYZYGY=<path> to enable for every engine equally if you ever want the
# comparison WITH tablebases; never enable it for one side only.
tb_args=()
if [[ -n "${SYZYGY:-}" ]]; then
    [[ -d "$SYZYGY" ]] || { echo "gauntlet: SYZYGY path missing: $SYZYGY" >&2; exit 2; }
    tb_args=("option.SyzygyPath=$SYZYGY")
fi

sf_args=()
for elo in $RUNGS; do
    sf_args+=(-engine "cmd=$SF" "name=SF-$elo" "option.UCI_LimitStrength=true" "option.UCI_Elo=$elo")
done

rounds=$(( GAMES / 2 ))
out="$SCRIPT_DIR/gauntlet_$(date +%Y%m%d-%H%M%S)"

echo "gauntlet: $DEV"
echo "  vs Stockfish 17 @ Elo: $RUNGS"
echo "  $GAMES games/rung  tc=$TC  concurrency=$CONCURRENCY  hash=${HASH}MB"
echo "  pgn -> $out.pgn"
echo

# -tournament gauntlet: engine #1 (dev) plays every other engine, but they
# don't play each other — exactly one bracket per rung, no wasted games.
"$FASTCHESS" \
    -engine "cmd=$DEV" "name=dev" \
    "${sf_args[@]}" \
    -each "tc=$TC" "proto=uci" "option.Hash=$HASH" "option.Threads=1" "${tb_args[@]}" \
    -tournament gauntlet \
    -rounds "$rounds" -games 2 -repeat -concurrency "$CONCURRENCY" \
    -openings "file=$BOOK" format=pgn order=random plies=16 \
    -resign movecount=4 score=700 twosided=true \
    -draw movenumber=40 movecount=10 score=8 \
    -ratinginterval 10 \
    -pgnout "file=$out.pgn" \
    2>&1 | tee "$out.log"

echo
echo "pgn: $out.pgn"
echo "log: $out.log"
