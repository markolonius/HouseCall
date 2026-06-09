package agent

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

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

// Drafter listens for persisted patient messages and drives the
// DRAFT → PENDING_REVIEW lifecycle for guidance recommendations.
//
// Threading: DraftAsync dispatches the work to a goroutine so the patient's
// HTTP response is returned immediately; the model call (which may take up to
// DefaultTimeout) runs concurrently. Context cancellation from the originating
// request is NOT propagated — drafting must complete even if the patient
// disconnects. The goroutine uses a background context derived from the store.
type Drafter struct {
	client     ModelClient
	store      *store.Store
	notifier   PhysicianNotifier
	onComplete func() // optional; called (via defer) when the goroutine exits — tests use this for synchronisation
}

// NewDrafter constructs a Drafter. All three arguments are required.
func NewDrafter(client ModelClient, s *store.Store, notifier PhysicianNotifier) *Drafter {
	return &Drafter{client: client, store: s, notifier: notifier}
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

// DraftAsync spawns a goroutine that assembles the conversation context,
// calls the model, and persists a PENDING_REVIEW recommendation. It is
// fire-and-forget: errors are logged but never returned to the caller.
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

		// Recover from any panic inside draft() (nil-deref, driver bug, etc.)
		// so a single drafting failure cannot crash the server process.
		// middleware.Recoverer only protects HTTP handler goroutines; fire-and-
		// forget goroutines must manage their own recovery.
		// Log type only — never the recovered value itself, which may echo
		// request content or PHI.
		defer func() {
			if r := recover(); r != nil {
				log.Printf("agent: draft panicked conversation_id=%s: %T", conv.ID, r)
			}
		}()

		ctx := context.Background()
		if err := d.draft(ctx, tenantID, conv, patient); err != nil {
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

// draft is the synchronous drafting logic, separated for testability.
func (d *Drafter) draft(ctx context.Context, tenantID store.TenantID, conv store.Conversation, patient store.Patient) error {
	// Assemble tenant-scoped conversation context. The query includes
	// tenant_id in the WHERE clause so messages from other tenants are
	// never mixed in, even if two tenants share a conversation UUID by
	// some extreme coincidence.
	msgs, err := d.store.ListMessagesByConversation(ctx, tenantID, conv.ID)
	if err != nil {
		return err
	}

	// Build the model message slice: a brief system prompt followed by the
	// conversation history. Content goes into the model call only — it is
	// never written to audit logs.
	modelMsgs := make([]Message, 0, len(msgs)+1)
	modelMsgs = append(modelMsgs, Message{
		Role:    "system",
		Content: "You are a medical assistant. Provide concise clinical guidance based on the conversation.",
	})
	for _, m := range msgs {
		modelMsgs = append(modelMsgs, Message{
			Role:    m.Role,
			Content: m.Content,
		})
	}

	text, err := d.client.Complete(ctx, modelMsgs)
	if err != nil {
		// Non-nil error means no valid model output — do NOT persist as
		// clinical content (failure contract from client.go). Task 4.3
		// handles this branch fully.
		return err
	}

	// Build the guidance payload. Only the model text goes here — no
	// audit metadata, no PHI from other sources.
	payload, err := json.Marshal(map[string]string{"text": text})
	if err != nil {
		return err
	}

	agentActor := domain.Actor{Type: domain.ActorAgent, ID: uuid.Nil}

	// Persist DRAFT → PENDING_REVIEW + audit event atomically. The
	// two-step pattern (create DRAFT then transition to PENDING_REVIEW
	// within the same Txn) mirrors the Phase 3 physician review pattern
	// so there is never a DRAFT row visible outside the transaction.
	var recID uuid.UUID
	if err := d.store.Txn(ctx, func(tx *store.TxStore) error {
		// Step 1: insert at DRAFT.
		rec, err := tx.CreateRecommendation(ctx, tenantID, store.Recommendation{
			ConversationID: conv.ID,
			PatientID:      patient.ID,
			State:          domain.StateDraft,
			PayloadType:    "guidance",
			Payload:        payload,
			DraftContent:   text,
		})
		if err != nil {
			return err
		}
		recID = rec.ID

		// Step 2: pure state-machine transition DRAFT → PENDING_REVIEW.
		// The agent actor has no path beyond this single transition.
		nextState, err := domain.Transition(rec.State, domain.ActionSubmitForReview, agentActor, patient.State)
		if err != nil {
			return err
		}

		// Step 3: persist the new state within the same transaction.
		if err := tx.UpdateRecommendationState(ctx, tenantID, rec.ID, nextState, nil, nil); err != nil {
			return err
		}

		// Step 4: write the audit event. Metadata contains identifiers only
		// — no PHI, no model output.
		return tx.CreateAuditEvent(ctx, tenantID, store.AuditEvent{
			ActorType: string(domain.ActorAgent),
			ActorID:   nil, // agent has no user UUID
			EventType: "recommendation.submitted_for_review",
			Metadata: mustMarshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"conversation_id":   conv.ID.String(),
				"new_state":         nextState,
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

func mustMarshalJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
