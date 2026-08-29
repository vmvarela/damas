package core

import (
	"testing"
)

func TestInitDeinitAndInitialState(t *testing.T) {
	game := Init()
	defer game.Deinit()

	if game.Turn != White {
		t.Errorf("expected White turn, got %v", game.Turn)
	}
	var moves MoveList
	game.GenerateMoves(&moves)
	if moves.Len() != 7 {
		t.Errorf("expected 7 moves, got %d", moves.Len())
	}
}

func TestApplyMoveFlipsTurnAndRejectsIllegal(t *testing.T) {
	game := Init()
	defer game.Deinit()

	// Legal opening move: (2,0) -> (3,1)
	legal := Move{
		From:        RowColToSquare(2, 0),
		To:          RowColToSquare(3, 1),
		Captured:    [12]uint8{},
		NumCaptured: 0,
	}
	if !game.ApplyMove(legal) {
		t.Error("legal move should be accepted")
	}
	if game.Turn != Black {
		t.Errorf("expected Black turn after move, got %v", game.Turn)
	}

	// Illegal move (white's pawn, black's turn): rejected, turn unchanged
	illegal := Move{
		From:        RowColToSquare(2, 2),
		To:          RowColToSquare(3, 3),
		Captured:    [12]uint8{},
		NumCaptured: 0,
	}
	if game.ApplyMove(illegal) {
		t.Error("illegal move should be rejected")
	}
	if game.Turn != Black {
		t.Errorf("turn should remain Black after illegal move, got %v", game.Turn)
	}
}

func TestInitRulesSelectsVariant(t *testing.T) {
	game := InitRules(Spanish)
	defer game.Deinit()

	if game.Rules != Spanish {
		t.Errorf("expected Spanish variant, got %v", game.Rules)
	}
	var moves MoveList
	game.GenerateMoves(&moves)
	if moves.Len() != 7 {
		t.Errorf("expected 7 moves, got %d", moves.Len())
	}
}

func TestGameOverDetectionAndWinner(t *testing.T) {
	game := Init()
	defer game.Deinit()

	// White pawn at (0,0) fully blocked: no moves for white
	game.Board = [32]Piece{}
	game.Board[RowColToSquare(0, 0)] = WhitePawn
	game.Board[RowColToSquare(1, 1)] = BlackPawn
	game.Board[RowColToSquare(2, 0)] = BlackPawn
	game.Board[RowColToSquare(2, 2)] = BlackPawn
	game.Turn = White

	if !game.IsGameOver() {
		t.Error("game should be over (white has no moves)")
	}
	// Stalemated side doesn't lose: the game is a draw
	if game.Winner() != nil {
		t.Errorf("stalemate should be draw, got winner %v", game.Winner())
	}

	// No pieces left for white
	game.Board = [32]Piece{}
	game.Board[RowColToSquare(7, 7)] = BlackPawn
	game.Turn = White

	if !game.IsGameOver() {
		t.Error("game should be over (white has no pieces)")
	}
	if game.Winner() == nil || *game.Winner() != Black {
		t.Errorf("expected Black winner, got %v", game.Winner())
	}
}

func TestRepetitionDraw(t *testing.T) {
	game := InitRules(English)
	defer game.Deinit()

	game.Board = [32]Piece{}
	game.Board[RowColToSquare(4, 2)] = WhiteKing
	game.Board[RowColToSquare(4, 6)] = BlackKing
	game.Turn = White
	game.HalfmoveClock = 0
	game.RecordPosition()

	shuffleCycle := [][4]uint8{
		{4, 2, 3, 1},
		{4, 6, 3, 5},
		{3, 1, 4, 2},
		{3, 5, 4, 6},
	}

	// One full cycle (4 plies): start position occurred twice
	for _, c := range shuffleCycle {
		m := findMove(game, c[0], c[1], c[2], c[3])
		if m == nil {
			t.Fatal("expected move not generated")
		}
		game.ApplyMove(*m)
	}
	if game.IsGameOver() {
		t.Error("game should not be over after one cycle")
	}

	// Second full cycle: start position occurs third time -> draw
	for _, c := range shuffleCycle {
		m := findMove(game, c[0], c[1], c[2], c[3])
		if m == nil {
			t.Fatal("expected move not generated")
		}
		game.ApplyMove(*m)
	}
	if !game.IsGameOver() {
		t.Error("game should be over after second cycle (3-fold repetition)")
	}
	if game.Winner() != nil {
		t.Errorf("repetition should be draw, got winner %v", game.Winner())
	}
}

func Test40MoveRule(t *testing.T) {
	game := Init()
	defer game.Deinit()

	game.HalfmoveClock = 79
	legal := Move{
		From:        RowColToSquare(2, 0),
		To:          RowColToSquare(3, 1),
		Captured:    [12]uint8{},
		NumCaptured: 0,
	}
	if !game.ApplyMove(legal) {
		t.Error("legal move should be accepted")
	}
	if game.HalfmoveClock != 80 {
		t.Errorf("expected halfmoveClock 80, got %d", game.HalfmoveClock)
	}
	if !game.IsGameOver() {
		t.Error("game should be over at 80 plies")
	}
	if game.Winner() != nil {
		t.Errorf("40-move rule should be draw, got winner %v", game.Winner())
	}
}

func TestIssue28Board(t *testing.T) {
	game := InitRules(Spanish)
	defer game.Deinit()
	game.Board = [32]Piece{}
	game.Board[RowColToSquare(2, 0)] = WhitePawn
	game.Board[RowColToSquare(3, 1)] = BlackKing
	game.Board[RowColToSquare(3, 7)] = BlackPawn
	game.Board[RowColToSquare(4, 2)] = BlackPawn
	game.Board[RowColToSquare(5, 7)] = BlackPawn
	game.Board[RowColToSquare(6, 4)] = BlackPawn
	game.Turn = White

	var moves MoveList
	game.GenerateMoves(&moves)
	if moves.Len() != 0 {
		t.Errorf("expected 0 moves, got %d", moves.Len())
	}
	if !game.IsGameOver() {
		t.Error("game should be over (stalemate)")
	}
	if game.Winner() != nil {
		t.Errorf("stalemate should be draw, got winner %v", game.Winner())
	}
}

func TestCaptureResetsHalfmoveClock(t *testing.T) {
	game := InitRules(English)
	defer game.Deinit()

	game.Board = [32]Piece{}
	game.Board[RowColToSquare(2, 2)] = WhitePawn
	game.Board[RowColToSquare(3, 3)] = BlackPawn
	game.Board[RowColToSquare(6, 6)] = BlackPawn
	game.Turn = White
	game.HalfmoveClock = 79
	game.RecordPosition()

	var moves MoveList
	game.GenerateMoves(&moves)
	capMove := findMove(game, 2, 2, 4, 4)
	if capMove == nil {
		t.Fatal("expected capture move not generated")
	}
	if capMove.NumCaptured == 0 {
		t.Error("expected capture move")
	}
	if !game.ApplyMove(*capMove) {
		t.Error("capture should be accepted")
	}
	if game.HalfmoveClock != 0 {
		t.Errorf("expected halfmoveClock 0 after capture, got %d", game.HalfmoveClock)
	}
	if game.IsGameOver() {
		t.Error("game should not be over after capture")
	}
}

func TestPromotionResetsHalfmoveClock(t *testing.T) {
	game := InitRules(English)
	defer game.Deinit()

	game.Board = [32]Piece{}
	game.Board[RowColToSquare(6, 2)] = WhitePawn
	game.Board[RowColToSquare(6, 6)] = BlackPawn
	game.Turn = White
	game.HalfmoveClock = 79
	game.RecordPosition()

	var moves MoveList
	game.GenerateMoves(&moves)
	promoMove := findMove(game, 6, 2, 7, 1)
	if promoMove == nil {
		t.Fatal("expected promotion move not generated")
	}
	if promoMove.NumCaptured != 0 {
		t.Error("promotion should not be a capture")
	}
	if !game.ApplyMove(*promoMove) {
		t.Error("promotion should be accepted")
	}
	if game.HalfmoveClock != 0 {
		t.Errorf("expected halfmoveClock 0 after promotion, got %d", game.HalfmoveClock)
	}
	if game.Board[RowColToSquare(7, 1)] != WhiteKing {
		t.Errorf("expected WhiteKing at (7,1), got %v", game.Board[RowColToSquare(7, 1)])
	}
	if game.IsGameOver() {
		t.Error("game should not be over after promotion")
	}
}

func TestRepetitionHistoryClearedAfterCapture(t *testing.T) {
	game := InitRules(English)
	defer game.Deinit()

	// Phase 1: shuffle cycle builds up repetition counts
	game.Board = [32]Piece{}
	game.Board[RowColToSquare(4, 2)] = WhiteKing
	game.Board[RowColToSquare(4, 6)] = BlackKing
	game.Turn = White
	game.HalfmoveClock = 0
	game.RecordPosition()

	shuffleCycle := [][4]uint8{
		{4, 2, 3, 1},
		{4, 6, 3, 5},
		{3, 1, 4, 2},
		{3, 5, 4, 6},
	}
	for _, c := range shuffleCycle {
		m := findMove(game, c[0], c[1], c[2], c[3])
		if m == nil {
			t.Fatal("expected move not generated")
		}
		game.ApplyMove(*m)
	}
	if game.IsGameOver() {
		t.Error("game should not be over after one cycle")
	}

	// Phase 2: irreversible capture clears history and resets clock
	game.Board = [32]Piece{}
	game.Board[RowColToSquare(2, 2)] = WhitePawn
	game.Board[RowColToSquare(3, 3)] = BlackPawn
	game.Board[RowColToSquare(6, 6)] = BlackPawn
	game.Turn = White
	var moves MoveList
	game.GenerateMoves(&moves)
	capMove := findMove(game, 2, 2, 4, 4)
	if capMove == nil {
		t.Fatal("expected capture move not generated")
	}
	if !game.ApplyMove(*capMove) {
		t.Error("capture should be accepted")
	}
	if game.HalfmoveClock != 0 {
		t.Errorf("expected halfmoveClock 0, got %d", game.HalfmoveClock)
	}
	if game.IsGameOver() {
		t.Error("game should not be over after capture")
	}

	// Phase 3: quiet moves on fresh position - stale shuffle history must not cause false draw
	game.GenerateMoves(&moves)
	quietMove := findMove(game, 6, 6, 5, 5)
	if quietMove == nil {
		t.Fatal("expected quiet move not generated")
	}
	if !game.ApplyMove(*quietMove) {
		t.Error("quiet move should be accepted")
	}
	if game.HalfmoveClock != 1 {
		t.Errorf("expected halfmoveClock 1, got %d", game.HalfmoveClock)
	}
	if game.IsGameOver() {
		t.Error("game should not be over - stale history cleared")
	}
}

// Helper to find a generated move
func findMove(g *Game, fromRow, fromCol, toRow, toCol uint8) *Move {
	var moves MoveList
	g.GenerateMoves(&moves)
	from := RowColToSquare(fromRow, fromCol)
	to := RowColToSquare(toRow, toCol)
	for _, m := range moves.Slice() {
		if m.From == from && m.To == to {
			return &m
		}
	}
	return nil
}