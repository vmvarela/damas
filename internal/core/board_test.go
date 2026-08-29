package core

import (
	"testing"
)

func TestInitialBoard(t *testing.T) {
	board := InitialBoard()

	whiteCount := 0
	blackCount := 0
	for _, p := range board {
		switch p {
		case WhitePawn:
			whiteCount++
		case BlackPawn:
			blackCount++
		}
	}

	if whiteCount != 12 {
		t.Errorf("expected 12 white pawns, got %d", whiteCount)
	}
	if blackCount != 12 {
		t.Errorf("expected 12 black pawns, got %d", blackCount)
	}

	// Verify positions
	for sq := 0; sq < 32; sq++ {
		rc := SquareToRowCol(uint8(sq))
		p := board[sq]
		switch p {
		case WhitePawn:
			if rc.Row >= 3 {
				t.Errorf("white pawn at row %d (sq %d) should be in rows 0-2", rc.Row, sq)
			}
		case BlackPawn:
			if rc.Row < 5 {
				t.Errorf("black pawn at row %d (sq %d) should be in rows 5-7", rc.Row, sq)
			}
		}
	}

	// Corner squares
	if board[RowColToSquare(0, 0)] != WhitePawn {
		t.Error("expected white pawn at (0,0)")
	}
	if board[RowColToSquare(2, 6)] != WhitePawn {
		t.Error("expected white pawn at (2,6)")
	}
	if board[RowColToSquare(5, 1)] != BlackPawn {
		t.Error("expected black pawn at (5,1)")
	}
	if board[RowColToSquare(7, 7)] != BlackPawn {
		t.Error("expected black pawn at (7,7)")
	}
	if board[RowColToSquare(3, 1)] != Empty {
		t.Error("expected empty at (3,1)")
	}
	if board[RowColToSquare(4, 4)] != Empty {
		t.Error("expected empty at (4,4)")
	}
}

func TestRowColMappingRoundTrip(t *testing.T) {
	for sq := 0; sq < 32; sq++ {
		rc := SquareToRowCol(uint8(sq))
		back := RowColToSquare(rc.Row, rc.Col)
		if back != uint8(sq) {
			t.Errorf("round-trip failed for sq=%d: got %d", sq, back)
		}
	}

	for row := 0; row < 8; row++ {
		for col := 0; col < 8; col++ {
			if (row+col)%2 == 1 {
				continue // light square, not playable
			}
			sq := RowColToSquare(uint8(row), uint8(col))
			rc := SquareToRowCol(sq)
			if rc.Row != uint8(row) || rc.Col != uint8(col) {
				t.Errorf("round-trip failed for (%d,%d): got (%d,%d)", row, col, rc.Row, rc.Col)
			}
		}
	}
}

func TestOpponent(t *testing.T) {
	if Opponent(White) != Black {
		t.Error("Opponent(White) should be Black")
	}
	if Opponent(Black) != White {
		t.Error("Opponent(Black) should be White")
	}
}

func TestBoardToAscii(t *testing.T) {
	ascii := BoardToAscii(InitialBoard())

	if len(ascii) != 64 {
		t.Errorf("expected 64 chars, got %d", len(ascii))
	}

	// Row 0: dark squares hold white pawns
	if ascii[0] != 'w' {
		t.Errorf("expected 'w' at index 0, got %c", ascii[0])
	}
	if ascii[1] != ' ' {
		t.Errorf("expected ' ' at index 1, got %c", ascii[1])
	}
	if ascii[2] != 'w' {
		t.Errorf("expected 'w' at index 2, got %c", ascii[2])
	}

	// Row 3 is empty: '.' on dark, ' ' on light
	if ascii[24] != ' ' {
		t.Errorf("expected ' ' at index 24, got %c", ascii[24])
	}
	if ascii[25] != '.' {
		t.Errorf("expected '.' at index 25, got %c", ascii[25])
	}

	// Row 7: black pawns
	if ascii[56] != ' ' {
		t.Errorf("expected ' ' at index 56, got %c", ascii[56])
	}
	if ascii[57] != 'b' {
		t.Errorf("expected 'b' at index 57, got %c", ascii[57])
	}
}

func TestPieceColor(t *testing.T) {
	tests := []struct {
		piece Piece
		want  Color
		ok    bool
	}{
		{Empty, White, false},
		{WhitePawn, White, true},
		{WhiteKing, White, true},
		{BlackPawn, Black, true},
		{BlackKing, Black, true},
	}
	for _, tt := range tests {
		got, ok := PieceColor(tt.piece)
		if ok != tt.ok || (ok && got != tt.want) {
			t.Errorf("PieceColor(%v) = (%v, %v), want (%v, %v)", tt.piece, got, ok, tt.want, tt.ok)
		}
	}
}

func TestIsKing(t *testing.T) {
	if !IsKing(WhiteKing) {
		t.Error("WhiteKing should be king")
	}
	if !IsKing(BlackKing) {
		t.Error("BlackKing should be king")
	}
	if IsKing(WhitePawn) {
		t.Error("WhitePawn should not be king")
	}
	if IsKing(BlackPawn) {
		t.Error("BlackPawn should not be king")
	}
	if IsKing(Empty) {
		t.Error("Empty should not be king")
	}
}