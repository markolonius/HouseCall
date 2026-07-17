// Package agent — unit tests for parseRelayTurn (Task 4.1).
//
// All tests in this file are pure: no DB, no model client, no I/O. They
// exercise marker-parsing mechanics only — never model output quality or
// content — mirroring interview_outcome_test.go's discipline for
// parseInterviewTurn.
package agent

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Scenario: the agent explains the delivered plan (normal reply, no marker)
// ---------------------------------------------------------------------------

// TestParseRelayTurn_Explain_NoMarker_TextReturned verifies that a plain
// explanatory reply with no marker is returned as Text with NewComplaint
// false.
func TestParseRelayTurn_Explain_NoMarker_TextReturned(t *testing.T) {
	const wantText = "Twice daily means once in the morning and once in the evening, as your physician outlined in your plan."
	raw := "  " + wantText + "  "
	got := parseRelayTurn(raw)
	if got.NewComplaint {
		t.Errorf("NewComplaint = true, want false for a normal explanation")
	}
	if got.Text != wantText {
		t.Errorf("Text = %q, want %q", got.Text, wantText)
	}
}

// ---------------------------------------------------------------------------
// Scenario: questions beyond the plan are deferred
// ---------------------------------------------------------------------------
//
// Deferral is a content-level, prompt-driven behaviour (RelaySystemPrompt
// rule 2) — not a distinct parser outcome. The deferral sentence is just
// another Text value with NewComplaint false, so it exercises the exact same
// parser path as TestParseRelayTurn_Explain_NoMarker_TextReturned. This test
// exists to document that choice and confirm the deferral sentence survives
// the parser unmodified.

// TestParseRelayTurn_Defer_NoMarker_TextReturned verifies that the fixed
// deferral sentence the prompt instructs the model to use is returned as
// plain Text — deferral is not a separate RelayOutcome state.
func TestParseRelayTurn_Defer_NoMarker_TextReturned(t *testing.T) {
	const wantText = "That's a question for your physician — I can pass it along."
	got := parseRelayTurn(wantText)
	if got.NewComplaint {
		t.Errorf("NewComplaint = true, want false for a deferral reply")
	}
	if got.Text != wantText {
		t.Errorf("Text = %q, want %q", got.Text, wantText)
	}
}

// ---------------------------------------------------------------------------
// Scenario: a new complaint reopens intake (marker detected)
// ---------------------------------------------------------------------------

// TestParseRelayTurn_MarkerAlone verifies that a raw string consisting only
// of NewComplaintMarker (with whitespace trimmed) returns NewComplaint true
// and an empty Text.
func TestParseRelayTurn_MarkerAlone(t *testing.T) {
	raw := NewComplaintMarker
	got := parseRelayTurn(raw)
	if !got.NewComplaint {
		t.Errorf("NewComplaint = false, want true for raw = %q", raw)
	}
	if got.Text != "" {
		t.Errorf("Text = %q, want \"\" when NewComplaint is true", got.Text)
	}
}

// TestParseRelayTurn_MarkerOnOwnLineAfterText verifies that when the model
// emits some text followed by a newline and then the marker, the result is
// NewComplaint true with no text — the text before the marker is discarded.
func TestParseRelayTurn_MarkerOnOwnLineAfterText(t *testing.T) {
	raw := "I also have a new rash on my arm that started today.\n" + NewComplaintMarker
	got := parseRelayTurn(raw)
	if !got.NewComplaint {
		t.Errorf("NewComplaint = false, want true; raw = %q", raw)
	}
	if got.Text != "" {
		t.Errorf("Text = %q, want \"\" — pre-marker text must be discarded", got.Text)
	}
}

// TestParseRelayTurn_MarkerWithTrailingText verifies that text after the
// marker is also discarded: NewComplaint is true and Text is empty.
func TestParseRelayTurn_MarkerWithTrailingText(t *testing.T) {
	raw := NewComplaintMarker + "\nSome additional text the model appended."
	got := parseRelayTurn(raw)
	if !got.NewComplaint {
		t.Errorf("NewComplaint = false, want true; raw = %q", raw)
	}
	if got.Text != "" {
		t.Errorf("Text = %q, want \"\" — trailing text must be discarded", got.Text)
	}
}

// TestParseRelayTurn_MarkerEmbeddedBothSides verifies that a marker embedded
// between a preamble and trailing content is still detected; all text is
// discarded and NewComplaint is true.
func TestParseRelayTurn_MarkerEmbeddedBothSides(t *testing.T) {
	raw := "Some prefix text.\n" + NewComplaintMarker + "\nSome trailing text."
	got := parseRelayTurn(raw)
	if !got.NewComplaint {
		t.Errorf("NewComplaint = false, want true; raw = %q", raw)
	}
	if got.Text != "" {
		t.Errorf("Text = %q, want \"\"", got.Text)
	}
}

// ---------------------------------------------------------------------------
// Robustness to minor formatting variance (whitespace, markdown wrapping) —
// see soap_robustness_test.go's pattern for parseSOAPSections.
// ---------------------------------------------------------------------------

// TestParseRelayTurn_WhitespaceSurroundingMarker verifies that the marker is
// detected even when it is surrounded by whitespace characters (spaces,
// newlines, tabs).
func TestParseRelayTurn_WhitespaceSurroundingMarker(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"leading spaces", "   " + NewComplaintMarker},
		{"trailing spaces", NewComplaintMarker + "   "},
		{"leading newline", "\n" + NewComplaintMarker},
		{"trailing newline", NewComplaintMarker + "\n"},
		{"tabs and newlines", "\t\n  " + NewComplaintMarker + "  \t\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseRelayTurn(tc.raw)
			if !got.NewComplaint {
				t.Errorf("NewComplaint = false, want true; raw = %q", tc.raw)
			}
			if got.Text != "" {
				t.Errorf("Text = %q, want \"\"", got.Text)
			}
		})
	}
}

// TestParseRelayTurn_MarkerWithMarkdownWrapping verifies that the marker is
// still detected when the model wraps it in markdown decoration (bold,
// backticks) rather than emitting it verbatim, matching the tolerance the
// interview marker parser affords via plain strings.Contains matching.
func TestParseRelayTurn_MarkerWithMarkdownWrapping(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"bold wrapped", "**" + NewComplaintMarker + "**"},
		{"backtick wrapped", "`" + NewComplaintMarker + "`"},
		{"preceded by bullet", "- " + NewComplaintMarker},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseRelayTurn(tc.raw)
			if !got.NewComplaint {
				t.Errorf("NewComplaint = false, want true; raw = %q", tc.raw)
			}
			if got.Text != "" {
				t.Errorf("Text = %q, want \"\"", got.Text)
			}
		})
	}
}

// TestParseRelayTurn_MarkerConstantUsed verifies that the check is driven by
// the NewComplaintMarker constant and not a hardcoded literal: a string that
// contains NewComplaintMarker (built from the constant) must be detected, and
// a string that replaces the angle brackets with different delimiters must
// not — matching parseInterviewTurn's equivalent guard.
func TestParseRelayTurn_MarkerConstantUsed(t *testing.T) {
	// Built from the constant — must be detected.
	rawWithMarker := "Some text\n" + NewComplaintMarker + "\n"
	if got := parseRelayTurn(rawWithMarker); !got.NewComplaint {
		t.Errorf("expected NewComplaint true for string built with NewComplaintMarker constant")
	}

	// Different delimiters — must NOT be detected.
	mangled := strings.ReplaceAll(NewComplaintMarker, "<", "[")
	mangled = strings.ReplaceAll(mangled, ">", "]")
	if got := parseRelayTurn(mangled); got.NewComplaint {
		t.Errorf("expected NewComplaint false for mangled marker %q", mangled)
	}
}

// TestParseRelayTurn_EmptyString verifies that an empty raw string returns
// NewComplaint false with an empty Text (not a panic).
func TestParseRelayTurn_EmptyString(t *testing.T) {
	got := parseRelayTurn("")
	if got.NewComplaint {
		t.Error("NewComplaint = true, want false for empty string")
	}
	if got.Text != "" {
		t.Errorf("Text = %q, want \"\" for empty string", got.Text)
	}
}

// TestParseRelayTurn_NoMarker_WhitespaceTrimmed verifies that leading and
// trailing whitespace (including newlines) is stripped from the returned Text
// when no marker is present.
func TestParseRelayTurn_NoMarker_WhitespaceTrimmed(t *testing.T) {
	const inner = "Your plan says to rest and stay hydrated for the next 48 hours."
	raw := "\n\t  " + inner + "  \n\t"
	got := parseRelayTurn(raw)
	if got.NewComplaint {
		t.Error("NewComplaint = true, want false")
	}
	if got.Text != inner {
		t.Errorf("Text = %q, want %q (whitespace not trimmed)", got.Text, inner)
	}
}
