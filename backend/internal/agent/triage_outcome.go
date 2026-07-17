// Package agent — TriageOutcome and parseTriageTurn classify one raw model
// turn produced by the red-flag triage classification call (Task 5.1). See
// prompt.go for TriageSystemPrompt, EmergentMarker, and RoutineMarker, and
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Red-Flag Triage".
package agent

import "strings"

// TriageOutcome is the result of classifying one raw model turn from the
// triage classification call. It is a value type with no I/O and no
// logging — mirroring InterviewOutcome's and RelayOutcome's discipline (see
// interview_outcome.go, relay_outcome.go) — so it is safe to use anywhere,
// including the hot path where PHI would otherwise leak through logs.
//
// Unlike InterviewOutcome and RelayOutcome, which each collapse to a binary
// "marker present vs. free text" choice, TriageOutcome is a strict
// three-state classification:
//
//   - TriageEmergent    → the model classified the patient's most recent
//     message as an emergency presentation. The caller (Task 5.2) must
//     suppress the normal interview turn and deliver the fixed
//     emergency-referral message and urgent physician notification instead.
//   - TriageRoutine      → the model classified the message as non-emergent.
//     The caller proceeds with the normal interview turn. No audit event is
//     written for this state — it is the expected, common case.
//   - TriageUnparseable  → the raw output contained neither marker, or
//     contained BOTH markers (ambiguous). This is deliberately a distinct
//     state from TriageRoutine, not a default/fallback folded into it: per
//     design.md ("Classifier unavailable or unparseable → fail open to the
//     normal interview turn"), the caller must fail open to the interview
//     turn AND write an ai_interaction_failed audit event recording the
//     triage failure. A TriageRoutine result never writes that audit event.
//     Collapsing this into TriageRoutine would silently lose that audit
//     trail and make a triage-classifier malfunction indistinguishable from
//     a working classifier that judged the message routine.
type TriageOutcome int

const (
	// TriageUnparseable means parseTriageTurn could not find exactly one of
	// EmergentMarker or RoutineMarker in the raw output — either neither
	// marker was present, or both were (ambiguous). Callers must fail open
	// to the normal interview turn and write an ai_interaction_failed audit
	// event; see the TriageOutcome doc comment for why this must remain
	// distinguishable from TriageRoutine.
	TriageUnparseable TriageOutcome = iota

	// TriageEmergent means the model classified the patient's most recent
	// message as an emergency presentation (EmergentMarker was present and
	// RoutineMarker was not).
	TriageEmergent

	// TriageRoutine means the model classified the patient's most recent
	// message as non-emergent (RoutineMarker was present and EmergentMarker
	// was not).
	TriageRoutine
)

// parseTriageTurn inspects the raw model output from one triage
// classification turn and returns the strict three-state classification
// described in TriageOutcome's doc comment.
//
// Detection is tolerant of surrounding whitespace and minor formatting
// variance (markdown wrapping, surrounding prose) the same way
// parseInterviewTurn and parseRelayTurn are: it uses strings.Contains against
// the unmodified raw string, so a marker is detected whether it appears
// alone, on its own line, or embedded in extra text around it. This
// tolerance exists purely to absorb small-model formatting noise around the
// TriageSystemPrompt's strict "marker and nothing else" instruction — it does
// NOT relax the classification contract itself: if raw contains neither
// EmergentMarker nor RoutineMarker, or contains both (an internally
// inconsistent response), the result is TriageUnparseable rather than a
// guess in either direction. This is the discipline TriageSystemPrompt
// documents: a strict binary marker output is required precisely because
// this string is parsed programmatically and never shown to anyone, so there
// is no reason to attempt free-text inference the way a patient-facing turn
// might.
//
// Constraints: pure function, no I/O, no logging. raw is never written to any
// log or audit trail (PHI constraint).
func parseTriageTurn(raw string) TriageOutcome {
	hasEmergent := strings.Contains(raw, EmergentMarker)
	hasRoutine := strings.Contains(raw, RoutineMarker)
	switch {
	case hasEmergent && hasRoutine:
		// Ambiguous — the model emitted both markers in the same turn. Do not
		// guess; treat this the same as no marker at all.
		return TriageUnparseable
	case hasEmergent:
		return TriageEmergent
	case hasRoutine:
		return TriageRoutine
	default:
		return TriageUnparseable
	}
}
