package agent_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/markolonius/housecall/backend/internal/agent"
)

func TestValidateEndpoint(t *testing.T) {
	cases := []struct {
		url, env string
		wantErr  bool
	}{
		{"http://host:11434/v1", "", false},
		{"http://host:11434/v1", "development", false},
		{"http://host:11434/v1", "production", true},
		{"http://host:11434/v1", "Production", true},
		{"https://host/v1", "production", false},
		{"ftp://host/v1", "", true},
		{"not a url", "", true},
		{"", "", true},
	}
	for _, c := range cases {
		err := agent.ValidateEndpoint(c.url, c.env)
		if (err != nil) != c.wantErr {
			t.Errorf("ValidateEndpoint(%q,%q) err=%v wantErr=%v", c.url, c.env, err, c.wantErr)
		}
	}
	if err := agent.ValidateEndpoint("http://user:secret@host/v1", "production"); err == nil || strings.Contains(err.Error(), "secret") {
		t.Errorf("error must exist and not leak credentials: %v", err)
	}
}

func TestTimeouts_DefaultsAndEnv(t *testing.T) {
	for _, k := range []string{"AGENT_TIMEOUT_TRIAGE", "AGENT_TIMEOUT_INTERVIEW", "AGENT_TIMEOUT_SOAP", "AGENT_TIMEOUT_RELAY"} {
		t.Setenv(k, "")
	}
	d := agent.TimeoutsFromEnv()
	if d.For(agent.TurnTriage) != 15*time.Second || d.For(agent.TurnInterview) != 60*time.Second ||
		d.For(agent.TurnSOAP) != 120*time.Second || d.For(agent.TurnRelay) != 60*time.Second {
		t.Errorf("unexpected defaults: %+v", d)
	}
	if d.For(agent.TurnDefault) != agent.DefaultTimeout {
		t.Errorf("TurnDefault should use DefaultTimeout")
	}
	t.Setenv("AGENT_TIMEOUT_TRIAGE", "3s")
	t.Setenv("AGENT_TIMEOUT_SOAP", "bogus")
	t.Setenv("AGENT_TIMEOUT_RELAY", "-1s")
	o := agent.TimeoutsFromEnv()
	if o.Triage != 3*time.Second || o.SOAP != 120*time.Second || o.Relay != 60*time.Second {
		t.Errorf("unexpected overrides: %+v", o)
	}
}

func TestCompleteFor_AppliesTurnTimeout(t *testing.T) {
	t.Setenv("AGENT_TIMEOUT_TRIAGE", "50ms")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(2 * time.Second):
		}
	}))
	defer srv.Close()
	c := agent.NewClient(agent.ClientConfig{BaseURL: srv.URL, Model: "m"}, nil)
	start := time.Now()
	_, err := c.CompleteFor(context.Background(), agent.TurnTriage, []agent.Message{{Role: "user", Content: "x"}})
	if err == nil || time.Since(start) > time.Second {
		t.Errorf("expected fast timeout, err=%v after %v", err, time.Since(start))
	}
}

func TestCheckEndpoint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"medgemma-27b"}]}`))
	}))
	defer srv.Close()
	ctx := context.Background()
	if w := agent.CheckEndpoint(ctx, agent.ClientConfig{BaseURL: srv.URL + "/v1", Model: "medgemma-27b", APIKey: "topsecret"}, nil); w != "" {
		t.Errorf("unexpected warning: %s", w)
	}
	w := agent.CheckEndpoint(ctx, agent.ClientConfig{BaseURL: srv.URL + "/v1", Model: "other", APIKey: "topsecret"}, nil)
	if w == "" || strings.Contains(w, "topsecret") || strings.Contains(w, "/v1") {
		t.Errorf("expected host-only model-missing warning, got %q", w)
	}
	w = agent.CheckEndpoint(ctx, agent.ClientConfig{BaseURL: "http://user:pw@127.0.0.1:1/v1", APIKey: "topsecret"}, nil)
	if w == "" || strings.Contains(w, "pw") || strings.Contains(w, "topsecret") {
		t.Errorf("expected host-only unreachable warning, got %q", w)
	}
}
