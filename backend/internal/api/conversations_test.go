package api_test

// TestHandler_ConversationCarePhase_* exercises the GET /api/conversations
// (list) and POST /api/conversations (create) handlers to verify the
// care_phase field round-trips in both response shapes for all three phases
// of the care-phase state machine (INTAKE, AWAITING_REVIEW, PLAN_DELIVERED).
//
// Handlers marshal store.Conversation directly (no DTO layer), so this test
// pins the wire shape: the field name is the Go struct field name
// "CarePhase" (untagged, matching every other Conversation field returned
// today such as "ID" and "TenantID").
//
// Follows the pattern from messages_test.go / recommendations_test.go: uses
// apiTestPool + signedJWT against the real router and handlers.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/api"
	"github.com/markolonius/housecall/backend/internal/store"
)

// getConversations sends GET /api/conversations and returns the recorder.
func getConversations(t *testing.T, r chi.Router, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/conversations", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)
	return rw
}

// postConversation sends POST /api/conversations with the supplied title
// and returns the recorder.
func postConversation(t *testing.T, r chi.Router, token, title string) *httptest.ResponseRecorder {
	t.Helper()
	b, err := json.Marshal(map[string]string{"title": title})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/conversations", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)
	return rw
}

// decodeConversation decodes the JSON body of a recorder into a
// map[string]any so the test can assert on the raw wire field name/value
// rather than round-tripping back through store.Conversation (which would
// hide a missing/renamed field).
func decodeConversation(t *testing.T, rw *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.NewDecoder(rw.Body).Decode(&m); err != nil {
		t.Fatalf("decode conversation response: %v\nbody: %s", err, rw.Body.String())
	}
	return m
}

// TestHandler_ConversationCarePhase_Create verifies that POST
// /api/conversations (single-conversation response) includes care_phase, and
// that a newly created conversation starts in INTAKE.
func TestHandler_ConversationCarePhase_Create(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "carephase-create-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@carephase-create.test",
		FullName:     "Pat",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	token := signedJWT(apiTestSecret, tid.String(), patient.ID.String(), "patient")

	rw := postConversation(t, r, token, "new complaint")
	if rw.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d (body: %s)", rw.Code, rw.Body.String())
	}

	conv := decodeConversation(t, rw)
	if got, want := conv["CarePhase"], string(store.CarePhaseIntake); got != want {
		t.Fatalf("create response CarePhase = %v, want %q", got, want)
	}
}

// TestHandler_ConversationCarePhase_List verifies that GET /api/conversations
// (list response) includes care_phase with the correct value for
// conversations in each of the three phases: INTAKE, AWAITING_REVIEW, and
// PLAN_DELIVERED.
func TestHandler_ConversationCarePhase_List(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "carephase-list-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@carephase-list.test",
		FullName:     "Pat",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	phases := []store.CarePhase{
		store.CarePhaseIntake,
		store.CarePhaseAwaitingReview,
		store.CarePhasePlanDelivered,
	}

	wantByTitle := make(map[string]store.CarePhase, len(phases))
	for _, phase := range phases {
		conv, err := s.CreateConversation(ctx, tid, patient.ID, string(phase)+" conversation")
		if err != nil {
			t.Fatalf("create conversation (%s): %v", phase, err)
		}
		if phase != store.CarePhaseIntake {
			if _, err := pool.Exec(ctx,
				`UPDATE conversations SET care_phase = $3 WHERE tenant_id = $1 AND id = $2`,
				tid.UUID(), conv.ID, string(phase),
			); err != nil {
				t.Fatalf("seed care_phase=%s: %v", phase, err)
			}
		}
		wantByTitle[conv.Title] = phase
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	token := signedJWT(apiTestSecret, tid.String(), patient.ID.String(), "patient")

	rw := getConversations(t, r, token)
	if rw.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (body: %s)", rw.Code, rw.Body.String())
	}

	var list []map[string]any
	if err := json.NewDecoder(rw.Body).Decode(&list); err != nil {
		t.Fatalf("decode list response: %v\nbody: %s", err, rw.Body.String())
	}
	if len(list) != len(phases) {
		t.Fatalf("expected %d conversations in list, got %d", len(phases), len(list))
	}

	seen := 0
	for _, conv := range list {
		title, _ := conv["Title"].(string)
		want, ok := wantByTitle[title]
		if !ok {
			t.Fatalf("unexpected conversation title %q in list response", title)
		}
		if got := conv["CarePhase"]; got != string(want) {
			t.Fatalf("list response CarePhase for %q = %v, want %q", title, got, want)
		}
		seen++
	}
	if seen != len(phases) {
		t.Fatalf("expected to verify %d conversations, verified %d", len(phases), seen)
	}
}
