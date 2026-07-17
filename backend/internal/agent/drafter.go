package agent

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"regexp"
	"strings"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// DefaultMaxInterviewTurns is the maximum number of assistant-role turns the
// interview is allowed to produce before the runtime must force a SOAP note
// draft. If the model never emits ReadyForNoteMarker the safety cap prevents
// an interview from running indefinitely.
//
// Callers that need a different limit can pass a custom value to
// interviewTurnCapReached; this constant is the production default.
// Enforcement (switching from interview to draft when the cap is reached) is
// wired in Tasks 1.3 and 2.2; this task only defines the constant and the
// pure helper function.
const DefaultMaxInterviewTurns = 12

// soapDraftMaxAttempts is how many times draftSOAPNote re-generates the SOAP
// note when the model returns output that fails section parsing/validation.
// Small local models format the required headers only intermittently, so a few
// fresh generations dramatically raise the success rate without masking a true
// model outage (transport errors are not retried here).
const soapDraftMaxAttempts = 3

// ModelClient is the narrow interface the Drafter needs from the model. Using
// an interface rather than *Client directly lets tests inject a stub without
// standing up a real model endpoint.
type ModelClient interface {
	Complete(ctx context.Context, messages []Message) (string, error)
}

// PhysicianNotifier is the narrow interface the Drafter needs to push
// queue.updated events to connected physicians.
type PhysicianNotifier interface {
	SendToPhysicians(tenantID string, event []byte)
}

// PatientNotifier is the narrow interface the Drafter needs to push
// message.created events to the patient who owns the conversation. The
// event payload carries identifiers only (conversation_id, message_id) —
// never message content (PHI). The iOS client fetches content via its
// authenticated REST channel after receiving the event.
type PatientNotifier interface {
	SendToPatient(tenantID, patientID string, event []byte)
}

// Drafter listens for persisted patient messages and drives the
// DRAFT → PENDING_REVIEW lifecycle for soap_note recommendations.
//
// Threading: DraftAsync dispatches the work to a goroutine so the patient's
// HTTP response is returned immediately; the model call (which may take up to
// DefaultTimeout) runs concurrently. Context cancellation from the originating
// request is NOT propagated — drafting must complete even if the patient
// disconnects. The goroutine uses a background context derived from the store.
type Drafter struct {
	client          ModelClient
	store           *store.Store
	notifier        PhysicianNotifier
	patientNotifier PatientNotifier
	onComplete      func() // optional; called (via defer) when the goroutine exits — tests use this for synchronisation
}

// NewDrafter constructs a Drafter. All four arguments are required.
func NewDrafter(client ModelClient, s *store.Store, notifier PhysicianNotifier, patientNotifier PatientNotifier) *Drafter {
	return &Drafter{client: client, store: s, notifier: notifier, patientNotifier: patientNotifier}
}

// WithOnComplete returns a shallow copy of d with the onComplete hook set.
// The hook is called (via defer) when the goroutine spawned by DraftAsync
// exits — regardless of whether it succeeded, failed, or panicked. Its
// primary use is test synchronisation: tests inject a sync.WaitGroup.Done so
// they can block until the goroutine has fully exited before making assertions
// or returning (preventing races with shared-DB cleanup between tests).
// Production callers use NewDrafter, which leaves the hook nil (no-op).
func (d *Drafter) WithOnComplete(fn func()) *Drafter {
	cp := *d
	cp.onComplete = fn
	return &cp
}

// DraftAsync spawns a goroutine that runs one turn of the care-phase state
// machine for a patient message, dispatching on conv.CarePhase (see
// openspec/changes/add-agent-care-loop/design.md, "Per-phase dispatch
// replaces the single interview path"):
//
//   - INTAKE (and any unrecognized/empty phase, defensively — conversations
//     loaded before the care_phase migration or built by in-memory test
//     fixtures may have a zero-value CarePhase): a cheap red-flag triage
//     classification runs first (see runIntakeTurn); an emergent result
//     short-circuits to a fixed emergency-referral message, otherwise
//     today's interview behaviour proceeds — either delivering the next
//     interview question directly to the patient, or drafting a soap_note
//     recommendation into PENDING_REVIEW for physician review.
//   - AWAITING_REVIEW: no model call and no new recommendation — the
//     conversation already has a draft awaiting physician review. This
//     dispatch branch IS the double-draft guard (task 2.3 fills in the
//     patient-facing acknowledgement).
//   - PLAN_DELIVERED: post-approval plan relay — explains or defers questions
//     about the delivered recommendation, or reopens INTAKE and runs an
//     interview turn when the patient reports a new complaint.
//
// It is fire-and-forget: errors are logged but never returned to the caller.
//
// The caller must not pass a request-scoped context — use context.Background()
// or a long-lived server context so the goroutine is not cancelled when the
// HTTP handler returns.
func (d *Drafter) DraftAsync(tenantID store.TenantID, conv store.Conversation, patient store.Patient) {
	go func() {
		// Signal completion to any test-injected hook. The defer is
		// registered first so it fires last — after the recover() defer
		// has had a chance to handle any panic.
		if d.onComplete != nil {
			defer d.onComplete()
		}

		// Recover from any panic inside the dispatched turn (nil-deref, driver
		// bug, etc.) so a single drafting failure cannot crash the server
		// process. middleware.Recoverer only protects HTTP handler goroutines;
		// fire-and-forget goroutines must manage their own recovery.
		// Log type only — never the recovered value itself, which may echo
		// request content or PHI.
		defer func() {
			if r := recover(); r != nil {
				log.Printf("agent: draft panicked conversation_id=%s: %T", conv.ID, r)
			}
		}()

		ctx := context.Background()
		if err := d.dispatchTurn(ctx, tenantID, conv, patient); err != nil {
			// Log type only — never the error message or body, which may echo
			// request content or PHI (see ModelError.Body HIPAA note in
			// client.go).
			log.Printf("agent: draft failed conversation_id=%s: %T", conv.ID, err)

			// Write the ai_interaction_failed audit event. The metadata contains
			// only identifiers and a coarse reason derived from the error type —
			// no PHI, no model error body, no error message text.
			reason := draftFailureReason(err)
			_, auditErr := d.store.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
				ActorType: string(domain.ActorAgent),
				ActorID:   nil, // agent has no user UUID
				EventType: "ai_interaction_failed",
				Metadata: mustMarshalJSON(map[string]any{
					"conversation_id": conv.ID.String(),
					"patient_id":      patient.ID.String(),
					"reason":          reason,
				}),
			})
			if auditErr != nil {
				// A failed audit write must not crash the goroutine. Log the
				// error type only — never the value, which could echo PHI.
				log.Printf("agent: audit write failed conversation_id=%s: %T", conv.ID, auditErr)
			}
		}
	}()
}

// dispatchTurn is the single entry point DraftAsync's goroutine calls to run
// one turn of the care-phase state machine. It selects the per-phase
// behaviour from conv.CarePhase — see DraftAsync's doc comment for the
// behaviour of each branch.
//
// Dispatching here (rather than inside runInterviewTurn) is deliberate: it is
// the mechanism that prevents a second model call/recommendation while a
// conversation is AWAITING_REVIEW (the double-draft bug this change fixes).
func (d *Drafter) dispatchTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	switch conv.CarePhase {
	case store.CarePhaseAwaitingReview:
		return d.runAwaitingReviewTurn(ctx, tenantID, conv, patient)
	case store.CarePhasePlanDelivered:
		return d.runPlanDeliveredTurn(ctx, tenantID, conv, patient)
	case store.CarePhaseIntake, "":
		// Empty CarePhase is treated as INTAKE defensively: conversations
		// loaded before the care_phase migration backfill, or built by
		// in-memory/older test fixtures that never set the field, must still
		// get the triage-then-interview behaviour rather than silently no-op.
		return d.runIntakeTurn(ctx, tenantID, conv, patient)
	default:
		return d.runIntakeTurn(ctx, tenantID, conv, patient)
	}
}

// runIntakeTurn is the entry point dispatchTurn uses for conversations in
// INTAKE (and the defensive empty/unrecognized-phase fallback). It runs a
// cheap red-flag triage classification on the patient's message BEFORE any
// interview turn — see design.md, "Triage is a separate cheap classification
// call", and openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/
// spec.md, "Red-Flag Triage":
//
//   - The triage Complete() call itself fails (timeout, transport error,
//     non-2xx model response): fail open. Writes an ai_interaction_failed
//     audit event describing the triage failure, then proceeds to
//     runInterviewTurn exactly as if triage had never run. Per design.md:
//     "blocking care on a triage outage is worse" than skipping the screen
//     for one turn — the physician gate that follows the interview is still
//     ahead of the patient either way.
//   - TriageUnparseable (the classifier ran but its output could not be
//     parsed unambiguously — see TriageOutcome's doc comment): the same
//     fail-open behaviour as a Complete() error, with a distinct audit
//     reason ("unparseable") so the two failure modes stay distinguishable
//     in the audit trail.
//   - TriageRoutine: proceeds straight to runInterviewTurn — today's
//     behaviour, unchanged by this method's existence.
//   - TriageEmergent: suppresses the normal interview turn entirely — see
//     runEmergentTurn. No interview-turn model call is made for this
//     patient message.
func (d *Drafter) runIntakeTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	raw, err := d.generateTriageTurn(ctx, tenantID, conv)
	if err != nil {
		// Classifier unavailable: fail open to the interview turn, recording
		// the failure first. draftFailureReason's type-driven mapping keeps
		// this consistent with every other model-failure audit reason in the
		// file — no error message, body, or PHI is inspected.
		d.writeTriageFailureAudit(ctx, tenantID, conv, patient, draftFailureReason(err))
		return d.runInterviewTurn(ctx, tenantID, conv, patient)
	}

	switch parseTriageTurn(raw) {
	case TriageEmergent:
		return d.runEmergentTurn(ctx, tenantID, conv, patient)
	case TriageUnparseable:
		d.writeTriageFailureAudit(ctx, tenantID, conv, patient, "unparseable")
		return d.runInterviewTurn(ctx, tenantID, conv, patient)
	default: // TriageRoutine
		return d.runInterviewTurn(ctx, tenantID, conv, patient)
	}
}

// generateTriageTurn assembles the triage model context for an INTAKE turn:
// TriageSystemPrompt as the sole system message, followed by the full
// tenant-scoped conversation history — the same message-assembly shape as
// generateInterviewTurn and generateRelayTurn, but with no additional
// per-conversation grounding message (triage classification needs neither
// rejection guidance nor delivered-plan content).
//
// No content is logged (PHI constraint). A non-nil error means the
// classifier call itself failed (store read error, timeout, transport error,
// non-2xx model response); the caller (runIntakeTurn) must fail open rather
// than treat the returned string as a classification.
func (d *Drafter) generateTriageTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation) (string, error) {
	msgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return "", err
	}

	modelMsgs := make([]Message, 0, len(msgs)+1)
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: TriageSystemPrompt,
	})
	for _, m := range msgs {
		modelMsgs = append(modelMsgs, Message{
			Role:    m.Role,
			Content: m.Content,
		})
	}

	return d.client.Complete(ctx, modelMsgs)
}

// writeTriageFailureAudit records a triage classification failure — either a
// Complete() call error or an unparseable/ambiguous marker result — as an
// ai_interaction_failed audit event, mirroring the audit write DraftAsync
// performs for every other draft failure. Metadata carries identifiers plus
// a coarse "reason" string and a "stage" marker distinguishing this from a
// whole-turn draft failure — no PHI, no model output, no error message text
// (see draftFailureReason's doc comment for the discipline this reuses).
//
// A failed audit write must not block the fail-open interview turn from
// running, so this method only logs (never returns an error) on its own
// failure — same discipline as the inline audit writes elsewhere in this
// file (e.g. deliverInterviewQuestion, runAwaitingReviewTurn).
func (d *Drafter) writeTriageFailureAudit(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient, reason string) {
	if _, err := d.store.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
		ActorType: string(domain.ActorAgent),
		ActorID:   nil, // agent has no user UUID
		EventType: "ai_interaction_failed",
		Metadata: mustMarshalJSON(map[string]any{
			"conversation_id": conv.ID.String(),
			"patient_id":      patient.ID.String(),
			"reason":          reason,
			"stage":           "triage",
		}),
	}); err != nil {
		log.Printf("agent: audit write failed conversation_id=%s: %T", conv.ID, err)
	}
}

// runEmergentTurn handles the TriageEmergent branch of runIntakeTurn: an
// emergency presentation short-circuits the normal interview entirely. It
// persists the fixed EmergencyReferralMessage — static text, never model
// output, for the same reason ReviewPendingAckMessage and
// ReviewPendingReminderMessage are static (see their doc comments) — emits
// an urgent physician notification, writes an audit event, and pushes the
// referral message to the patient. No interview-turn model call is made for
// this patient message.
//
// Urgent notification shape: reuses the existing "queue.updated" event type
// (additive, not a new event type) with "priority": "urgent" in its data
// payload, so any existing queue.updated consumer keeps working unmodified
// while gaining a way to distinguish this notification from a normal
// drafted-recommendation queue.updated. There is no recommendation_id — a
// triage short-circuit creates no recommendation.
//
// Order guarantee mirrors deliverInterviewQuestion: the message is committed
// and audited before either notifier fires, so neither the patient's client
// nor a physician can ever receive a reference to a message that does not
// yet exist in the DB.
func (d *Drafter) runEmergentTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	// Step 1: persist the fixed emergency-referral message as an
	// assistant-role message so the iOS client can retrieve it via
	// GET /api/conversations/{id}/messages.
	msg, err := d.store.CreateMessage(ctx, tenantID, conv.ID, "assistant", EmergencyReferralMessage)
	if err != nil {
		return err
	}

	// Step 2: write the audit event. Metadata contains identifiers only — no
	// PHI, no message content (the message is fixed text, but the pattern is
	// kept consistent with the rest of the drafter).
	if _, auditErr := d.store.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
		ActorType: string(domain.ActorAgent),
		ActorID:   nil, // agent has no user UUID
		EventType: "agent.emergent_triage",
		Metadata: mustMarshalJSON(map[string]any{
			"conversation_id": conv.ID.String(),
			"patient_id":      patient.ID.String(),
			"message_id":      msg.ID.String(),
		}),
	}); auditErr != nil {
		// A failed audit write must not prevent the referral or the urgent
		// notification from firing — log the error type only (never the
		// value, which could echo PHI) and continue.
		log.Printf("agent: audit write failed conversation_id=%s: %T", conv.ID, auditErr)
	}

	// Step 3: emit the urgent queue.updated variant to physicians AFTER the
	// message is durably committed. Payload carries identifiers plus a
	// priority flag only — no PHI.
	d.notifier.SendToPhysicians(tenantID.String(), mustMarshalJSON(map[string]any{
		"type": "queue.updated",
		"data": map[string]any{
			"conversation_id": conv.ID.String(),
			"priority":        "urgent",
		},
	}))

	// Step 4: push the referral to the patient over WS. The payload is IDs
	// only so no PHI crosses the notification channel; the client fetches
	// content via its authenticated REST endpoint after receiving the event.
	d.patientNotifier.SendToPatient(tenantID.String(), patient.ID.String(), mustMarshalJSON(map[string]any{
		"type": "message.created",
		"data": map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		},
	}))

	return nil
}

// runAwaitingReviewTurn handles a patient message received while the
// conversation's drafted recommendation is still awaiting physician review.
// This is the double-draft fix (bead HouseCall-lkzs, 2026-07-15): dispatchTurn
// already routes AWAITING_REVIEW away from runInterviewTurn, so this method
// makes NO model call and creates NO recommendation — it only tells the
// patient their report is already with the physician.
//
// Order guarantee mirrors deliverInterviewQuestion: the reminder message is
// persisted and audited before the patient notifier fires, so the client can
// never receive a reference to a message that does not yet exist in the DB.
//
// PHI discipline: ReviewPendingReminderMessage is fixed, non-clinical text —
// not model output — so no drafted SOAP content can leak here. Audit metadata
// and the patient WebSocket event contain conversation_id and message_id
// only.
func (d *Drafter) runAwaitingReviewTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	// Step 1: persist the fixed reminder as an assistant-role message so the
	// iOS client can retrieve it via GET /api/conversations/{id}/messages.
	msg, err := d.store.CreateMessage(ctx, tenantID, conv.ID, "assistant", ReviewPendingReminderMessage)
	if err != nil {
		return err
	}

	// Step 2: write the audit event. Metadata contains identifiers only — no
	// PHI, no message content (the message is fixed text, but the pattern is
	// kept consistent with deliverInterviewQuestion / draftSOAPNote's ack).
	if _, auditErr := d.store.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
		ActorType: string(domain.ActorAgent),
		ActorID:   nil, // agent has no user UUID
		EventType: "agent.awaiting_review_reminder",
		Metadata: mustMarshalJSON(map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		}),
	}); auditErr != nil {
		// A failed audit write must not prevent the reminder from being
		// delivered — log the error type only (never the value, which could
		// echo PHI) and continue.
		log.Printf("agent: audit write failed conversation_id=%s: %T", conv.ID, auditErr)
	}

	// Step 3: emit a WebSocket event to the patient — same message.created
	// shape as deliverInterviewQuestion/draftSOAPNote's ack push. The payload
	// is IDs only so no PHI crosses the notification channel; the client
	// fetches content via its authenticated REST endpoint after receiving
	// the event.
	d.patientNotifier.SendToPatient(tenantID.String(), patient.ID.String(), mustMarshalJSON(map[string]any{
		"type": "message.created",
		"data": map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		},
	}))

	return nil
}

// runPlanDeliveredTurn handles a patient message received after the
// conversation's recommendation has been delivered (see
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Post-Approval Plan Relay", and design.md's "Relay grounding is prompt +
// provenance, not a new delivery gate"). It assembles relay context from the
// delivered recommendation's final content plus conversation history, calls
// the model with RelaySystemPrompt, and parses the result with
// parseRelayTurn:
//
//   - NewComplaint == false: the reply (an explanation grounded in the
//     delivered plan, or a fixed-style deferral — both are plain relay text,
//     indistinguishable at this layer by design) is persisted as an
//     assistant message and pushed to the patient. No care-phase transition;
//     the conversation stays in PLAN_DELIVERED.
//   - NewComplaint == true: the conversation transitions PLAN_DELIVERED →
//     INTAKE, and an interview turn runs immediately against the same
//     conversation history (which already includes the patient's
//     new-complaint message) so the interview starts without requiring a
//     further patient message.
//
// Error discipline mirrors runInterviewTurn: a non-nil return means no
// content was delivered to the patient. The caller (DraftAsync) logs the
// error type and writes the ai_interaction_failed audit event — no model
// output or PHI is inspected here.
func (d *Drafter) runPlanDeliveredTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	raw, err := d.generateRelayTurn(ctx, tenantID, conv)
	if err != nil {
		return err
	}

	outcome := parseRelayTurn(raw)

	if outcome.NewComplaint {
		return d.reopenIntakeForNewComplaint(ctx, tenantID, conv, patient)
	}

	return d.deliverRelayReply(ctx, tenantID, conv, patient, outcome.Text)
}

// generateRelayTurn assembles the relay model context for a PLAN_DELIVERED
// turn: RelaySystemPrompt (system role), a second system-role message
// grounding the reply in the most recently delivered recommendation's final
// content (see deliveredPlanContextMessage), followed by the full
// tenant-scoped conversation history — the same message-assembly shape as
// generateInterviewTurn, with the delivered-plan grounding message in place
// of the rejection-guidance message.
//
// No content is logged (PHI constraint). A non-nil error means no usable
// model output was obtained; the caller must not treat the returned string
// as clinical content.
func (d *Drafter) generateRelayTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation) (string, error) {
	// Grounding source: the most recently delivered recommendation for this
	// conversation. Per design.md, relay context is assembled ONLY from this
	// content and the conversation history — nothing else.
	deliveredRec, err := d.store.GetLatestDeliveredRecommendation(ctx, tenantID, conv.ID)
	if err != nil {
		return "", err
	}
	var deliveredContent string
	if deliveredRec.FinalContent != nil {
		deliveredContent = *deliveredRec.FinalContent
	}

	msgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return "", err
	}

	modelMsgs := make([]Message, 0, len(msgs)+2)
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: RelaySystemPrompt,
	})
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: deliveredPlanContextMessage(deliveredContent),
	})
	for _, m := range msgs {
		modelMsgs = append(modelMsgs, Message{
			Role:    m.Role,
			Content: m.Content,
		})
	}

	return d.client.Complete(ctx, modelMsgs)
}

// deliverRelayReply persists a PLAN_DELIVERED relay reply — an explanation
// grounded in the delivered plan, or a fixed-style deferral (see
// RelayOutcome's doc comment for why the two are not distinguished here) —
// as an assistant-role message, writes an audit event with identifiers only
// (no PHI), and emits a WebSocket event to the patient. This does NOT
// transition the conversation's care phase: PLAN_DELIVERED stays
// PLAN_DELIVERED for both the explain and defer scenarios.
//
// Order guarantee mirrors deliverInterviewQuestion: the message is committed
// and audited before the patient notifier fires, so the client can never
// receive a reference to a message that does not yet exist in the DB.
func (d *Drafter) deliverRelayReply(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient, text string) error {
	// Step 1: persist the reply as an assistant-role message so the iOS
	// client can retrieve it via GET /api/conversations/{id}/messages.
	msg, err := d.store.CreateMessage(ctx, tenantID, conv.ID, "assistant", text)
	if err != nil {
		return err
	}

	// Step 2: write the audit event. Metadata contains identifiers only — no
	// PHI, no message content.
	if _, auditErr := d.store.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
		ActorType: string(domain.ActorAgent),
		ActorID:   nil, // agent has no user UUID
		EventType: "agent.relay_reply",
		Metadata: mustMarshalJSON(map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		}),
	}); auditErr != nil {
		// A failed audit write must not prevent the reply from being
		// delivered — log the error type only (never the value, which could
		// echo PHI) and continue.
		log.Printf("agent: audit write failed conversation_id=%s: %T", conv.ID, auditErr)
	}

	// Step 3: emit a WebSocket event to the patient. The payload is IDs only
	// so no PHI crosses the notification channel; the client fetches content
	// via its authenticated REST endpoint after receiving the event.
	d.patientNotifier.SendToPatient(tenantID.String(), patient.ID.String(), mustMarshalJSON(map[string]any{
		"type": "message.created",
		"data": map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		},
	}))

	return nil
}

// reopenIntakeForNewComplaint handles the RelayOutcome.NewComplaint == true
// branch of runPlanDeliveredTurn: it transitions the conversation
// PLAN_DELIVERED → INTAKE and immediately runs an interview turn so the
// patient's new-complaint message — already present in the conversation
// history that generateRelayTurn (and now generateInterviewTurn) read —
// begins being interviewed without requiring a further patient message.
//
// The phase transition and its audit event are written together in a short
// transaction so the audit trail always reflects a durable phase change (the
// same discipline as every other TransitionCarePhase caller in this file).
// TransitionCarePhase's compare-and-swap guard means a racing writer that
// already moved the conversation off PLAN_DELIVERED causes this call to fail
// with store.ErrNotFound, which propagates like any other draft failure —
// no interview turn runs and DraftAsync writes ai_interaction_failed.
func (d *Drafter) reopenIntakeForNewComplaint(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	if err := d.store.Txn(ctx, func(tx *store.TxStore) error {
		if err := tx.TransitionCarePhase(ctx, tenantID, conv.ID, store.CarePhasePlanDelivered, store.CarePhaseIntake); err != nil {
			return err
		}
		return tx.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
			ActorType: string(domain.ActorAgent),
			ActorID:   nil, // agent has no user UUID
			EventType: "agent.new_complaint_reopened_intake",
			Metadata: mustMarshalJSON(map[string]any{
				"conversation_id": conv.ID.String(),
			}),
		})
	}); err != nil {
		return err
	}

	// Run the interview turn against the now-INTAKE conversation. The
	// existing message history already contains the patient's new-complaint
	// message, so this turn is what starts the interview on it — no
	// additional patient message is required.
	conv.CarePhase = store.CarePhaseIntake
	return d.runInterviewTurn(ctx, tenantID, conv, patient)
}

// runInterviewTurn is the synchronous orchestration logic called by
// runIntakeTurn for conversations in INTAKE whose message passed (or failed
// open past) the triage screen. It runs one step of the clinical interview:
//
//   - Generates the next turn from the tenant-scoped conversation history using
//     the clinical interview system prompt.
//   - Loads the prior messages (tenant-scoped) to check the turn cap.
//   - Decides whether the interview is complete (marker detected or cap reached).
//   - If complete: drafts a soap_note recommendation → PENDING_REVIEW and emits
//     queue.updated to the physician. The patient is NOT notified here — clinical
//     Assessment & Plan require physician review before reaching the patient.
//   - If continuing: delivers the interview question to the patient as an
//     assistant message (persisted + WebSocket notification). No recommendation
//     is created for interview questions (non-clinical data collection only).
//
// Delivery carve-out guarantee: interview questions (non-clinical) are the ONLY
// agent output delivered directly to the patient. The soap_note (clinical A/P)
// never reaches the patient without a physician lifecycle transition — enforced
// by this branching logic. There is no code path in this function (or in
// deliverInterviewQuestion) that creates a recommendation or delivers clinical
// content directly.
func (d *Drafter) runInterviewTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	// Generate the next interview turn. The model is called with the clinical
	// interview system prompt followed by the full tenant-scoped conversation
	// history. Content never enters logs or audit (PHI constraint).
	raw, err := d.generateInterviewTurn(ctx, tenantID, conv)
	if err != nil {
		return err
	}

	// Load prior messages for the turn-cap check. Tenant-scoped query ensures
	// cross-tenant bleed is impossible. These are the messages present before
	// any assistant response is persisted — correct for decideInterviewAction's
	// "priorMsgs" contract (assistant-role count before this turn).
	priorMsgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return err
	}

	outcome := decideInterviewAction(raw, priorMsgs, DefaultMaxInterviewTurns)

	if outcome.ReadyForNote {
		// Interview complete: draft the SOAP note through DRAFT→PENDING_REVIEW.
		// Physicians receive a queue.updated event; the patient receives nothing
		// from the agent at this point. Clinical content (Assessment & Plan) will
		// reach the patient only after a physician transitions the recommendation
		// to APPROVED/MODIFIED and it is delivered via the standard lifecycle.
		return d.draftSOAPNote(ctx, tenantID, conv, patient)
	}

	// Interview continues: deliver the next question to the patient. No
	// recommendation row is created; this is non-clinical data collection.
	return d.deliverInterviewQuestion(ctx, tenantID, conv, patient, outcome.Question)
}

// generateInterviewTurn assembles the full tenant-scoped conversation history
// and calls the model to produce the next interview question. The leading
// message in the model call is always InterviewSystemPrompt (system role) so
// the model stays in interview mode; the rest is the raw conversation history.
//
// Error discipline mirrors runInterviewTurn's contract: a non-nil error means no usable model
// output was obtained — the caller must not treat the returned string as
// clinical content. Message content is never logged (PHI constraint). The
// error type carries enough coarse information for draftFailureReason to
// classify it without inspecting the body.
//
// Task 1.3 is responsible for inspecting the returned text for
// ReadyForNoteMarker and branching between delivering an interview question
// and triggering SOAP note drafting. This method is intentionally output-
// agnostic: it returns whatever the model produced.
//
// Task 3.3: when the conversation's latest reviewed outcome is a physician
// rejection (store.GetLatestRejectionReason), an additional system-role
// message carrying the rejection reason as reviewer guidance is inserted
// between InterviewSystemPrompt and the conversation history — see
// rejectionGuidanceMessage in prompt.go. The reason reaches the model
// context only; it is never persisted via store.CreateMessage or written to
// any patient-facing text (patient-facing content in this codepath is
// entirely model-generated question text and the fixed ack/reminder
// messages elsewhere, none of which touch this string).
func (d *Drafter) generateInterviewTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation) (string, error) {
	// Fetch the full conversation history scoped to this tenant. The query
	// includes tenant_id in the WHERE clause so cross-tenant bleed is
	// impossible even when two tenants share a conversation UUID.
	msgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return "", err
	}

	// Determine whether a rejection is the conversation's current (not
	// stale) reviewed outcome. See store.GetLatestRejectionReason for the
	// "newer than any delivered recommendation" rule.
	reason, hasRejection, err := d.store.GetLatestRejectionReason(ctx, tenantID, conv.ID)
	if err != nil {
		return "", err
	}

	// Build the model message slice: the clinical interview system prompt as
	// the leading system message, optionally followed by the rejection
	// reviewer-guidance message, then every stored turn in order. Content
	// goes to the model call only — never written to logs or audit.
	modelMsgs := make([]Message, 0, len(msgs)+2)
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: InterviewSystemPrompt,
	})
	if hasRejection {
		modelMsgs = append(modelMsgs, Message{
			Role:    "system",
			Content: rejectionGuidanceMessage(reason),
		})
	}
	for _, m := range msgs {
		modelMsgs = append(modelMsgs, Message{
			Role:    m.Role,
			Content: m.Content,
		})
	}

	return d.client.Complete(ctx, modelMsgs)
}

// interviewTurnCapReached reports whether the number of assistant-role turns
// already present in msgs has reached or exceeded max. When true, the agent
// runtime should switch from interviewing to SOAP note drafting regardless of
// whether ReadyForNoteMarker has been emitted, so an interview cannot run
// unbounded.
//
// Only "assistant" role messages are counted — "user" messages (patient input)
// and "system" messages do not count toward the cap.
//
// The function is pure and side-effect-free so it can be unit-tested in
// isolation without a store or model client.
func interviewTurnCapReached(msgs []store.Message, max int) bool {
	count := 0
	for _, m := range msgs {
		if m.Role == "assistant" {
			count++
		}
	}
	return count >= max
}

// draftFailureReason maps a draft error to a coarse, safe string reason that
// can appear in audit metadata. The mapping is entirely type-driven — the
// error message, body, or any embedded content is never inspected, so no PHI
// or model-response content can leak into audit rows.
//
//   - context.DeadlineExceeded                   → "timeout"
//   - *ParseError                                → "parse_error"
//   - *ModelError (connection refused / net err) → "model_unavailable"
//   - *ModelError (non-2xx from the model)       → "model_error"
//   - anything else                              → "internal_error"
func draftFailureReason(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var pe *ParseError
	if errors.As(err, &pe) {
		return "parse_error"
	}
	var ve *domain.SOAPValidationError
	if errors.As(err, &ve) {
		// SOAP note generated but missing/blank a required section.
		return "validation_error"
	}
	var me *ModelError
	if errors.As(err, &me) {
		// Distinguish a transport/connection failure (wrapped inside ModelError
		// only when the HTTP client itself fails before a status code is
		// available) from a well-formed non-2xx response. A net.Error or
		// context.Canceled unwrapped from the error signals "unreachable";
		// a StatusCode > 0 signals the model replied with an error status.
		if me.StatusCode == 0 {
			return "model_unavailable"
		}
		return "model_error"
	}
	// Transport errors that are not wrapped in *ModelError (e.g. connection
	// refused before any HTTP response is parsed).
	var ne net.Error
	if errors.As(err, &ne) {
		return "model_unavailable"
	}
	return "internal_error"
}

// headerDecorationRE matches leading Markdown/list decoration on a header line:
// heading hashes, blockquote markers, emphasis (*/_), list bullets (-/+), and an
// optional ordered-list number ("1." or "1)"). Stripped before label matching.
var headerDecorationRE = regexp.MustCompile(`^[\s#>*_+\-]*(?:\d+[.)]\s*)?`)

// normalizeHeaderLine reduces a raw line to its bare uppercase header token by
// stripping surrounding Markdown/list decoration, so headers like
// "**SUBJECTIVE:**", "### Subjective", "1. SUBJECTIVE", or "- PLAN:" all match
// the plain labels. Returns the uppercased, trimmed result.
func normalizeHeaderLine(line string) string {
	s := strings.TrimSpace(line)
	s = headerDecorationRE.ReplaceAllString(s, "")
	s = strings.TrimRight(s, " \t*_#")
	return strings.ToUpper(strings.TrimSpace(s))
}

// parseSOAPSections extracts the four required SOAP sections from raw model
// output. Section headers SUBJECTIVE:, OBJECTIVE:, ASSESSMENT:, and PLAN: are
// recognised case-insensitively with whitespace trimmed. Content may appear
// inline on the header line (after the colon) or on the lines that follow.
//
// Returns a *ParseError if fewer than four distinct headers are found. The
// caller must separately call domain.SOAPPayload.Validate() to check that no
// extracted section is empty or whitespace-only (validator task 2.1).
//
// No content is logged (PHI constraint).
func parseSOAPSections(raw string) (domain.SOAPPayload, error) {
	const (
		labelSubjective = "SUBJECTIVE"
		labelObjective  = "OBJECTIVE"
		labelAssessment = "ASSESSMENT"
		labelPlan       = "PLAN"
	)
	orderedLabels := []string{labelSubjective, labelObjective, labelAssessment, labelPlan}

	lines := strings.Split(raw, "\n")

	type span struct {
		label   string
		lineIdx int
	}
	seen := map[string]bool{}
	var spans []span

	for i, line := range lines {
		// Strip common Markdown/list decoration the model adds around headers
		// (e.g. "**SUBJECTIVE:**", "### Subjective", "1. SUBJECTIVE", "- PLAN:")
		// so the label match is robust to formatting variation from small models.
		upper := normalizeHeaderLine(line)
		for _, label := range orderedLabels {
			if !seen[label] && (upper == label || upper == label+":" || strings.HasPrefix(upper, label+":")) {
				seen[label] = true
				spans = append(spans, span{label: label, lineIdx: i})
				break
			}
		}
	}

	if len(spans) < 4 {
		return domain.SOAPPayload{}, &ParseError{
			Detail: "model output is missing one or more SOAP section headers (SUBJECTIVE, OBJECTIVE, ASSESSMENT, PLAN)",
		}
	}

	// Extract content for each section: inline text after the first colon on the
	// header line (if any), then all subsequent lines up to the next header.
	sections := make(map[string]string, 4)
	for i, sp := range spans {
		endIdx := len(lines)
		if i+1 < len(spans) {
			endIdx = spans[i+1].lineIdx
		}

		var parts []string

		// Inline content: text after the colon on the header line itself.
		headerLine := lines[sp.lineIdx]
		if colonPos := strings.Index(headerLine, ":"); colonPos >= 0 {
			if inline := strings.TrimSpace(headerLine[colonPos+1:]); inline != "" {
				parts = append(parts, inline)
			}
		}

		// Body lines between this header and the next.
		for j := sp.lineIdx + 1; j < endIdx; j++ {
			parts = append(parts, lines[j])
		}

		sections[sp.label] = strings.TrimSpace(strings.Join(parts, "\n"))
	}

	return domain.SOAPPayload{
		Subjective: sections[labelSubjective],
		Objective:  sections[labelObjective],
		Assessment: sections[labelAssessment],
		Plan:       sections[labelPlan],
	}, nil
}

// draftSOAPNote assembles the conversation history, calls the model with
// SOAPDraftSystemPrompt, parses the four SOAP sections, validates them, and
// atomically persists a soap_note recommendation at PENDING_REVIEW — mirroring
// the DRAFT→PENDING_REVIEW transaction pattern used across the agent.
//
// Error discipline is identical to the rest of the agent: a non-nil return means no
// recommendation was persisted; the caller (DraftAsync or the phase-3 entry
// point) is responsible for writing the ai_interaction_failed audit event.
// No model output is logged (PHI constraint).
func (d *Drafter) draftSOAPNote(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	// Assemble tenant-scoped conversation context. The query includes tenant_id
	// in the WHERE clause so cross-tenant bleed is impossible.
	msgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return err
	}

	// Build the model message slice: SOAPDraftSystemPrompt as the sole system
	// message, followed by the full conversation history so the model has
	// the complete interview context to write from.
	// Content goes to the model call only — never written to logs or audit.
	modelMsgs := make([]Message, 0, len(msgs)+1)
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: SOAPDraftSystemPrompt,
	})
	for _, m := range msgs {
		modelMsgs = append(modelMsgs, Message{
			Role:    m.Role,
			Content: m.Content,
		})
	}

	// Small models (e.g. medgemma:4b) format the SOAP headers correctly only
	// intermittently, so a single bad generation must not sink the whole draft.
	// Retry the generate→parse→validate cycle a few times; only a fresh model
	// generation can fix a malformed one, so we re-call Complete each attempt.
	// Transport/model errors are NOT retried here (they surface immediately).
	var text string
	var soapPayload domain.SOAPPayload
	var parseErr error
	for attempt := 0; attempt < soapDraftMaxAttempts; attempt++ {
		text, err = d.client.Complete(ctx, modelMsgs)
		if err != nil {
			// Non-nil error means no valid model output — do NOT persist.
			return err
		}
		soapPayload, parseErr = parseSOAPSections(text)
		if parseErr == nil {
			// Domain validation: all four sections must be non-empty.
			if vErr := soapPayload.Validate(); vErr != nil {
				parseErr = vErr
			}
		}
		if parseErr == nil {
			break
		}
		// Malformed output — try a fresh generation (unless this was the last attempt).
	}
	if parseErr != nil {
		return parseErr
	}

	// Marshal the structured payload for storage.
	payloadJSON, err := json.Marshal(soapPayload)
	if err != nil {
		return err
	}

	agentActor := domain.Actor{Type: domain.ActorAgent, ID: uuid.Nil}

	// The care phase the conversation was observed in when this turn was
	// dispatched. dispatchTurn routes both CarePhaseIntake and the empty
	// (pre-migration/legacy-fixture) phase to runIntakeTurn → runInterviewTurn
	// → draftSOAPNote, so an empty value here is treated as INTAKE for the CAS
	// `from` — the same defensive mapping dispatchTurn already applies. Every real
	// database row always has a non-empty care_phase (NOT NULL DEFAULT
	// 'INTAKE'), so this only matters for in-memory test fixtures.
	fromPhase := conv.CarePhase
	if fromPhase == "" {
		fromPhase = store.CarePhaseIntake
	}

	// Persist DRAFT → PENDING_REVIEW, the fixed patient-facing acknowledgement
	// message, and the INTAKE → AWAITING_REVIEW care-phase transition
	// atomically. Doing all of this in one transaction is deliberate: a
	// physician must never see a queue entry (or a patient an ack) for a
	// draft that didn't durably land, and the conversation must never sit in
	// AWAITING_REVIEW without an actual pending recommendation behind it.
	//
	// CAS-failure semantics: TransitionCarePhase compares-and-swaps on
	// care_phase = fromPhase. If the row has already moved on (e.g. a racing
	// second draft — the double-draft bug guarded against in task 2.3, or any
	// other concurrent writer), it returns store.ErrNotFound, which aborts and
	// rolls back the ENTIRE transaction: no recommendation, no ack message,
	// nothing partial. The caller (DraftAsync) treats this exactly like any
	// other draft failure — it logs the failure type and writes an
	// ai_interaction_failed audit event. No recommendation is left in DRAFT
	// state and no ack is shown for content the patient never actually
	// triggered a successful draft for.
	var recID uuid.UUID
	var ackMsgID uuid.UUID
	if err := d.store.Txn(ctx, func(tx *store.TxStore) error {
		// Step 1: insert at DRAFT.
		rec, err := tx.CreateRecommendation(ctx, tenantID, store.Recommendation{
			ConversationID: conv.ID,
			PatientID:      patient.ID,
			State:          domain.StateDraft,
			PayloadType:    domain.PayloadTypeSOAPNote,
			Payload:        payloadJSON,
			DraftContent:   strings.TrimSpace(text),
		})
		if err != nil {
			return err
		}
		recID = rec.ID

		// Step 2: pure state-machine transition DRAFT → PENDING_REVIEW.
		nextState, err := domain.Transition(rec.State, domain.ActionSubmitForReview, agentActor, patient.State)
		if err != nil {
			return err
		}

		// Step 3: persist the new state within the same transaction.
		if err := tx.UpdateRecommendationState(ctx, tenantID, rec.ID, nextState, nil, nil); err != nil {
			return err
		}

		// Step 4: write the audit event. Metadata contains identifiers +
		// payload_type only — no PHI, no model output.
		if err := tx.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
			ActorType: string(domain.ActorAgent),
			ActorID:   nil, // agent has no user UUID
			EventType: "recommendation.submitted_for_review",
			Metadata: mustMarshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"conversation_id":   conv.ID.String(),
				"new_state":         nextState,
				"payload_type":      domain.PayloadTypeSOAPNote,
			}),
		}); err != nil {
			return err
		}

		// Step 5: persist the fixed review-pending acknowledgement as an
		// assistant message in the same conversation. This is static text
		// (ReviewPendingAckMessage), never model output, and reveals nothing
		// of the drafted Subjective/Objective/Assessment/Plan content.
		ackMsg, err := tx.CreateMessage(ctx, tenantID, conv.ID, "assistant", ReviewPendingAckMessage)
		if err != nil {
			return err
		}
		ackMsgID = ackMsg.ID

		// Step 6: write the audit event for the acknowledgement. Metadata
		// contains identifiers only — no PHI, no message content (the message
		// is fixed text, but the pattern is kept consistent with
		// deliverInterviewQuestion).
		if err := tx.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
			ActorType: string(domain.ActorAgent),
			ActorID:   nil, // agent has no user UUID
			EventType: "agent.review_pending_ack",
			Metadata: mustMarshalJSON(map[string]any{
				"conversation_id":   conv.ID.String(),
				"message_id":        ackMsgID.String(),
				"recommendation_id": recID.String(),
			}),
		}); err != nil {
			return err
		}

		// Step 7: move the conversation INTAKE → AWAITING_REVIEW so
		// dispatchTurn routes any further patient messages away from
		// runInterviewTurn (the double-draft guard task 2.3 completes).
		return tx.TransitionCarePhase(ctx, tenantID, conv.ID, fromPhase, store.CarePhaseAwaitingReview)
	}); err != nil {
		return err
	}

	// Emit queue.updated AFTER the successful commit so physicians only
	// receive the event when the row is durably visible.
	d.notifier.SendToPhysicians(tenantID.String(), mustMarshalJSON(map[string]any{
		"type": "queue.updated",
		"data": map[string]any{
			"recommendation_id": recID.String(),
			"conversation_id":   conv.ID.String(),
		},
	}))

	// Push the acknowledgement to the patient over WS AFTER the successful
	// commit, mirroring deliverInterviewQuestion: the payload carries
	// identifiers only (never message content), and the client can never
	// receive a reference to a message that does not yet exist in the
	// database.
	d.patientNotifier.SendToPatient(tenantID.String(), patient.ID.String(), mustMarshalJSON(map[string]any{
		"type": "message.created",
		"data": map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      ackMsgID.String(),
		},
	}))

	return nil
}

// deliverInterviewQuestion persists an agent interview question as an
// assistant-role message, writes an audit event with identifiers only (no
// PHI), and emits a WebSocket event to the patient carrying only IDs so the
// iOS client can fetch the content over its authenticated REST channel.
//
// Order guarantee: the message is committed and audited before the patient
// notifier fires, so the client can never receive a reference to a message
// that does not yet exist in the database.
//
// PHI discipline: question content is stored in the message row only. Audit
// metadata and the patient WebSocket event contain conversation_id and
// message_id exclusively — never the question text.
func (d *Drafter) deliverInterviewQuestion(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient, question string) error {
	// Step 1: persist the question as an assistant-role message so the iOS
	// client can retrieve it via GET /api/conversations/{id}/messages.
	msg, err := d.store.CreateMessage(ctx, tenantID, conv.ID, "assistant", question)
	if err != nil {
		return err
	}

	// Step 2: write the audit event. Metadata contains identifiers only —
	// no PHI, no message content.
	if _, auditErr := d.store.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
		ActorType: string(domain.ActorAgent),
		ActorID:   nil, // agent has no user UUID
		EventType: "agent.interview_question",
		Metadata: mustMarshalJSON(map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		}),
	}); auditErr != nil {
		// A failed audit write must not prevent the message from being
		// delivered — log the error type only (never the value, which could
		// echo PHI) and continue.
		log.Printf("agent: audit write failed conversation_id=%s: %T", conv.ID, auditErr)
	}

	// Step 3: emit a WebSocket event to the patient. The payload is IDs only
	// so no PHI crosses the notification channel. The client fetches message
	// content via its authenticated REST endpoint after receiving the event.
	d.patientNotifier.SendToPatient(tenantID.String(), patient.ID.String(), mustMarshalJSON(map[string]any{
		"type": "message.created",
		"data": map[string]any{
			"conversation_id": conv.ID.String(),
			"message_id":      msg.ID.String(),
		},
	}))

	return nil
}

func mustMarshalJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
