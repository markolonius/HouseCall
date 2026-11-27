// Package agent — RelayOutcome and parseRelayTurn classify one raw model turn
// produced during a PLAN_DELIVERED relay turn (Task 4.1). See prompt.go for
// RelaySystemPrompt and NewComplaintMarker, and
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Post-Approval Plan Relay".
package agent

import "strings"

// RelayOutcome is the result of classifying one raw model turn from a
// PLAN_DELIVERED relay turn. It is a value type with no I/O and no logging —
// mirroring InterviewOutcome's discipline (see interview_outcome.go) — so it
// is safe to use anywhere, including the hot path where PHI would otherwise
// leak through logs.
//
// The spec describes three patient-facing scenarios: explaining the
// delivered plan, deferring a question the plan doesn't cover, and reopening
// intake for a new complaint. The first two collapse into a single parser
// outcome deliberately: both are just the model's free-text reply — an
// explanation grounded in the delivered plan, or the fixed-style deferral
// sentence — and the choice between them is entirely prompt-driven behaviour
// (RelaySystemPrompt rules 1-2), not something the parser needs to
// distinguish. Only the new-complaint scenario changes server-side control
// flow (a care-phase transition back to INTAKE), so it is the only one that
// needs a machine-readable marker. This gives RelayOutcome exactly two
// states, matching design.md's binary framing ("A message raising a new
// complaint... reopens intake"):
//
//   - NewComplaint == true  → the patient described a new, plan-unrelated
//     complaint; the caller should transition the conversation back to
//     INTAKE and run an interview turn instead of delivering Text. Text is
//     always empty in this state.
//   - NewComplaint == false → deliver Text to the patient as the relay reply
//     (an explanation or a deferral — indistinguishable at the parser level
//     by design; see above).
type RelayOutcome struct {
	// NewComplaint is true when the model detected (and signalled via
	// NewComplaintMarker) that the patient's message describes a new medical
	// complaint unrelated to the delivered plan.
	NewComplaint bool

	// Text is the trimmed relay reply to deliver to the patient. It is
	// non-empty only when NewComplaint is false. When NewComplaint is true,
	// Text is always "".
	Text string
}

// parseRelayTurn inspects the raw model output from one PLAN_DELIVERED relay
// turn and classifies it as either a new-complaint signal or a relay reply.
//
// If raw contains NewComplaintMarker (the constant defined in prompt.go), the
// turn is treated as a new-complaint signal: the function returns
// RelayOutcome{NewComplaint: true} and discards all text — neither the marker
// nor any prefix or suffix text is returned as Text. This mirrors
// parseInterviewTurn's handling of ReadyForNoteMarker exactly: the marker is
// a server-internal protocol token that must never reach the patient, and any
// partial reply text the model emitted around it is discarded rather than
// partially delivered.
//
// The check is tolerant of surrounding whitespace and newlines: it uses
// strings.Contains against the unmodified raw string, so the marker is
// detected whether it appears on its own line, at the start, at the end, or
// embedded in surrounding whitespace or markdown decoration around it —
// matching parseInterviewTurn's robustness contract.
//
// If raw does not contain NewComplaintMarker, the trimmed raw text is
// returned as Text (the relay reply — explanation or deferral, both plain
// text driven entirely by RelaySystemPrompt).
//
// Constraints: pure function, no I/O, no logging. raw is never written to any
// log or audit trail (PHI constraint).
func parseRelayTurn(raw string) RelayOutcome {
	if strings.Contains(raw, NewComplaintMarker) {
		return RelayOutcome{NewComplaint: true}
	}
	return RelayOutcome{Text: strings.TrimSpace(raw)}
}
