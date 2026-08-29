package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/vmvarela/damas/internal/core"
)

var (
	ErrFileNotFound   = errors.New("config file not found")
	ErrInvalidConfig  = errors.New("invalid config")
	ErrMissingAPIKey  = errors.New("missing API key")
)

type LlmConfig struct {
	Provider string `json:"provider,omitempty"`
	Model    string `json:"model"`
}

type PlayerConfig struct {
	Llm      *LlmConfig      `json:"llm,omitempty"`
	Minimax  *MinimaxConfig  `json:"minimax,omitempty"`
	Human    *HumanConfig    `json:"human,omitempty"`
}

type MinimaxConfig struct {
	TimeLimitMs uint32 `json:"time_limit_ms"`
}

type HumanConfig struct{}

type Config struct {
	Rules       core.Variant   `json:"rules"`
	PlayerWhite PlayerConfig   `json:"player_white"`
	PlayerBlack PlayerConfig   `json:"player_black"`
}

// Load loads config from path, trying XDG config dir first, then cwd.
func Load(path string) (Config, error) {
	// Try XDG config dir
	if xdgPath := xdgConfigPath(); xdgPath != "" {
		if cfg, err := loadFile(xdgPath); err == nil {
			return cfg, nil
		}
	}

	// Try cwd
	if cfg, err := loadFile(path); err == nil {
		return cfg, nil
	}

	return Config{}, ErrFileNotFound
}

func loadFile(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	return Parse(data)
}

func Parse(data []byte) (Config, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return Config{}, ErrInvalidConfig
	}

	// Parse rules
	variant := core.Spanish
	if v, ok := raw["rules"]; ok {
		var s string
		_ = json.Unmarshal(v, &s)
		if s == "english" {
			variant = core.English
		}
	}

	// Parse players
	white, err := parsePlayer(raw["player_white"])
	if err != nil {
		return Config{}, err
	}
	black, err := parsePlayer(raw["player_black"])
	if err != nil {
		return Config{}, err
	}

	return Config{
		Rules:       variant,
		PlayerWhite: white,
		PlayerBlack: black,
	}, nil
}

func parsePlayer(data json.RawMessage) (PlayerConfig, error) {
	if data == nil {
		return PlayerConfig{}, ErrInvalidConfig
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return PlayerConfig{}, ErrInvalidConfig
	}

	typeField, ok := raw["type"]
	if !ok {
		return PlayerConfig{}, ErrInvalidConfig
	}
	var typeStr string
	_ = json.Unmarshal(typeField, &typeStr)

	switch typeStr {
	case "llm":
		modelField, ok := raw["model"]
		if !ok {
			return PlayerConfig{}, ErrInvalidConfig
		}
		var model string
		_ = json.Unmarshal(modelField, &model)

		var provider string
		if p, ok := raw["provider"]; ok {
			_ = json.Unmarshal(p, &provider)
		}
		return PlayerConfig{Llm: &LlmConfig{Provider: provider, Model: model}}, nil

	case "minimax":
		timeField, ok := raw["time_limit_ms"]
		if !ok {
			return PlayerConfig{}, ErrInvalidConfig
		}
		var ms uint32
		_ = json.Unmarshal(timeField, &ms)
		return PlayerConfig{Minimax: &MinimaxConfig{TimeLimitMs: ms}}, nil

	case "human":
		return PlayerConfig{Human: &HumanConfig{}}, nil

	default:
		return PlayerConfig{}, ErrInvalidConfig
	}
}

func xdgConfigPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "damas", "config.json")
}

// APIKey retrieves an API key from environment.
func APIKey(provider string) (string, error) {
	keyEnv := ""
	switch provider {
	case "groq":
		keyEnv = "GROQ_API_KEY"
	case "openai":
		keyEnv = "OPENAI_API_KEY"
	}
	if keyEnv == "" {
		return "", ErrMissingAPIKey
	}
	val := os.Getenv(keyEnv)
	if val == "" {
		return "", ErrMissingAPIKey
	}
	return val, nil
}