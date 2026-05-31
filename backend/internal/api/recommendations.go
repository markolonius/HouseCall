package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

type reviewRequest struct {
	Action       string `json:"action"`        // approve | modify | reject
	FinalContent string `json:"final_content"` // required for modify; optional override for approve
}

func (rt *Router) handleListRecommendations(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	if claims.ActorType != "physician" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	state := r.URL.Query().Get("state")
	if state == "" {
		state = domain.StatePendingReview
	}
	recs, err := rt.store.ListRecommendationsByPhysician(r.Context(), claims.TenantID, claims.ActorID, state)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	if recs == nil {
		recs = []store.Recommendation{}
	}
	writeJSON(w, http.StatusOK, recs)
}

func (rt *Router) handleGetRecommendation(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	recID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		http.Error(w, "invalid recommendation id", http.StatusBadRequest)
		return
	}
	rec, err := rt.store.GetRecommendation(r.Context(), claims.TenantID, recID)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	} else if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	// Patients may only read their own DELIVERED recommendations.
	if claims.ActorType == "patient" {
		if rec.PatientID != claims.ActorID || rec.State != domain.StateDelivered {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
	}
	writeJSON(w, http.StatusOK, rec)
}

func (rt *Router) handleReviewRecommendation(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	if claims.ActorType != "physician" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	recID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		http.Error(w, "invalid recommendation id", http.StatusBadRequest)
		return
	}
	var req reviewRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// modify requires a non-empty final_content.
	if req.Action == domain.ActionModify && req.FinalContent == "" {
		http.Error(w, "final_content required for modify", http.StatusUnprocessableEntity)
		return
	}

	ctx := r.Context()
	rec, err := rt.store.GetRecommendation(ctx, claims.TenantID, recID)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	} else if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	actor := domain.Actor{Type: domain.ActorPhysician, ID: claims.ActorID}

	// Step 1: validate the physician's action using the canonical pure state
	// machine — this moves PENDING_REVIEW → APPROVED / MODIFIED / REJECTED.
	midState, err := domain.Transition(rec.State, req.Action, actor)
	if errors.Is(err, domain.ErrInvalidTransition) {
		http.Error(w, "invalid transition", http.StatusUnprocessableEntity)
		return
	} else if err != nil {
		http.Error(w, err.Error(), http.StatusUnprocessableEntity)
		return
	}

	// Step 2: for approve/modify the workflow continues to DELIVERED in the
	// same atomic commit.  Determine final_content here — it is set ONLY on
	// the DELIVERED write, never on intermediate states.
	finalState := midState
	var finalContent *string
	if midState == domain.StateApproved || midState == domain.StateModified {
		// Transition APPROVED/MODIFIED → DELIVERED (cannot fail: both are
		// valid source states in the pure machine).
		delivered, err := domain.Transition(midState, domain.ActionDeliver, actor)
		if err != nil {
			// Should never happen given valid midState values above.
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}
		finalState = delivered

		// Compute the patient-visible content only for the DELIVERED write.
		content := rec.DraftContent
		if req.FinalContent != "" {
			content = req.FinalContent
		}
		finalContent = &content
	}
	// For REJECTED: finalContent remains nil — patients never see it.

	// State change AND audit_event are written in a single DB transaction so
	// they either both commit or both roll back.
	reviewedBy := claims.ActorID
	if err := rt.store.Txn(ctx, func(tx *store.TxStore) error {
		// Write the final state. final_content is only non-nil when
		// finalState == DELIVERED, enforcing the content-visibility gate.
		if err := tx.UpdateRecommendationState(ctx, claims.TenantID, recID,
			finalState, &reviewedBy, finalContent); err != nil {
			return err
		}
		return tx.CreateAuditEvent(ctx, claims.TenantID, store.AuditEvent{
			ActorType: "physician",
			ActorID:   &reviewedBy,
			EventType: "recommendation.reviewed",
			Metadata: marshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"action":            req.Action,
				"new_state":         finalState,
			}),
		})
	}); err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	// Push a WebSocket event to the patient only once DELIVERED.
	if finalState == domain.StateDelivered {
		rt.hub.SendToPatient(claims.TenantID.String(), rec.PatientID.String(),
			marshalJSON(map[string]any{
				"type": "recommendation.delivered",
				"data": map[string]any{
					"recommendation_id": recID.String(),
					"conversation_id":   rec.ConversationID.String(),
				},
			}))
	}

	writeJSON(w, http.StatusOK, map[string]string{"state": finalState})
}
