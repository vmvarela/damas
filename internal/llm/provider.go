package llm

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/vmvarela/damas/internal/core"
)

var (
	ErrInvalidLLMResponse = errors.New("invalid LLM response")
	ErrMissingAPIKey      = errors.New("missing API key")
	ErrInvalidMove        = errors.New("LLM did not produce a legal move")
)

// Request represents the input to a provider's move request.
type Request struct {
	BoardASCII  string      `json:"board_ascii"`
	LegalMoves  []core.Move `json:"legal_moves"`
	Note        string      `json:"note,omitempty"`
}

// Response represents the chosen move.
type Response struct {
	Reasoning string     `json:"reasoning"`
	Move      core.Move  `json:"move"`
}

// LlmProvider is the interface for LLM providers.
type LlmProvider interface {
	RequestMove(ctx context.Context, req Request) (Response, error)
	Close() error
}

const SYSTEM_PROMPT = "You are a checkers engine. Reply ONLY with compact JSON and nothing else."

// BuildPrompt builds the prompt for the LLM.
func BuildPrompt(req Request) string {
	prompt := "Board (64 chars, row-major; . empty, w/W white pawn/king, b/B black pawn/king, space = light square):\n" + req.BoardASCII + "\n\n"
	prompt += "Legal moves (index: from,to):\n"
	for i, m := range req.LegalMoves {
		prompt += formatMove(i, m)
		if m.NumCaptured > 0 {
			prompt += " (capture)"
		}
		prompt += "\n"
	}
	prompt += "\nReply with ONLY compact JSON: {\"move\": <number>}. The number must be one of the legal move numbers above."
	if req.Note != "" {
		prompt += "\n\n" + req.Note
	}
	return prompt
}

func formatMove(index int, m core.Move) string {
	return string(rune('0'+index)) + ": " + itoa(int(m.From)) + "," + itoa(int(m.To))
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [10]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// ParseMoveJSON parses the LLM's JSON reply.
func ParseMoveJSON(content string, legalMoves []core.Move) (Response, error) {
	var inner struct {
		Move      *int    `json:"move"`
		Reasoning string  `json:"reasoning"`
	}
	if err := json.Unmarshal([]byte(content), &inner); err != nil {
		return Response{}, ErrInvalidLLMResponse
	}
	if inner.Move == nil {
		return Response{}, ErrInvalidLLMResponse
	}
	idx := *inner.Move
	if idx < 0 || idx >= len(legalMoves) {
		return Response{}, ErrInvalidLLMResponse
	}
	return Response{
		Reasoning: inner.Reasoning,
		Move:      legalMoves[idx],
	}, nil
}