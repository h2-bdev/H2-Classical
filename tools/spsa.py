#!/usr/bin/env python3
"""SPSA tuner for CarelessChess search parameters.

fastchess has no built-in SPSA, so this drives it: every iteration it perturbs
ALL tunable params at once (Bernoulli +-1), plays a small node-limited batch of
plus-vs-minus games, and takes one simultaneous-perturbation gradient step.

Node-limited games (not wall-clock) are used on purpose: deterministic per-move
effort, no time-jitter noise, and reproducible -- ideal for tuning search params.
The result is only ever *kept* after a separate SPRT verification, so a mediocre
tune costs time, not strength.

Live progress: appends to tools/spsa.log and rewrites tools/spsa_state.json
(resumable) + tools/spsa_result.json (current best-estimate theta, ready to paste
as engine defaults). Ctrl-C stops cleanly and writes the result.

The tunable list is read out of the engine's own `uci` handshake at startup, so
it can never drift from TUNE_PARAMS in src/search.cpp.

Usage:
  tools/spsa.py --iters 500              # real run
  tools/spsa.py --iters 250 --minutes 60 # run for one hour, then stop cleanly
  tools/spsa.py --smoke                  # 2 tiny iters to validate the pipeline
  tools/spsa.py --iters 500 --resume     # continue from tools/spsa_state.json
"""
import argparse, json, os, random, re, subprocess, sys, signal, time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.dirname(HERE)
BIN = os.path.join(ENGINE_DIR, "build", "MC-Nature")
FASTCHESS = os.path.join(HERE, "fastchess", "fastchess")
BOOK = os.path.join(HERE, "books", "8moves_v3.pgn")
LOG = os.path.join(HERE, "spsa.log")
STATE = os.path.join(HERE, "spsa_state.json")
RESULT = os.path.join(HERE, "spsa_result.json")

# Standard UCI options the engine advertises that are NOT search tunables.
# Everything else in the `uci` handshake is treated as a TUNE_PARAMS entry.
NON_TUNABLE = {
    "hash", "move overhead", "syzygypath", "syzygyprobelimit", "evalfile",
    "threads", "ponder", "multipv", "skill level", "contempt",
    "uci_limitstrength", "uci_elo", "uci_variant", "clear hash",
}


def discover_params(binary):
    """Read the tunables straight out of the engine's `uci` handshake.

    The previous hardcoded table silently drifted out of sync with
    TUNE_PARAMS in src/search.cpp -- it was missing RazorMargin and still
    carried the pre-tune defaults, so a run would have tuned the wrong
    starting point against the wrong parameter set. Deriving the list makes
    that class of bug impossible.

    Returns [(name, default, lo, hi), ...] in the engine's own order.
    """
    out = subprocess.run([binary], input="uci\nquit\n", capture_output=True,
                         text=True, timeout=60).stdout
    params = []
    pat = re.compile(
        r"^option name (.+?) type spin default (-?\d+) min (-?\d+) max (-?\d+)\s*$")
    for line in out.splitlines():
        m = pat.match(line.strip())
        if m and m.group(1).strip().lower() not in NON_TUNABLE:
            params.append((m.group(1).strip(), int(m.group(2)),
                           int(m.group(3)), int(m.group(4))))
    if not params:
        sys.exit(f"[spsa] no tunable spin options found in {binary}'s uci output")
    return params


PARAMS = []  # filled in main() from the engine binary

# SPSA knobs.
NODES = 50000        # per-move node limit for each engine (fast, deterministic)
GAMES_PER_ITER = 8   # even; played as rounds = GAMES_PER_ITER/2 with -repeat
CONCURRENCY = 8      # node-limited games are contention-immune -> use all cores
LR0 = 0.5            # base learning-rate factor (fraction of a perturbation step)

_stop = False
def _sigint(*_):
    global _stop
    _stop = True
    print("\n[spsa] stop requested — finishing current iteration...", flush=True)
signal.signal(signal.SIGINT, _sigint)


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def c_of(lo, hi):
    """Fixed perturbation size for a param: ~10% of its range, at least 1."""
    return max(1, round(0.10 * (hi - lo)))


def play_batch(theta_plus, theta_minus, games):
    """Return y = (Wplus - Lplus) / games over a node-limited plus-vs-minus batch."""
    def opts(theta):
        out = []
        for (name, _d, lo, hi), t in zip(PARAMS, theta):
            out += [f"option.{name}={int(round(clamp(t, lo, hi)))}"]
        return out
    rounds = max(1, games // 2)
    cmd = [
        FASTCHESS,
        "-engine", f"cmd={BIN}", "name=plus",  f"nodes={NODES}", *opts(theta_plus),
        "-engine", f"cmd={BIN}", "name=minus", f"nodes={NODES}", *opts(theta_minus),
        "-each", "proto=uci", "option.Hash=32", "option.Threads=1",
        "-rounds", str(rounds), "-games", "2", "-repeat",
        "-concurrency", str(CONCURRENCY),
        "-openings", f"file={BOOK}", "format=pgn", "order=random", "plies=16",
        "-resign", "movecount=4", "score=700", "twosided=true",
        "-draw", "movenumber=40", "movecount=10", "score=8",
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    # fastchess prints, from the FIRST engine's (plus) perspective:
    #   "Games: N, Wins: W, Losses: L, Draws: D, Points: ..."
    m = None
    for line in out.splitlines():
        mm = re.search(r"Games:\s*\d+,\s*Wins:\s*(\d+),\s*Losses:\s*(\d+),\s*Draws:\s*(\d+)", line)
        if mm:
            m = mm  # keep the last (final tally)
    if not m:
        sys.stderr.write("[spsa] could not parse fastchess score:\n" + out[-800:] + "\n")
        return 0.0, (0, 0, 0)
    w, l, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    n = max(1, w + l + d)
    return (w - l) / n, (w, l, d)


def main():
    global PARAMS
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=500,
                    help="iteration budget; also sets the learning-rate decay schedule")
    ap.add_argument("--minutes", type=float, default=None,
                    help="wall-clock cap. Stops cleanly after the iteration that "
                         "crosses it, writing the result as usual.")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--resume", action="store_true")
    args = ap.parse_args()

    for path, what in [(BIN, "engine binary"), (FASTCHESS, "fastchess"), (BOOK, "book")]:
        if not os.path.exists(path):
            sys.exit(f"[spsa] missing {what}: {path}")

    PARAMS = discover_params(BIN)
    print(f"[spsa] discovered {len(PARAMS)} tunables from {os.path.basename(BIN)}:",
          flush=True)
    for n, d, lo, hi in PARAMS:
        print(f"         {n:<14} default={d:<6} [{lo}, {hi}]", flush=True)

    iters = 2 if args.smoke else args.iters
    games = 2 if args.smoke else GAMES_PER_ITER
    A = max(1, iters // 2)
    deadline = time.time() + args.minutes * 60 if args.minutes else None

    theta = [float(d) for (_n, d, _lo, _hi) in PARAMS]
    start = 0
    if args.resume and os.path.exists(STATE):
        st = json.load(open(STATE))
        theta = [float(st["theta"].get(n, d)) for (n, d, _lo, _hi) in PARAMS]
        start = st.get("iter", 0)
        print(f"[spsa] resumed at iter {start}", flush=True)

    print(f"[spsa] {len(PARAMS)} params, {iters} iters, {games} games/iter, "
          f"nodes={NODES}, conc={CONCURRENCY}", flush=True)

    for k in range(start, iters):
        if _stop:
            break
        if deadline and time.time() >= deadline:
            print(f"[spsa] wall-clock cap reached after {k - start} iterations "
                  f"this run", flush=True)
            break
        lr = LR0 * A / (A + k)
        delta = [random.choice((-1, 1)) for _ in PARAMS]
        tp, tm = [], []
        for (name, _d, lo, hi), t, dl in zip(PARAMS, theta, delta):
            c = c_of(lo, hi)
            tp.append(clamp(t + c * dl, lo, hi))
            tm.append(clamp(t - c * dl, lo, hi))
        y, (w, l, d) = play_batch(tp, tm, games)
        # Gradient ascent on score: step each param toward the winning perturbation.
        for i, ((name, _d, lo, hi), dl) in enumerate(zip(PARAMS, delta)):
            c = c_of(lo, hi)
            theta[i] = clamp(theta[i] + lr * y * dl * c, lo, hi)

        rounded = {n: int(round(clamp(t, lo, hi)))
                   for (n, _d, lo, hi), t in zip(PARAMS, theta)}
        json.dump({"iter": k + 1, "theta": {n: t for (n, _d, _lo, _hi), t
                                            in zip(PARAMS, theta)}},
                  open(STATE, "w"), indent=2)
        json.dump(rounded, open(RESULT, "w"), indent=2)
        line = (f"iter {k+1:4d}/{iters}  y={y:+.3f} (W{w} L{l} D{d})  lr={lr:.3f}  "
                + " ".join(f"{n}={rounded[n]}" for n, *_ in PARAMS))
        with open(LOG, "a") as f:
            f.write(line + "\n")
        print(line, flush=True)

    print(f"[spsa] done. result -> {RESULT}", flush=True)


if __name__ == "__main__":
    main()
