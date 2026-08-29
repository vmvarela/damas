package engine

import (
	"testing"

	"github.com/vmvarela/damas/internal/core"
)

func TestForcedCaptureFound(t *testing.T) {
	var board core.Board32
	board[core.RowColToSquare(2, 2)] = core.WhitePawn
	board[core.RowColToSquare(3, 3)] = core.BlackPawn

	result := SearchDepth(board, core.White, 3, core.English, SearchState{})
	if !core.IsCapture(result.Move) {
		t.Error("expected capture move")
	}
}

func TestMaterialAdvantageEvaluatesPositive(t *testing.T) {
	var board core.Board32
	board[core.RowColToSquare(2, 2)] = core.WhitePawn
	board[core.RowColToSquare(3, 3)] = core.BlackPawn
	board[core.RowColToSquare(5, 5)] = core.WhitePawn

	result := SearchDepth(board, core.White, 2, core.English, SearchState{})
	if result.Score <= 0 {
		t.Errorf("expected positive score, got %d", result.Score)
	}
}

func TestSearchIsDeterministic(t *testing.T) {
	board := core.InitialBoard()
	r1 := SearchDepth(board, core.White, 3, core.English, SearchState{})
	r2 := SearchDepth(board, core.White, 3, core.English, SearchState{})

	if r1.Move.From != r2.Move.From {
		t.Errorf("move from differs: %d vs %d", r1.Move.From, r2.Move.From)
	}
	if r1.Move.To != r2.Move.To {
		t.Errorf("move to differs: %d vs %d", r1.Move.To, r2.Move.To)
	}
	if r1.Score != r2.Score {
		t.Errorf("score differs: %d vs %d", r1.Score, r2.Score)
	}
}

func TestSearchTimeLimitReturnsLegalMove(t *testing.T) {
	board := core.InitialBoard()
	result := Search(board, core.White, 1, core.English, SearchState{})

	var moves core.MoveList
	core.GenerateMoves(board, core.White, &moves, core.English)
	found := false
	for _, m := range moves.Slice() {
		if m.From == result.Move.From && m.To == result.Move.To {
			found = true
			break
		}
	}
	if !found {
		t.Error("search should return a legal move")
	}
}

func TestInitialPositionSearchReturnsLegalMove(t *testing.T) {
	board := core.InitialBoard()
	result := Search(board, core.White, 100, core.English, SearchState{})

	if result.Depth < 1 {
		t.Errorf("expected depth >= 1, got %d", result.Depth)
	}

	var moves core.MoveList
	core.GenerateMoves(board, core.White, &moves, core.English)
	found := false
	for _, m := range moves.Slice() {
		if m.From == result.Move.From && m.To == result.Move.To {
			found = true
			break
		}
	}
	if !found {
		t.Error("search should return a legal move")
	}
}

func TestDeeperSearchFindsAtLeastAsGoodScore(t *testing.T) {
	var board core.Board32
	board[core.RowColToSquare(2, 2)] = core.WhitePawn
	board[core.RowColToSquare(3, 3)] = core.BlackPawn
	board[core.RowColToSquare(5, 5)] = core.BlackPawn

	d1 := SearchDepth(board, core.White, 1, core.English, SearchState{})
	d3 := SearchDepth(board, core.White, 3, core.English, SearchState{})
	if d3.Score < d1.Score {
		t.Errorf("deeper search score %d < shallower %d", d3.Score, d1.Score)
	}
}

func TestPromotionMoveFound(t *testing.T) {
	var board core.Board32
	board[core.RowColToSquare(6, 6)] = core.WhitePawn

	result := SearchDepth(board, core.White, 2, core.English, SearchState{})
	rc := core.SquareToRowCol(result.Move.To)
	if rc.Row != 7 {
		t.Errorf("expected promotion to row 7, got row %d", rc.Row)
	}
}

func TestStalemateIsDraw(t *testing.T) {
	// Regression for issue #28: a side with pieces but no legal move is
	// stalemated (draw), not mated.
	var board core.Board32
	board[core.RowColToSquare(2, 0)] = core.WhitePawn
	board[core.RowColToSquare(0, 0)] = core.BlackKing
	board[core.RowColToSquare(1, 1)] = core.BlackPawn
	board[core.RowColToSquare(0, 2)] = core.BlackPawn
	board[core.RowColToSquare(3, 1)] = core.BlackPawn

	result := SearchDepth(board, core.White, 3, core.English, SearchState{})
	if result.Score != 0 {
		t.Errorf("stalemate should score 0, got %d", result.Score)
	}
}

func Test80PlyDrawClock(t *testing.T) {
	// White is up material (2 pawns vs 1) but every quiet move pushes the
	// 80-ply clock to 80 -> draw.
	var board core.Board32
	board[core.RowColToSquare(4, 4)] = core.WhitePawn
	board[core.RowColToSquare(5, 5)] = core.WhitePawn
	board[core.RowColToSquare(1, 1)] = core.BlackPawn

	state := SearchState{HalfmoveClock: 79}
	result := SearchDepth(board, core.White, 3, core.English, state)
	if result.Score != 0 {
		t.Errorf("80-ply draw should score 0, got %d", result.Score)
	}

	// Escape hatch: a capture resets the clock to 0
	var capBoard core.Board32
	capBoard[core.RowColToSquare(2, 2)] = core.WhiteKing
	capBoard[core.RowColToSquare(3, 3)] = core.BlackPawn
	capBoard[core.RowColToSquare(0, 0)] = core.BlackKing

	res2 := SearchDepth(capBoard, core.White, 3, core.English, state)
	if res2.Move.NumCaptured == 0 {
		t.Error("should play the mandatory capture")
	}
	if res2.Score <= 0 {
		t.Errorf("capture should score positive, got %d", res2.Score)
	}
}

func TestThreeFoldRepetitionViaHistory(t *testing.T) {
	// Two-king shuffle: white king (4,2) vs black king (4,6), variant English,
	// with extra black pawn at (6,6) so white is down material.
	var board core.Board32
	board[core.RowColToSquare(4, 2)] = core.WhiteKing
	board[core.RowColToSquare(4, 6)] = core.BlackKing
	board[core.RowColToSquare(6, 6)] = core.BlackPawn

	var history map[uint64]uint8 = make(map[uint64]uint8)
	var child core.Board32
	child[core.RowColToSquare(3, 1)] = core.WhiteKing
	child[core.RowColToSquare(4, 6)] = core.BlackKing
	child[core.RowColToSquare(6, 6)] = core.BlackPawn
	history[core.Hash(child, core.Black)] = 2

	state := SearchState{History: history}
	result := SearchDepth(board, core.White, 3, core.English, state)
	if result.Score != 0 {
		t.Errorf("3-fold repetition should score 0, got %d", result.Score)
	}

	// Control: count 1 in history is NOT a draw
	history1 := make(map[uint64]uint8)
	history1[core.Hash(child, core.Black)] = 1
	state1 := SearchState{History: history1}
	r1 := SearchDepth(board, core.White, 3, core.English, state1)
	if r1.Score >= 0 {
		t.Errorf("count 1 should not be draw, got %d", r1.Score)
	}
}