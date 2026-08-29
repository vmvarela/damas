package engine

import (
	"github.com/vmvarela/damas/internal/core"
)

const MAX_DEPTH = 24

// SearchResult contains the result of a search.
type SearchResult struct {
	Move  core.Move
	Score int32
	Depth uint8
	Nodes uint64
}

// SearchState holds state that persists across search iterations.
type SearchState struct {
	HalfmoveClock uint16
	History       map[uint64]uint8 // Zobrist hash -> occurrence count
}

// SearchCtx holds the search context.
type SearchCtx struct {
	tt       *TranspositionTable
	timer    Timer
	nodes    uint64
	aborted  bool
	rootBest core.Move
	variant  core.Variant
	history  map[uint64]uint8
	path     [MAX_DEPTH + 2]uint64
}

// Search performs time-limited search with iterative deepening.
// Returns the best move from the deepest completed iteration.
func Search(board core.Board32, turn core.Color, timeLimitMs uint32, variant core.Variant, state SearchState) SearchResult {
	tt := NewTranspositionTable(1 << 16)
	defer tt.Close()

	ctx := SearchCtx{
		tt:      tt,
		timer:   NewTimer(timeLimitMs),
		variant: variant,
		history: state.History,
	}

	var moves core.MoveList
	core.GenerateMoves(board, turn, &moves, variant)
	if moves.Len() == 0 {
		return SearchResult{Score: -MATE_SCORE} // No moves = mate
	}

	best := moves.Slice()[0]
	var bestScore int32
	var completedDepth uint8

	for depth := uint8(1); depth <= MAX_DEPTH; depth++ {
		ctx.aborted = false
		ctx.nodes = 0
		score := rootSearch(board, turn, depth, state.HalfmoveClock, &ctx)
		if ctx.aborted {
			break
		}
		best = ctx.rootBest
		bestScore = score
		completedDepth = depth
	}

	return SearchResult{
		Move:  best,
		Score: bestScore,
		Depth: completedDepth,
		Nodes: ctx.nodes,
	}
}

// SearchDepth performs a fixed-depth search (no time limit).
func SearchDepth(board core.Board32, turn core.Color, depth uint8, variant core.Variant, state SearchState) SearchResult {
	tt := NewTranspositionTable(1 << 16)
	defer tt.Close()

	ctx := SearchCtx{
		tt:      tt,
		timer:   NewTimer(0),
		variant: variant,
		history: state.History,
	}

	var moves core.MoveList
	core.GenerateMoves(board, turn, &moves, variant)
	if moves.Len() == 0 {
		return SearchResult{Score: -MATE_SCORE}
	}

	d := depth
	if d == 0 {
		d = 1
	}
	score := rootSearch(board, turn, d, state.HalfmoveClock, &ctx)
	return SearchResult{
		Move:  ctx.rootBest,
		Score: score,
		Depth: d,
		Nodes: ctx.nodes,
	}
}

func rootSearch(board core.Board32, turn core.Color, depth uint8, clock uint16, ctx *SearchCtx) int32 {
	var moves core.MoveList
	core.GenerateMoves(board, turn, &moves, ctx.variant)

	bestScore := int32(-2_000_000_000)
	bestMove := moves.Slice()[0]
	alpha := bestScore
	beta := int32(2_000_000_000)

	for _, m := range moves.Slice() {
		score := childScore(board, turn, m, depth, alpha, beta, 0, clock, 1, ctx)
		if ctx.aborted {
			return 0
		}
		if score > bestScore {
			bestScore = score
			bestMove = m
		}
		if score > alpha {
			alpha = score
		}
	}
	ctx.rootBest = bestMove
	return bestScore
}

func negamax(board core.Board32, turn core.Color, depth uint8, alpha, beta int32, ply uint8, clock uint16, repBase uint8, ctx *SearchCtx) int32 {
	ctx.nodes++
	if (ctx.nodes&0x3FF) == 0 && ctx.timer.Expired() {
		ctx.aborted = true
		return 0
	}

	var moves core.MoveList
	core.GenerateMoves(board, turn, &moves, ctx.variant)

	if moves.Len() == 0 {
		// Stalemate (pieces but no legal move) is a draw; only a side with no pieces loses.
		if hasAnyPiece(board, turn) {
			return 0
		}
		return -MATE_SCORE + int32(ply)
	}

	if depth == 0 {
		return Evaluate(board, turn, ctx.variant)
	}

	key := core.Hash(board, turn)
	ttEntry := ctx.tt.Get(key)
	if ttEntry != nil {
		if ttEntry.Depth >= depth {
			switch ttEntry.Flag {
			case Exact:
				return ttEntry.Score
			case LowerBound:
				if ttEntry.Score > alpha {
					alpha = ttEntry.Score
				}
			case UpperBound:
				if ttEntry.Score < beta {
					beta = ttEntry.Score
				}
			}
			if alpha >= beta {
				return ttEntry.Score
			}
		}
	}

	orderMoves(&moves, board, ttEntry)

	bestScore := int32(-2_000_000_000)
	var bestMove *core.Move
	for _, m := range moves.Slice() {
		score := childScore(board, turn, m, depth, alpha, beta, ply, clock, repBase, ctx)
		if ctx.aborted {
			return 0
		}
		if score > bestScore {
			bestScore = score
			bestMove = &m
		}
		if score > alpha {
			alpha = score
		}
		if alpha >= beta {
			break
		}
	}

	flag := UpperBound
	if bestScore > alpha {
		flag = Exact
	}
	if alpha >= beta {
		flag = LowerBound
	}
	if bestMove != nil {
		ctx.tt.Put(TTEntry{
			Key:   key,
			Depth: depth,
			Score: bestScore,
			Flag:  flag,
			Move:  *bestMove,
		})
	}
	return bestScore
}

func childScore(board core.Board32, turn core.Color, m core.Move, depth uint8, alpha, beta int32, ply uint8, clock uint16, repBase uint8, ctx *SearchCtx) int32 {
	var b2 core.Board32 = board
	core.ApplyMove(&b2, m)
	childTurn := core.Opponent(turn)

	// Check for promotion: only a promotion turns a pawn into a king
	movedPiece := board[m.From]
	promoted := core.IsKing(b2[m.To]) && !core.IsKing(movedPiece)
	irreversible := m.NumCaptured > 0 || promoted

	newClock := clock
	if irreversible {
		newClock = 0
	} else {
		newClock++
	}
	if newClock >= 80 {
		return 0 // 40-move rule: 80 plies without capture/promotion
	}

	if !irreversible {
		h := core.Hash(b2, childTurn)
		if repeatCount(ctx, h, ply, repBase) >= 2 {
			return 0 // this record = 3rd occurrence
		}
		ctx.path[ply+1] = h
	} else {
		ctx.path[ply+1] = core.Hash(b2, childTurn) // fresh window starts here
	}

	childRepBase := repBase
	if irreversible {
		childRepBase = ply + 1
	}
	return -negamax(b2, childTurn, depth-1, -beta, -alpha, ply+1, newClock, childRepBase, ctx)
}

func repeatCount(ctx *SearchCtx, hash uint64, ply, repBase uint8) uint32 {
	var n uint32
	if ctx.history != nil {
		n += uint32(ctx.history[hash])
	}
	for i := repBase; i <= ply; i++ {
		if ctx.path[i] == hash {
			n++
		}
	}
	return n
}

func hasAnyPiece(board core.Board32, color core.Color) bool {
	for _, p := range board {
		if c, ok := core.PieceColor(p); ok && c == color {
			return true
		}
	}
	return false
}

const pieceValueK = 300
const pawnValueK = 100

func pieceValue(p core.Piece) int32 {
	switch p {
	case core.WhiteKing, core.BlackKing:
		return pieceValueK
	case core.WhitePawn, core.BlackPawn:
		return pawnValueK
	}
	return 0
}

func orderMoves(moves *core.MoveList, board core.Board32, ttMove *TTEntry) {
	// Simple MVV-LVA ordering: TT move first, then captures by victim value desc / attacker value asc
	type scoredMove struct {
		move  core.Move
		score int32
	}
	scored := make([]scoredMove, moves.Len())
	for i, m := range moves.Slice() {
		s := int32(0)
		if ttMove != nil && ttMove.Move.From == m.From && ttMove.Move.To == m.To && ttMove.Move.NumCaptured == m.NumCaptured {
			s = 1_000_000
		} else if m.NumCaptured > 0 {
			victim := pieceValue(board[m.Captured[0]])
			attacker := pieceValue(board[m.From])
			s = victim*10 - attacker
		}
		scored[i] = scoredMove{m, s}
	}

	// Sort by score descending
	for i := 0; i < len(scored)-1; i++ {
		for j := i + 1; j < len(scored); j++ {
			if scored[j].score > scored[i].score {
				scored[i], scored[j] = scored[j], scored[i]
			}
		}
	}
	for i, sm := range scored {
		moves.MutSlice()[i] = sm.move
	}
}