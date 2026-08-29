package protocol

import (
	"encoding/json"
	"errors"

	"github.com/vmvarela/damas/internal/core"
	"github.com/vmvarela/damas/internal/engine"
)

var (
	ErrMalformedJSON   = errors.New("malformed JSON")
	ErrNotObject       = errors.New("expected JSON object")
	ErrMissingAction   = errors.New("missing or invalid action")
	ErrInvalidFrom     = errors.New("invalid from")
	ErrInvalidTo       = errors.New("invalid to")
	ErrInvalidCaptured = errors.New("invalid captured")
	ErrNotLegalMove    = errors.New("not a legal move")
	ErrSearchFailed    = errors.New("search failed")
	ErrEngineIllegal   = errors.New("engine produced an illegal move")
	ErrLLMUnavailable  = errors.New("LLM provider unavailable")
	ErrLLMIllegal      = errors.New("LLM produced an illegal move")
	ErrInvalidMove     = errors.New("LLM did not produce a legal move")
	ErrUnknownAction   = errors.New("unknown action")
)

// HandleMessage processes a client request and returns the response JSON.
func HandleMessage(game *core.Game, conn *ConnState, jsonData []byte, defaultRules core.Variant) []byte {
	var req Request
	if err := json.Unmarshal(jsonData, &req); err != nil {
		return mustMarshal(Response{Error: ErrMalformedJSON.Error()})
	}

	switch req.Action {
	case "new_game":
		return handleNewGame(game, conn, req, defaultRules)
	case "make_move":
		return handleMakeMove(game, conn, req)
	case "legal_moves":
		return handleLegalMoves(game, req)
	case "compute_minimax":
		return handleComputeMinimax(game, conn, req)
	case "request_llm":
		return handleRequestLLM(game, conn, req)
	default:
		return mustMarshal(Response{Error: ErrUnknownAction.Error()})
	}
}

func handleNewGame(game *core.Game, conn *ConnState, req Request, defaultRules core.Variant) []byte {
	variant := defaultRules
	if req.Rules == "english" {
		variant = core.English
	} else if req.Rules == "spanish" {
		variant = core.Spanish
	}

	// Reset game state
	game.Board = core.InitialBoard()
	game.Turn = core.White
	game.Rules = variant
	game.HalfmoveClock = 0
	game.PositionHistory = nil
	conn.LastMove = nil

	return mustMarshal(buildResponse(game, conn, nil))
}

func handleMakeMove(game *core.Game, conn *ConnState, req Request) []byte {
	if req.From >= 32 {
		return mustMarshal(Response{Error: ErrInvalidFrom.Error()})
	}
	if req.To >= 32 {
		return mustMarshal(Response{Error: ErrInvalidTo.Error()})
	}

	var moves core.MoveList
	game.GenerateMoves(&moves)

	var found *core.Move
	if len(req.Captured) > 0 {
		if len(req.Captured) > 12 {
			return mustMarshal(Response{Error: ErrInvalidCaptured.Error()})
		}
		captured := [12]uint8{}
		copy(captured[:], req.Captured)
		for _, m := range moves.Slice() {
			if m.From == req.From && m.To == req.To && m.NumCaptured == uint8(len(req.Captured)) {
				match := true
				for i := uint8(0); i < m.NumCaptured; i++ {
					if m.Captured[i] != req.Captured[i] {
						match = false
						break
					}
				}
				if match {
					found = &m
					break
				}
			}
		}
	} else {
		for _, m := range moves.Slice() {
			if m.From == req.From && m.To == req.To {
				found = &m
				break
			}
		}
	}

	if found == nil {
		return mustMarshal(Response{Error: ErrNotLegalMove.Error()})
	}

	if !game.ApplyMove(*found) {
		return mustMarshal(Response{Error: ErrNotLegalMove.Error()})
	}

	conn.LastMove = found
	return mustMarshal(buildResponse(game, conn, nil))
}

func handleLegalMoves(game *core.Game, req Request) []byte {
	if req.From >= 32 {
		return mustMarshal(Response{Error: ErrInvalidFrom.Error()})
	}

	var moves core.MoveList
	game.GenerateMoves(&moves)

	legalMoves := []LegalMove{}
	for _, m := range moves.Slice() {
		if m.From == req.From {
			captured := make([]uint8, m.NumCaptured)
			copy(captured, m.Captured[:m.NumCaptured])
			legalMoves = append(legalMoves, LegalMove{
				From:     m.From,
				To:       m.To,
				Captured: captured,
			})
		}
	}

	resp := buildResponse(game, nil, legalMoves)
	return mustMarshal(resp)
}

func handleComputeMinimax(game *core.Game, conn *ConnState, req Request) []byte {
	timeLimitMs := req.TimeLimitMs
	if timeLimitMs == 0 || timeLimitMs > 30000 {
		timeLimitMs = 1000
	}
	if timeLimitMs < 1 {
		timeLimitMs = 1
	}

	state := engine.SearchState{
		HalfmoveClock: game.HalfmoveClock,
		History:       game.PositionHistory,
	}

	result := engine.Search(game.Board, game.Turn, timeLimitMs, game.Rules, state)
	if !game.ApplyMove(result.Move) {
		return mustMarshal(Response{Error: ErrEngineIllegal.Error()})
	}

	conn.LastMove = &result.Move
	return mustMarshal(buildResponse(game, conn, nil))
}

func handleRequestLLM(game *core.Game, conn *ConnState, req Request) []byte {
	model := req.Model
	if model == "" {
		model = DEFAULT_LLM_MODEL
	}

	// TODO: Implement when llm package is available
	return mustMarshal(Response{Error: ErrLLMUnavailable.Error()})
}

func buildResponse(game *core.Game, conn *ConnState, moves []LegalMove) Response {
	var lastMove *LastMove
	if conn != nil && conn.LastMove != nil {
		lastMove = &LastMove{
			From:     conn.LastMove.From,
			To:       conn.LastMove.To,
			Captured: conn.LastMove.NumCaptured,
		}
	}

	var winner *core.Color
	if w := game.Winner(); w != nil {
		winner = w
	}

	resp := Response{
		Board:    core.BoardToAscii(game.Board),
		Turn:     game.Turn,
		Rules:    game.Rules,
		Over:     game.IsGameOver(),
		Winner:   winner,
		LastMove: lastMove,
		Moves:    moves,
	}
	return resp
}

func mustMarshal(v interface{}) []byte {
	data, _ := json.Marshal(v)
	return data
}