// Package agent — unit tests for parseTriageTurn (Task 5.1).
//
// All tests in this file are pure: no DB, no model client, no I/O. They
// exercise marker-parsing mechanics only — never model output quality or
// content — mirroring interview_outcome_test.go's and relay_outcome_test.go's
// discipline for their respective parsers.
package agent

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Scenario: an emergent message short-circuits the interview
// ---------------------------------------------------------------------------

// TestParseTriageTurn_EmergentMarkerAlone verifies that a raw string
// consisting only of EmergentMarker (with whitespace trimmed) classifies as
// TriageEmergent.
func TestParseTriageTurn_EmergentMarkerAlone(t *testing.T) {
	got := parseTriageTurn(EmergentMarker)
	if got != TriageEmergent {
		t.Errorf("parseTriageTurn(%q) = %v, want TriageEmergent", EmergentMarker, got)
	}
}

// TestParseTriageTurn_RoutineMarkerAlone verifies that a raw string
// consisting only of RoutineMarker (with whitespace trimmed) classifies as
// TriageRoutine.
func TestParseTriageTurn_RoutineMarkerAlone(t *testing.T) {
	got := parseTriageTurn(RoutineMarker)
	if got != TriageRoutine {
		t.Errorf("parseTriageTurn(%q) = %v, want TriageRoutine", RoutineMarker, got)
	}
}

// ---------------------------------------------------------------------------
// Scenario: triage failure fails open to the interview (unparseable output)
// ---------------------------------------------------------------------------

// TestParseTriageTurn_Garbage verifies that output containing neither marker
// classifies as TriageUnparseable — this is the case the caller (Task 5.2)
// must fail open on and write an ai_interaction_failed audit event for.
func TestParseTriageTurn_Garbage(t *testing.T) {
	cases := []string{
		"",
		"I'm not sure how to classify this.",
		"EMERGENT",           // no angle brackets — not the real marker
		"<emergent>",         // wrong case, not tolerated as a distinct marker form
		"[EMERGENT]",         // different delimiters
		"The patient seems fine to me.",
	}
	for _, raw := range cases {
		t.Run(raw, func(t *testing.T) {
			got := parseTriageTurn(raw)
			if got != TriageUnparseable {
				t.Errorf("parseTriageTurn(%q) = %v, want TriageUnparseable", raw, got)
			}
		})
	}
}

// TestParseTriageTurn_BothMarkersPresent verifies that a raw output
// containing BOTH EmergentMarker and RoutineMarker is treated as
// TriageUnparseable — an internally inconsistent response must not be
// resolved by a coin flip or precedence rule; it must fail open the same as
// no marker at all.
func TestParseTriageTurn_BothMarkersPresent(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"emergent then routine", EmergentMarker + "\n" + RoutineMarker},
		{"routine then emergent", RoutineMarker + "\n" + EmergentMarker},
		{"both on one line", EmergentMarker + " " + RoutineMarker},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseTriageTurn(tc.raw)
			if got != TriageUnparseable {
				t.Errorf("parseTriageTurn(%q) = %v, want TriageUnparseable (ambiguous, must not guess)", tc.raw, got)
			}
		})
	}
}

// TestParseTriageTurn_UnparseableIsDistinctFromRoutine verifies, at the type
// level, that TriageUnparseable and TriageRoutine are genuinely different
// enum values — guarding against a regression that collapses "classifier
// failed" into "classified routine". design.md is explicit that only the
// unparseable/failure path writes ai_interaction_failed; a caller that could
// not tell these two states apart would silently lose that audit trail.
func TestParseTriageTurn_UnparseableIsDistinctFromRoutine(t *testing.T) {
	if TriageUnparseable == TriageRoutine {
		t.Fatal("TriageUnparseable must not equal TriageRoutine")
	}
	if TriageUnparseable == TriageEmergent {
		t.Fatal("TriageUnparseable must not equal TriageEmergent")
	}
	if TriageEmergent == TriageRoutine {
		t.Fatal("TriageEmergent must not equal TriageRoutine")
	}
}

// ---------------------------------------------------------------------------
// Robustness to minor formatting variance (whitespace, markdown wrapping,
// surrounding prose) — see soap_robustness_test.go's and relay_outcome_test's
// pattern.
// ---------------------------------------------------------------------------

// TestParseTriageTurn_WhitespaceSurroundingMarker verifies that a marker is
// detected even when surrounded by whitespace characters (spaces, newlines,
// tabs), for both EMERGENT and ROUTINE.
func TestParseTriageTurn_WhitespaceSurroundingMarker(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want TriageOutcome
	}{
		{"emergent leading spaces", "   " + EmergentMarker, TriageEmergent},
		{"emergent trailing spaces", EmergentMarker + "   ", TriageEmergent},
		{"emergent leading newline", "\n" + EmergentMarker, TriageEmergent},
		{"emergent trailing newline", EmergentMarker + "\n", TriageEmergent},
		{"emergent tabs and newlines", "\t\n  " + EmergentMarker + "  \t\n", TriageEmergent},
		{"routine leading spaces", "   " + RoutineMarker, TriageRoutine},
		{"routine trailing spaces", RoutineMarker + "   ", TriageRoutine},
		{"routine leading newline", "\n" + RoutineMarker, TriageRoutine},
		{"routine trailing newline", RoutineMarker + "\n", TriageRoutine},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseTriageTurn(tc.raw)
			if got != tc.want {
				t.Errorf("parseTriageTurn(%q) = %v, want %v", tc.raw, got, tc.want)
			}
		})
	}
}

// TestParseTriageTurn_MarkerWithMarkdownWrapping verifies that a marker is
// still detected when the model wraps it in markdown decoration (bold,
// backticks) rather than emitting it verbatim — matching the tolerance
// parseInterviewTurn and parseRelayTurn afford via plain strings.Contains
// matching.
func TestParseTriageTurn_MarkerWithMarkdownWrapping(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want TriageOutcome
	}{
		{"emergent bold wrapped", "**" + EmergentMarker + "**", TriageEmergent},
		{"emergent backtick wrapped", "`" + EmergentMarker + "`", TriageEmergent},
		{"routine bold wrapped", "**" + RoutineMarker + "**", TriageRoutine},
		{"routine backtick wrapped", "`" + RoutineMarker + "`", TriageRoutine},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseTriageTurn(tc.raw)
			if got != tc.want {
				t.Errorf("parseTriageTurn(%q) = %v, want %v", tc.raw, got, tc.want)
			}
		})
	}
}

// TestParseTriageTurn_MarkerEmbeddedInProse verifies that a marker embedded
// between a preamble and trailing prose is still detected — small models may
// ignore the "nothing else" instruction and add surrounding text despite the
// strict prompt contract, and the parser must still classify correctly.
func TestParseTriageTurn_MarkerEmbeddedInProse(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want TriageOutcome
	}{
		{
			"emergent with preamble and trailing prose",
			"Based on the conversation, this looks urgent.\n" + EmergentMarker + "\nPlease advise the patient immediately.",
			TriageEmergent,
		},
		{
			"routine with preamble",
			"This does not appear to be an emergency.\n" + RoutineMarker,
			TriageRoutine,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseTriageTurn(tc.raw)
			if got != tc.want {
				t.Errorf("parseTriageTurn(%q) = %v, want %v", tc.raw, got, tc.want)
			}
		})
	}
}

// TestParseTriageTurn_MarkerConstantUsed verifies that detection is driven by
// the EmergentMarker/RoutineMarker constants and not a hardcoded literal: a
// string built from the constant must be detected, and a string that
// replaces the angle brackets with different delimiters must not — matching
// parseInterviewTurn's and parseRelayTurn's equivalent guard.
func TestParseTriageTurn_MarkerConstantUsed(t *testing.T) {
	rawWithMarker := "Some text\n" + EmergentMarker + "\n"
	if got := parseTriageTurn(rawWithMarker); got != TriageEmergent {
		t.Errorf("expected TriageEmergent for string built with EmergentMarker constant, got %v", got)
	}

	mangled := strings.ReplaceAll(EmergentMarker, "<", "[")
	mangled = strings.ReplaceAll(mangled, ">", "]")
	if got := parseTriageTurn(mangled); got != TriageUnparseable {
		t.Errorf("expected TriageUnparseable for mangled marker %q, got %v", mangled, got)
	}
}
