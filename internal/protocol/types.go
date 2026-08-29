package protocol

import (
	"github.com/vmvarela/damas/internal/core"
)

const DEFAULT_LLM_MODEL = "llama-3.3-70b-versatile"

// Request represents a client request.
type Request struct {
	Action   string  `json:"action"`
	Rules    string  `json:"rules,omitempty"`
	From     uint8   `json:"from,omitempty"`
	To       uint8   `json:"to,omitempty"`
	Captured []uint8 `json:"captured,omitempty"`
	TimeLimitMs uint32 `json:"time_limit_ms,omitempty"`
	Model    string  `json:"model,omitempty"`
}

// Response represents a server response.
type Response struct {
	Board    [64]byte      `json:"board"`
	Turn     core.Color    `json:"turn"`
	Rules    core.Variant  `json:"rules"`
	Over     bool          `json:"over"`
	Winner   *core.Color   `json:"winner"`
	LastMove *LastMove     `json:"last_move,omitempty"`
	Error    string        `json:"error,omitempty"`
	Moves    []LegalMove   `json:"moves,omitempty"`
}

// LastMove represents the last move played.
type LastMove struct {
	From     uint8 `json:"from"`
	To       uint8 `json:"to"`
	Captured uint8 `json:"captured"` // count only
}

// LegalMove represents a legal move for the legal_moves response.
type LegalMove struct {
	From     uint8   `json:"from"`
	To       uint8   `json:"to"`
	Captured []uint8 `json:"captured"`
}

// ConnState holds per-connection state.
type ConnState struct {
	LastMove      *core.Move
	Provider      interface{} // Will be llm.LlmProvider after llm package is created
	BuildProvider func() interface{}
}