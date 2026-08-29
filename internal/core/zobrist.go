package core

import (
	"math/rand/v2"
)

// Zobrist hashing for board positions.
// The [32][5]uint64 table plus the turn hash are generated at init from a
// fixed seed — deterministic (tests and search are reproducible) and
// immutable, so concurrent searches never race on shared state.
const zobristSeed = 0x9E3779B97F4A7C15

var (
	zobristTable [32][5]uint64
	zobristTurn  uint64
)

func init() {
	r := rand.New(rand.NewPCG(zobristSeed, 0))
	for sq := 0; sq < 32; sq++ {
		for pt := 0; pt < 5; pt++ {
			zobristTable[sq][pt] = r.Uint64()
		}
	}
	zobristTurn = r.Uint64()
}

// Hash returns the Zobrist hash of a position.
// XORs piece entries plus the turn hash if black to move.
// Key 0 is reserved as the TT empty-slot marker; never return 0.
func Hash(board Board32, turn Color) uint64 {
	var h uint64
	for sq := 0; sq < 32; sq++ {
		p := board[sq]
		if p != Empty {
			h ^= zobristTable[sq][p]
		}
	}
	if turn == Black {
		h ^= zobristTurn
	}
	if h == 0 {
		h = 1 // TT empty marker
	}
	return h
}