# ARCHITECTURE.md — MC-Nature (H2-N)

Deep-dive reference for how the engine actually works, module by module. For
commands, correctness gates, and day-to-day dev discipline, see `CLAUDE.md` in
this directory. For outstanding/unverified work, see `TODO.md`.

## Big picture

MC-Nature is a from-scratch, single-threaded-by-default UCI chess engine in
C++20 (optional 2-thread Lazy SMP — see Search). It plays standard chess only.
Move search is fail-soft principal-variation search with iterative deepening;
evaluation is a bullet-trained NNUE by default, with a hand-crafted eval (HCE)
as a fallback if no net loads. It is the engine half of a two-process
system — `lichess-bot` (a separate Python harness, not in this repo) spawns
the compiled binary and talks to it over stdin/stdout UCI.

## Bootstrap order (fixed, do not reorder)

`main.cpp:engine_init()`:

```
BB::init() → Magic::init() → Zobrist::init() → Search::init() → NNUE::init()
```

`Magic::init()` reads the `SquareDistance` table that `BB::init()` fills, so
bitboards must initialize before magics. This ordering is not defensive
boilerplate — get it wrong and magic-bitboard generation reads uninitialized
distances silently.

## Module map (`src/`)

| File(s) | Responsibility |
|---|---|
| `types.h` | `Square`/`Piece`/`Color` enums, packed 16-bit `Move` (to/from/promo/type). `Value` is a plain `int` alias — deliberately not an enum. LERF square layout (a1=0). |
| `bitboard.{h,cpp}` | Bitboard primitives, `BB::init()` (fills `SquareDistance` and friends). |
| `magic.{h,cpp}` | Fancy magic bitboards, searched via PRNG at startup (no PEXT — Apple Silicon has no BMI2). |
| `attacks.h` | Attack-lookup dispatch used by movegen/SEE/eval. |
| `zobrist.{h,cpp}` | Incremental Zobrist keys: piece placement, en passant, castling, side to move. |
| `position.{h,cpp}` | Bitboard-per-{color,type} board representation. `do_move`/`undo_move` maintain the full Zobrist key **and** an incremental pawn-only key (`StateInfo::pawnKey`) used by correction history. `StateInfo` forms a linked list on the search stack, carrying checkers/pins/check-squares (refreshed via `set_check_info`). `Position` has a working copy constructor (verified-safe shallow copy — required for Lazy SMP worker threads; see `position.h`'s comment). Standard chess only. |
| `movegen.{h,cpp}` | Templated per-color generation with a check-evasion target mask. Every pseudo-legal move is filtered through `pos.legal()` (pins, king safety, en-passant discovered check). Entry points: `generate_legal`, `generate_tactical`. |
| `perft.{h,cpp}` | `perft` + `perft_suite()` (6 positions incl. Kiwipete) — the movegen correctness gate. |
| `see.{h,cpp}` | `see_ge(pos, m, threshold)` — static exchange evaluation, used for capture ordering and pruning. |
| `tt.{h,cpp}` | 3-entry-cluster transposition table, depth+age replacement, mul-shift indexing. Global `TT`. XOR-protected for lockless concurrent access from the second Lazy-SMP thread. |
| `timeman.{h,cpp}` | Soft/hard time-budget split with a bullet-aware divisor; score-drop extension (see Search). |
| `search.{h,cpp}` | Iterative-deepening driver + fail-soft PVS. See below. |
| `eval.{h,cpp}` | Dispatch (`evaluate()`) plus the HCE fallback implementation. |
| `nnue/` | NNUE net + inference (see NNUE section). |
| `syzygy/` | Vendored Fathom + glue code (see Syzygy section). |
| `uci.{h,cpp}` | UCI protocol loop. |
| `bench.{h,cpp}` | The `bench` command — fixed-depth deterministic node-count signature. |
| `datagen.{h,cpp}` | Self-play data generation subcommand for NNUE training (see H2-B's pipeline, ported here). |

## Search (`search.{h,cpp}`)

Single-threaded (default) iterative deepening + fail-soft principal variation
search (PVS).

**Move ordering:** TT move → captures (SEE + MVV-LVA + capture history) →
killers → countermove → combined quiet history (butterfly + 1/2-ply
continuation history).

**Pruning/reductions** (non-PV nodes, not in check): reverse futility pruning
(RFP), null-move pruning, late-move pruning (LMP), futility pruning,
history/SEE pruning, internal iterative reduction (IIR), late-move reductions
(LMR) from a precomputed table adjusted by PV/cutNode/improving/history,
razoring.

**Singular extensions:** a reduced-depth verification search that excludes
the TT move (`excludedMove` lives on the ply stack), with double-extension
and multi-cut handling.

**Correction history:** `pawnCorrHist`, keyed by `pos.pawn_key()`, de-biases
the static eval used for pruning decisions and the qsearch stand-pat; the raw
(uncorrected) eval is still what gets cached in the TT.

**History persistence:** history tables persist across moves within a game;
they are reset only on `ucinewgame` via `Search::clear()`.

**Aspiration windows** and **mate-distance pruning** wrap the ID loop.

**Time management:** soft/hard split (`timeman.{h,cpp}`) plus score-drop
detection — if the best move's score drops significantly between iterations,
the soft limit is extended so the engine doesn't cut off a search that's
walking into trouble mid-think.

**Tunable parameters:** ~20 pruning/reduction constants are runtime-tunable
via an X-macro table `TUNE_PARAMS` in `search.cpp` (`namespace Tune`),
exposed as UCI spin options and settable via `setoption` (routed through
`Search::set_tune`). See `TODO.md` for the unverified SPSA-tuned defaults
currently baked in.

**Syzygy** WDL/root probing is wired into the search here (see Syzygy
section below).

### Lazy SMP (2 threads, optional)

`Threads` is a UCI spin option (`min 1 max 2`). At `Threads=2`,
`Search::think()` spawns a second `SearchWorker` with its own history
tables, PV, limits, and its own `Position` copy — it searches alongside the
reporting (main) thread. The two threads share only:

- `TT` (transposition table — now lockless-safe via XOR protection),
- the read-only `Reductions` table,
- the read-mostly `Tune::*` SPSA params.

`Threads=1` is bit-identical to the pre-Lazy-SMP engine — this was verified
during the 2026-08 campaign, not assumed. Two prerequisites had to be fixed
to make this safe: `Position` needed a working copy constructor (was
`delete`d — repetition detection depends on the `StateInfo` chain, which a
naive FEN-reconstruction would truncate), and the NNUE accumulator state
needed to become `thread_local` (was a single global, not thread-safe).

### MultiPV, UCI extras

`go searchmoves <moves...>` restricts the root move list; `go ponder` is
supported. `seldepth`, `hashfull`, and MultiPV reporting are implemented per
UCI spec.

## Evaluation

`eval.cpp`'s `evaluate()` dispatches:

```cpp
if (NNUE::active()) return NNUE::evaluate(pos);
else /* HCE */;
```

Both paths return a side-to-move-POV score.

### NNUE (default)

Port of akimbo's bullet-trained net (MIT-licensed; see `nnue/NOTICE` and
`nnue/LICENSE-akimbo`).

- **Architecture:** `(768→1024)×2→1`, 4 king-input buckets, horizontal
  mirroring (king file e–h maps via `sq^7`) plus vertical flip for black
  (`sq^56`), SCReLU activation, `QA=255 QB=64 SCALE=400`, plus akimbo's
  material output scaling.
- **Embedding:** the default net `nnue/net.bin` is embedded directly into the
  binary via `incbin.s` at assemble time — the engine is self-contained; the
  net file must exist when building.
- **Inference:** incremental accumulator (`nnue.cpp`'s `Accumulator` stack),
  pushed/popped alongside `do_move`/`undo_move` via
  `begin_move`/`end_move`/`push_null`/`pop`. Refreshed from scratch only on a
  king-bucket change (`king_key` mismatch) or explicit `refresh()`. The
  from-scratch evaluation path in `evaluate()` remains available as a
  non-search oracle (used by the `eval` UCI command, and whenever the
  accumulator isn't active) — both paths are verified bit-for-bit identical.
- **Possible follow-up (unclaimed):** a small king-bucket cache to avoid
  repeated full accumulator rebuilds when the king shuffles back and forth
  across a bucket boundary.
- **Overriding the net:** UCI `EvalFile` loads an external net of identical
  architecture, replacing the embedded one. If loading fails, the engine
  falls back to HCE.

### HCE fallback (`eval.cpp`)

Tapered PeSTO material/piece-square tables plus mobility, pawn structure,
rook-on-open/semi-open-file bonuses, bishop pair, king safety, threats, and
tempo.

## Syzygy tablebases (`syzygy/`)

Vendored **Fathom** (`tbprobe.c/.h`, `tbchess.c`, `tbconfig.h`,
`stdendian.h`; MIT, see `syzygy/LICENSE-Fathom`), compiled as C11 with
`-DTB_NO_THREADS`. Glue code `syzygy/syzygy.{h,cpp}` converts the engine's
`Position` into Fathom's bitboard representation and exposes:

- `probe_wdl` — internal-node cutoff, gated on `rule50==0`, no castling
  rights, and `popcount(pieces) <= MaxPieces`.
- `probe_root` — root DTZ probing; plays the tablebase-optimal move directly,
  matched back to an engine `Move` via `generate_legal`.

The UCI `SyzygyPath` option triggers `tb_init`. **Probing is off unless a
path is set** — the default `bench` is unaffected either way. Tablebase data
files (`.rtbw`/`.rtbz`, 3–4–5-piece) are installed separately, not checked
into the repo, and must be rsync'd/curl'd into whatever folder `SyzygyPath`
points at (gitignored). Note: macOS ships `openrsync`, which lacks
`--info=progress2` — use plain `rsync -a`.

## UCI protocol (`uci.{h,cpp}`)

Standard UCI loop; search runs asynchronously in a `std::thread`, joined on
`stop`/`quit`/a new `position` command. `setoption` handles `Hash`, `Move
Overhead`, `SyzygyPath`, `EvalFile`, `Threads`, `Skill Level`, `Contempt`.
`Ponder` is accepted; unknown option names are silently ignored (per UCI
spec — GUIs probe for options this engine doesn't have).

Dev/UCI tokens (pipe or type at the prompt): `position startpos|fen ...
[moves ...]`, `go depth|movetime|nodes|infinite|wtime ... btime ...`, `go
perft <d>` / `perft <d>` / `divide <d>`, `bench [d]`, `eval` (prints static
eval + which of HCE/NNUE is active), `d`/`print` (dump FEN), `stop`, `quit`.

## Testing & strength infrastructure (`tools/`)

- **A/B SPRT** (`tools/sprt.sh`, overridable `PREFIX`/`DEV_BIN`): defaults
  `tc=8+0.08 elo0=0 elo1=10` with two-sided adjudication, driving
  `tools/fastchess/fastchess` from `tools/books/8moves_v3.pgn`. Keep
  concurrency ≤7 on an 8-core machine (in practice, cap at 3–4 — see the
  `fastchess concurrency` note in project memory; higher concurrency causes
  time-forfeits that corrupt SPRT results even below the naive "leave 1 core
  free" heuristic).
- **Absolute strength anchor:** `tools/ref/` holds a downloaded Stockfish run
  with `UCI_LimitStrength`/`UCI_Elo`; score converts to Elo via the standard
  logistic formula.
- **SPSA driver:** `tools/spsa.py` (fastchess has no built-in SPSA) —
  simultaneous ±1 perturbation of all `TUNE_PARAMS`, node-limited
  (deterministic) games, gradient step. Writes `tools/spsa.log` +
  `tools/spsa_result.json` (resumable).
- Gitignored: `tools/{baselines,ref,fastchess,books}`, `build/`, `*.o`, and
  the Syzygy data folder.

## Engine style constraints

No exceptions, no RTTI (enforced by compiler flags), C++20. Hot paths
(`do_move`, `legal`, movegen, attack lookups) avoid heap allocation;
`StateInfo` lives on the search stack, not the heap. **Chess960 remains an
explicit non-goal for this project** (it's in scope for the sibling
`Fairy-MC` project instead).

## Relationship to sibling projects

MC-Nature is the base lineage. `H2-B` is a parallel fork (branded
CarelessChess) that currently lacks ProbCut, the incremental NNUE
accumulator, and best-move-stability time management that this project has —
don't assume feature parity; diff the actual source before porting anything
either direction. `Fairy-MC` is a fork of this project at tag `v2.1`, adding
a data-driven variant layer on top — see that project's own
`ARCHITECTURE.md`.
