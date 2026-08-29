package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

type ollamaProvider struct {
	model    string
	baseURL  string
	client   *http.Client
}

type generateRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
	Stream bool   `json:"stream"`
	Format string `json:"format"`
}

type generateResponse struct {
	Response string `json:"response"`
}

// NewOllamaProvider creates a new Ollama provider.
func NewOllamaProvider(model, baseURL string) LlmProvider {
	return &ollamaProvider{
		model:    model,
		baseURL:  baseURL,
		client:   &http.Client{Timeout: 30 * time.Second},
	}
}

func (p *ollamaProvider) RequestMove(ctx context.Context, req Request) (Response, error) {
	prompt := BuildPrompt(req)

	body := generateRequest{
		Model:  p.model,
		Prompt: prompt,
		Stream: false,
		Format: "json",
	}

	jsonBody, err := json.Marshal(body)
	if err != nil {
		return Response{}, err
	}

	url := p.baseURL + "/api/generate"
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(jsonBody))
	if err != nil {
		return Response{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(httpReq)
	if err != nil {
		return Response{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return Response{}, errors.New("API error: " + resp.Status)
	}

	var genResp generateResponse
	if err := json.NewDecoder(resp.Body).Decode(&genResp); err != nil {
		return Response{}, err
	}

	return ParseMoveJSON(genResp.Response, req.LegalMoves)
}

func (p *ollamaProvider) Close() error {
	return nil
}