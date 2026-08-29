package engine

import (
	"github.com/vmvarela/damas/internal/core"
)

const (
	PAWN_VALUE   = 100
	KING_VALUE_E = 300
	KING_VALUE_S = 500
	MATE_SCORE   = 100_000
)

var (
	// rayTable[sq][d][k] = square reached from sq after k+1 steps in direction d,
	// or -1 once the ray leaves the board.
	rayTable [32][4][7]int8
	dirs     = [4][2]int8{{-1, -1}, {-1, 1}, {1, -1}, {1, 1}}
)

func init() {
	for sq := 0; sq < 32; sq++ {
		rc := core.SquareToRowCol(uint8(sq))
		for d := 0; d < 4; d++ {
			var row, col int8 = int8(rc.Row), int8(rc.Col)
			for k := 0; k < 7; k++ {
				row += dirs[d][0]
				col += dirs[d][1]
				if row < 0 || row >= 8 || col < 0 || col >= 8 {
					rayTable[sq][d][k] = -1
				} else {
					rayTable[sq][d][k] = int8(core.RowColToSquare(uint8(row), uint8(col)))
				}
			}
		}
	}
}

func kingValue(v core.Variant) int32 {
	if v == core.Spanish {
		return KING_VALUE_S
	}
	return KING_VALUE_E
}

func pawnDest(board core.Board32, sq uint8, color core.Color) int32 {
	var n int32
	first := 2
	if color == core.Black {
		first = 0
	}
	for d := first; d < first+2; d++ {
		nsq := rayTable[sq][d][0]
		if nsq < 0 {
			continue
		}
		if board[nsq] == core.Empty {
			n++
		}
	}
	return n
}

func kingDest(board core.Board32, sq uint8, v core.Variant) int32 {
	var n int32
	for d := 0; d < 4; d++ {
		if v == core.English {
			nsq := rayTable[sq][d][0]
			if nsq >= 0 && board[nsq] == core.Empty {
				n++
			}
		} else {
			for _, nsq := range rayTable[sq][d] {
				if nsq < 0 {
					break
				}
				if board[nsq] != core.Empty {
					break
				}
				n++
			}
		}
	}
	return n
}

func mobility(board core.Board32, v core.Variant) int32 {
	var mob int32
	for sq := 0; sq < 32; sq++ {
		switch board[sq] {
		case core.WhitePawn:
			mob += pawnDest(board, uint8(sq), core.White)
		case core.BlackPawn:
			mob -= pawnDest(board, uint8(sq), core.Black)
		case core.WhiteKing:
			mob += 3 * kingDest(board, uint8(sq), v)
		case core.BlackKing:
			mob -= 3 * kingDest(board, uint8(sq), v)
		}
	}
	return mob
}

func promotionBonus(board core.Board32, sq uint8, color core.Color) int32 {
	rc := core.SquareToRowCol(sq)
	promoRow := uint8(6)
	if color == core.Black {
		promoRow = 1
	}
	if rc.Row != promoRow {
		return 0
	}
	if pawnDest(board, sq, color) > 0 {
		return 40
	}
	return 0
}

func structurePenalty(board core.Board32, sq uint8, color core.Color) int32 {
	rc := core.SquareToRowCol(sq)
	if rc.Col != 0 && rc.Col != 7 {
		return 0
	}
	penalty := int32(10)
	hasMove := pawnDest(board, sq, color) > 0

	first := 2
	if color == core.Black {
		first = 0
	}
	var hasCapture bool
	for d := first; d < first+2; d++ {
		mid := rayTable[sq][d][0]
		if mid < 0 {
			continue
		}
		p := board[mid]
		if p == core.Empty {
			continue
		}
		c, ok := core.PieceColor(p)
		if !ok || c == color {
			continue
		}
		land := rayTable[sq][d][1]
		if land >= 0 && board[land] == core.Empty {
			hasCapture = true
			break
		}
	}
	if !hasMove && !hasCapture {
		penalty += 50
	}
	return -penalty
}

// EvaluateMaterial returns material + row-advance + center logic (white-positive, no flip).
func EvaluateMaterial(board core.Board32, variant core.Variant) int32 {
	var score int32
	for sq := 0; sq < 32; sq++ {
		p := board[sq]
		rc := core.SquareToRowCol(uint8(sq))
		var val int32
		switch p {
		case core.WhitePawn:
			val = PAWN_VALUE + 10*int32(rc.Row)
		case core.WhiteKing:
			val = kingValue(variant) + centerBonus(rc.Col)
		case core.BlackPawn:
			val = -(PAWN_VALUE + 10*int32(7-rc.Row))
		case core.BlackKing:
			val = -(kingValue(variant) + centerBonus(rc.Col))
		}
		score += val
	}
	return score
}

func centerBonus(col uint8) int32 {
	if col >= 3 && col <= 4 {
		return 5
	}
	return 0
}

func sidePositional(board core.Board32, variant core.Variant, color core.Color) int32 {
	var s int32
	for sq := 0; sq < 32; sq++ {
		p := board[sq]
		c, ok := core.PieceColor(p)
		if !ok || c != color {
			continue
		}
		sqU := uint8(sq)
		switch p {
		case core.WhitePawn, core.BlackPawn:
			s += pawnDest(board, sqU, color) + promotionBonus(board, sqU, color) + structurePenalty(board, sqU, color)
		default:
			s += 3 * kingDest(board, sqU, variant)
		}
	}
	return s
}

// Evaluate returns the static evaluation of the position from the side-to-move's perspective.
// Material + positional terms, white-positive, flipped exactly once into side-to-move perspective.
func Evaluate(board core.Board32, turn core.Color, variant core.Variant) int32 {
	var score int32
	for sq := 0; sq < 32; sq++ {
		p := board[sq]
		rc := core.SquareToRowCol(uint8(sq))
		var val int32
		switch p {
		case core.WhitePawn:
			val = PAWN_VALUE + 10*int32(rc.Row) + promotionBonus(board, uint8(sq), core.White) + structurePenalty(board, uint8(sq), core.White)
		case core.WhiteKing:
			val = kingValue(variant) + centerBonus(rc.Col)
		case core.BlackPawn:
			val = -(PAWN_VALUE + 10*int32(7-rc.Row) + promotionBonus(board, uint8(sq), core.Black) + structurePenalty(board, uint8(sq), core.Black))
		case core.BlackKing:
			val = -(kingValue(variant) + centerBonus(rc.Col))
		}
		score += val
	}
	score += mobility(board, variant)
	if turn == core.White {
		return score
	}
	return -score
}