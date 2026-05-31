package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/store"
)

type createMessageRequest struct {
	Content string `json:"content"`
}

func (rt *Router) handleListMessages(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	convID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		http.Error(w, "invalid conversation id", http.StatusBadRequest)
		return
	}
	conv, err := rt.store.GetConversation(r.Context(), claims.TenantID, convID)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	} else if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	// Patients can only see their own conversations.
	if claims.ActorType == "patient" && conv.PatientID != claims.ActorID {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	msgs, err := rt.store.ListMessagesByConversation(r.Context(), claims.TenantID, convID)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	if msgs == nil {
		msgs = []store.Message{}
	}
	writeJSON(w, http.StatusOK, msgs)
}

func (rt *Router) handleCreateMessage(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	if claims.ActorType != "patient" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	convID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		http.Error(w, "invalid conversation id", http.StatusBadRequest)
		return
	}
	conv, err := rt.store.GetConversation(r.Context(), claims.TenantID, convID)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	} else if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	if conv.PatientID != claims.ActorID {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	var req createMessageRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Content == "" {
		http.Error(w, "content is required", http.StatusBadRequest)
		return
	}
	msg, err := rt.store.CreateMessage(r.Context(), claims.TenantID, convID, "user", req.Content)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	rt.audit.Write(r.Context(), claims.TenantID, claims.ActorType, &claims.ActorID,
		"message.created", map[string]any{
			"conversation_id": convID.String(),
			"message_id":      msg.ID.String(),
		})
	// Phase 4 (Task 4.2): trigger AI Agent Runtime here after persisting the message.
	writeJSON(w, http.StatusCreated, msg)
}
