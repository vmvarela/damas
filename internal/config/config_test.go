package config

import (
	"os"
	"testing"

	"github.com/vmvarela/damas/internal/core"
)

func TestParseValidConfig(t *testing.T) {
	jsonData := []byte(`{
		"rules": "spanish",
		"player_white": {"type": "llm", "provider": "groq", "model": "llama-3.3-70b-versatile"},
		"player_black": {"type": "minimax", "time_limit_ms": 2000}
	}`)

	cfg, err := Parse(jsonData)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	if cfg.Rules != core.Spanish {
		t.Errorf("expected Spanish rules, got %v", cfg.Rules)
	}
	if cfg.PlayerWhite.Llm == nil {
		t.Error("expected white to be llm")
	}
	if cfg.PlayerWhite.Llm.Provider != "groq" {
		t.Errorf("expected provider groq, got %s", cfg.PlayerWhite.Llm.Provider)
	}
	if cfg.PlayerWhite.Llm.Model != "llama-3.3-70b-versatile" {
		t.Errorf("expected model llama-3.3-70b-versatile, got %s", cfg.PlayerWhite.Llm.Model)
	}
	if cfg.PlayerBlack.Minimax == nil {
		t.Error("expected black to be minimax")
	}
	if cfg.PlayerBlack.Minimax.TimeLimitMs != 2000 {
		t.Errorf("expected time limit 2000, got %d", cfg.PlayerBlack.Minimax.TimeLimitMs)
	}
}

func TestParseEnglishRules(t *testing.T) {
	jsonData := []byte(`{
		"rules": "english",
		"player_white": {"type": "human"},
		"player_black": {"type": "human"}
	}`)

	cfg, err := Parse(jsonData)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if cfg.Rules != core.English {
		t.Errorf("expected English rules, got %v", cfg.Rules)
	}
}

func TestParseDefaultsToSpanish(t *testing.T) {
	jsonData := []byte(`{
		"player_white": {"type": "human"},
		"player_black": {"type": "human"}
	}`)

	cfg, err := Parse(jsonData)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if cfg.Rules != core.Spanish {
		t.Errorf("expected Spanish (default), got %v", cfg.Rules)
	}
}

func TestParseUnknownRulesDefaultsToSpanish(t *testing.T) {
	jsonData := []byte(`{
		"rules": "unknown",
		"player_white": {"type": "human"},
		"player_black": {"type": "human"}
	}`)

	cfg, err := Parse(jsonData)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if cfg.Rules != core.Spanish {
		t.Errorf("expected Spanish (default), got %v", cfg.Rules)
	}
}

func TestParseInvalidJSON(t *testing.T) {
	_, err := Parse([]byte(`{invalid}`))
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestParseMissingType(t *testing.T) {
	jsonData := []byte(`{
		"player_white": {"model": "test"},
		"player_black": {"type": "human"}
	}`)
	_, err := Parse(jsonData)
	if err == nil {
		t.Error("expected error for missing type")
	}
}

func TestParseHuman(t *testing.T) {
	jsonData := []byte(`{
		"player_white": {"type": "human"},
		"player_black": {"type": "human"}
	}`)

	cfg, err := Parse(jsonData)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if cfg.PlayerWhite.Human == nil {
		t.Error("expected human player")
	}
}

func TestAPIKey(t *testing.T) {
	// Test with env var set
	os.Setenv("GROQ_API_KEY", "test-key")
	defer os.Unsetenv("GROQ_API_KEY")

	key, err := APIKey("groq")
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if key != "test-key" {
		t.Errorf("expected test-key, got %s", key)
	}

	// Test missing env var
	os.Unsetenv("GROQ_API_KEY")
	_, err = APIKey("groq")
	if err == nil {
		t.Error("expected error for missing API key")
	}
}

func TestXDGConfigPath(t *testing.T) {
	path := xdgConfigPath()
	if path == "" {
		t.Error("XDG config path should not be empty")
	}
}