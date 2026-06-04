// Package agent implements the AI Agent Runtime. The model client in this file
// is a pure HTTP concern: given a slice of messages it calls an
// OpenAI-compatible Chat Completions endpoint and returns the assistant's text.
//
// # Failure contract
//
// Any non-success outcome is returned as a typed error — never as an empty
// string or as valid text. Callers MUST treat a non-nil error as "no model
// output available" and must NOT surface the error message to the patient as
// clinical content. The concrete error types are:
//
//   - *ModelError  — the endpoint returned a non-2xx HTTP status.
//   - *ParseError  — the response body was not valid / had unexpected shape.
//   - Other errors — network / timeout failures (context.DeadlineExceeded, etc.)
//
// Example usage:
//
//	cfg := agent.ClientConfigFromEnv()
//	c := agent.NewClient(cfg, nil) // nil → default http.Client with timeout
//	text, err := c.Complete(ctx, []agent.Message{
//	    {Role: "system", Content: "You are a medical assistant."},
//	    {Role: "user",   Content: "What are common flu symptoms?"},
//	})
//	if err != nil {
//	    // model unavailable — do NOT present err.Error() to the patient
//	}
package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// DefaultBaseURL is the OpenAI-compatible endpoint used when
// AGENT_MODEL_BASE_URL is not set (Ollama's default listen address).
const DefaultBaseURL = "http://localhost:11434/v1"

// DefaultModel is the model name sent when AGENT_MODEL_NAME is not set.
const DefaultModel = "medgemma"

// DefaultTimeout is applied to each model call when the caller does not
// supply a context deadline.
const DefaultTimeout = 60 * time.Second

// ClientConfig holds everything the Client needs to reach the model endpoint.
// Values that come from environment variables are populated by ClientConfigFromEnv.
//
// API keys must not be logged. The config's String() method intentionally
// omits the APIKey field to avoid accidental exposure in log lines.
type ClientConfig struct {
	// BaseURL is the base URL of an OpenAI-compatible endpoint, e.g.
	// "http://localhost:11434/v1".  AGENT_MODEL_BASE_URL sets this at runtime.
	BaseURL string

	// Model is the model name forwarded in the Chat Completions request body.
	// AGENT_MODEL_NAME sets this at runtime.
	Model string

	// APIKey is an optional bearer token.  AGENT_MODEL_API_KEY sets this at
	// runtime.  Never log this value.
	APIKey string
}

// String returns a safe representation suitable for log lines. The API key is
// replaced with a redaction marker.
func (c ClientConfig) String() string {
	key := "<none>"
	if c.APIKey != "" {
		key = "<redacted>"
	}
	return fmt.Sprintf("ClientConfig{BaseURL:%q Model:%q APIKey:%s}", c.BaseURL, c.Model, key)
}

// ClientConfigFromEnv builds a ClientConfig from environment variables:
//
//   - AGENT_MODEL_BASE_URL   (default: DefaultBaseURL)
//   - AGENT_MODEL_NAME       (default: DefaultModel)
//   - AGENT_MODEL_API_KEY    (optional; never logged)
func ClientConfigFromEnv() ClientConfig {
	base := os.Getenv("AGENT_MODEL_BASE_URL")
	if base == "" {
		base = DefaultBaseURL
	}
	model := os.Getenv("AGENT_MODEL_NAME")
	if model == "" {
		model = DefaultModel
	}
	return ClientConfig{
		BaseURL: base,
		Model:   model,
		APIKey:  os.Getenv("AGENT_MODEL_API_KEY"),
	}
}

// Message is one turn in the conversation sent to the model.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Client calls an OpenAI-compatible Chat Completions endpoint.
//
// The zero value is not valid; construct via NewClient.
type Client struct {
	cfg  ClientConfig
	http *http.Client
}

// NewClient creates a Client. If httpClient is nil a default client with
// DefaultTimeout is used.
func NewClient(cfg ClientConfig, httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: DefaultTimeout}
	}
	return &Client{cfg: cfg, http: httpClient}
}

// chatRequest is the subset of the OpenAI Chat Completions request body used
// by the agent. It is unexported; callers use Complete.
type chatRequest struct {
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
}

// chatResponse captures only the fields the agent cares about. Extra fields
// returned by various backends are silently ignored via json.Decoder.
type chatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
}

// ModelError is returned when the model endpoint replies with a non-2xx
// HTTP status code.
//
// The Body field contains the raw response body trimmed to 256 bytes for
// debugging; it MUST NOT be forwarded to a patient as clinical content.
type ModelError struct {
	StatusCode int
	Body       string // truncated; for debugging only — never present to patients
}

func (e *ModelError) Error() string {
	return fmt.Sprintf("agent: model endpoint returned HTTP %d", e.StatusCode)
}

// ParseError is returned when the response body cannot be decoded or does not
// contain a usable assistant message.
//
// The Detail field is for debugging; it MUST NOT be forwarded to a patient.
type ParseError struct {
	Detail string
}

func (e *ParseError) Error() string {
	return fmt.Sprintf("agent: could not parse model response: %s", e.Detail)
}

// Complete sends messages to the configured Chat Completions endpoint and
// returns the assistant's text on success.
//
// On any non-success outcome the error is non-nil and the returned string is
// empty. The concrete error type is one of *ModelError, *ParseError, or a
// transport / context error. The caller MUST NOT treat a non-nil error as
// clinical content — see the package-level failure contract.
func (c *Client) Complete(ctx context.Context, messages []Message) (string, error) {
	body, err := json.Marshal(chatRequest{Model: c.cfg.Model, Messages: messages})
	if err != nil {
		// json.Marshal failure is a programming error; wrap for context.
		return "", fmt.Errorf("agent: marshal request: %w", err)
	}

	url := strings.TrimRight(c.cfg.BaseURL, "/") + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("agent: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if c.cfg.APIKey != "" {
		// Set the bearer token without logging it.
		req.Header.Set("Authorization", "Bearer "+c.cfg.APIKey)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		// Transport / timeout errors pass through unmodified so the caller can
		// inspect context.DeadlineExceeded, context.Canceled, etc.
		return "", err
	}
	defer resp.Body.Close()

	// Read at most 64 KiB to avoid unbounded memory growth on runaway responses.
	const maxBody = 64 * 1024
	rawBody, err := io.ReadAll(io.LimitReader(resp.Body, maxBody))
	if err != nil {
		return "", fmt.Errorf("agent: read response body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		// Truncate the body in the error to avoid leaking large / sensitive
		// payloads into logs.
		const maxErrBody = 256
		excerpt := string(rawBody)
		if len(excerpt) > maxErrBody {
			excerpt = excerpt[:maxErrBody] + "…"
		}
		return "", &ModelError{StatusCode: resp.StatusCode, Body: excerpt}
	}

	var cr chatResponse
	if err := json.Unmarshal(rawBody, &cr); err != nil {
		return "", &ParseError{Detail: "invalid JSON: " + err.Error()}
	}
	if len(cr.Choices) == 0 {
		return "", &ParseError{Detail: "response contained no choices"}
	}
	text := cr.Choices[0].Message.Content
	if text == "" {
		return "", &ParseError{Detail: "first choice had empty content"}
	}
	return text, nil
}
