package core

import (
	"testing"
)

func TestInitialPositionEnglish(t *testing.T) {
	board := InitialBoard()
	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 7 {
		t.Errorf("expected 7 moves, got %d", moves.Len())
	}
	for _, m := range moves.Slice() {
		if IsCapture(m) {
			t.Error("initial position should have no captures")
		}
	}
}

func TestMandatoryCaptureEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(2, 2)] = WhitePawn
	board[RowColToSquare(2, 6)] = WhitePawn
	board[RowColToSquare(3, 3)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if !IsCapture(m) {
		t.Error("expected capture move")
	}
	if m.From != RowColToSquare(2, 2) {
		t.Errorf("expected from (2,2), got %d", m.From)
	}
	if m.To != RowColToSquare(4, 4) {
		t.Errorf("expected to (4,4), got %d", m.To)
	}
	if m.NumCaptured != 1 {
		t.Errorf("expected 1 capture, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(3, 3) {
		t.Errorf("expected captured (3,3), got %d", m.Captured[0])
	}
}

func TestMultiJumpChainEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(2, 2)] = WhitePawn
	board[RowColToSquare(3, 3)] = BlackPawn
	board[RowColToSquare(5, 5)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.From != RowColToSquare(2, 2) {
		t.Errorf("expected from (2,2), got %d", m.From)
	}
	if m.To != RowColToSquare(6, 6) {
		t.Errorf("expected to (6,6), got %d", m.To)
	}
	if m.NumCaptured != 2 {
		t.Errorf("expected 2 captures, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(3, 3) {
		t.Errorf("expected captured[0] (3,3), got %d", m.Captured[0])
	}
	if m.Captured[1] != RowColToSquare(5, 5) {
		t.Errorf("expected captured[1] (5,5), got %d", m.Captured[1])
	}
}

func TestPromotionEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(6, 6)] = WhitePawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 2 {
		t.Errorf("expected 2 moves, got %d", moves.Len())
	}

	m := moves.Slice()[0]
	ApplyMove(&board, m)
	if board[m.To] != WhiteKing {
		t.Errorf("expected WhiteKing at to, got %v", board[m.To])
	}
	if board[m.From] != Empty {
		t.Errorf("expected Empty at from, got %v", board[m.From])
	}
}

func TestKingMovesBackwardEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 4 {
		t.Errorf("expected 4 moves, got %d", moves.Len())
	}
	foundBackward := false
	for _, m := range moves.Slice() {
		if m.To == RowColToSquare(3, 3) {
			foundBackward = true
		}
	}
	if !foundBackward {
		t.Error("expected backward move to (3,3)")
	}
}

func TestApplyMoveRemovesCapturedAndPromotes(t *testing.T) {
	var board Board32
	board[RowColToSquare(2, 2)] = WhitePawn
	board[RowColToSquare(3, 3)] = BlackPawn
	board[RowColToSquare(5, 5)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	ApplyMove(&board, m)
	if board[RowColToSquare(2, 2)] != Empty {
		t.Error("from should be empty")
	}
	if board[RowColToSquare(3, 3)] != Empty {
		t.Error("captured (3,3) should be empty")
	}
	if board[RowColToSquare(5, 5)] != Empty {
		t.Error("captured (5,5) should be empty")
	}
	if board[RowColToSquare(6, 6)] != WhitePawn {
		t.Errorf("expected WhitePawn at (6,6), got %v", board[RowColToSquare(6, 6)])
	}
}

func TestIsLegalMoveEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(2, 2)] = WhitePawn
	board[RowColToSquare(3, 3)] = BlackPawn

	// Legal capture
	legal := Move{
		From:        RowColToSquare(2, 2),
		To:          RowColToSquare(4, 4),
		Captured:    [12]uint8{RowColToSquare(3, 3)},
		NumCaptured: 1,
	}
	if !IsLegalMove(board, White, legal, English) {
		t.Error("legal move should be accepted")
	}

	// Wrong turn
	if IsLegalMove(board, Black, legal, English) {
		t.Error("wrong turn should be rejected")
	}

	// Non-diagonal move
	nonDiag := Move{
		From:        RowColToSquare(2, 2),
		To:          RowColToSquare(2, 4),
		Captured:    [12]uint8{},
		NumCaptured: 0,
	}
	if IsLegalMove(board, White, nonDiag, English) {
		t.Error("non-diagonal move should be rejected")
	}

	// Jumping own piece
	board[RowColToSquare(3, 3)] = WhitePawn
	ownJump := Move{
		From:        RowColToSquare(2, 2),
		To:          RowColToSquare(4, 4),
		Captured:    [12]uint8{RowColToSquare(3, 3)},
		NumCaptured: 1,
	}
	if IsLegalMove(board, White, ownJump, English) {
		t.Error("jumping own piece should be rejected")
	}
}

func TestPawnDoesNotCaptureBackward(t *testing.T) {
	var board Board32
	board[RowColToSquare(3, 3)] = WhitePawn
	board[RowColToSquare(2, 2)] = BlackPawn

	var english MoveList
	GenerateMoves(board, White, &english, English)
	if english.Len() != 2 {
		t.Errorf("english: expected 2 moves, got %d", english.Len())
	}
	for _, m := range english.Slice() {
		if IsCapture(m) {
			t.Error("english: pawn should not capture backward")
		}
		if SquareToRowCol(m.To).Row <= 3 {
			t.Errorf("english: pawn should move forward only, got row %d", SquareToRowCol(m.To).Row)
		}
	}

	var spanish MoveList
	GenerateMoves(board, White, &spanish, Spanish)
	if spanish.Len() != 2 {
		t.Errorf("spanish: expected 2 moves, got %d", spanish.Len())
	}
	for _, m := range spanish.Slice() {
		if IsCapture(m) {
			t.Error("spanish: pawn should not capture backward")
		}
		if SquareToRowCol(m.To).Row <= 3 {
			t.Errorf("spanish: pawn should move forward only, got row %d", SquareToRowCol(m.To).Row)
		}
	}
}

func TestBlackPawnDoesNotCaptureBackward(t *testing.T) {
	var board Board32
	board[RowColToSquare(3, 3)] = BlackPawn
	board[RowColToSquare(4, 4)] = WhitePawn

	var moves MoveList
	GenerateMoves(board, Black, &moves, English)
	if moves.Len() != 2 {
		t.Errorf("expected 2 moves, got %d", moves.Len())
	}
	for _, m := range moves.Slice() {
		if IsCapture(m) {
			t.Error("black pawn should not capture backward")
		}
		if SquareToRowCol(m.To).Row != 2 {
			t.Errorf("black pawn should move to row 2, got %d", SquareToRowCol(m.To).Row)
		}
	}
}

func TestKingCapturesBackwardEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(3, 3)] = WhiteKing
	board[RowColToSquare(2, 2)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 1 {
		t.Errorf("expected 1 capture move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if !IsCapture(m) {
		t.Error("expected capture")
	}
	if m.To != RowColToSquare(1, 1) {
		t.Errorf("expected to (1,1), got %d", m.To)
	}
	if m.Captured[0] != RowColToSquare(2, 2) {
		t.Errorf("expected captured (2,2), got %d", m.Captured[0])
	}
}

func TestPawnInChainCapturesForwardOnlyEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(3, 3)] = WhitePawn
	board[RowColToSquare(4, 4)] = BlackPawn
	board[RowColToSquare(4, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.To != RowColToSquare(5, 5) {
		t.Errorf("expected to (5,5), got %d", m.To)
	}
	if m.NumCaptured != 1 {
		t.Errorf("expected 1 capture, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(4, 4) {
		t.Errorf("expected captured (4,4), got %d", m.Captured[0])
	}
}

// Spanish variant tests

func TestSpanishFlyingKingQuietMoves(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	// Four diagonals from (4,4): 4 + 3 + 3 + 3 = 13 free squares
	if moves.Len() != 13 {
		t.Errorf("expected 13 moves, got %d", moves.Len())
	}
	has00 := false
	has77 := false
	for _, m := range moves.Slice() {
		if IsCapture(m) {
			t.Error("expected no captures")
		}
		if m.To == RowColToSquare(0, 0) {
			has00 = true
		}
		if m.To == RowColToSquare(7, 7) {
			has77 = true
		}
	}
	if !has00 {
		t.Error("expected move to (0,0)")
	}
	if !has77 {
		t.Error("expected move to (7,7)")
	}
}

func TestSpanishFlyingKingCaptures(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing
	board[RowColToSquare(6, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if !IsCapture(m) {
		t.Error("expected capture")
	}
	if m.To != RowColToSquare(7, 7) {
		t.Errorf("expected to (7,7), got %d", m.To)
	}
	if m.NumCaptured != 1 {
		t.Errorf("expected 1 capture, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(6, 6) {
		t.Errorf("expected captured (6,6), got %d", m.Captured[0])
	}
}

func TestSpanishFlyingKingAnyLandingSquare(t *testing.T) {
	var board Board32
	board[RowColToSquare(1, 1)] = WhiteKing
	board[RowColToSquare(3, 3)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 4 {
		t.Errorf("expected 4 moves, got %d", moves.Len())
	}
	expected := []uint8{
		RowColToSquare(4, 4),
		RowColToSquare(5, 5),
		RowColToSquare(6, 6),
		RowColToSquare(7, 7),
	}
	for _, m := range moves.Slice() {
		if !IsCapture(m) {
			t.Error("expected capture")
		}
		if m.Captured[0] != RowColToSquare(3, 3) {
			t.Errorf("expected captured (3,3), got %d", m.Captured[0])
		}
		found := false
		for _, e := range expected {
			if m.To == e {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("unexpected landing square %d", m.To)
		}
	}
}

func TestSpanishFlyingKingMultiCapture(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing
	board[RowColToSquare(3, 3)] = BlackPawn
	board[RowColToSquare(1, 1)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.To != RowColToSquare(0, 0) {
		t.Errorf("expected to (0,0), got %d", m.To)
	}
	if m.NumCaptured != 2 {
		t.Errorf("expected 2 captures, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(3, 3) {
		t.Errorf("expected captured[0] (3,3), got %d", m.Captured[0])
	}
	if m.Captured[1] != RowColToSquare(1, 1) {
		t.Errorf("expected captured[1] (1,1), got %d", m.Captured[1])
	}
}

func TestSpanishLeyDeLaCantidad(t *testing.T) {
	var board Board32
	// Single capture: (0,0) -> (2,2) over (1,1)
	board[RowColToSquare(0, 0)] = WhitePawn
	board[RowColToSquare(1, 1)] = BlackPawn
	// Double capture: (1,3) -> (5,7) over (2,4), (4,6)
	board[RowColToSquare(1, 3)] = WhitePawn
	board[RowColToSquare(2, 4)] = BlackPawn
	board[RowColToSquare(4, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.From != RowColToSquare(1, 3) {
		t.Errorf("expected from (1,3), got %d", m.From)
	}
	if m.To != RowColToSquare(5, 7) {
		t.Errorf("expected to (5,7), got %d", m.To)
	}
	if m.NumCaptured != 2 {
		t.Errorf("expected 2 captures, got %d", m.NumCaptured)
	}
}

func TestSpanishLeyDeLaCalidad(t *testing.T) {
	var board Board32
	// Chain with a king: (0,0) -> (4,4) over king (1,1), pawn (3,3)
	board[RowColToSquare(0, 0)] = WhitePawn
	board[RowColToSquare(1, 1)] = BlackKing
	board[RowColToSquare(3, 3)] = BlackPawn
	// Chain of two pawns: (1,3) -> (5,7)
	board[RowColToSquare(1, 3)] = WhitePawn
	board[RowColToSquare(2, 4)] = BlackPawn
	board[RowColToSquare(4, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.From != RowColToSquare(0, 0) {
		t.Errorf("expected from (0,0), got %d", m.From)
	}
	if m.To != RowColToSquare(4, 4) {
		t.Errorf("expected to (4,4), got %d", m.To)
	}
	if m.NumCaptured != 2 {
		t.Errorf("expected 2 captures, got %d", m.NumCaptured)
	}
}

func TestSpanishLeyDeLaCantidadOutranksQuality(t *testing.T) {
	var board Board32
	// Chain of one king: (0,0) -> (2,2) over king (1,1)
	board[RowColToSquare(0, 0)] = WhitePawn
	board[RowColToSquare(1, 1)] = BlackKing
	// Chain of two pawns: (1,3) -> (5,7)
	board[RowColToSquare(1, 3)] = WhitePawn
	board[RowColToSquare(2, 4)] = BlackPawn
	board[RowColToSquare(4, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.From != RowColToSquare(1, 3) {
		t.Errorf("expected from (1,3), got %d", m.From)
	}
	if m.NumCaptured != 2 {
		t.Errorf("expected 2 captures, got %d", m.NumCaptured)
	}
}

func TestSpanishOwnPieceBlocksSlide(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing
	board[RowColToSquare(5, 5)] = WhitePawn
	board[RowColToSquare(6, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if !IsCapture(m) {
		t.Error("expected capture")
	}
	if m.From != RowColToSquare(5, 5) {
		t.Errorf("expected from (5,5), got %d", m.From)
	}
	if m.To != RowColToSquare(7, 7) {
		t.Errorf("expected to (7,7), got %d", m.To)
	}
	if m.Captured[0] != RowColToSquare(6, 6) {
		t.Errorf("expected captured (6,6), got %d", m.Captured[0])
	}
	if m.From == RowColToSquare(4, 4) {
		t.Error("king at (4,4) should not generate capture (blocked by own pawn)")
	}
}

func TestSpanishOwnPieceBlocksLanding(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing
	board[RowColToSquare(5, 5)] = BlackPawn
	board[RowColToSquare(6, 6)] = WhitePawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 12 {
		t.Errorf("expected 12 moves, got %d", moves.Len())
	}
	kingQuiet := 0
	for _, m := range moves.Slice() {
		if IsCapture(m) {
			t.Error("expected no captures")
		}
		if m.From == RowColToSquare(4, 4) {
			kingQuiet++
		}
	}
	// King slides to every free square on four diagonals: 3 + 4 + 3 = 10
	if kingQuiet != 10 {
		t.Errorf("expected 10 king quiet moves, got %d", kingQuiet)
	}
}

func TestSpanishFlyingKingContinuesAfterLanding(t *testing.T) {
	var board Board32
	board[RowColToSquare(3, 3)] = WhiteKing
	board[RowColToSquare(4, 4)] = BlackPawn
	board[RowColToSquare(6, 4)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.To != RowColToSquare(7, 3) {
		t.Errorf("expected to (7,3), got %d", m.To)
	}
	if m.NumCaptured != 2 {
		t.Errorf("expected 2 captures, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(4, 4) {
		t.Errorf("expected captured[0] (4,4), got %d", m.Captured[0])
	}
	if m.Captured[1] != RowColToSquare(6, 4) {
		t.Errorf("expected captured[1] (6,4), got %d", m.Captured[1])
	}
}

func TestSpanishChainNeverReLandsOnOrigin(t *testing.T) {
	var board Board32
	board[RowColToSquare(4, 4)] = WhiteKing
	board[RowColToSquare(3, 3)] = BlackPawn
	board[RowColToSquare(6, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 4 {
		t.Errorf("expected 4 moves, got %d", moves.Len())
	}
	endsOn77 := false
	for _, m := range moves.Slice() {
		if m.NumCaptured != 2 {
			t.Errorf("expected 2 captures, got %d", m.NumCaptured)
		}
		if m.To == RowColToSquare(4, 4) {
			t.Error("no chain should end on origin (4,4)")
		}
		if m.To == RowColToSquare(7, 7) {
			endsOn77 = true
		}
	}
	if !endsOn77 {
		t.Error("at least one chain should end on (7,7)")
	}
}

func TestPromotionEndsChainEnglish(t *testing.T) {
	var board Board32
	board[RowColToSquare(5, 3)] = WhitePawn
	board[RowColToSquare(6, 4)] = BlackPawn
	board[RowColToSquare(6, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, English)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.To != RowColToSquare(7, 5) {
		t.Errorf("expected to (7,5), got %d", m.To)
	}
	if m.NumCaptured != 1 {
		t.Errorf("expected 1 capture, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(6, 4) {
		t.Errorf("expected captured (6,4), got %d", m.Captured[0])
	}
}

func TestSpanishPawnInChainCapturesForwardOnly(t *testing.T) {
	var board Board32
	board[RowColToSquare(3, 3)] = WhitePawn
	board[RowColToSquare(4, 4)] = BlackPawn
	board[RowColToSquare(4, 6)] = BlackPawn

	var moves MoveList
	GenerateMoves(board, White, &moves, Spanish)
	if moves.Len() != 1 {
		t.Errorf("expected 1 move, got %d", moves.Len())
	}
	m := moves.Slice()[0]
	if m.To != RowColToSquare(5, 5) {
		t.Errorf("expected to (5,5), got %d", m.To)
	}
	if m.NumCaptured != 1 {
		t.Errorf("expected 1 capture, got %d", m.NumCaptured)
	}
	if m.Captured[0] != RowColToSquare(4, 4) {
		t.Errorf("expected captured (4,4), got %d", m.Captured[0])
	}
}

func TestHasAnyMove(t *testing.T) {
	board := InitialBoard()
	if !HasAnyMove(board, White, English) {
		t.Error("white should have moves in initial position")
	}
	if !HasAnyMove(board, Black, English) {
		t.Error("black should have moves in initial position")
	}

	// Empty board
	var empty Board32
	if HasAnyMove(empty, White, English) {
		t.Error("empty board should have no moves")
	}
}