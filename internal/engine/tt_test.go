package engine

import (
	"testing"

	"github.com/vmvarela/damas/internal/core"
)

func TestTTPutGet(t *testing.T) {
	tt := NewTranspositionTable(1 << 8)
	defer tt.Close()

	e := TTEntry{
		Key:   42,
		Depth: 5,
		Score: 123,
		Flag:  Exact,
		Move: core.Move{From: 1, To: 2, Captured: [12]uint8{}, NumCaptured: 0},
	}
	tt.Put(e)

	got := tt.Get(42)
	if got == nil {
		t.Error("expected entry, got nil")
	}
	if got.Depth != 5 {
		t.Errorf("expected depth 5, got %d", got.Depth)
	}
	if got.Score != 123 {
		t.Errorf("expected score 123, got %d", got.Score)
	}
	if got.Flag != Exact {
		t.Errorf("expected flag Exact, got %v", got.Flag)
	}
	if got.Move.From != 1 {
		t.Errorf("expected move from 1, got %d", got.Move.From)
	}
}

func TestTTCollision(t *testing.T) {
	tt := NewTranspositionTable(1 << 8)
	defer tt.Close()

	tt.Put(TTEntry{
		Key:   42,
		Depth: 1,
		Score: 1,
		Flag:  Exact,
		Move:  core.Move{From: 1, To: 2},
	})
	// 298 & 255 == 42 & 255, but keys differ
	if tt.Get(298) != nil {
		t.Error("collision: different key at same index should not be returned")
	}
}

func TestTTClear(t *testing.T) {
	tt := NewTranspositionTable(1 << 8)
	defer tt.Close()

	tt.Put(TTEntry{
		Key:   7,
		Depth: 1,
		Score: 1,
		Flag:  Exact,
		Move:  core.Move{From: 1, To: 2},
	})
	tt.Clear()
	if tt.Get(7) != nil {
		t.Error("clear should empty the table")
	}
}