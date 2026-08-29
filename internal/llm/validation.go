package llm

import (
	"context"
	"errors"

	"github.com/vmvarela/damas/internal/core"
)

func RequestValidMove(ctx context.Context, prov LlmProvider, board core.Board32, legalMoves []core.Move) (Response, error) {
	ascii := core.BoardToAscii(board)
	boardASCII := string(ascii[:])
	note := ""

	for i := 0; i < 3; i++ {
		req := Request{
			BoardASCII: boardASCII,
			LegalMoves: legalMoves,
			Note:       note,
		}

		resp, err := prov.RequestMove(ctx, req)
		if err != nil {
			if errors.Is(err, ErrInvalidLLMResponse) {
				note = "Reply with ONLY the JSON object {\"move\": <number>} — nothing else."
				continue
			}
			return Response{}, err
		}

		// Verify the move is in legalMoves (from/to match)
		found := false
		for _, m := range legalMoves {
			if m.From == resp.Move.From && m.To == resp.Move.To {
				found = true
				break
			}
		}
		if found {
			return resp, nil
		}

		note = "Your previous move number is not in the legal list. Reply with one number from the legal moves list."
	}

	return Response{}, ErrInvalidMove
}