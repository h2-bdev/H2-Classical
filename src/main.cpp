#include "bitboard.h"
#include "magic.h"
#include "zobrist.h"
#include "search.h"
#include "perft.h"
#include "bench.h"
#include "uci.h"
#include "nnue/nnue.h"
#include "datagen.h"

#include <cstdlib>
#include <cstring>

static void engine_init() {
    BB::init();       // geometry + non-slider attacks (fills SquareDistance)
    Magic::init();    // slider magics (needs SquareDistance)
    Zobrist::init();
    Search::init();
    NNUE::init();     // load the embedded default net (HCE fallback if it fails)
}

int main(int argc, char* argv[]) {
    engine_init();

    if (argc > 1 && std::strcmp(argv[1], "perft") == 0)
        return perft_suite() ? 0 : 1;

    // datagen <out.txt> <games> <nodesPerMove> <seed> — self-play NNUE data.
    // Single-threaded by design; tools/gen_data.sh fans out one proc per core.
    if (argc > 1 && std::strcmp(argv[1], "datagen") == 0) {
        std::string out   = argc > 2 ? argv[2] : "data.txt";
        int         games = argc > 3 ? std::atoi(argv[3]) : 1000;
        int         nodes = argc > 4 ? std::atoi(argv[4]) : 5000;
        uint64_t    seed  = argc > 5 ? std::strtoull(argv[5], nullptr, 10) : 0;
        datagen_run(out, games, nodes, seed);
        return 0;
    }

    if (argc > 1 && std::strcmp(argv[1], "bench") == 0) {
        bench_run(argc > 2 ? std::atoi(argv[2]) : 13);
        return 0;
    }

    uci_loop();
    return 0;
}
