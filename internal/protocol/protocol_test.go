package protocol

import (
	"encoding/json"
	"testing"

	"github.com/vmvarela/damas/internal/core"
)

func TestHandleMessageNewGame(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	req := Request{Action: "new_game"}
	reqJSON, _ := json.Marshal(req)

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Turn != core.White {
		t.Errorf("expected White turn, got %v", resp.Turn)
	}
	if resp.Rules != core.English {
		t.Errorf("expected English rules, got %v", resp.Rules)
	}
	if resp.Over {
		t.Error("game should not be over")
	}
	if resp.Winner != nil {
		t.Error("winner should be nil")
	}
	// Board should be initial position
	expectedBoard := core.BoardToAscii(core.InitialBoard())
	if resp.Board != expectedBoard {
		t.Error("board should be initial position")
	}
}

func TestHandleMessageNewGameWithRules(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	req := Request{Action: "new_game", Rules: "spanish"}
	reqJSON, _ := json.Marshal(req)

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Rules != core.Spanish {
		t.Errorf("expected Spanish rules, got %v", resp.Rules)
	}
}

func TestHandleMessageMakeMove(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	// First, make a move
	req := Request{Action: "make_move", From: 8, To: 12}
	reqJSON, _ := json.Marshal(req)

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Turn != core.Black {
		t.Errorf("expected Black turn after move, got %v", resp.Turn)
	}
	if conn.LastMove == nil {
		t.Error("LastMove should be set")
	}
	if conn.LastMove.From != 8 || conn.LastMove.To != 12 {
		t.Errorf("LastMove should be 8->12, got %d->%d", conn.LastMove.From, conn.LastMove.To)
	}
}

func TestHandleMessageMakeMoveInvalid(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	req := Request{Action: "make_move", From: 8, To: 13} // Invalid move
	reqJSON, _ := json.Marshal(req)

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error == "" {
		t.Error("expected error for invalid move")
	}
}

func TestHandleMessageLegalMoves(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	req := Request{Action: "legal_moves", From: 8}
	reqJSON, _ := json.Marshal(req)

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if len(resp.Moves) == 0 {
		t.Error("expected legal moves")
	}
	for _, m := range resp.Moves {
		if m.From != 8 {
			t.Errorf("all moves should be from 8, got %d", m.From)
		}
	}
}

func TestHandleMessageComputeMinimax(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	req := Request{Action: "compute_minimax", TimeLimitMs: 100}
	reqJSON, _ := json.Marshal(req)

	// Save board state before move to verify legality
	boardBefore := game.Board

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if conn.LastMove == nil {
		t.Error("LastMove should be set after engine move")
	}
	if !core.IsLegalMove(boardBefore, core.White, *conn.LastMove, core.English) {
		t.Error("engine move should be legal")
	}
}

func TestHandleMessageUnknownAction(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	req := Request{Action: "unknown"}
	reqJSON, _ := json.Marshal(req)

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error == "" {
		t.Error("expected error for unknown action")
	}
}

func TestHandleMessageMalformedJSON(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	reqJSON := []byte("not valid json")

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error == "" {
		t.Error("expected error for malformed JSON")
	}
}

func TestHandleMessageNonObjectJSON(t *testing.T) {
	game := core.InitRules(core.English)
	defer game.Deinit()

	conn := &ConnState{}
	reqJSON := []byte("123")

	respJSON := HandleMessage(game, conn, reqJSON, core.English)
	var resp Response
	json.Unmarshal(respJSON, &resp)

	if resp.Error == "" {
		t.Error("expected error for non-object JSON")
	}
}

// Helper to find a generated move
func findMove(board core.Board32, turn core.Color, fromRow, fromCol, toRow, toCol uint8, v core.Variant) *core.Move {
	var moves core.MoveList
	core.GenerateMoves(board, turn, &moves, v)
	from := core.RowColToSquare(fromRow, fromCol)
	to := core.RowColToSquare(toRow, toCol)
	for _, m := range moves.Slice() {
		if m.From == from && m.To == to {
			return &m
		}
	}
	return nil
}