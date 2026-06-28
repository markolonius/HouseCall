package agent

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
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

// DraftAsync spawns a goroutine that runs one step of the clinical interview
// per patient message: either delivers the next interview question directly to
// the patient, or — when the interview is judged complete — drafts a soap_note
// recommendation into PENDING_REVIEW for physician review. It is fire-and-
// forget: errors are logged but never returned to the caller.
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

		// Recover from any panic inside runInterviewTurn (nil-deref, driver
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
		if err := d.runInterviewTurn(ctx, tenantID, conv, patient); err != nil {
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

// runInterviewTurn is the synchronous orchestration logic called by DraftAsync
// per patient message. It runs one step of the clinical interview:
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
func (d *Drafter) generateInterviewTurn(ctx context.Context, tenantID store.TenantID, conv store.Conversation) (string, error) {
	// Fetch the full conversation history scoped to this tenant. The query
	// includes tenant_id in the WHERE clause so cross-tenant bleed is
	// impossible even when two tenants share a conversation UUID.
	msgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return "", err
	}

	// Build the model message slice: the clinical interview system prompt as
	// the sole system message, followed by every stored turn in order.
	// Content goes to the model call only — never written to logs or audit.
	modelMsgs := make([]Message, 0, len(msgs)+1)
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: InterviewSystemPrompt,
	})
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
		upper := strings.ToUpper(strings.TrimSpace(line))
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

	text, err := d.client.Complete(ctx, modelMsgs)
	if err != nil {
		// Non-nil error means no valid model output — do NOT persist.
		return err
	}

	// Parse the model output into the four SOAP sections.
	soapPayload, err := parseSOAPSections(text)
	if err != nil {
		return err
	}
	// Domain validation: all four sections must be non-empty (whitespace-only
	// content is treated as empty by the validator tightened in task 2.1).
	if err := soapPayload.Validate(); err != nil {
		return err
	}

	// Marshal the structured payload for storage.
	payloadJSON, err := json.Marshal(soapPayload)
	if err != nil {
		return err
	}

	agentActor := domain.Actor{Type: domain.ActorAgent, ID: uuid.Nil}

	// Persist DRAFT → PENDING_REVIEW + audit event atomically.
	var recID uuid.UUID
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
		return tx.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
			ActorType: string(domain.ActorAgent),
			ActorID:   nil, // agent has no user UUID
			EventType: "recommendation.submitted_for_review",
			Metadata: mustMarshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"conversation_id":   conv.ID.String(),
				"new_state":         nextState,
				"payload_type":      domain.PayloadTypeSOAPNote,
			}),
		})
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
