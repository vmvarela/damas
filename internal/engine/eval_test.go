package engine

import (
	"testing"

	"github.com/vmvarela/damas/internal/core"
)

func TestEvaluateAntisymmetric(t *testing.T) {
	b1 := core.InitialBoard()
	b2 := core.Board32{}
	b2[core.RowColToSquare(4, 4)] = core.WhiteKing
	b2[core.RowColToSquare(0, 0)] = core.BlackKing
	b2[core.RowColToSquare(7, 7)] = core.BlackKing
	b3 := core.Board32{}
	b3[core.RowColToSquare(5, 5)] = core.WhitePawn
	b3[core.RowColToSquare(4, 2)] = core.WhitePawn
	b3[core.RowColToSquare(2, 4)] = core.BlackPawn

	cases := []struct {
		board   core.Board32
		variant core.Variant
	}{
		{board: b1, variant: core.English},
		{board: b1, variant: core.Spanish},
		{board: b2, variant: core.Spanish}, // king-heavy endgame
		{board: b3, variant: core.English},
	}
	for _, c := range cases {
		scoreWhite := Evaluate(c.board, core.White, c.variant)
		scoreBlack := Evaluate(c.board, core.Black, c.variant)
		if scoreWhite != -scoreBlack {
			t.Errorf("evaluate not antisymmetric: white=%d, black=%d", scoreWhite, scoreBlack)
		}
	}
}

func TestEvaluateBlockedDiagonalsChangeMobility(t *testing.T) {
	var blocked core.Board32
	blocked[core.RowColToSquare(4, 4)] = core.WhiteKing
	blocked[core.RowColToSquare(7, 7)] = core.BlackKing

	var open core.Board32
	open[core.RowColToSquare(4, 4)] = core.WhiteKing
	open[core.RowColToSquare(1, 1)] = core.BlackKing

	// Same material (one king each). blocked corners the black king (1 dest vs 4),
	// flipping the white-black mobility balance from 0 to +9.
	if Evaluate(blocked, core.White, core.English) <= Evaluate(open, core.White, core.English) {
		t.Error("blocked should have higher eval than open for white")
	}
}

func TestEvaluateSpanishKingScoresHigher(t *testing.T) {
	var board core.Board32
	board[core.RowColToSquare(4, 4)] = core.WhiteKing

	if Evaluate(board, core.White, core.Spanish) <= Evaluate(board, core.White, core.English) {
		t.Error("Spanish king should score higher than English king")
	}
}

func TestEvaluatePenultimateRowPromoBonus(t *testing.T) {
	var near core.Board32
	near[core.RowColToSquare(6, 6)] = core.WhitePawn

	var far core.Board32
	far[core.RowColToSquare(5, 5)] = core.WhitePawn

	if Evaluate(near, core.White, core.English) <= Evaluate(far, core.White, core.English) {
		t.Error("penultimate-row pawn should get promo bonus")
	}
}

func TestEvaluateEdgeManBlockedIsPerro(t *testing.T) {
	var blocked core.Board32
	blocked[core.RowColToSquare(0, 0)] = core.WhitePawn
	blocked[core.RowColToSquare(1, 1)] = core.WhitePawn

	var open core.Board32
	open[core.RowColToSquare(0, 0)] = core.WhitePawn
	open[core.RowColToSquare(1, 3)] = core.WhitePawn

	if Evaluate(blocked, core.White, core.English) >= Evaluate(open, core.White, core.English) {
		t.Error("blocked edge man (perro) should score lower")
	}
}

func TestEvaluateForwardCaptureRescuesPerro(t *testing.T) {
	var backwardEnemy core.Board32
	backwardEnemy[core.RowColToSquare(4, 0)] = core.WhitePawn
	backwardEnemy[core.RowColToSquare(5, 1)] = core.WhitePawn
	backwardEnemy[core.RowColToSquare(3, 1)] = core.BlackPawn

	// Pawns capture forward only, so backward enemy leaves it a perro
	if Evaluate(backwardEnemy, core.White, core.English) != Evaluate(backwardEnemy, core.White, core.Spanish) {
		t.Error("backward enemy should score identically in both variants")
	}

	var forwardCapture core.Board32
	forwardCapture[core.RowColToSquare(4, 0)] = core.WhitePawn
	forwardCapture[core.RowColToSquare(5, 1)] = core.BlackPawn
	forwardCapture[core.RowColToSquare(2, 2)] = core.WhitePawn

	// Forward enemy with empty landing rescues the man
	if Evaluate(forwardCapture, core.White, core.English) != Evaluate(forwardCapture, core.White, core.Spanish) {
		t.Error("forward capture should score identically in both variants")
	}
	if Evaluate(forwardCapture, core.White, core.English) <= Evaluate(backwardEnemy, core.White, core.English) {
		t.Error("forward capture should rescue perro")
	}
}

func TestEvaluatePositionalTermsUnderOnePawn(t *testing.T) {
	type Pos struct {
		board   core.Board32
		variant core.Variant
	}

	var mat core.Board32
	mat[core.RowColToSquare(2, 2)] = core.WhitePawn
	mat[core.RowColToSquare(4, 4)] = core.WhitePawn
	mat[core.RowColToSquare(6, 6)] = core.BlackPawn

	var mob core.Board32
	mob[core.RowColToSquare(2, 2)] = core.WhitePawn
	mob[core.RowColToSquare(5, 7)] = core.BlackPawn

	var promo core.Board32
	promo[core.RowColToSquare(6, 6)] = core.WhitePawn

	var perro core.Board32
	perro[core.RowColToSquare(0, 0)] = core.WhitePawn
	perro[core.RowColToSquare(1, 1)] = core.WhitePawn

	var kings core.Board32
	kings[core.RowColToSquare(4, 4)] = core.WhiteKing
	kings[core.RowColToSquare(0, 0)] = core.BlackKing
	kings[core.RowColToSquare(7, 7)] = core.BlackKing

	cases := []Pos{
		{board: mat, variant: core.English},
		{board: mob, variant: core.English},
		{board: promo, variant: core.English},
		{board: perro, variant: core.English},
		{board: kings, variant: core.Spanish},
	}
	for _, c := range cases {
		materialDiff := Evaluate(c.board, core.White, c.variant) - EvaluateMaterial(c.board, c.variant)
		if materialDiff >= 100 || materialDiff <= -100 {
			t.Errorf("positional terms exceed one pawn: %d", materialDiff)
		}
		if sidePositional(c.board, c.variant, core.White) >= 100 || sidePositional(c.board, c.variant, core.White) <= -100 {
			t.Errorf("white positional terms exceed one pawn: %d", sidePositional(c.board, c.variant, core.White))
		}
		if sidePositional(c.board, c.variant, core.Black) >= 100 || sidePositional(c.board, c.variant, core.Black) <= -100 {
			t.Errorf("black positional terms exceed one pawn: %d", sidePositional(c.board, c.variant, core.Black))
		}
	}
}

func TestEvaluateExactRegression(t *testing.T) {
	type Pos struct {
		board     core.Board32
		variant   core.Variant
		expected  int32
	}

	var initial core.Board32 = core.InitialBoard()

	var mat core.Board32
	mat[core.RowColToSquare(2, 2)] = core.WhitePawn
	mat[core.RowColToSquare(4, 4)] = core.WhitePawn
	mat[core.RowColToSquare(6, 6)] = core.BlackPawn

	var mob core.Board32
	mob[core.RowColToSquare(2, 2)] = core.WhitePawn
	mob[core.RowColToSquare(5, 7)] = core.BlackPawn

	var promo core.Board32
	promo[core.RowColToSquare(6, 6)] = core.WhitePawn

	var perro core.Board32
	perro[core.RowColToSquare(0, 0)] = core.WhitePawn
	perro[core.RowColToSquare(1, 1)] = core.WhitePawn

	var king core.Board32
	king[core.RowColToSquare(4, 4)] = core.WhiteKing

	cases := []Pos{
		{board: initial, variant: core.English, expected: 0},
		{board: mat, variant: core.English, expected: 152},
		{board: mob, variant: core.English, expected: 11},
		{board: promo, variant: core.English, expected: 202},
		{board: perro, variant: core.English, expected: 152},
		{board: king, variant: core.Spanish, expected: 544},
	}
	for _, c := range cases {
		got := Evaluate(c.board, core.White, c.variant)
		if got != c.expected {
			t.Errorf("eval(%v, %v) = %d, want %d", c.board, c.variant, got, c.expected)
		}
	}
}

// TestEvaluatePromotionRace is in minimax_test.go since it requires SearchDepth