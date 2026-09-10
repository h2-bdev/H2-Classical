#pragma once
// Time allocation with a soft/hard split.

#include "types.h"
#include <chrono>
#include <cstdint>

struct Limits {
    int64_t time[COLOR_NB] = { 0, 0 }; // wtime, btime (ms)
    int64_t inc[COLOR_NB]  = { 0, 0 };
    int64_t movetime = 0;
    int     movestogo = 0;
    int     depth = 0;
    int64_t nodes = 0;
    int64_t moveOverhead = 100;
    bool    infinite = false;
    bool    useTimeManager = false; // true iff a game clock was given

    // `go searchmoves <m1> <m2> ...`: restrict the root to these moves only
    // (empty = no restriction). Populated by the UCI layer, which has the
    // Position needed to parse move strings.
    Move searchMoves[MAX_MOVES];
    int  searchMovesCount = 0;

    // True for `go ponder`: search the predicted position on the opponent's
    // clock. The search runs unlimited while `Search::pondering` is set, and
    // `ponderhit` clears that flag to start the real budget (see
    // SearchWorker::ponder_wait). Do NOT fold this into `infinite` — that was
    // the old behaviour, and because no `ponderhit` handler existed the search
    // stayed untimed forever and the engine lost on time in a real game.
    bool ponder = false;
};

class TimeManager {
public:
    void init(const Limits& limits, Color us);
    void start() { startTime = now(); }

    // Move the clock's origin forward to `t`, used at `ponderhit`: the budget
    // computed at `go ponder` is still valid (our clock did not run while the
    // opponent thought), so it should be spent from the ponderhit instant
    // rather than from the start of the ponder. Never moves the origin
    // backwards, so a `ponderhit` racing ahead of `start()` can only leave the
    // normal budget intact, never grant more than a fresh search would get.
    void rebase(int64_t t) { if (t > startTime) startTime = t; }

    int64_t elapsed() const { return now() - startTime; }
    int64_t soft_ms() const { return optimumMs; }
    int64_t hard_ms() const { return maximumMs; }

    void extend_soft(double factor) {
        optimumMs = int64_t(optimumMs * factor);
        if (optimumMs > maximumMs * 4 / 5)
            optimumMs = maximumMs * 4 / 5;
    }

    static int64_t now() {
        using namespace std::chrono;
        return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
    }

private:
    int64_t startTime = 0;
    int64_t optimumMs = 0;
    int64_t maximumMs = 0;
};
