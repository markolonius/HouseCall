package agent

import (
	"context"
	"encoding/json"
	"log"

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
	client   ModelClient
	store    *store.Store
	notifier PhysicianNotifier
}

// NewDrafter constructs a Drafter. All three arguments are required.
func NewDrafter(client ModelClient, s *store.Store, notifier PhysicianNotifier) *Drafter {
	return &Drafter{client: client, store: s, notifier: notifier}
}

// DraftAsync spawns a goroutine that assembles the conversation context,
// calls the model, and persists a PENDING_REVIEW recommendation. It is
// fire-and-forget: errors are logged but never returned to the caller.
// The caller must not pass a request-scoped context — use context.Background()
// or a long-lived server context so the goroutine is not cancelled when the
// HTTP handler returns.
func (d *Drafter) DraftAsync(tenantID store.TenantID, conv store.Conversation, patient store.Patient) {
	go func() {
		ctx := context.Background()
		if err := d.draft(ctx, tenantID, conv, patient); err != nil {
			// Task 4.3 will slot the failure path (ai_interaction_failed audit)
			// here. For now we log without exposing error bodies that may echo
			// request content (see ModelError.Body HIPAA note in client.go).
			log.Printf("agent: draft failed conversation_id=%s: %T", conv.ID, err)
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

func mustMarshalJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
