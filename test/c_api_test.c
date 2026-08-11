#include "damas.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    dz_game *g = dz_game_new();
    assert(g != NULL);

    assert(dz_game_turn(g) == 0); /* white to move */

    uint8_t board[32];
    dz_game_board(g, board);
    int pawns = 0;
    for (int i = 0; i < 32; i++)
        if (board[i] == 1) pawns++;
    assert(pawns == 12);

    dz_move moves[64];
    size_t n = dz_game_moves(g, moves, 64);
    assert(n == 7); /* opening position: 7 legal non-capture moves */

    /* apply a legal opening move */
    assert(dz_game_apply(g, moves[0].from, moves[0].to,
                         moves[0].captured, moves[0].num_captured));
    assert(dz_game_turn(g) == 1);

    /* illegal move rejected, turn unchanged */
    assert(!dz_game_apply(g, 0, 0, NULL, 0));
    assert(dz_game_turn(g) == 1);

    /* engine finds a move */
    dz_move best;
    assert(dz_game_best_move(g, 100, &best));
    assert(best.from != best.to);

    assert(!dz_game_over(g));
    assert(dz_game_winner(g) == -1);

    dz_game_free(g);
    printf("c_api_test: all assertions passed\n");
    return 0;
}