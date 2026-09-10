#pragma once
// Self-play training-data generation for NNUE.
//
// Plays fixed-node self-play games from randomised openings and writes one text
// line per recorded quiet position, in the format bullet's `convert --from text`
// ingests:  <FEN> | <score> | <result>
//   score  : white-relative centipawns (clamped)
//   result : white-relative game outcome, "1.0" win / "0.5" draw / "0.0" loss
//
// Single-threaded by design (the engine is): run one process per core, each
// writing its own file with a distinct seed, then shuffle+interleave.

#include <cstdint>
#include <string>

void datagen_run(const std::string& outPath, int numGames, int nodes, uint64_t seed);
