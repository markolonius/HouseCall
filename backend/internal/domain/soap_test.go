package domain_test

import (
	"strings"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
)

func TestValidateSOAPPayload_Valid(t *testing.T) {
	payload := []byte(`{
		"subjective":  "patient reports headache for 3 days",
		"objective":   "none reported",
		"assessment":  "tension headache",
		"plan":        "rest and ibuprofen"
	}`)
	if err := domain.ValidateSOAPPayload(payload); err != nil {
		t.Fatalf("expected valid payload to pass: %v", err)
	}
}

func TestValidateSOAPPayload_InvalidJSON(t *testing.T) {
	if err := domain.ValidateSOAPPayload([]byte(`not json`)); err == nil {
		t.Fatal("expected error for non-JSON payload, got nil")
	}
}

// TestValidateSOAPPayload_MissingSections uses a table-driven approach to
// verify that each missing or empty section is caught individually and that
// the error message names the offending section(s).
func TestValidateSOAPPayload_MissingSections(t *testing.T) {
	cases := []struct {
		name        string
		payload     []byte
		wantMissing []string
	}{
		{
			name:        "missing subjective",
			payload:     []byte(`{"objective":"o","assessment":"a","plan":"p"}`),
			wantMissing: []string{"subjective"},
		},
		{
			name:        "empty subjective",
			payload:     []byte(`{"subjective":"","objective":"o","assessment":"a","plan":"p"}`),
			wantMissing: []string{"subjective"},
		},
		{
			name:        "missing objective",
			payload:     []byte(`{"subjective":"s","assessment":"a","plan":"p"}`),
			wantMissing: []string{"objective"},
		},
		{
			name:        "missing assessment",
			payload:     []byte(`{"subjective":"s","objective":"o","plan":"p"}`),
			wantMissing: []string{"assessment"},
		},
		{
			name:        "missing plan",
			payload:     []byte(`{"subjective":"s","objective":"o","assessment":"a"}`),
			wantMissing: []string{"plan"},
		},
		{
			name:        "missing all four sections",
			payload:     []byte(`{}`),
			wantMissing: []string{"subjective", "objective", "assessment", "plan"},
		},
		{
			name:        "missing assessment and plan",
			payload:     []byte(`{"subjective":"s","objective":"o"}`),
			wantMissing: []string{"assessment", "plan"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := domain.ValidateSOAPPayload(tc.payload)
			if err == nil {
				t.Fatalf("expected validation error, got nil")
			}
			msg := err.Error()
			for _, section := range tc.wantMissing {
				if !strings.Contains(msg, section) {
					t.Errorf("error message %q does not mention missing section %q", msg, section)
				}
			}
		})
	}
}

// TestSOAPPayload_Validate exercises the struct method directly (used by
// callers that already have a decoded struct, e.g. the drafter).
func TestSOAPPayload_Validate(t *testing.T) {
	full := domain.SOAPPayload{
		Subjective: "s",
		Objective:  "o",
		Assessment: "a",
		Plan:       "p",
	}
	if err := full.Validate(); err != nil {
		t.Fatalf("full payload: %v", err)
	}

	empty := domain.SOAPPayload{}
	if err := empty.Validate(); err == nil {
		t.Fatal("empty payload: expected error, got nil")
	}
}

// TestPayloadTypeSOAPNote_Constant ensures the constant value matches the
// database-level payload_type string so prompt + parser + constraint stay
// in sync.
func TestPayloadTypeSOAPNote_Constant(t *testing.T) {
	const want = "soap_note"
	if domain.PayloadTypeSOAPNote != want {
		t.Fatalf("PayloadTypeSOAPNote = %q, want %q", domain.PayloadTypeSOAPNote, want)
	}
}
