package core

import (
	"testing"
)

func TestHashIsDeterministic(t *testing.T) {
	board := InitialBoard()
	h1 := Hash(board, White)
	h2 := Hash(board, White)
	if h1 != h2 {
		t.Errorf("hash not deterministic: %d != %d", h1, h2)
	}
}

func TestHashNeverReturnsZero(t *testing.T) {
	empty := Board32{}
	h1 := Hash(empty, White)
	h2 := Hash(empty, Black)
	if h1 == 0 {
		t.Error("hash(empty, White) should not be zero")
	}
	if h2 == 0 {
		t.Error("hash(empty, Black) should not be zero")
	}
}

func TestDifferentPositionsHashDifferently(t *testing.T) {
	b1 := InitialBoard()
	var b2 Board32
	copy(b2[:], b1[:])
	b2[RowColToSquare(2, 0)] = Empty // remove a white pawn

	h1 := Hash(b1, White)
	h2 := Hash(b2, White)
	h3 := Hash(b1, Black)

	if h1 == h2 {
		t.Error("different positions should hash differently")
	}
	if h1 == h3 {
		t.Error("different turn should hash differently")
	}
}