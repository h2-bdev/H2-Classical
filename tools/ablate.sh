#!/usr/bin/env bash
# Rapid ablation: does a feature actually DO anything, before spending games on it?
#
# Runs a fixed position set at fixed depth under different UCI option settings
# and reports nodes + eval for each. Takes seconds, costs no games, needs no
# rebuild -- any feature exposed through TUNE_PARAMS can be switched off at
# runtime and measured.
#
# The question this answers is NOT "is it stronger" (only an SPRT says that).
# It is "is it inert" -- which is the first thing to check when a feature
# gates clean but measures flat, because the two failure modes need opposite
# responses:
#   * numbers barely move  -> the code is not firing. A tuning/wiring problem.
#   * numbers move a lot   -> it is firing and the effect is genuinely not worth
#                             Elo. A design problem; archive it.
#
# Usage:
#   tools/ablate.sh                       # default: correction-history keys
#   DEPTH=14 tools/ablate.sh
#   tools/ablate.sh "CorrWCont=0" "CorrWNonPawn=0"     # custom settings
#
# Each argument is one comma-separated option set, e.g. "CorrWCont=0,CorrWPawn=0".

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ENGINE_DIR" || exit 2

BIN="$(awk -F':=' '/^BIN[[:space:]]*:=/ {gsub(/[[:space:]]/,"",$2); print $2}' Makefile)"
[[ -x "$BIN" ]] || { echo "ablate: no binary at $BIN" >&2; exit 2; }

DEPTH="${DEPTH:-14}"

# A spread of phases -- correction history is a middlegame/endgame effect, so a
# startpos-only measurement would understate it.
POSITIONS=(
  "startpos"
  "fen r1bqkb1r/pp2nppp/3p4/2pNN3/2B1P3/3P4/PPP2PPP/R1BQK2R w KQkq - 2 8"
  "fen 4rrk1/pp1n1pp1/2pb1q1p/3p4/3P1B2/2NBP2P/PPQ2PP1/R3R1K1 w - - 0 18"
  "fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
  "fen 8/8/8/4Bnp1/8/5k1K/8/8 w - - 0 56"
)

SETTINGS=("$@")
if [[ ${#SETTINGS[@]} -eq 0 ]]; then
    SETTINGS=("" "CorrWCont=0" "CorrWNonPawn=0" "CorrWCont=0,CorrWNonPawn=0")
elif [[ "${SETTINGS[0]}" != "" ]]; then
    # Always measure <defaults> first. Every row is only meaningful RELATIVE to
    # it -- without the baseline the numbers are unreadable, and passing custom
    # settings used to silently drop it.
    SETTINGS=("" "${SETTINGS[@]}")
fi

run_set() {
    local opts="$1" total=0 line evals=""
    for pos in "${POSITIONS[@]}"; do
        {
            echo "uci"
            if [[ -n "$opts" ]]; then
                IFS=',' read -ra kv <<< "$opts"
                for o in "${kv[@]}"; do
                    echo "setoption name ${o%%=*} value ${o##*=}"
                done
            fi
            echo "ucinewgame"
            echo "position $pos"
            echo "go depth $DEPTH"
            echo "quit"
        } | ./"$BIN" 2>/dev/null > /tmp/ablate_$$.txt
        # Last full info line of the search.
        line=$(grep "^info depth $DEPTH " /tmp/ablate_$$.txt | tail -1)
        local n s
        n=$(awk '{for(i=1;i<=NF;i++) if($i=="nodes") print $(i+1)}' <<< "$line")
        s=$(awk '{for(i=1;i<=NF;i++) if($i=="score") print $(i+2)}' <<< "$line")
        total=$(( total + ${n:-0} ))
        evals="$evals ${s:-?}"
        rm -f /tmp/ablate_$$.txt
    done
    printf '%-34s nodes=%-12s evals=%s\n' "${opts:-<defaults>}" "$total" "$evals"
}

echo "ablation at depth $DEPTH over ${#POSITIONS[@]} positions ($BIN)"
echo
for s in "${SETTINGS[@]}"; do run_set "$s"; done
echo
echo "Reading: if a row's nodes/evals are ~identical to <defaults>, that option"
echo "is inert -- the feature is not firing and no SPRT will ever show it."
