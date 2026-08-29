package core

// Move represents a complete move.
// For multi-jump chains, From is the starting square, To is the final landing square,
// and Captured lists the squares of captured pieces in order.
// Non-capture moves have NumCaptured == 0.
type Move struct {
	From        uint8
	To          uint8
	Captured    [12]uint8
	NumCaptured uint8
}

// MoveList is a fixed-capacity list of moves (no allocator).
// Capacity 256 covers every legal move in any position.
type MoveList struct {
	items [256]Move
	len   int
}

// Add appends a move. Returns false if the list is full.
func (ml *MoveList) Add(m Move) bool {
	if ml.len >= len(ml.items) {
		return false
	}
	ml.items[ml.len] = m
	ml.len++
	return true
}

// Clear resets the list length to 0.
func (ml *MoveList) Clear() {
	ml.len = 0
}

// Len returns the number of moves in the list.
func (ml *MoveList) Len() int {
	return ml.len
}

// Slice returns a read-only slice of the moves.
func (ml *MoveList) Slice() []Move {
	return ml.items[:ml.len]
}

// MutSlice returns a mutable slice of the moves (used for move ordering).
func (ml *MoveList) MutSlice() []Move {
	return ml.items[:ml.len]
}

// IsCapture returns true if the move captures at least one piece.
func IsCapture(m Move) bool {
	return m.NumCaptured > 0
}