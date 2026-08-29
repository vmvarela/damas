package core

// Variant represents the draughts rule variant.
type Variant uint8

const (
	English Variant = iota
	Spanish
)

type dir struct {
	dr int8
	dc int8
}

var kingDirs = [4]dir{
	{dr: -1, dc: -1},
	{dr: -1, dc: 1},
	{dr: 1, dc: -1},
	{dr: 1, dc: 1},
}

func pieceDirs(p Piece) []dir {
	switch p {
	case WhitePawn:
		return []dir{{dr: 1, dc: -1}, {dr: 1, dc: 1}}
	case BlackPawn:
		return []dir{{dr: -1, dc: -1}, {dr: -1, dc: 1}}
	default:
		return kingDirs[:]
	}
}

func captureDirs(p Piece, v Variant) []dir {
	switch p {
	case WhitePawn, BlackPawn:
		return pieceDirs(p)
	default:
		if v == English {
			return kingDirs[:]
		}
		return nil // Spanish kings handled separately
	}
}

func step(rc RowCol, d dir) (RowCol, bool) {
	r := int8(rc.Row) + d.dr
	c := int8(rc.Col) + d.dc
	if r < 0 || r >= 8 || c < 0 || c >= 8 {
		return RowCol{}, false
	}
	return RowCol{Row: uint8(r), Col: uint8(c)}, true
}

// genCaptures recursively extends a capture chain from `from`.
// `start` is the chain's origin square; `visited` marks landing squares already used;
// `captured` accumulates captured squares in order. Each complete chain is emitted as one Move.
func genCaptures(board Board32, from, start uint8, turn Color, visited *[32]bool, captured *[12]uint8, num uint8, moves *MoveList, v Variant) {
	// The moving piece never leaves `start` on the board copy.
	piece := board[start]

	// Pawn landing on last row is promoted and move ends.
	if num > 0 && !IsKing(piece) {
		lastRow := uint8(7)
		if turn == Black {
			lastRow = 0
		}
		if SquareToRowCol(from).Row == lastRow {
			_ = moves.Add(Move{From: start, To: from, Captured: *captured, NumCaptured: num})
			return
		}
	}

	made := false
	rc := SquareToRowCol(from)

	if v == Spanish && IsKing(piece) {
		flyCaptures(&board, rc, start, turn, visited, captured, num, moves, &made)
	} else {
		for _, d := range captureDirs(piece, v) {
			mid, ok := step(rc, d)
			if !ok {
				continue
			}
			land, ok := step(mid, d)
			if !ok {
				continue
			}
			midSq := RowColToSquare(mid.Row, mid.Col)
			landSq := RowColToSquare(land.Row, land.Col)
			target := board[midSq]
			if target == Empty {
				continue
			}
			targetColor, ok := PieceColor(target)
			if !ok || targetColor != Opponent(turn) {
				continue
			}
			if board[landSq] != Empty {
				continue
			}
			if visited[landSq] {
				continue
			}

			visited[landSq] = true
			captured[num] = midSq
			saved := board[midSq]
			board[midSq] = Empty
			genCaptures(board, landSq, start, turn, visited, captured, num+1, moves, v)
			board[midSq] = saved
			visited[landSq] = false
			made = true
		}
	}
	if !made && num > 0 {
		_ = moves.Add(Move{From: start, To: from, Captured: *captured, NumCaptured: num})
	}
}

// flyCaptures handles Spanish flying king captures.
func flyCaptures(board *Board32, fromRC RowCol, start uint8, turn Color, visited *[32]bool, captured *[12]uint8, num uint8, moves *MoveList, made *bool) {
	for _, d := range kingDirs {
		rc, ok := step(fromRC, d)
		if !ok {
			continue
		}
		var midSq uint8
		found := false
		for {
			sq := RowColToSquare(rc.Row, rc.Col)
			if sq == start {
				rc, ok = step(rc, d)
				if !ok {
					break
				}
				continue
			}
			p := board[sq]
			if p != Empty {
				c, ok := PieceColor(p)
				if ok && c == turn {
					break // own piece blocks
				}
				midSq = sq
				found = true
				break
			}
			rc, ok = step(rc, d)
			if !ok {
				break
			}
		}
		if !found {
			continue
		}

		lrc, ok := step(SquareToRowCol(midSq), d)
		if !ok {
			continue
		}
		for {
			lsq := RowColToSquare(lrc.Row, lrc.Col)
			if board[lsq] != Empty {
				break
			}
			if !visited[lsq] {
				visited[lsq] = true
				captured[num] = midSq
				saved := board[midSq]
				board[midSq] = Empty
				genCaptures(*board, lsq, start, turn, visited, captured, num+1, moves, Spanish)
				board[midSq] = saved
				visited[lsq] = false
				*made = true
			}
			lrc, ok = step(lrc, d)
			if !ok {
				break
			}
		}
	}
}

func kingsCaptured(board Board32, m Move) uint8 {
	var n uint8
	for i := uint8(0); i < m.NumCaptured; i++ {
		if IsKing(board[m.Captured[i]]) {
			n++
		}
	}
	return n
}

func movesEqual(a, b Move) bool {
	if a.From != b.From || a.To != b.To || a.NumCaptured != b.NumCaptured {
		return false
	}
	for i := uint8(0); i < a.NumCaptured; i++ {
		if a.Captured[i] != b.Captured[i] {
			return false
		}
	}
	return true
}

// applyCaptureLaws applies Spanish capture laws (ley de la cantidad, then ley de la calidad).
func applyCaptureLaws(board Board32, moves *MoveList) {
	if moves.Len() == 0 {
		return
	}
	var maxNum uint8
	for _, m := range moves.Slice() {
		if m.NumCaptured > maxNum {
			maxNum = m.NumCaptured
		}
	}
	var maxKings uint8
	for _, m := range moves.Slice() {
		if m.NumCaptured != maxNum {
			continue
		}
		k := kingsCaptured(board, m)
		if k > maxKings {
			maxKings = k
		}
	}
	// Filter by quantity and quality
	w := 0
	for _, m := range moves.Slice() {
		if m.NumCaptured != maxNum || kingsCaptured(board, m) != maxKings {
			continue
		}
		moves.items[w] = m
		w++
	}
	moves.len = w

	// Dedupe convergent chains
	j := 0
	for i := 0; i < moves.Len(); i++ {
		m := moves.items[i]
		dup := false
		for k := 0; k < j; k++ {
			if movesEqual(moves.items[k], m) {
				dup = true
				break
			}
		}
		if !dup {
			moves.items[j] = m
			j++
		}
	}
	moves.len = j
}

// GenerateMoves generates all legal moves for `turn`.
// Captures are mandatory: if any capture exists, only capture moves are returned.
func GenerateMoves(board Board32, turn Color, moves *MoveList, v Variant) {
	moves.Clear()

	// Capture moves
	for sq := 0; sq < 32; sq++ {
		piece := board[sq]
		if piece == Empty {
			continue
		}
		color, ok := PieceColor(piece)
		if !ok || color != turn {
			continue
		}
		var visited [32]bool
		visited[sq] = true
		var captured [12]uint8
		genCaptures(board, uint8(sq), uint8(sq), turn, &visited, &captured, 0, moves, v)
	}
	if v == Spanish {
		applyCaptureLaws(board, moves)
	}
	if moves.Len() > 0 {
		return
	}

	// Quiet moves
	for sq := 0; sq < 32; sq++ {
		piece := board[sq]
		if piece == Empty {
			continue
		}
		color, ok := PieceColor(piece)
		if !ok || color != turn {
			continue
		}
		from := uint8(sq)
		rc := SquareToRowCol(from)
		if v == Spanish && IsKing(piece) {
			for _, d := range kingDirs {
				cur, ok := step(rc, d)
				if !ok {
					continue
				}
				for {
					curSq := RowColToSquare(cur.Row, cur.Col)
					if board[curSq] != Empty {
						break
					}
					_ = moves.Add(Move{From: from, To: curSq, Captured: [12]uint8{}, NumCaptured: 0})
					cur, ok = step(cur, d)
					if !ok {
						break
					}
				}
			}
		} else {
			for _, d := range pieceDirs(piece) {
				to, ok := step(rc, d)
				if !ok {
					continue
				}
				toSq := RowColToSquare(to.Row, to.Col)
				if board[toSq] != Empty {
					continue
				}
				_ = moves.Add(Move{From: from, To: toSq, Captured: [12]uint8{}, NumCaptured: 0})
			}
		}
	}
}

// ApplyMove applies a move: moves piece, removes captured, promotes pawn on last row.
func ApplyMove(board *Board32, m Move) {
	piece := board[m.From]
	board[m.From] = Empty
	board[m.To] = piece
	for i := uint8(0); i < m.NumCaptured; i++ {
		board[m.Captured[i]] = Empty
	}
	rc := SquareToRowCol(m.To)
	if piece == WhitePawn && rc.Row == 7 {
		board[m.To] = WhiteKing
	} else if piece == BlackPawn && rc.Row == 0 {
		board[m.To] = BlackKing
	}
}

// IsLegalMove checks if a move is legal for the given turn.
func IsLegalMove(board Board32, turn Color, m Move, v Variant) bool {
	var moves MoveList
	GenerateMoves(board, turn, &moves, v)
	for _, gen := range moves.Slice() {
		if gen.From != m.From || gen.To != m.To || gen.NumCaptured != m.NumCaptured {
			continue
		}
		match := true
		for i := uint8(0); i < m.NumCaptured; i++ {
			if gen.Captured[i] != m.Captured[i] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// HasAnyMove returns true if the side has any legal move.
func HasAnyMove(board Board32, turn Color, v Variant) bool {
	var moves MoveList
	GenerateMoves(board, turn, &moves, v)
	return moves.Len() > 0
}