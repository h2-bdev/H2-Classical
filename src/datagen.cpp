#include "datagen.h"

#include "bitboard.h"
#include "position.h"
#include "movegen.h"
#include "search.h"
#include "tt.h"
#include "types.h"

#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

const char* StartFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

// splitmix64 — cheap, well-distributed; seeded per process for opening variety.
struct RNG {
    uint64_t s;
    explicit RNG(uint64_t seed) : s(seed) {}
    uint64_t next() {
        uint64_t z = (s += 0x9E3779B97F4A7C15ULL);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        return z ^ (z >> 31);
    }
    int below(int n) { return int(next() % uint64_t(n)); }
};

// A recorded quiet position awaiting the game's final result.
struct Sample { std::string fen; int whiteCp; };

constexpr int OPENING_PLIES = 8;    // random plies for opening diversity
constexpr int MAX_PLIES     = 320;  // hard game-length cap
constexpr int ADJ_CP        = 2000; // |white eval| for decisive adjudication
constexpr int ADJ_COUNT     = 6;    // consecutive plies before adjudicating

} // namespace

void datagen_run(const std::string& outPath, int numGames, int nodes, uint64_t seed) {
    if (nodes <= 0) nodes = 5000;
    RNG rng(seed ? seed : 0x9E3779B97F4A7C15ULL);

    std::ofstream out(outPath, std::ios::out | std::ios::trunc);
    if (!out) { std::cerr << "datagen: cannot open " << outPath << "\n"; return; }

    TT.resize(16);

    // Redirect the engine's per-search UCI output into a throwaway sink; progress
    // goes to stderr so it stays visible.
    std::streambuf* coutBuf = std::cout.rdbuf();
    std::ostringstream sink;

    // One StateInfo per applied move for the whole game (do_move chains pointers).
    std::vector<StateInfo> st(OPENING_PLIES + MAX_PLIES + 8);

    int64_t totalPositions = 0;
    int completed = 0;

    for (int g = 0; g < numGames; ++g) {
        Position pos;
        int si = 0; // running StateInfo index for this game

        // Randomised opening; retry if it dead-ends into a terminal position.
        bool opened = false;
        for (int attempt = 0; attempt < 20 && !opened; ++attempt) {
            pos.set(StartFEN, &st[0]);
            si = 1;
            bool bad = false;
            for (int i = 0; i < OPENING_PLIES; ++i) {
                MoveList ml(pos);
                if (ml.size() == 0) { bad = true; break; }
                Move m = ml.list[rng.below(int(ml.size()))].move;
                pos.do_move(m, st[si++]);
            }
            if (!bad && MoveList(pos).size() > 0)
                opened = true;
        }
        if (!opened) continue;

        TT.clear();
        Search::clear();

        std::vector<Sample> samples;
        std::unordered_map<uint64_t, int> seen; // in-game repetition counter
        double result = 0.5;  // white POV; default draw (used if ply cap hit)
        int winStreak = 0, lossStreak = 0;

        for (int ply = 0; ply < MAX_PLIES; ++ply) {
            MoveList ml(pos);
            if (ml.size() == 0) {                         // checkmate or stalemate
                if (pos.checkers())
                    result = (pos.side_to_move() == WHITE) ? 0.0 : 1.0;
                else
                    result = 0.5;
                break;
            }
            if (pos.rule50_count() >= 100) { result = 0.5; break; }   // 50-move
            if (++seen[pos.key()] >= 3)    { result = 0.5; break; }   // 3-fold

            Limits lim; lim.nodes = nodes;
            std::cout.rdbuf(sink.rdbuf());
            Search::think(pos, lim);
            std::cout.rdbuf(coutBuf);
            sink.str(std::string());

            Move  best  = Search::best_move();
            Value score = Search::best_value();  // side-to-move POV
            if (best == MOVE_NONE) { result = 0.5; break; }

            int whiteEval = (pos.side_to_move() == WHITE) ? int(score) : -int(score);

            // Record quiet, non-check, non-mate positions only (NNUE wants
            // static-eval-friendly positions; tactical ones add label noise).
            // Bare kings are skipped: bullet-utils flags them as invalid
            // ("no non-king pieces"), and they carry no learnable signal.
            if (!pos.checkers() && !pos.capture(best)
                && type_of_move(best) != PROMOTION && !is_mate_score(score)
                && popcount(pos.pieces()) > 2) {
                int cp = whiteEval < -ADJ_CP ? -ADJ_CP : whiteEval > ADJ_CP ? ADJ_CP : whiteEval;
                samples.push_back({ pos.fen(), cp });
            }

            // Decisive-eval adjudication to keep games short.
            winStreak  = whiteEval >=  ADJ_CP ? winStreak  + 1 : 0;
            lossStreak = whiteEval <= -ADJ_CP ? lossStreak + 1 : 0;
            if (winStreak  >= ADJ_COUNT) { result = 1.0; break; }
            if (lossStreak >= ADJ_COUNT) { result = 0.0; break; }

            pos.do_move(best, st[si++]);
            if (si >= int(st.size())) { result = 0.5; break; } // safety
        }

        // Backfill the game result into every recorded sample and flush.
        const char* r = result == 1.0 ? "1.0" : result == 0.0 ? "0.0" : "0.5";
        for (const Sample& s : samples)
            out << s.fen << " | " << s.whiteCp << " | " << r << '\n';
        totalPositions += int(samples.size());
        ++completed;

        if ((g + 1) % 32 == 0) {
            out.flush();
            std::fprintf(stderr, "\rgames %d/%d  positions %lld",
                         g + 1, numGames, (long long)totalPositions);
            std::fflush(stderr);
        }
    }

    out.flush();
    std::fprintf(stderr, "\ndatagen done: %d games, %lld positions -> %s\n",
                 completed, (long long)totalPositions, outPath.c_str());
}
