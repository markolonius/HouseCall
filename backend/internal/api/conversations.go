package api

import (
	"encoding/json"
	"net/http"

	"github.com/markolonius/housecall/backend/internal/store"
)

type createConversationRequest struct {
	Title string `json:"title"`
}

func (rt *Router) handleListConversations(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	if claims.ActorType != "patient" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	convs, err := rt.store.ListConversationsByPatient(r.Context(), claims.TenantID, claims.ActorID)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	if convs == nil {
		convs = []store.Conversation{}
	}
	writeJSON(w, http.StatusOK, convs)
}

func (rt *Router) handleCreateConversation(w http.ResponseWriter, r *http.Request) {
	claims, _ := claimsFromCtx(r.Context())
	if claims.ActorType != "patient" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var req createConversationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Title == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	conv, err := rt.store.CreateConversation(r.Context(), claims.TenantID, claims.ActorID, req.Title)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	rt.audit.Write(r.Context(), claims.TenantID, claims.ActorType, &claims.ActorID,
		"conversation.created", map[string]any{"conversation_id": conv.ID.String()})
	writeJSON(w, http.StatusCreated, conv)
}
