# H2-Classical

A UCI chess engine written from scratch in C++20. Standard chess only (no Chess960).

H2-Classical pairs a classical alpha-beta search with an NNUE evaluation. It is
built to be small, readable and easy to test, and every search change is meant to
be measured before it is kept. Older notes in this repository refer to it as
**MC-Nature** or **H2-N**.

> **Status:** actively developed. Several recent search features are still being
> verified, so this README makes no Elo claims. See [`TODO.md`](TODO.md) for what is
> and isn't confirmed.

## Features

**Search**
- Iterative deepening with fail-soft principal variation search and aspiration windows
- Transposition table (3-entry clusters, lockless-safe for the second search thread)
- Null-move pruning, reverse futility pruning, razoring, ProbCut, futility and late-move pruning, SEE pruning
- Late-move reductions, internal iterative reduction, singular extensions, check extensions
- Move ordering from TT move, SEE and capture history, killers, counter-moves, butterfly and continuation history
- Eval correction history (pawn, non-pawn and continuation keys)
- Soft/hard time management with best-move stability and score-drop extension
- Lazy SMP with up to 2 threads
- Syzygy tablebase probing (WDL in search, DTZ at the root) via [Fathom](https://github.com/jdart1/Fathom)

**Evaluation**
- NNUE: `(768 → 1024)×2 → 1`, 4 king-input buckets with horizontal mirroring, SCReLU,
  incremental accumulators and a refresh cache. The network is a port of
  [akimbo](https://github.com/jw1912/akimbo)'s bullet-trained net and is embedded in the binary.
- Hand-crafted fallback (PeSTO-style tapered tables plus mobility, pawn structure, king safety, threats) if no net loads

**UCI**
- `MultiPV`, `go searchmoves`, `go ponder` / `ponderhit`, `seldepth`, `hashfull`
- Self-play data generation (`datagen`) for NNUE training

## Building

You need `clang++` (C++20), `make`, and a C compiler for the vendored Fathom code.

```sh
make            # builds build/H2-Classical
make perft      # movegen correctness suite
./build/H2-Classical bench
```

> **Platform note:** the build is currently set up for Apple Silicon macOS
> (`-mcpu=apple-m1`, NEON SIMD, Mach-O assembly for the embedded net). Linux and
> x86-64 builds are not supported yet.

## Using it

H2-Classical speaks UCI over stdin/stdout, so it works in any UCI GUI (Cute Chess,
Arena, En Croissant, …) and behind [lichess-bot](https://github.com/lichess-bot-devs/lichess-bot).
Point your GUI at `build/H2-Classical`.

| Option | Default | Notes |
|---|---|---|
| `Hash` | 64 | Transposition table size in MB |
| `Threads` | 1 | 1 or 2 (Lazy SMP) |
| `MultiPV` | 1 | 1–8 lines |
| `Move Overhead` | 100 | Milliseconds reserved per move for latency |
| `Ponder` | false | |
| `Skill Level` | 20 | Below 20 caps search depth |
| `Contempt` | 0 | Draw-score bias |
| `SyzygyPath` | empty | Directories containing `.rtbw` / `.rtbz` files |
| `EvalFile` | internal | Optional external net with the same architecture |

The search also exposes its pruning and reduction constants as spin options (used
by the SPSA tuner). Send `uci` to list them.

Handy console commands: `bench [depth]`, `perft <d>`, `divide <d>`, `eval`, `d`.

## Testing and development

`bench` runs a fixed-depth search over 12 positions and prints a node count. The
count is deterministic, so a refactor must reproduce it exactly and a real search
change should move it. History is in [`tools/BENCH.txt`](tools/BENCH.txt).

Scripts in [`tools/`](tools/):

| Script | Purpose |
|---|---|
| `gate.sh` | Build, perft and bench-signature check |
| `smoke.sh` | Short match against a saved baseline (catches crashes and big regressions) |
| `sprt.sh` | SPRT A/B test against a baseline using [fastchess](https://github.com/Disservin/fastchess) |
| `spsa.py` | SPSA tuning of the search parameters |
| `test_ponder.py` | UCI ponder handshake test |

The match scripts expect `fastchess`, an opening book and saved baseline binaries
under `tools/`, which are git-ignored.

## Repository layout

```
src/            engine sources
  search.cpp    iterative deepening, PVS, quiescence, Lazy SMP
  eval.cpp      evaluation dispatch + hand-crafted fallback
  nnue/         NNUE inference and the embedded net
  syzygy/       Fathom (vendored) + glue
  uci.cpp       UCI loop
tools/          testing, tuning and match scripts
ARCHITECTURE.md module-by-module design notes
TODO.md         open and unverified work
```

For how the pieces fit together, read [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Credits

- NNUE network and architecture: [akimbo](https://github.com/jw1912/akimbo) (MIT), trained with [bullet](https://github.com/jw1912/bullet)
- Tablebase probing: [Fathom](https://github.com/jdart1/Fathom) (MIT)
- Hand-crafted eval tables: PeSTO by Ronald Friederich (Rofchade)
- Match testing: [fastchess](https://github.com/Disservin/fastchess)

## License

No license has been chosen for the engine code yet. Bundled third-party components
keep their own licenses: [`src/nnue/LICENSE-akimbo`](src/nnue/LICENSE-akimbo) and
[`src/syzygy/LICENSE-Fathom`](src/syzygy/LICENSE-Fathom).
