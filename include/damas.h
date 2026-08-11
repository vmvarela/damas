#ifndef DAMAS_H
#define DAMAS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dz_game dz_game;

/* A complete move. For a multi-jump chain, `from` is the starting square,
   `to` the final landing square, and `captured` lists the squares of the
   captured pieces in order. Non-capture moves have num_captured == 0. */
typedef struct dz_move {
    uint8_t from;
    uint8_t to;
    uint8_t captured[12];
    uint8_t num_captured;
} dz_move;

dz_game *dz_game_new(void);
void dz_game_free(dz_game *game);

/* Piece codes: 0 empty, 1 white_pawn, 2 white_king, 3 black_pawn, 4 black_king. */
void dz_game_board(const dz_game *game, uint8_t out[32]);
/* 0 = white, 1 = black. */
uint8_t dz_game_turn(const dz_game *game);

/* Writes up to `cap` legal moves for the side to move; returns the count. */
size_t dz_game_moves(const dz_game *game, dz_move *out, size_t cap);

/* Applies a move. Returns false if illegal (board and turn unchanged).
   `captured` may be NULL when num_captured == 0. */
bool dz_game_apply(dz_game *game, uint8_t from, uint8_t to,
                   const uint8_t *captured, uint8_t num_captured);

/* Runs the minimax engine for time_limit_ms and writes the best move.
   Returns false if the position has no legal moves.
   NOTE: not thread-safe — serialize concurrent calls to dz_game_best_move
   (single global zobrist seed). */
bool dz_game_best_move(const dz_game *game, uint32_t time_limit_ms, dz_move *out);

bool dz_game_over(const dz_game *game);
/* -1 = not over, 0 = white, 1 = black. */
int8_t dz_game_winner(const dz_game *game);

#ifdef __cplusplus
}
#endif

#endif /* DAMAS_H */