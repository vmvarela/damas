package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

type openaiProvider struct {
	apiKey   string
	model    string
	baseURL  string
	client   *http.Client
}

type chatRequest struct {
	Model       string        `json:"model"`
	Messages    []chatMessage `json:"messages"`
	Temperature float64       `json:"temperature"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
}

// NewOpenAIProvider creates a new OpenAI-compatible provider.
func NewOpenAIProvider(apiKey, model, baseURL string) LlmProvider {
	return &openaiProvider{
		apiKey:  apiKey,
		model:   model,
		baseURL: baseURL,
		client:  &http.Client{Timeout: 30 * time.Second},
	}
}

func (p *openaiProvider) RequestMove(ctx context.Context, req Request) (Response, error) {
	prompt := BuildPrompt(req)

	body := chatRequest{
		Model: p.model,
		Messages: []chatMessage{
			{Role: "system", Content: SYSTEM_PROMPT},
			{Role: "user", Content: prompt},
		},
		Temperature: 0,
	}

	jsonBody, err := json.Marshal(body)
	if err != nil {
		return Response{}, err
	}

	url := p.baseURL + "/chat/completions"
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(jsonBody))
	if err != nil {
		return Response{}, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+p.apiKey)
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(httpReq)
	if err != nil {
		return Response{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return Response{}, errors.New("API error: " + resp.Status)
	}

	var chatResp chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&chatResp); err != nil {
		return Response{}, err
	}

	if len(chatResp.Choices) == 0 {
		return Response{}, ErrInvalidLLMResponse
	}

	return ParseMoveJSON(chatResp.Choices[0].Message.Content, req.LegalMoves)
}

func (p *openaiProvider) Close() error {
	return nil
}