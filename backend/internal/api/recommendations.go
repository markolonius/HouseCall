package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/review"
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

	// Delegate to the shared, transport-agnostic review logic. This ensures the
	// web app and the JSON API drive identical state-machine semantics.
	result, err := review.Execute(ctx, rt.store, claims.TenantID, claims.ActorID, recID, req.Action, req.FinalContent)
	if errors.Is(err, review.ErrActorNotFound) {
		// Physician record not found for the session actor — treat as 403 (session
		// anomaly) rather than leaking internal state, preserving the original
		// pre-refactor contract.
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if errors.Is(err, domain.ErrUnlicensedState) {
		http.Error(w, "forbidden: physician not licensed in patient's state", http.StatusForbidden)
		return
	}
	if errors.Is(err, domain.ErrInvalidTransition) {
		http.Error(w, "invalid transition", http.StatusUnprocessableEntity)
		return
	}
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	// Push a WebSocket event to the patient only once DELIVERED.
	if result.FinalState == domain.StateDelivered {
		rt.hub.SendToPatient(claims.TenantID.String(), result.PatientID.String(),
			marshalJSON(map[string]any{
				"type": "recommendation.delivered",
				"data": map[string]any{
					"recommendation_id": result.RecommendationID.String(),
					"conversation_id":   result.ConversationID.String(),
				},
			}))
	}

	writeJSON(w, http.StatusOK, map[string]string{"state": result.FinalState})
}
