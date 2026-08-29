package llm

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/vmvarela/damas/internal/core"
)

func TestBuildPrompt(t *testing.T) {
	req := Request{
		BoardASCII: "test board",
		LegalMoves: []core.Move{
			{From: 8, To: 12, NumCaptured: 0},
			{From: 9, To: 13, NumCaptured: 1, Captured: [12]uint8{10}},
		},
		Note: "test note",
	}

	prompt := BuildPrompt(req)
	if !contains(prompt, "test board") {
		t.Error("prompt should contain board")
	}
	if !contains(prompt, "8,12") {
		t.Error("prompt should contain move 8,12")
	}
	if !contains(prompt, "9,13") {
		t.Error("prompt should contain move 9,13")
	}
	if !contains(prompt, "capture") {
		t.Error("prompt should indicate capture")
	}
	if !contains(prompt, "test note") {
		t.Error("prompt should contain note")
	}
}

func TestParseMoveJSON(t *testing.T) {
	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
		{From: 9, To: 13, NumCaptured: 1, Captured: [12]uint8{10}},
	}

	// Valid move
	resp, err := ParseMoveJSON(`{"move": 0, "reasoning": "test"}`, legalMoves)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if resp.Move.From != 8 || resp.Move.To != 12 {
		t.Errorf("expected move 8->12, got %d->%d", resp.Move.From, resp.Move.To)
	}
	if resp.Reasoning != "test" {
		t.Errorf("expected reasoning 'test', got %s", resp.Reasoning)
	}

	// Valid move with capture
	resp, err = ParseMoveJSON(`{"move": 1}`, legalMoves)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if resp.Move.From != 9 || resp.Move.To != 13 {
		t.Errorf("expected move 9->13, got %d->%d", resp.Move.From, resp.Move.To)
	}
	if resp.Move.NumCaptured != 1 || resp.Move.Captured[0] != 10 {
		t.Errorf("expected capture 10, got %v", resp.Move.Captured)
	}

	// Out of range
	_, err = ParseMoveJSON(`{"move": 5}`, legalMoves)
	if err == nil {
		t.Error("expected error for out of range move")
	}

	// Invalid JSON
	_, err = ParseMoveJSON(`not json`, legalMoves)
	if err == nil {
		t.Error("expected error for invalid JSON")
	}

	// Missing move field
	_, err = ParseMoveJSON(`{"reasoning": "test"}`, legalMoves)
	if err == nil {
		t.Error("expected error for missing move field")
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && findSubstring(s, substr))
}

func findSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// Mock provider for testing
type mockProvider struct {
	results []mockResult
	callCount int
}

type mockResult struct {
	resp Response
	err  error
}

func (m *mockProvider) RequestMove(ctx context.Context, req Request) (Response, error) {
	if m.callCount >= len(m.results) {
		return Response{}, errors.New("no more responses")
	}
	r := m.results[m.callCount]
	m.callCount++
	return r.resp, r.err
}

func (m *mockProvider) Close() error { return nil }

func TestRequestValidMoveSuccess(t *testing.T) {
	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
	}
	prov := &mockProvider{
		results: []mockResult{{resp: Response{Move: legalMoves[0], Reasoning: "test"}, err: nil}},
	}

	resp, err := RequestValidMove(context.Background(), prov, core.Board32{}, legalMoves)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if resp.Move.From != 8 {
		t.Errorf("expected move from 8, got %d", resp.Move.From)
	}
}

func TestRequestValidMoveRetryOnInvalidResponse(t *testing.T) {
	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
	}
	prov := &mockProvider{
		results: []mockResult{
			{err: ErrInvalidLLMResponse},
			{resp: Response{Move: legalMoves[0], Reasoning: "test"}, err: nil},
		},
	}

	resp, err := RequestValidMove(context.Background(), prov, core.Board32{}, legalMoves)
	if err != nil {
		t.Errorf("unexpected error after retry: %v", err)
	}
	if resp.Move.From != 8 {
		t.Errorf("expected move from 8, got %d", resp.Move.From)
	}
	if prov.callCount != 2 {
		t.Errorf("expected 2 calls, got %d", prov.callCount)
	}
}

func TestRequestValidMoveRetryOnIllegalMove(t *testing.T) {
	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
	}
	// First response has wrong move, second has correct move
	prov := &mockProvider{
		results: []mockResult{
			{resp: Response{Move: core.Move{From: 9, To: 13, NumCaptured: 0}}, err: nil}, // Not in legalMoves
			{resp: Response{Move: legalMoves[0], Reasoning: "test"}, err: nil},
		},
	}

	resp, err := RequestValidMove(context.Background(), prov, core.Board32{}, legalMoves)
	if err != nil {
		t.Errorf("unexpected error after retry: %v", err)
	}
	if resp.Move.From != 8 {
		t.Errorf("expected move from 8, got %d", resp.Move.From)
	}
	if prov.callCount != 2 {
		t.Errorf("expected 2 calls, got %d", prov.callCount)
	}
}

func TestRequestValidMoveFailsAfter3Attempts(t *testing.T) {
	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
	}
	prov := &mockProvider{
		results: []mockResult{
			{resp: Response{Move: core.Move{From: 9, To: 13, NumCaptured: 0}}, err: nil},
			{resp: Response{Move: core.Move{From: 9, To: 13, NumCaptured: 0}}, err: nil},
			{resp: Response{Move: core.Move{From: 9, To: 13, NumCaptured: 0}}, err: nil},
		},
	}

	_, err := RequestValidMove(context.Background(), prov, core.Board32{}, legalMoves)
	if err == nil {
		t.Error("expected error after 3 attempts")
	}
	if !errors.Is(err, ErrInvalidMove) {
		t.Errorf("expected ErrInvalidMove, got %v", err)
	}
	if prov.callCount != 3 {
		t.Errorf("expected 3 calls, got %d", prov.callCount)
	}
}

// Test OpenAI provider with mock server
func TestOpenAIProvider(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("missing auth header")
		}
		var req chatRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.Model != "test-model" {
			t.Errorf("wrong model: %s", req.Model)
		}
		if len(req.Messages) != 2 {
			t.Errorf("expected 2 messages, got %d", len(req.Messages))
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(chatResponse{
			Choices: []struct {
				Message chatMessage `json:"message"`
			}{
				{Message: chatMessage{Content: `{"move": 0, "reasoning": "test"}`}},
			},
		})
	}))
	defer server.Close()

	prov := NewOpenAIProvider("test-key", "test-model", server.URL)
	ctx := context.Background()

	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
	}
	resp, err := prov.RequestMove(ctx, Request{
		BoardASCII:  "test",
		LegalMoves:  legalMoves,
	})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if resp.Move.From != 8 {
		t.Errorf("expected move from 8, got %d", resp.Move.From)
	}
}

func TestOllamaProvider(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req generateRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.Model != "test-model" {
			t.Errorf("wrong model: %s", req.Model)
		}
		if req.Format != "json" {
			t.Errorf("expected format json, got %s", req.Format)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(generateResponse{Response: `{"move": 0, "reasoning": "test"}`})
	}))
	defer server.Close()

	prov := NewOllamaProvider("test-model", server.URL)
	ctx := context.Background()

	legalMoves := []core.Move{
		{From: 8, To: 12, NumCaptured: 0},
	}
	resp, err := prov.RequestMove(ctx, Request{
		BoardASCII:  "test",
		LegalMoves:  legalMoves,
	})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if resp.Move.From != 8 {
		t.Errorf("expected move from 8, got %d", resp.Move.From)
	}
}

func TestDetectProvider(t *testing.T) {
	// Save and restore env
	oldGroq := os.Getenv("GROQ_API_KEY")
	oldOpenAI := os.Getenv("OPENAI_API_KEY")
	defer func() {
		os.Setenv("GROQ_API_KEY", oldGroq)
		os.Setenv("OPENAI_API_KEY", oldOpenAI)
	}()

	os.Unsetenv("GROQ_API_KEY")
	os.Unsetenv("OPENAI_API_KEY")
	if DetectProvider() != "" {
		t.Error("expected empty when no keys set")
	}

	os.Setenv("GROQ_API_KEY", "test")
	if DetectProvider() != "groq" {
		t.Errorf("expected groq, got %s", DetectProvider())
	}

	os.Unsetenv("GROQ_API_KEY")
	os.Setenv("OPENAI_API_KEY", "test")
	if DetectProvider() != "openai" {
		t.Errorf("expected openai, got %s", DetectProvider())
	}
}

func TestFromConfig(t *testing.T) {
	// Save and restore env
	oldGroq := os.Getenv("GROQ_API_KEY")
	oldOpenAI := os.Getenv("OPENAI_API_KEY")
	defer func() {
		os.Setenv("GROQ_API_KEY", oldGroq)
		os.Setenv("OPENAI_API_KEY", oldOpenAI)
	}()

	os.Setenv("GROQ_API_KEY", "test-key")

	prov, err := FromConfig(LlmConfig{Provider: "groq", Model: "test-model"})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if prov == nil {
		t.Error("provider should not be nil")
	}
	prov.Close()

	// Unknown provider
	_, err = FromConfig(LlmConfig{Provider: "unknown", Model: "test-model"})
	if err == nil {
		t.Error("expected error for unknown provider")
	}
	if !errors.Is(err, ErrUnknownProvider) {
		t.Errorf("expected ErrUnknownProvider, got %v", err)
	}
}