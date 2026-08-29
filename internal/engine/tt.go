package engine

import (
	"github.com/vmvarela/damas/internal/core"
)

// TTFlag represents the type of transposition table entry.
type TTFlag uint8

const (
	Exact      TTFlag = iota
	LowerBound
	UpperBound
)

// TTEntry is a single transposition table entry.
type TTEntry struct {
	Key   uint64
	Depth uint8
	Score int32
	Flag  TTFlag
	Move  core.Move
}

// TranspositionTable is a fixed-size hash table with overwrite replacement.
type TranspositionTable struct {
	entries []TTEntry
}

// NewTranspositionTable creates a new transposition table.
// size must be a power of two.
func NewTranspositionTable(size int) *TranspositionTable {
	if size&(size-1) != 0 {
		panic("TranspositionTable size must be a power of two")
	}
	return &TranspositionTable{
		entries: make([]TTEntry, size),
	}
}

// Close frees the transposition table resources.
func (tt *TranspositionTable) Close() {
	tt.entries = nil
}

// Get returns the entry for key, or nil if absent.
func (tt *TranspositionTable) Get(key uint64) *TTEntry {
	if key == 0 {
		return nil // 0 is the empty marker
	}
	idx := int(key) & (len(tt.entries) - 1)
	e := tt.entries[idx]
	if e.Key == key {
		return &e
	}
	return nil
}

// Put stores an entry in the table (overwrite replacement).
func (tt *TranspositionTable) Put(e TTEntry) {
	idx := int(e.Key) & (len(tt.entries) - 1)
	tt.entries[idx] = e
}

// Clear zeros the table.
func (tt *TranspositionTable) Clear() {
	for i := range tt.entries {
		tt.entries[i] = TTEntry{}
	}
}