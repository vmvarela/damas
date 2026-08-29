package llm

import (
	"errors"
	"os"
	"strings"
)

var (
	ErrUnknownProvider = errors.New("unknown provider")
)

type providerInfo struct {
	Name    string
	BaseURL string
	KeyEnv  string
}

var providers = []providerInfo{
	{Name: "groq", BaseURL: "https://api.groq.com/openai/v1", KeyEnv: "GROQ_API_KEY"},
	{Name: "openai", BaseURL: "https://api.openai.com/v1", KeyEnv: "OPENAI_API_KEY"},
}

// DetectProvider returns the first provider whose API key env var is set.
func DetectProvider() string {
	for _, p := range providers {
		if val := os.Getenv(p.KeyEnv); val != "" {
			return p.Name
		}
	}
	return ""
}

// FromConfig creates a provider from configuration.
func FromConfig(cfg LlmConfig) (LlmProvider, error) {
	name := cfg.Provider
	if name == "" {
		name = DetectProvider()
		if name == "" {
			return nil, ErrMissingAPIKey
		}
	}

	if strings.EqualFold(name, "ollama") {
		return NewOllamaProvider(cfg.Model, "http://localhost:11434"), nil
	}

	for _, p := range providers {
		if strings.EqualFold(name, p.Name) {
			key := os.Getenv(p.KeyEnv)
			if key == "" {
				return nil, ErrMissingAPIKey
			}
			return NewOpenAIProvider(key, cfg.Model, p.BaseURL), nil
		}
	}

	return nil, ErrUnknownProvider
}

// LlmConfig holds LLM configuration.
type LlmConfig struct {
	Provider string
	Model    string
}