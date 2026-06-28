package agent

import (
	"strings"

	"github.com/markolonius/housecall/backend/internal/store"
)

// InterviewOutcome is the result of classifying one raw model turn. It is a
// value type with no I/O and no logging so it is safe to use anywhere — even
// in the hot path where PHI would otherwise leak through logs.
//
// Exactly one of the two semantic states is true for every turn:
//   - ReadyForNote == true  → the interview is complete; draft the SOAP note
//     now. Question is always empty in this state.
//   - ReadyForNote == false → continue the interview; deliver Question to the
//     patient as the next history-taking question.
type InterviewOutcome struct {
	// ReadyForNote is true when the agent runtime should stop interviewing and
	// switch to SOAP note drafting. This happens either because the model
	// voluntarily emitted ReadyForNoteMarker or because the turn cap was
	// reached (forced draft). Question is always empty when ReadyForNote is true.
	ReadyForNote bool

	// Question is the trimmed interview question to deliver to the patient. It
	// is non-empty only when ReadyForNote is false. When ReadyForNote is true,
	// Question is always "".
	Question string
}

// parseInterviewTurn inspects the raw model output from one interview turn and
// classifies it as either a readiness signal or an interview question.
//
// If raw contains ReadyForNoteMarker (the constant defined in prompt.go), the
// turn is treated as a readiness signal: the function returns
// InterviewOutcome{ReadyForNote: true, Question: ""} and discards all text —
// neither the marker nor any prefix or suffix text is returned as a question.
// This prevents the server-internal marker token from ever being forwarded to
// the patient, and discards any partial question text the model may have emitted
// before or after the marker in the same turn.
//
// The check is tolerant of surrounding whitespace and newlines: it uses
// strings.Contains against the unmodified raw string, so the marker is detected
// whether it appears on its own line, at the start, at the end, or embedded in
// surrounding whitespace.
//
// If raw does not contain ReadyForNoteMarker, the trimmed raw text is returned
// as the interview question.
//
// Constraints: pure function, no I/O, no logging. raw is never written to any
// log or audit trail (PHI constraint).
func parseInterviewTurn(raw string) InterviewOutcome {
	if strings.Contains(raw, ReadyForNoteMarker) {
		return InterviewOutcome{ReadyForNote: true}
	}
	return InterviewOutcome{Question: strings.TrimSpace(raw)}
}

// decideInterviewAction returns whether to draft the SOAP note now — either
// because the model voluntarily signalled readiness or because the turn cap
// was reached — and, when continuing the interview, the question to deliver.
//
// Precedence (highest to lowest):
//
//  1. Model emitted ReadyForNoteMarker → ReadyForNote true (voluntary completion).
//     All marker and surrounding text is discarded; Question is "".
//  2. Turn cap reached (assistant-role turns in priorMsgs >= maxTurns) →
//     ReadyForNote true (forced draft). Question is "" regardless of what the
//     model said. This prevents an interview from running unbounded if the model
//     never emits the marker.
//  3. Neither → ReadyForNote false; the model's trimmed output is returned as
//     Question.
//
// priorMsgs must contain the conversation messages that were present BEFORE this
// turn (i.e., not including the turn being classified). maxTurns is typically
// DefaultMaxInterviewTurns but callers may pass a custom value for testing.
//
// Constraints: pure function, no I/O, no logging. raw is never written to any
// log or audit trail (PHI constraint).
func decideInterviewAction(raw string, priorMsgs []store.Message, maxTurns int) InterviewOutcome {
	outcome := parseInterviewTurn(raw)
	if outcome.ReadyForNote {
		// Rule 1: model voluntarily signalled readiness — highest precedence.
		return outcome
	}
	if interviewTurnCapReached(priorMsgs, maxTurns) {
		// Rule 2: turn cap exhausted — force a draft regardless of the model
		// output. Return a clean ReadyForNote outcome with no question so the
		// caller does not accidentally deliver partial output.
		return InterviewOutcome{ReadyForNote: true}
	}
	// Rule 3: continue the interview with the model's question.
	return outcome
}
