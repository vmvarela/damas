package core

// Color represents the piece color.
type Color uint8

const (
	White Color = iota
	Black
)

// Piece represents a piece on the board.
type Piece uint8

const (
	Empty Piece = iota
	WhitePawn
	WhiteKing
	BlackPawn
	BlackKing
)

// Board32 is the 32-square board representation (dark squares only).
type Board32 [32]Piece

// RowCol represents a board coordinate.
type RowCol struct {
	Row uint8
	Col uint8
}

// InitialBoard returns the standard opening position.
func InitialBoard() Board32 {
	var board Board32
	for row := 0; row < 3; row++ {
		start := uint8(1)
		if row%2 == 0 {
			start = 0
		}
		for col := start; col < 8; col += 2 {
			board[RowColToSquare(uint8(row), col)] = WhitePawn
		}
	}
	for row := 5; row < 8; row++ {
		start := uint8(1)
		if row%2 == 0 {
			start = 0
		}
		for col := start; col < 8; col += 2 {
			board[RowColToSquare(uint8(row), col)] = BlackPawn
		}
	}
	return board
}

// SquareToRowCol converts a 32-square index to (row, col) on the 8x8 board.
func SquareToRowCol(sq uint8) RowCol {
	row := sq / 4
	col := (sq % 4) * 2 + (row % 2)
	return RowCol{Row: row, Col: col}
}

// RowColToSquare converts (row, col) to a 32-square index.
// The square must be a dark square ((row + col) % 2 == 0).
func RowColToSquare(row, col uint8) uint8 {
	return row*4 + col/2
}

// Opponent returns the opposite color.
func Opponent(c Color) Color {
	return 1 - c
}

// IsKing returns true if the piece is a king.
func IsKing(p Piece) bool {
	return p == WhiteKing || p == BlackKing
}

// PieceColor returns the color of a piece, or false if empty.
func PieceColor(p Piece) (Color, bool) {
	switch p {
	case WhitePawn, WhiteKing:
		return White, true
	case BlackPawn, BlackKing:
		return Black, true
	default:
		return White, false
	}
}

// BoardToAscii returns a 64-char ASCII representation (row-major, 8x8).
// Light squares are ' ', dark squares: '.', 'w', 'W', 'b', 'B'.
func BoardToAscii(board Board32) [64]byte {
	var out [64]byte
	for row := 0; row < 8; row++ {
		for col := 0; col < 8; col++ {
			idx := row*8 + col
			if (row+col)%2 == 1 {
				out[idx] = ' '
			} else {
				sq := RowColToSquare(uint8(row), uint8(col))
				switch board[sq] {
				case Empty:
					out[idx] = '.'
				case WhitePawn:
					out[idx] = 'w'
				case WhiteKing:
					out[idx] = 'W'
				case BlackPawn:
					out[idx] = 'b'
				case BlackKing:
					out[idx] = 'B'
				}
			}
		}
	}
	return out
}