# TODO.md — MC-Nature (H2-N)

Outstanding / unverified work. See `CLAUDE.md` for commands and dev
discipline, `ARCHITECTURE.md` for how the engine works. Dates below are
carried over from the project history — do not assume anything here is
stale just because it's dated; verify against `tools/BENCH.txt`,
`tools/baselines/`, and `git log` before acting.

## 1. SPSA search-param tuning — UNVERIFIED (opened 2026-07-31, paused mid-verification)

**Status: the tuned defaults are baked into `TUNE_PARAMS` in `search.cpp`
right now, but they are NOT proven.** Do not treat the current tree as a
confirmed improvement without finishing this.

- The tunable-param harness itself is a verified no-op (bench bit-identical
  at `1842508` with the harness's original, pre-tune defaults).
- Current tree = tuned defaults, builds clean, perft-pass, **bench
  `1933988`** (moved from `1842508` — a real search behavior change, as
  expected). Tuned binary saved at `tools/baselines/cc-1a-spsa`. Pre-tune
  baseline at `tools/baselines/latest -> cc-c4-incremental` (bench
  `1842508`), untouched.
- **The only SPRT run so far was cut at 40 games:** `cc-1a-spsa` vs
  `cc-c4-incremental`, +43.7 ±69.6 Elo, 56.25%, LLR 0.24 — trending positive
  but statistically inconclusive (the CI is huge relative to the effect).

**To resume:** rerun to a real sample —
`TC=30+0 CONCURRENCY=8 BASE=c4-incremental tools/sprt.sh` (the build under
test must be the tuned tree; per the fastchess-concurrency memory, consider
capping concurrency at 3–4 instead of 8 on this machine to avoid
time-forfeit noise).

**To revert instead of verifying:** restore these `TUNE_PARAMS` defaults in
`search.cpp` and rebuild — bench should return to `1842508`:

```
RfpMargin 80, RfpMarginImp 60, NullBase 3, NullDepthDiv 6, NullEvalDiv 200,
ProbCutImp 60, FutBase 150, FutScale 100, HistPruneMul 4000, SeeCapMul 50,
LmrHistDiv 8192, LmrDivX100 210, AspDelta 12, HistBonusMul 4,
HistBonusMax 8000, LmpBase 3
(all other TUNE_PARAMS entries already at their default)
```

Nothing from this tune has been `make install`ed — the live bot is
unaffected either way.

## 2. Razoring + Lazy SMP (2-thread) — quick-gated only, not formally confirmed

Landed as part of the 2026-08-02/03 SIMD/timeman/usability/Lazy-SMP
campaign (full writeup: `tools/CAMPAIGN_RESULTS_2026-08.md`). Both features
were smoke-tested with two rounds of 30-then-20-game quick gates each, zero
losses in every round — directionally strong — but the LLR never crossed the
formal SPRT bound in either case:

- Razoring: +34.9 ±75.1 Elo (quick gate).
- Lazy SMP 2-thread: +46.6 ±39.8 Elo, LOS 99% (quick gate).

**To resume:** run a longer confirmatory SPRT for each (or batch both
together) before treating either as a proven Elo claim. This is separate
from item 1 above — do not conflate the SPSA-tune SPRT with this one; they
gate different commits.

Final bench for this campaign line: `1703779` (everything from razoring
onward is a verified no-op on top of that baseline, i.e. `bench` itself
doesn't move from adding these features — only match results do).

## 2b. `Search::clear()` never resets `helperWorker` (found 2026-08-15)

`search.cpp`'s `clear()` `memset`s only `mainWorker`'s tables. `helperWorker`
(`search.cpp:241`, the Lazy-SMP second thread) holds its own independent
`mainHistory`, `counterMoves`, `contHistory`, `captureHistory` and all three
correction histories, and **none of them are reset on `ucinewgame`**.

Pre-existing — it predates the correction-history expansion, which merely added
two more tables to the same blind spot. **Inert at the default `Threads=1`**
(the helper never runs); at `Threads=2` it means learned history and eval
corrections leak across games within one running process.

Fix is a one-liner per table, but it changes `Threads=2` behaviour, so it wants
its own gate rather than riding along with another feature.

## 3. Deferred architectural decision — Stockfish BT4-style net

Considered and explicitly rejected during the 2026-08 campaign: BT4's
HalfKAv2_hm feature set is architecturally incompatible with this engine's
flat-768 king-bucketed NNUE at every level (accumulator refresh semantics,
quantization, and no SIMD path wide enough to make a much larger net fast
enough). Integrating it would mean building a second NNUE implementation
from scratch, not swapping a net file. Logged here as a rejected direction,
not a live to-do — revisit only if the constraint that killed it changes
(e.g. a SIMD rewrite wide enough to make a bigger net tractable).

## 4. Small optimization idea (not scheduled)

A king-bucket cache in the NNUE accumulator, to avoid a full rebuild when
the king shuffles back and forth across a bucket boundary repeatedly within
a search. Noted in `ARCHITECTURE.md`'s NNUE section; nobody has picked this
up.

## 5. Unexplained stray binary

`H2-N/lichess-bot/engines/` contains an inert `carelesschess` binary
alongside the correct `MC-Nature` one. `config.yml` points at `MC-Nature` by
name, so it isn't loaded, but its origin was never investigated (found
2026-08-03). Don't assume it's safe to delete without checking first — but
also don't assume it's load-bearing.

## 6. In the working tree, built but NOT SPRT-verified (2026-08-16)

Three uncommitted changes are stacked in `src/`. Bench is **1654276** for all
three together; they have **not** been separated by SPRT, and the machine was
running an 8-core datagen job when this was built, so no Elo measurement of any
kind has been taken.

- **SPSA tune** — live in `TUNE_PARAMS`. Two runs (+14.64+/-15.31, then an
  invalid +9.82+/-12.77). Still unverified. Revert list is in the
  `TUNE_PARAMS` comment block. `NullBase` is pinned at its upper bound (6);
  widen the range before any future tuning round.
- **A1, correction-history expansion** (non-pawn + continuation keys). SPRT cut
  at 1418 games: **+3.19 +/- 7.70, LOS 79.14%, LLR 0.29/2.94** — a near-zero
  effect that looked promising only on thin data (+3.95 at 440, +6.76 at 720).
  `tools/ablate.sh` proved it is FIRING, not inert: defaults 488,926 nodes;
  `CorrWCont=0` 472,607 (-3.3%); `CorrWNonPawn=0` 559,750 (+14.5%); both off
  568,495 (+16.3%). The continuation key is the suspect — disabling it makes
  the search SMALLER. Open decision: run the `CorrWCont=0` salvage SPRT (a UCI
  option, so no rebuild needed) or archive per the standing decision rule.
- **A2, continuation-history plies {1,2,4,6}** — written, now BUILT for the
  first time (it required `StackPad = 6`, guarded by a `static_assert`). It
  changed the bench (A1 alone was 1678045 -> 1654276 with A2), so it is
  affecting the search. Never gated, never played a game.

## 6b. Four more stacked, unverified changes (2026-08-28)

Stacked on top of §6 and **all still uncommitted**. Baselines chained, so each
was measured against the one before it. Bench progression:
`1654276` (helperfix, no-op) → `1856396` (ttPv) → `1505550` (cutoffCnt) →
`1532059` (multicut).

None of these is a claim. Three ran only to a 15-minute cap, which at
`tc=8+0.08` yields 80–140 games against a ±30–70 Elo CI — structurally unable
to resolve the ~+10 Elo effects being tested.

- **helperWorker reset fix** — `Search::clear()` now resets the helper's tables
  too (closes §2b, which was wrong to call the leak "inert at Threads=1": the
  live `config.yml` sets `Threads: 2`). SPRT at THREADS=2/CONC=2:
  **+8.69 +/- 29.45**, 80 games, LLR 0.12, health clean. Needs ~2254 games.
- **ttPv** — sticky PV flag through the TT (bit 2 of `genBound8`, generation
  narrowed to 5 bits), read by LMR to reduce former PV lines less. SPRT:
  **+14.90 +/- 19.20**, 140 games, LLR 0.45, LOS 93.63%, health clean. Needs
  ~953 games. The most promising of the four.
- **cutoffCnt** — per-node beta-cutoff counter read by the parent's LMR to
  reduce more in easy subtrees. `CutoffCntMax` is in `TUNE_PARAMS`. First run
  was INVALID (6.38% time-losses, worst overrun 965s, machine in heavy swap —
  it reported a bogus +88.74). Clean rerun at CONC=2: **+17.39 +/- 33.81**,
  80 games, LLR 0.22, health clean. Needs ~1269 games.
- **multicut — TRENDING NEGATIVE, the weakest of the four.** Replaced the old
  `singularBeta >= beta` test (which ignored the verification search's result
  and fires rarely at depth, since the margin grows with depth) with
  `v >= beta`, returning `v`, guarded against mate scores. Strictly subsumes
  the old condition. Ran the **full pipeline**: gate PASS, `engine-doctor`
  PROCEED, smoke clean (40 games, 45.0%), then SPRT cut at 243 games:
  **-7.24 +/- 18.59**, LOS 22.23%, LLR -0.44, Ptnml `[1,21,80,18,0]`.
  One time-loss (0.42%, charged to *base*, 223ms overrun) trips the report's
  INVALID flag; note the corruption **favours dev**, so the negative lean is
  conservative rather than exaggerated. Needs ~1428 games to settle.
  **Open decision: this is the one most likely to be worth reverting.** The
  `engine-doctor` review is on record as sound — if it is dropped, drop it as
  "measured, didn't work", not as "broken".

Also noted during that review, pre-existing and NOT introduced by multicut: the
multicut cutoff path returns without a `tte->save`, unlike the ProbCut block a
few lines above which does `tte->save(...); return v;`. Candidate refinement.

## 6c. SPRTs DEFERRED, and a commit that had to be unpicked (2026-08-30)

**State: three features sit uncommitted in the working tree, none confirmed.
multicut was reverted on evidence. Rerun the SPRTs when the machine is quiet.**

### The commit incident

On 2026-08-29 all of §6b's search changes — 304 lines across `search.cpp`,
`tt.{h,cpp}`, `position.*`, `main.cpp` — were committed inside `15a9197`, a
commit whose message read *"Remove CLAUDE.md from the repo"*. Unverified search
work landed under a documentation-cleanup message, invisible to anyone reading
the log, and was pushed to the public repo. That is the exact thing
"one feature per commit, SPRT-gated; never batch unmeasured changes" exists to
prevent.

Unpicked 2026-08-30: the commit was **split**, not reverted. `git revert` would
have restored `CLAUDE.md` into a public repo, which is separately forbidden. The
replacement commit `1160c6e` contains only `.gitignore` + the `CLAUDE.md`
deletion; all source changes are back in the working tree, uncommitted.
The pre-split state is preserved at tag **`backup-before-revert-20260830`**
(= the old `15a9197`) — do not delete that tag until the features are settled.

### ttPv — the only one with real data, and it is WEAKER than it looked

A 3000-game SPRT (dev `cc-ttpv` vs base `cc-helperfix`, saved binaries, so the
tree was uninvolved) reached **2378 games** before dying. Result at that point:

```
Elo: +5.30 +/- 5.98    (2360 games, 50.76%, W256 L220 D1884)
LLR:  1.45 of 2.94     — crossed neither bound
health: 0 time-losses, 0 crashes, 0 illegal
```

**The early readings were small-sample optimism and must not be quoted.** This
feature read +14.90 +/- 19.20 at 140 games and +14.90 +/- 14.21 at 430; with 5x
the data it decayed to +5.30 +/- 5.98. The plausible range is roughly -0.7 to
+11.3 — a small positive at best, not a +15 Elo feature. Any future write-up
should cite the 2378-game figure, not the earlier ones.

**Why the verdict was lost:** concurrent work in this tree replaced
`tools/sprt_ttpv_long.log` with a new inode while fastchess held the original on
fd 1/2. The process kept writing to the now-unlinked inode and the final ~600
games plus the terminating verdict went with it when it exited. The file at the
path is frozen at game 2378. **Do not run a match and edit this tree at the same
time** — and note this is a *different* failure from a rebuild mid-match: nothing
was rebuilt, the log path was simply recreated underneath a live writer.

### Deferred, in priority order

1. **ttPv** — rerun to a bound, or accept ~+5 Elo as the working estimate. Needs
   roughly 1300 more games from the 2378 already played to resolve at this rate.
2. **cutoffCnt** — only ever 80 clean games (+17.39 +/- 33.81). Unresolved.
3. **helperWorker reset fix** — 80 games (+8.69 +/- 29.45). Note this one is a
   *correctness* fix (history leaked across `ucinewgame` at the live config's
   `Threads: 2`), so it is defensible on its own merits even without an Elo
   claim; measure it, but do not scrap it merely for being inconclusive.
4. **multicut — DONE, reverted.** -7.24 +/- 18.59 over 243 games. Not a bug; a
   worse heuristic. Rationale is in the `search.cpp` comment. Do not re-derive.

Run these one at a time, on a quiet machine, with nothing else writing to this
directory.

## 7. PV/bestmove mismatch — FIXED 2026-08-16 (reporting only)

fastchess reported "Bestmove does not match" 23/38/31/5 times across four
matches, in BOTH dev and base, so it predated all current work.

**Cause:** when the final iteration aborts mid-search, `print_info()` is never
reached for that depth, so the last line a GUI saw described depth N while
`bestmove` came from the partial depth N+1 search.

**Not a strength bug.** The move played was always correct: a stopped child
returns `VALUE_ZERO` *before* `rootBestMove` is touched, so a partial result
cannot poison the root. Only the REPORT was stale — but that corrupts PGN
annotation, GUI display, and `tools/curate_pgn.py`, which feeds `game-analyst`.

**Fix:** emit one reconciling `info` line after the ID loop when the aborted
iteration changed the root move, and force `pvTable[0]` to agree with the move
actually played (which also fixes the `ponder` suggestion, read from
`pvTable[0][1]`).

**Verified:** 15/15 timed searches now have PV head == bestmove, and the new
line fires in 12/12 — so the check is not vacuous. Firing rate explains the
original distribution: `movetime` sets soft == hard and always aborts
mid-iteration, while real games usually stop at the soft limit BETWEEN
iterations (clean), so games only hit it on an occasional hard-limit abort.

Bench is unchanged by this fix in the sense that it cannot alter node counts
(it runs after the search loop and touches only the PV table and stdout), but
note this was NOT separately gated against a pre-fix build — A2 was in the same
build. If you want that attribution, gate it explicitly when the machine is free.

## 6d. ponderhit — FIXED and SHIPPED (2026-08-31)

**This one is done and live.** It is the only item in §6 that is both verified
and installed; everything else here remains unverified and uncommitted.

**The bug.** The engine advertised `option name Ponder` (`uci.cpp`), lichess-bot
therefore enabled pondering (`config.yml: ponder: true`), and `go ponder` set
`limits.infinite = true` — but **no `ponderhit` token handler existed** in the
uci_loop dispatch. The token fell through the `else if` chain and was silently
discarded, so the search never became time-limited and never emitted `bestmove`.
On 2026-08-30 this lost a rated game: 410 seconds of search with 147.9 seconds on
the clock (game `whrZEApN`, move 14). The wedged engine was still burning 197%
CPU 26 minutes later and could not be killed by SIGINT, because lichess-bot could
not join it.

**Why no test caught it:** fastchess does not ponder. Every SPRT this project has
ever run executed with pondering off — including the one that gated `go ponder`
itself. `go ponder` shipped tested; `ponderhit` shipped untested.

**A second, latent bug found in the same path:** `join_search()` was a bare
`join()`. On a ponder MISS the GUI sends `position`+`go`, both of which call it,
and joining an unlimited search deadlocks the UCI loop forever. Confirmed
reproducible against the old binary, not theoretical.

**The fix** — `Search::pondering` + `Search::ponderhitTime` atomics (release/
acquire paired), a per-worker `ponder_wait()` + `TimeManager::rebase()`, the
missing `ponderhit` handler (which deliberately does NOT join), `pondering`
cleared in `stop` and in `join_search()`, and `ponderRebased` reset in the
prologues of BOTH `think()` and `think_helper()` so Threads=2 is correct.
The clock is rebased AT the ponderhit because the `wtime` handed to us at
`go ponder` is still our true remaining time (the opponent's clock ran while we
pondered); not rebasing would make the engine believe it had spent time it had
not. `engine-doctor` reviewed it and caught one real ordering bug: `pondering`
was armed BEFORE `join_search()`, which force-clears it — reordered so the
invariant holds unconditionally.

**Gates:** perft PASS; **bench `1703779`, bit-identical** to the live v2.1
signature; `tools/test_ponder.py` 4/4 (and RED on the old binary on exactly the
two real defects). A realistic-clock probe gave 4.95s after a 2s ponder against a
5.3s soft target. Live confirmation in a real game: `ponderhit -> bestmove` in
5.62s and 13.77s, clock drawing down normally, 0 outoftime/traceback/429.

**`tools/test_ponder.py` is new** and is the only test of this path anywhere in
the project. Run it after any change to `uci.cpp`, `timeman.h`, or the search's
time-management, because no SPRT or smoke test will ever exercise pondering.

**Shipped via a throwaway git worktree at HEAD**, so the 304 unverified lines in
§6b/§6c never reached the live account. Also required: `config.yml:6` changed
from `name: "MC-Nature"` to `"H2-Classical"` — `make install` writes
`H2-Classical` while the config still named the old binary, so installing without
that edit would have left the bot launching the Aug 3 engine and the fix would
silently not have shipped. **The ponderhit change itself is still UNCOMMITTED in
the working tree**, mixed into `search.cpp`/`search.h` alongside §6b's work.

### Still broken in the other two engines
- **Fairy-MC** — identical bug (`uci.cpp:120-121`, zero `ponderhit` handlers).
  Structurally identical to Nature, so the patch applies cleanly. Its bot has no
  token and no `.venv`, so the risk is latent rather than active.
- **BravoBlue** — different and milder: advertises `option name Ponder`
  (`uci.cpp:132`) but never parses the `ponder` token, so `go ponder` runs as a
  NORMAL timed search and answers on the opponent's clock. Not a time forfeit,
  but protocol-incorrect. Either implement it properly or stop advertising Ponder.
