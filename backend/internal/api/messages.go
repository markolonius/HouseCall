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
	Content        string `json:"content"`
	// IdempotencyKey is the local message UUID sent by the iOS client on
	// both the initial POST and every replay.  When present, the handler
	// deduplicates: a second POST carrying the same key for the same
	// tenant + conversation returns the original server message (same ID)
	// with HTTP 200 instead of 201.  Absent means always insert (legacy /
	// server-generated messages).
	IdempotencyKey string `json:"idempotency_key,omitempty"`
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

	var msg store.Message
	var deduped bool

	if req.IdempotencyKey != "" {
		// Idempotent path: use the provided key to deduplicate replays.
		// Two concurrent POSTs with the same (tenant, conv, key) converge
		// on a single row; no duplicate is ever written.
		var idempErr error
		msg, deduped, idempErr = rt.store.CreateMessageIdempotent(
			r.Context(), claims.TenantID, convID, "user", req.Content, req.IdempotencyKey,
		)
		if idempErr != nil {
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}
	} else {
		// No key supplied — always insert (legacy / non-replay path).
		var plainErr error
		msg, plainErr = rt.store.CreateMessage(r.Context(), claims.TenantID, convID, "user", req.Content)
		if plainErr != nil {
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}
	}

	// Write the audit event only for genuine inserts, never for dedupe hits.
	// A deduped response means the event was already written for the original
	// insert, so writing again would create a spurious second audit row for
	// the same logical message.
	if !deduped {
		rt.audit.Write(r.Context(), claims.TenantID, claims.ActorType, &claims.ActorID,
			"message.created", map[string]any{
				"conversation_id": convID.String(),
				"message_id":      msg.ID.String(),
			})
	}

	// Task 4.2: trigger reactive drafting asynchronously after the message is
	// persisted. DraftAsync spawns a goroutine — the patient's response is
	// returned immediately; drafting proceeds in the background. We load the
	// patient here (tenant-scoped) so the drafter has the patient.State needed
	// for the domain.Transition call without a second DB round-trip inside the
	// goroutine startup path.
	// For dedupe hits we skip drafting — the original message already triggered
	// a draft (or the conversation has progressed past that point).
	if rt.drafter != nil && !deduped {
		patient, err := rt.store.GetPatient(r.Context(), claims.TenantID, claims.ActorID)
		if err == nil {
			rt.drafter.DraftAsync(claims.TenantID, conv, patient)
		}
		// If the patient lookup fails (unexpected), we skip drafting and log
		// nothing that includes PHI — the message is already persisted.
	}

	// HTTP 200 for a dedupe hit (same message returned), 201 for a fresh
	// insert. Both carry the same Message DTO shape; the iOS client treats
	// both as success and adopts the returned server ID.
	status := http.StatusCreated
	if deduped {
		status = http.StatusOK
	}
	writeJSON(w, status, msg)
}
