package agent

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// TurnType identifies which kind of model turn a call serves; each has its own
// timeout. The zero value (TurnDefault) uses DefaultTimeout.
type TurnType int

const (
	TurnDefault TurnType = iota
	TurnTriage
	TurnInterview
	TurnSOAP
	TurnRelay
)

// Per-turn-type default timeouts.
const (
	DefaultTriageTimeout    = 15 * time.Second // blocks the patient's reply
	DefaultInterviewTimeout = 60 * time.Second
	DefaultSOAPTimeout      = 120 * time.Second // 27B on one GPU is slower
	DefaultRelayTimeout     = 60 * time.Second
)

// Timeouts holds the per-call timeout for each turn type.
type Timeouts struct {
	Triage, Interview, SOAP, Relay time.Duration
}

// DefaultTimeouts returns the built-in per-turn-type timeouts.
func DefaultTimeouts() Timeouts {
	return Timeouts{
		Triage:    DefaultTriageTimeout,
		Interview: DefaultInterviewTimeout,
		SOAP:      DefaultSOAPTimeout,
		Relay:     DefaultRelayTimeout,
	}
}

// TimeoutsFromEnv reads AGENT_TIMEOUT_TRIAGE, AGENT_TIMEOUT_INTERVIEW,
// AGENT_TIMEOUT_SOAP and AGENT_TIMEOUT_RELAY (Go duration strings). Unset,
// unparsable or non-positive values keep the default.
func TimeoutsFromEnv() Timeouts {
	t := DefaultTimeouts()
	override := func(name string, dst *time.Duration) {
		if d, err := time.ParseDuration(strings.TrimSpace(os.Getenv(name))); err == nil && d > 0 {
			*dst = d
		}
	}
	override("AGENT_TIMEOUT_TRIAGE", &t.Triage)
	override("AGENT_TIMEOUT_INTERVIEW", &t.Interview)
	override("AGENT_TIMEOUT_SOAP", &t.SOAP)
	override("AGENT_TIMEOUT_RELAY", &t.Relay)
	return t
}

// For returns the timeout for a turn type; TurnDefault yields DefaultTimeout.
func (t Timeouts) For(turn TurnType) time.Duration {
	switch turn {
	case TurnTriage:
		return t.Triage
	case TurnInterview:
		return t.Interview
	case TurnSOAP:
		return t.SOAP
	case TurnRelay:
		return t.Relay
	}
	return DefaultTimeout
}

// ValidateEndpoint returns a configuration error when the base URL is not a
// usable http(s) URL, or when appEnv is "production" and it is not https.
// The error never contains the URL itself (it may carry credentials).
func ValidateEndpoint(baseURL, appEnv string) error {
	u, err := url.Parse(baseURL)
	if err != nil || u.Host == "" {
		return fmt.Errorf("agent: AGENT_MODEL_BASE_URL is not a valid URL")
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
		return nil
	case "http":
		if strings.EqualFold(appEnv, "production") {
			return fmt.Errorf("agent: APP_ENV=production requires an https AGENT_MODEL_BASE_URL (host %s)", u.Host)
		}
		return nil
	}
	return fmt.Errorf("agent: AGENT_MODEL_BASE_URL must use http or https")
}

// CheckEndpoint performs a best-effort GET {base}/models and returns a
// host-only warning string, or "" when the endpoint is reachable and, if model
// is non-empty, lists it. It never returns the API key or the full URL.
func CheckEndpoint(ctx context.Context, cfg ClientConfig, httpClient *http.Client) string {
	u, err := url.Parse(cfg.BaseURL)
	if err != nil || u.Host == "" {
		return "agent: model endpoint URL is invalid"
	}
	host := u.Host // excludes any userinfo
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 5 * time.Second}
	}
	target := strings.TrimRight(cfg.BaseURL, "/") + "/models"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return fmt.Sprintf("agent: model endpoint check could not build request for host %s", host)
	}
	if cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Sprintf("agent: model endpoint host %s unreachable at startup (continuing)", host)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Sprintf("agent: model endpoint host %s returned HTTP %d for /models (continuing)", host, resp.StatusCode)
	}
	buf := make([]byte, 256*1024)
	n, _ := resp.Body.Read(buf)
	for n < len(buf) {
		m, rerr := resp.Body.Read(buf[n:])
		n += m
		if rerr != nil {
			break
		}
	}
	if cfg.Model != "" && !strings.Contains(string(buf[:n]), `"`+cfg.Model+`"`) {
		return fmt.Sprintf("agent: model %q not listed by endpoint host %s /models (continuing)", cfg.Model, host)
	}
	return ""
}

// turnCompleter is implemented by clients that support per-turn timeouts
// (*Client). Other ModelClient implementations (e.g. test fakes) fall back to
// plain Complete.
type turnCompleter interface {
	CompleteFor(ctx context.Context, turn TurnType, messages []Message) (string, error)
}

func completeFor(ctx context.Context, mc ModelClient, turn TurnType, messages []Message) (string, error) {
	if tc, ok := mc.(turnCompleter); ok {
		return tc.CompleteFor(ctx, turn, messages)
	}
	return mc.Complete(ctx, messages)
}
