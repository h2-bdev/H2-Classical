#!/usr/bin/env python3
"""UCI ponder handshake test.

This exists because neither `gate.sh` nor `smoke.sh` can catch a ponder bug:
fastchess does not ponder, so every SPRT this project has ever run executed
with pondering off. `go ponder` shipped tested; `ponderhit` shipped untested,
and the engine lost a rated game on time on 2026-08-30 -- searching 410s on a
move with 147.9s on the clock -- because no `ponderhit` token handler existed
and the search stayed unlimited forever.

Each case below is bounded by a hard timeout, so a regression fails the test
rather than hanging CI.

    tools/test_ponder.py [path-to-binary]
"""
from __future__ import annotations

import subprocess
import sys
import threading
import time
from pathlib import Path
from queue import Empty, Queue

BIN = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent.parent / "build" / "H2-Classical"

# A 10s clock keeps the test fast. With moveOverhead 100 the engine's own
# time manager yields optimum ~380ms and a hard cap of ~1900ms, so a correct
# search answers well inside HARD_CAP_S while a broken one runs forever.
CLOCK_MS = 10_000
HARD_CAP_S = 8.0
PONDER_S = 3.0

failures: list[str] = []


class Engine:
    def __init__(self) -> None:
        self.p = subprocess.Popen(
            [str(BIN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.q: Queue[str] = Queue()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        assert self.p.stdout
        for line in self.p.stdout:
            self.q.put(line.strip())

    def send(self, cmd: str) -> None:
        assert self.p.stdin
        self.p.stdin.write(cmd + "\n")
        self.p.stdin.flush()

    def wait_for(self, prefix: str, timeout: float) -> tuple[str | None, float]:
        """Return (line, seconds_waited); line is None on timeout."""
        t0 = time.monotonic()
        while True:
            remaining = timeout - (time.monotonic() - t0)
            if remaining <= 0:
                return None, time.monotonic() - t0
            try:
                line = self.q.get(timeout=remaining)
            except Empty:
                return None, time.monotonic() - t0
            if line.startswith(prefix):
                return line, time.monotonic() - t0

    def ready(self) -> None:
        self.send("uci")
        self.wait_for("uciok", 10)
        self.send("isready")
        self.wait_for("readyok", 10)

    def close(self) -> None:
        try:
            self.send("quit")
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def check(name: str, ok: bool, detail: str) -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")
    if not ok:
        failures.append(name)


def case_ponderhit() -> None:
    """ponderhit must end the search on the real clock, and not before it."""
    e = Engine()
    try:
        e.ready()
        e.send("position startpos moves e2e4")
        e.send(f"go ponder wtime {CLOCK_MS} btime {CLOCK_MS}")

        # While pondering, the engine must NOT return a move: its clock is not
        # running yet. This is the half that already worked.
        line, _ = e.wait_for("bestmove", PONDER_S)
        check("no bestmove while pondering", line is None,
              "stayed silent for 3s" if line is None else f"returned {line!r} early")

        e.send("ponderhit")
        line, waited = e.wait_for("bestmove", HARD_CAP_S)

        check("ponderhit returns a bestmove", line is not None,
              f"{line!r} after {waited:.2f}s" if line else
              f"NO bestmove within {HARD_CAP_S}s -- this is the 2026-08-30 time-loss bug")

        # The discriminating assertion. If the clock were NOT rebased at
        # ponderhit, the 3s already spent pondering would exceed the ~1.9s hard
        # cap and the engine would answer instantly. A measurable delay proves
        # the ponder time was correctly treated as free.
        if line is not None:
            check("clock rebased at ponderhit", waited > 0.05,
                  f"searched a further {waited:.2f}s after ponderhit")
    finally:
        e.close()


def case_stop_during_ponder() -> None:
    """`stop` mid-ponder must still produce a bestmove."""
    e = Engine()
    try:
        e.ready()
        e.send("position startpos moves e2e4")
        e.send(f"go ponder wtime {CLOCK_MS} btime {CLOCK_MS}")
        time.sleep(0.5)
        e.send("stop")
        line, waited = e.wait_for("bestmove", 5.0)
        check("stop during ponder", line is not None,
              f"{line!r} after {waited:.2f}s" if line else "NO bestmove -- engine wedged")
    finally:
        e.close()


def case_ponder_miss() -> None:
    """A ponder MISS must not deadlock the UCI loop.

    The GUI answers a miss with `position`+`go` for the move actually played.
    Both call join_search(), which was a bare join() -- with an unlimited ponder
    search still running that never returns.
    """
    e = Engine()
    try:
        e.ready()
        e.send("position startpos moves e2e4")
        e.send(f"go ponder wtime {CLOCK_MS} btime {CLOCK_MS}")
        time.sleep(0.5)
        # No `stop` -- straight to the real position, as a ponder miss does.
        e.send("position startpos moves e2e4 c7c5")
        e.send(f"go wtime {CLOCK_MS} btime {CLOCK_MS}")
        line, waited = e.wait_for("bestmove", HARD_CAP_S)
        check("ponder miss does not deadlock", line is not None,
              f"{line!r} after {waited:.2f}s" if line else
              f"NO bestmove within {HARD_CAP_S}s -- join_search() deadlock")
    finally:
        e.close()


def case_normal_search_unaffected() -> None:
    """A plain timed `go` must be untouched by any of this."""
    e = Engine()
    try:
        e.ready()
        e.send("position startpos")
        e.send(f"go wtime {CLOCK_MS} btime {CLOCK_MS}")
        line, waited = e.wait_for("bestmove", HARD_CAP_S)
        check("normal timed search", line is not None and waited < HARD_CAP_S,
              f"{line!r} after {waited:.2f}s" if line else "NO bestmove")
    finally:
        e.close()


if __name__ == "__main__":
    if not BIN.exists():
        sys.exit(f"no such binary: {BIN}")
    print(f"ponder handshake test -- {BIN}")
    for fn in (case_normal_search_unaffected, case_ponderhit,
               case_stop_during_ponder, case_ponder_miss):
        print(f"\n{fn.__name__}:")
        fn()
    print()
    if failures:
        sys.exit(f"FAILED: {', '.join(failures)}")
    print("all ponder cases passed")
