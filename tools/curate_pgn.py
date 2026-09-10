#!/usr/bin/env python3
"""Reduce a match PGN to the handful of positions actually worth looking at.

A gauntlet PGN is ~48k tokens and its log ~284k. Handing either to an agent is
both expensive and ineffective -- it skims. This extracts candidate positions
mechanically (which is what machines are good at) so the agent only ever sees
curated cases (which is what judgment is for). Typical output is ~1-2k tokens.

fastchess writes a comment per move: {+2.51/13 0.236s} = eval/depth time, or
{book}. Eval is from the moving side's point of view. That gives us everything
needed without re-analysing anything.

What it looks for, in priority order:
  blunder     a side's eval falls sharply between its own consecutive moves
  overeval    engine was winning by a lot at the end but did not win
              (an eval-quality problem, not a search problem -- these are the
              positions worth feeding back into NNUE training)
  slowmove    move time far above that game's median (time-management outlier)
  shallow     depth far below that engine's median (search fell off a cliff)

Usage:
  tools/curate_pgn.py tools/gauntlet_*.pgn
  tools/curate_pgn.py --engine dev --max 20 --drop 250 x.pgn
"""
import argparse, glob, re, statistics, sys

try:
    import chess.pgn
except ImportError:
    sys.exit("curate_pgn: needs python-chess (pip3 install --break-system-packages chess)")

COMMENT = re.compile(r"^([+-]?)(M?)([\d.]+)/(\d+)\s+([\d.]+)s")

MATE_CP = 3000      # clamp for mate scores; see parse_comment
LOST_CP = -150      # below this the side is already losing, so "now sees mate" is noise

# Below this, the position is already hopeless and a further "drop" is not a
# blunder -- it is just a lost game getting more lost. Without this, sorting by
# absolute delta fills the report with king marches in dead positions (a -500 to
# -2500 slide outranks a genuine +1.1 -> -11.7 middlegame collapse) and buries
# everything actionable.
ALREADY_LOST_CP = -800


def parse_comment(c):
    """-> (eval_cp, depth, seconds) from the mover's POV, or None for book moves."""
    m = COMMENT.match(c.strip())
    if not m:
        return None
    sign, mate, val, depth, secs = m.groups()
    if mate:
        # Clamped well below a real mate value on purpose. Using +/-10000 makes
        # every "already lost, now sees mate" endgame outrank every genuine
        # middlegame blunder, because the delta is an order of magnitude larger.
        cp = MATE_CP if sign != "-" else -MATE_CP
    else:
        cp = int(round(float(val) * 100))
        if sign == "-":
            cp = -cp
    return cp, int(depth), float(secs)


def curate(path, engine, drop, max_per_file):
    findings = []
    with open(path) as fh:
        gi = 0
        while True:
            game = chess.pgn.read_game(fh)
            if game is None:
                break
            gi += 1
            white = game.headers.get("White", "?")
            black = game.headers.get("Black", "?")
            result = game.headers.get("Result", "*")
            if engine and engine not in (white, black):
                continue

            board = game.board()
            # per-side move records: (ply, fen_before, san, cp, depth, secs)
            rec = {chess.WHITE: [], chess.BLACK: []}
            for ply, node in enumerate(game.mainline(), start=1):
                mover = board.turn
                fen = board.fen()
                san = board.san(node.move)
                info = parse_comment(node.comment or "")
                board.push(node.move)
                if info:
                    cp, depth, secs = info
                    rec[mover].append((ply, fen, san, cp, depth, secs))

            for color in (chess.WHITE, chess.BLACK):
                name = white if color == chess.WHITE else black
                if engine and name != engine:
                    continue
                moves = rec[color]
                if len(moves) < 4:
                    continue
                times = [m[5] for m in moves]
                depths = [m[4] for m in moves]
                med_t, med_d = statistics.median(times), statistics.median(depths)

                # blunders: this side's eval collapsing between its own moves
                for i in range(1, len(moves)):
                    prev, cur = moves[i - 1], moves[i]
                    delta = cur[3] - prev[3]
                    if delta > -drop:
                        continue
                    prev_mate = abs(prev[3]) >= MATE_CP
                    cur_mate = abs(cur[3]) >= MATE_CP
                    if prev_mate:
                        continue                      # was already forced; nothing learned
                    if prev[3] < ALREADY_LOST_CP:
                        continue                      # already lost; not a blunder
                    if cur_mate and prev[3] < LOST_CP:
                        continue                      # already losing, mate is just the ending
                    findings.append(dict(
                        kind="walked-into-mate" if cur_mate else "blunder",
                        game=gi, side=name, ply=cur[0],
                        fen=cur[1], san=cur[2], cp=cur[3], prev=prev[3],
                        delta=delta, depth=cur[4], secs=cur[5], result=result,
                        note=f"{prev[2]} then {cur[2]}"))

                # over-optimistic final eval vs the actual result
                last = moves[-1]
                won = (result == "1-0" and color == chess.WHITE) or \
                      (result == "0-1" and color == chess.BLACK)
                if last[3] >= 300 and not won and abs(last[3]) < MATE_CP:
                    findings.append(dict(
                        kind="overeval", game=gi, side=name, ply=last[0],
                        fen=last[1], san=last[2], cp=last[3], prev=last[3],
                        delta=0, depth=last[4], secs=last[5], result=result,
                        note=f"final eval {last[3]/100:+.2f} but result {result}"))

                # time and depth outliers
                for m in moves:
                    if med_t > 0 and m[5] > max(4 * med_t, med_t + 1.0):
                        findings.append(dict(
                            kind="slowmove", game=gi, side=name, ply=m[0],
                            fen=m[1], san=m[2], cp=m[3], prev=m[3], delta=0,
                            depth=m[4], secs=m[5], result=result,
                            note=f"{m[5]:.3f}s vs {med_t:.3f}s median"))
                    if m[4] <= max(1, med_d - 6):
                        findings.append(dict(
                            kind="shallow", game=gi, side=name, ply=m[0],
                            fen=m[1], san=m[2], cp=m[3], prev=m[3], delta=0,
                            depth=m[4], secs=m[5], result=result,
                            note=f"depth {m[4]} vs {med_d:.0f} median"))

    order = {"walked-into-mate": 0, "blunder": 1, "overeval": 2, "slowmove": 3, "shallow": 4}
    findings.sort(key=lambda f: (order[f["kind"]], f["delta"]))
    return findings[:max_per_file]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pgns", nargs="+")
    ap.add_argument("--engine", default=None, help="only this engine's moves (e.g. dev)")
    ap.add_argument("--drop", type=int, default=250, help="blunder threshold, cp")
    ap.add_argument("--max", type=int, default=20, help="max findings per file")
    args = ap.parse_args()

    paths = [p for pat in args.pgns for p in sorted(glob.glob(pat))]
    if not paths:
        sys.exit("curate_pgn: no PGN files matched")

    total = 0
    for path in paths:
        f = curate(path, args.engine, args.drop, args.max)
        print(f"\n=== {path} — {len(f)} findings ===")
        for i, x in enumerate(f, 1):
            head = f"#{i} {x['kind']} game {x['game']} ({x['side']}) ply {x['ply']} result {x['result']}"
            print(head)
            if x["kind"] in ("blunder", "walked-into-mate"):
                print(f"   {x['san']}  eval {x['prev']/100:+.2f} -> {x['cp']/100:+.2f} "
                      f"({x['delta']}cp)  d{x['depth']} {x['secs']:.3f}s")
            else:
                print(f"   {x['san']}  {x['note']}  d{x['depth']} {x['secs']:.3f}s")
            print(f"   {x['fen']}")
        total += len(f)
    print(f"\ntotal findings: {total} across {len(paths)} file(s)")


if __name__ == "__main__":
    main()
