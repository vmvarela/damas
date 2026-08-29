package core

// Game represents the game state: board, turn, rules, and draw detection.
type Game struct {
	Board            Board32
	Turn             Color
	Rules            Variant
	PositionHistory  map[uint64]uint8 // Zobrist hash -> occurrence count
	HalfmoveClock    uint16           // Plies since last capture or promotion (exported for tests)
}

// Init creates a new game with Spanish rules (default).
func Init() *Game {
	return InitRules(Spanish)
}

// InitRules creates a new game with the specified variant.
func InitRules(v Variant) *Game {
	return &Game{
		Board:           InitialBoard(),
		Turn:            White,
		Rules:           v,
		HalfmoveClock:   0,
		PositionHistory: nil, // allocated lazily on first RecordPosition
	}
}

// Deinit frees the game resources.
func (g *Game) Deinit() {
	g.PositionHistory = nil
}

// GenerateMoves populates the move list with legal moves for the current turn.
func (g *Game) GenerateMoves(moves *MoveList) {
	GenerateMoves(g.Board, g.Turn, moves, g.Rules)
}

// ApplyMove validates and applies a move; flips the turn.
// Returns false if illegal (board and turn unchanged).
// Tracks halfmove clock and 3-fold repetition.
func (g *Game) ApplyMove(m Move) bool {
	if !IsLegalMove(g.Board, g.Turn, m, g.Rules) {
		return false
	}

	movedPiece := g.Board[m.From]
	ApplyMove(&g.Board, m)
	g.Turn = Opponent(g.Turn)

	// Only a promotion turns a pawn into a king.
	promoted := IsKing(g.Board[m.To]) && !IsKing(movedPiece)

	if m.NumCaptured > 0 || promoted {
		g.HalfmoveClock = 0
		if g.PositionHistory != nil {
			g.PositionHistory = make(map[uint64]uint8)
		}
	} else {
		g.HalfmoveClock++
	}
	g.RecordPosition()
	return true
}

// IsGameOver returns true if the game is over.
// Game over when: current turn has no moves, a side has no pieces,
// 80 plies pass without capture/promotion, or position repeats 3 times.
func (g *Game) IsGameOver() bool {
	if !HasAnyMove(g.Board, g.Turn, g.Rules) {
		return true
	}
	if !hasPieces(g.Board, White) || !hasPieces(g.Board, Black) {
		return true
	}
	if g.HalfmoveClock >= 80 {
		return true
	}
	if g.PositionHistory != nil {
		for _, count := range g.PositionHistory {
			if count >= 3 {
				return true
			}
		}
	}
	return false
}

// Winner returns the winner, or nil if game is not over or ended in draw.
// A player blocked with no legal move does not lose — it's a draw.
func (g *Game) Winner() *Color {
	if !g.IsGameOver() {
		return nil
	}
	if !hasPieces(g.Board, White) {
		return ptr(Black)
	}
	if !hasPieces(g.Board, Black) {
		return ptr(White)
	}
	// Both sides have pieces: current turn is stalemated -> draw
	return nil
}

// RecordPosition records the current position in the history map.
func (g *Game) RecordPosition() {
	if g.PositionHistory == nil {
		g.PositionHistory = make(map[uint64]uint8)
	}
	h := Hash(g.Board, g.Turn)
	g.PositionHistory[h]++
}

// hasPieces checks if a color has any pieces on the board.
func hasPieces(board Board32, color Color) bool {
	for _, p := range board {
		if c, ok := PieceColor(p); ok && c == color {
			return true
		}
	}
	return false
}

func ptr(c Color) *Color {
	return &c
}