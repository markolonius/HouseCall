package agent_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/markolonius/housecall/backend/internal/agent"
)

// newTestClient builds a Client pointed at the given httptest.Server.
func newTestClient(srv *httptest.Server) *agent.Client {
	cfg := agent.ClientConfig{
		BaseURL: srv.URL,
		Model:   "test-model",
	}
	return agent.NewClient(cfg, srv.Client())
}

// chatResponseBody returns a minimal valid Chat Completions JSON body.
func chatResponseBody(content string) string {
	b, _ := json.Marshal(map[string]any{
		"choices": []map[string]any{
			{
				"message":       map[string]any{"role": "assistant", "content": content},
				"finish_reason": "stop",
			},
		},
	})
	return string(b)
}

// --- success path ---

func TestComplete_Success(t *testing.T) {
	const want = "Take two aspirin and rest."
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, chatResponseBody(want))
	}))
	defer srv.Close()

	c := newTestClient(srv)
	got, err := c.Complete(context.Background(), []agent.Message{
		{Role: "user", Content: "What should I do for a headache?"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestComplete_WithAPIKey_SetsAuthHeader(t *testing.T) {
	const key = "sk-test-key"
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, chatResponseBody("ok"))
	}))
	defer srv.Close()

	cfg := agent.ClientConfig{BaseURL: srv.URL, Model: "test-model", APIKey: key}
	c := agent.NewClient(cfg, srv.Client())
	_, err := c.Complete(context.Background(), []agent.Message{{Role: "user", Content: "hi"}})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotAuth != "Bearer "+key {
		t.Errorf("Authorization header = %q, want %q", gotAuth, "Bearer "+key)
	}
}

// --- non-2xx → *ModelError ---

func TestComplete_Non2xx_ReturnsModelError(t *testing.T) {
	for _, code := range []int{400, 401, 429, 500, 503} {
		code := code
		t.Run(http.StatusText(code), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Error(w, "error from model", code)
			}))
			defer srv.Close()

			c := newTestClient(srv)
			text, err := c.Complete(context.Background(), []agent.Message{{Role: "user", Content: "x"}})
			if err == nil {
				t.Fatalf("expected error for HTTP %d, got text=%q", code, text)
			}
			if text != "" {
				t.Errorf("non-empty text returned alongside error: %q", text)
			}
			var me *agent.ModelError
			if !errors.As(err, &me) {
				t.Errorf("expected *ModelError, got %T: %v", err, err)
			}
			if me != nil && me.StatusCode != code {
				t.Errorf("ModelError.StatusCode = %d, want %d", me.StatusCode, code)
			}
		})
	}
}

// --- malformed body → *ParseError ---

func TestComplete_MalformedJSON_ReturnsParseError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, `{not valid json`)
	}))
	defer srv.Close()

	c := newTestClient(srv)
	text, err := c.Complete(context.Background(), []agent.Message{{Role: "user", Content: "x"}})
	if err == nil {
		t.Fatalf("expected parse error, got text=%q", text)
	}
	if text != "" {
		t.Errorf("non-empty text returned alongside error: %q", text)
	}
	var pe *agent.ParseError
	if !errors.As(err, &pe) {
		t.Errorf("expected *ParseError, got %T: %v", err, err)
	}
}

func TestComplete_EmptyChoices_ReturnsParseError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"choices":[]}`)
	}))
	defer srv.Close()

	c := newTestClient(srv)
	text, err := c.Complete(context.Background(), []agent.Message{{Role: "user", Content: "x"}})
	if err == nil {
		t.Fatalf("expected parse error, got text=%q", text)
	}
	if text != "" {
		t.Errorf("non-empty text returned alongside error: %q", text)
	}
	var pe *agent.ParseError
	if !errors.As(err, &pe) {
		t.Errorf("expected *ParseError, got %T: %v", err, err)
	}
}

func TestComplete_EmptyContent_ReturnsParseError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, chatResponseBody("")) // empty string content
	}))
	defer srv.Close()

	c := newTestClient(srv)
	text, err := c.Complete(context.Background(), []agent.Message{{Role: "user", Content: "x"}})
	if err == nil {
		t.Fatalf("expected parse error for empty content, got text=%q", text)
	}
	if text != "" {
		t.Errorf("non-empty text returned alongside error: %q", text)
	}
	var pe *agent.ParseError
	if !errors.As(err, &pe) {
		t.Errorf("expected *ParseError, got %T: %v", err, err)
	}
}

// --- timeout / transport error ---

func TestComplete_ContextCancelled_ReturnsError(t *testing.T) {
	// Use an already-cancelled context so the http.Client bails out immediately
	// before even establishing the connection — no server needed.
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancelled before the call

	cfg := agent.ClientConfig{
		BaseURL: "http://127.0.0.1:19999", // arbitrary; we never connect
		Model:   "test-model",
	}
	c := agent.NewClient(cfg, &http.Client{Timeout: 2 * time.Second})
	text, err := c.Complete(ctx, []agent.Message{{Role: "user", Content: "x"}})
	if err == nil {
		t.Fatalf("expected error for cancelled context, got text=%q", text)
	}
	if text != "" {
		t.Errorf("non-empty text returned alongside error: %q", text)
	}
	if !errors.Is(err, context.Canceled) {
		t.Logf("error was: %v (type %T) — acceptable as long as it is non-nil and text is empty", err, err)
	}
}

func TestComplete_TransportError_ReturnsError(t *testing.T) {
	// Point the client at a port that (very likely) has nothing listening.
	cfg := agent.ClientConfig{
		BaseURL: "http://127.0.0.1:1", // port 1 is reserved; connection refused
		Model:   "test-model",
	}
	c := agent.NewClient(cfg, &http.Client{Timeout: 2 * time.Second})
	text, err := c.Complete(context.Background(), []agent.Message{{Role: "user", Content: "x"}})
	if err == nil {
		t.Fatalf("expected transport error, got text=%q", text)
	}
	if text != "" {
		t.Errorf("non-empty text returned alongside transport error: %q", text)
	}
}

// --- ClientConfig.String() does not leak the API key ---

func TestClientConfig_String_RedactsAPIKey(t *testing.T) {
	cfg := agent.ClientConfig{
		BaseURL: "http://localhost:11434/v1",
		Model:   "medgemma",
		APIKey:  "sk-super-secret",
	}
	s := cfg.String()
	if strings.Contains(s, "sk-super-secret") {
		t.Errorf("ClientConfig.String() exposed API key: %s", s)
	}
	if !strings.Contains(s, "<redacted>") {
		t.Errorf("ClientConfig.String() should contain '<redacted>', got: %s", s)
	}
}

func TestClientConfig_String_NoKeyShowsNone(t *testing.T) {
	cfg := agent.ClientConfig{BaseURL: "http://localhost:11434/v1", Model: "m"}
	s := cfg.String()
	if !strings.Contains(s, "<none>") {
		t.Errorf("ClientConfig.String() should say '<none>' when APIKey is empty, got: %s", s)
	}
}

// --- ClientConfigFromEnv ---

func TestClientConfigFromEnv_Defaults(t *testing.T) {
	// Unset the env vars to ensure defaults are used.
	t.Setenv("AGENT_MODEL_BASE_URL", "")
	t.Setenv("AGENT_MODEL_NAME", "")
	t.Setenv("AGENT_MODEL_API_KEY", "")

	cfg := agent.ClientConfigFromEnv()
	if cfg.BaseURL != agent.DefaultBaseURL {
		t.Errorf("BaseURL = %q, want %q", cfg.BaseURL, agent.DefaultBaseURL)
	}
	if cfg.Model != agent.DefaultModel {
		t.Errorf("Model = %q, want %q", cfg.Model, agent.DefaultModel)
	}
	if cfg.APIKey != "" {
		t.Errorf("APIKey should be empty, got non-empty")
	}
}

func TestClientConfigFromEnv_Overrides(t *testing.T) {
	t.Setenv("AGENT_MODEL_BASE_URL", "http://model.example.com/v1")
	t.Setenv("AGENT_MODEL_NAME", "custom-model")
	t.Setenv("AGENT_MODEL_API_KEY", "tok-xyz")

	cfg := agent.ClientConfigFromEnv()
	if cfg.BaseURL != "http://model.example.com/v1" {
		t.Errorf("BaseURL = %q", cfg.BaseURL)
	}
	if cfg.Model != "custom-model" {
		t.Errorf("Model = %q", cfg.Model)
	}
	if cfg.APIKey != "tok-xyz" {
		t.Errorf("APIKey = %q", cfg.APIKey)
	}
}
