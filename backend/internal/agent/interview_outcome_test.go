// Package agent — unit tests for parseInterviewTurn and decideInterviewAction
// (Task 1.3).
//
// All tests in this file are pure: no DB, no model client, no I/O. They use
// the internal package access of "package agent" to reach unexported helpers.
package agent

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Tests: parseInterviewTurn
// ---------------------------------------------------------------------------

// TestParseInterviewTurn_MarkerAlone verifies that a raw string consisting only
// of ReadyForNoteMarker (with whitespace trimmed) returns ReadyForNote true and
// an empty Question.
func TestParseInterviewTurn_MarkerAlone(t *testing.T) {
	raw := ReadyForNoteMarker
	got := parseInterviewTurn(raw)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true for raw = %q", raw)
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\" when ReadyForNote is true", got.Question)
	}
}

// TestParseInterviewTurn_MarkerOnOwnLineAfterQuestion verifies that when the
// model emits some text followed by a newline and then the marker, the result is
// ReadyForNote true with no question — the text before the marker is discarded.
func TestParseInterviewTurn_MarkerOnOwnLineAfterQuestion(t *testing.T) {
	raw := "Do you have any known allergies?\n" + ReadyForNoteMarker
	got := parseInterviewTurn(raw)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true; raw = %q", raw)
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\" — pre-marker text must be discarded", got.Question)
	}
}

// TestParseInterviewTurn_MarkerWithTrailingText verifies that text after the
// marker is also discarded: ReadyForNote is true and Question is empty.
func TestParseInterviewTurn_MarkerWithTrailingText(t *testing.T) {
	raw := ReadyForNoteMarker + "\nSome additional text the model appended."
	got := parseInterviewTurn(raw)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true; raw = %q", raw)
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\" — trailing text must be discarded", got.Question)
	}
}

// TestParseInterviewTurn_MarkerEmbeddedBothSides verifies that marker embedded
// between a preamble and trailing content is still detected; all text is
// discarded and ReadyForNote is true.
func TestParseInterviewTurn_MarkerEmbeddedBothSides(t *testing.T) {
	raw := "Some prefix text.\n" + ReadyForNoteMarker + "\nSome trailing text."
	got := parseInterviewTurn(raw)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true; raw = %q", raw)
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\"", got.Question)
	}
}

// TestParseInterviewTurn_NoMarker_QuestionReturned verifies that when the raw
// string contains no marker, ReadyForNote is false and Question equals the
// trimmed raw text.
func TestParseInterviewTurn_NoMarker_QuestionReturned(t *testing.T) {
	const wantQ = "How would you rate the pain on a scale of 0 to 10?"
	raw := "  " + wantQ + "  "
	got := parseInterviewTurn(raw)
	if got.ReadyForNote {
		t.Errorf("ReadyForNote = true, want false for a normal question")
	}
	if got.Question != wantQ {
		t.Errorf("Question = %q, want %q", got.Question, wantQ)
	}
}

// TestParseInterviewTurn_NoMarker_WhitespaceTrimmed verifies that leading and
// trailing whitespace (including newlines) is stripped from the returned Question
// when no marker is present.
func TestParseInterviewTurn_NoMarker_WhitespaceTrimmed(t *testing.T) {
	const inner = "When did the pain start?"
	raw := "\n\t  " + inner + "  \n\t"
	got := parseInterviewTurn(raw)
	if got.ReadyForNote {
		t.Error("ReadyForNote = true, want false")
	}
	if got.Question != inner {
		t.Errorf("Question = %q, want %q (whitespace not trimmed)", got.Question, inner)
	}
}

// TestParseInterviewTurn_WhitespaceSurroundingMarker verifies that the marker is
// detected even when it is surrounded by whitespace characters (spaces, newlines,
// tabs), matching the tolerance requirement.
func TestParseInterviewTurn_WhitespaceSurroundingMarker(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"leading spaces", "   " + ReadyForNoteMarker},
		{"trailing spaces", ReadyForNoteMarker + "   "},
		{"leading newline", "\n" + ReadyForNoteMarker},
		{"trailing newline", ReadyForNoteMarker + "\n"},
		{"tabs and newlines", "\t\n  " + ReadyForNoteMarker + "  \t\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseInterviewTurn(tc.raw)
			if !got.ReadyForNote {
				t.Errorf("ReadyForNote = false, want true; raw = %q", tc.raw)
			}
			if got.Question != "" {
				t.Errorf("Question = %q, want \"\"", got.Question)
			}
		})
	}
}

// TestParseInterviewTurn_MarkerConstantUsed verifies that the check is driven by
// the ReadyForNoteMarker constant and not a hardcoded literal: a string that
// contains ReadyForNoteMarker (built from the constant) must be detected, and
// a string that replaces the angle brackets with different delimiters must not.
func TestParseInterviewTurn_MarkerConstantUsed(t *testing.T) {
	// Built from the constant — must be detected.
	rawWithMarker := "Some text\n" + ReadyForNoteMarker + "\n"
	if got := parseInterviewTurn(rawWithMarker); !got.ReadyForNote {
		t.Errorf("expected ReadyForNote true for string built with ReadyForNoteMarker constant")
	}

	// Different delimiters — must NOT be detected.
	mangled := strings.ReplaceAll(ReadyForNoteMarker, "<", "[")
	mangled = strings.ReplaceAll(mangled, ">", "]")
	if got := parseInterviewTurn(mangled); got.ReadyForNote {
		t.Errorf("expected ReadyForNote false for mangled marker %q", mangled)
	}
}

// TestParseInterviewTurn_EmptyString verifies that an empty raw string returns
// ReadyForNote false with an empty Question (not a panic).
func TestParseInterviewTurn_EmptyString(t *testing.T) {
	got := parseInterviewTurn("")
	if got.ReadyForNote {
		t.Error("ReadyForNote = true, want false for empty string")
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\" for empty string", got.Question)
	}
}

// ---------------------------------------------------------------------------
// Tests: decideInterviewAction
// ---------------------------------------------------------------------------

// TestDecideInterviewAction_MarkerWins_BelowCap verifies that when the model
// emits ReadyForNoteMarker, the outcome is ReadyForNote regardless of whether
// the turn cap has been reached (marker has highest precedence).
func TestDecideInterviewAction_MarkerWins_BelowCap(t *testing.T) {
	// priorMsgs has only 1 assistant turn — well below DefaultMaxInterviewTurns.
	priorMsgs := makeTestMessages("user", "assistant")
	raw := ReadyForNoteMarker
	got := decideInterviewAction(raw, priorMsgs, DefaultMaxInterviewTurns)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true when marker present")
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\"", got.Question)
	}
}

// TestDecideInterviewAction_MarkerWins_AtCap verifies that the marker still wins
// when the cap would independently force a draft (both are ReadyForNote true, but
// the code takes the marker path first).
func TestDecideInterviewAction_MarkerWins_AtCap(t *testing.T) {
	// Exactly DefaultMaxInterviewTurns assistant turns.
	roles := make([]string, DefaultMaxInterviewTurns*2)
	for i := range roles {
		if i%2 == 0 {
			roles[i] = "user"
		} else {
			roles[i] = "assistant"
		}
	}
	priorMsgs := makeTestMessages(roles...)
	raw := "Good to know.\n" + ReadyForNoteMarker
	got := decideInterviewAction(raw, priorMsgs, DefaultMaxInterviewTurns)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true")
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\"", got.Question)
	}
}

// TestDecideInterviewAction_CapForcesDraft verifies that when the turn cap is
// reached and the model did NOT emit the marker, the outcome is still
// ReadyForNote true (forced draft) with an empty Question.
func TestDecideInterviewAction_CapForcesDraft(t *testing.T) {
	// Exactly DefaultMaxInterviewTurns assistant turns, no marker.
	roles := make([]string, DefaultMaxInterviewTurns*2)
	for i := range roles {
		if i%2 == 0 {
			roles[i] = "user"
		} else {
			roles[i] = "assistant"
		}
	}
	priorMsgs := makeTestMessages(roles...)
	const raw = "Do you have a family history of diabetes?"
	got := decideInterviewAction(raw, priorMsgs, DefaultMaxInterviewTurns)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true when cap reached without marker")
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\" on forced draft", got.Question)
	}
}

// TestDecideInterviewAction_CapForcesDraft_AboveCap verifies that exceeding the
// cap also forces a draft (not just reaching it exactly).
func TestDecideInterviewAction_CapForcesDraft_AboveCap(t *testing.T) {
	// DefaultMaxInterviewTurns + 2 assistant turns.
	count := DefaultMaxInterviewTurns + 2
	roles := make([]string, count*2)
	for i := range roles {
		if i%2 == 0 {
			roles[i] = "user"
		} else {
			roles[i] = "assistant"
		}
	}
	priorMsgs := makeTestMessages(roles...)
	got := decideInterviewAction("Are you on any medication?", priorMsgs, DefaultMaxInterviewTurns)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true when above cap")
	}
	if got.Question != "" {
		t.Errorf("Question = %q, want \"\"", got.Question)
	}
}

// TestDecideInterviewAction_NormalQuestion verifies the non-terminal path: no
// marker, cap not reached → ReadyForNote false, Question is the trimmed model
// output.
func TestDecideInterviewAction_NormalQuestion(t *testing.T) {
	// 2 assistant turns, cap is 12 → well below.
	priorMsgs := makeTestMessages("user", "assistant", "user", "assistant")
	const wantQ = "On a scale of 0 to 10, how severe is the pain?"
	raw := "  " + wantQ + "\n"
	got := decideInterviewAction(raw, priorMsgs, DefaultMaxInterviewTurns)
	if got.ReadyForNote {
		t.Errorf("ReadyForNote = true, want false for normal question below cap")
	}
	if got.Question != wantQ {
		t.Errorf("Question = %q, want %q", got.Question, wantQ)
	}
}

// TestDecideInterviewAction_EmptyPriorMsgs_NormalQuestion verifies that with no
// prior messages and no marker, a normal question is returned.
func TestDecideInterviewAction_EmptyPriorMsgs_NormalQuestion(t *testing.T) {
	const wantQ = "What brings you in today?"
	got := decideInterviewAction(wantQ, nil, DefaultMaxInterviewTurns)
	if got.ReadyForNote {
		t.Errorf("ReadyForNote = true, want false for first turn with no marker")
	}
	if got.Question != wantQ {
		t.Errorf("Question = %q, want %q", got.Question, wantQ)
	}
}

// TestDecideInterviewAction_CustomMaxTurns verifies that a caller-supplied
// maxTurns different from DefaultMaxInterviewTurns is respected.
func TestDecideInterviewAction_CustomMaxTurns(t *testing.T) {
	const customMax = 2
	// 2 assistant turns → cap reached with customMax=2.
	priorMsgs := makeTestMessages("user", "assistant", "user", "assistant")
	got := decideInterviewAction("Anything else you'd like to mention?", priorMsgs, customMax)
	if !got.ReadyForNote {
		t.Errorf("ReadyForNote = false, want true: 2 assistant turns at customMax=2")
	}
	// Same history but cap=3 → not yet reached.
	got2 := decideInterviewAction("Anything else you'd like to mention?", priorMsgs, 3)
	if got2.ReadyForNote {
		t.Errorf("ReadyForNote = true, want false: 2 assistant turns below cap=3")
	}
}

// TestDecideInterviewAction_OneBelowCap_NormalQuestion verifies the boundary:
// one turn below the cap and no marker → continue interviewing.
func TestDecideInterviewAction_OneBelowCap_NormalQuestion(t *testing.T) {
	// DefaultMaxInterviewTurns - 1 assistant turns.
	count := DefaultMaxInterviewTurns - 1
	roles := make([]string, count*2)
	for i := range roles {
		if i%2 == 0 {
			roles[i] = "user"
		} else {
			roles[i] = "assistant"
		}
	}
	priorMsgs := makeTestMessages(roles...)
	const wantQ = "Do you smoke or use tobacco products?"
	got := decideInterviewAction(wantQ, priorMsgs, DefaultMaxInterviewTurns)
	if got.ReadyForNote {
		t.Errorf("ReadyForNote = true, want false: one turn below cap, no marker")
	}
	if got.Question != wantQ {
		t.Errorf("Question = %q, want %q", got.Question, wantQ)
	}
}
