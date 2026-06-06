package api_test

// TestHandler_MessageIdempotency exercises the POST /api/conversations/{id}/messages
// handler with DB-backed assertions for the idempotency-key dedupe path.
//
// Assertions per test:
//   - Posting the same idempotency_key twice → ONE message row, same server ID
//     returned both times, ONE message.created audit event.
//   - A different key (or no key) → a new row (no collision).
//   - The same key under a different tenant/conversation → no collision.
//
// Follows the pattern from recommendations_test.go: uses apiTestPool + signedJWT.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/api"
	"github.com/markolonius/housecall/backend/internal/store"
)

// postMessage is a helper that sends POST /api/conversations/{convID}/messages
// with the supplied body and returns the recorder.
func postMessage(t *testing.T, r chi.Router, token, convID string, body any) *httptest.ResponseRecorder {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	url := fmt.Sprintf("/api/conversations/%s/messages", convID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)
	return rw
}

// decodeMessage decodes the JSON body of a recorder into store.Message.
func decodeMessage(t *testing.T, rw *httptest.ResponseRecorder) store.Message {
	t.Helper()
	var m store.Message
	if err := json.NewDecoder(rw.Body).Decode(&m); err != nil {
		t.Fatalf("decode message response: %v\nbody: %s", err, rw.Body.String())
	}
	return m
}

// TestHandler_MessageIdempotency_SameKey_OneDuplicate verifies that two POSTs
// with the same idempotency_key produce exactly one message row and return the
// same server message ID.
func TestHandler_MessageIdempotency_SameKey_OneDuplicate(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "idemp-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@idemp.test",
		FullName:     "Pat",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "idemp test")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	token := signedJWT(apiTestSecret, tid.String(), patient.ID.String(), "patient")
	ikey := uuid.NewString() // simulates local message UUID from iOS

	// First POST — should create the message (201).
	rw1 := postMessage(t, r, token, conv.ID.String(), map[string]string{
		"content":         "hello idempotent",
		"idempotency_key": ikey,
	})
	if rw1.Code != http.StatusCreated {
		t.Fatalf("first POST: expected 201, got %d (body: %s)", rw1.Code, rw1.Body.String())
	}
	m1 := decodeMessage(t, rw1)

	// Second POST with the same key — should return the existing row (200).
	rw2 := postMessage(t, r, token, conv.ID.String(), map[string]string{
		"content":         "hello idempotent",
		"idempotency_key": ikey,
	})
	if rw2.Code != http.StatusOK {
		t.Fatalf("second POST (dedupe): expected 200, got %d (body: %s)", rw2.Code, rw2.Body.String())
	}
	m2 := decodeMessage(t, rw2)

	// Both responses must carry the same server-assigned message ID.
	if m1.ID != m2.ID {
		t.Fatalf("dedupe: got different IDs: first=%s second=%s", m1.ID, m2.ID)
	}

	// Exactly ONE message row should exist for this conversation.
	msgs, err := s.ListMessagesByConversation(ctx, tid, conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected exactly 1 message row, got %d", len(msgs))
	}

	// Exactly ONE message.created audit event.
	var count int
	err = pool.QueryRow(ctx,
		`SELECT count(*) FROM audit_events
		  WHERE tenant_id  = $1
		    AND event_type = 'message.created'`,
		tid.UUID(),
	).Scan(&count)
	if err != nil {
		t.Fatalf("count audit events: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 message.created audit event, got %d", count)
	}
}

// TestHandler_MessageIdempotency_DifferentKey_NewRow verifies that a POST with
// a different idempotency_key creates a second (distinct) message row.
func TestHandler_MessageIdempotency_DifferentKey_NewRow(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "idemp-diffkey-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@diffkey.test",
		FullName:     "Pat",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "diffkey test")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	token := signedJWT(apiTestSecret, tid.String(), patient.ID.String(), "patient")

	rw1 := postMessage(t, r, token, conv.ID.String(), map[string]string{
		"content":         "message one",
		"idempotency_key": uuid.NewString(),
	})
	if rw1.Code != http.StatusCreated {
		t.Fatalf("first POST: expected 201, got %d", rw1.Code)
	}

	rw2 := postMessage(t, r, token, conv.ID.String(), map[string]string{
		"content":         "message two",
		"idempotency_key": uuid.NewString(), // different key
	})
	if rw2.Code != http.StatusCreated {
		t.Fatalf("second POST (different key): expected 201, got %d", rw2.Code)
	}

	m1 := decodeMessage(t, rw1)
	m2 := decodeMessage(t, rw2)

	if m1.ID == m2.ID {
		t.Fatal("different idempotency keys must produce different message IDs")
	}

	msgs, err := s.ListMessagesByConversation(ctx, tid, conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 message rows for different keys, got %d", len(msgs))
	}
}

// TestHandler_MessageIdempotency_NoKey_AlwaysInsert verifies that a POST with
// no idempotency_key always inserts (legacy behavior unchanged).
func TestHandler_MessageIdempotency_NoKey_AlwaysInsert(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "idemp-nokey-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@nokey.test",
		FullName:     "Pat",
		State:        "TX",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "nokey test")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	token := signedJWT(apiTestSecret, tid.String(), patient.ID.String(), "patient")

	rw1 := postMessage(t, r, token, conv.ID.String(), map[string]string{
		"content": "no key first",
	})
	if rw1.Code != http.StatusCreated {
		t.Fatalf("first POST (no key): expected 201, got %d", rw1.Code)
	}

	rw2 := postMessage(t, r, token, conv.ID.String(), map[string]string{
		"content": "no key second",
	})
	if rw2.Code != http.StatusCreated {
		t.Fatalf("second POST (no key): expected 201, got %d", rw2.Code)
	}

	msgs, err := s.ListMessagesByConversation(ctx, tid, conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 rows when no key supplied, got %d", len(msgs))
	}
}

// TestHandler_MessageIdempotency_TenantScoping verifies that the same
// idempotency_key string under a different tenant does NOT collide with a
// message in the first tenant.
func TestHandler_MessageIdempotency_TenantScoping(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	// Shared idempotency key — same string for both tenants.
	sharedKey := uuid.NewString()

	makeTenantFixture := func(name string) (store.TenantID, uuid.UUID, uuid.UUID) {
		tenant, err := s.CreateTenant(ctx, "dtc", name+"-"+uuid.NewString())
		if err != nil {
			t.Fatalf("create tenant %s: %v", name, err)
		}
		tid := store.TenantID(tenant.ID)
		pat, err := s.CreatePatient(ctx, tid, store.Patient{
			Email:        "p@" + name + ".test",
			FullName:     "P",
			State:        "CA",
			PasswordHash: "h",
		})
		if err != nil {
			t.Fatalf("create patient %s: %v", name, err)
		}
		conv, err := s.CreateConversation(ctx, tid, pat.ID, name+" conv")
		if err != nil {
			t.Fatalf("create conversation %s: %v", name, err)
		}
		return tid, pat.ID, conv.ID
	}

	tidA, patA, convA := makeTenantFixture("tenant-A")
	tidB, patB, convB := makeTenantFixture("tenant-B")

	routerA := api.New(s, apiTestSecret)
	rA := chi.NewRouter()
	routerA.Mount(rA)

	routerB := api.New(s, apiTestSecret)
	rB := chi.NewRouter()
	routerB.Mount(rB)

	tokenA := signedJWT(apiTestSecret, tidA.String(), patA.String(), "patient")
	tokenB := signedJWT(apiTestSecret, tidB.String(), patB.String(), "patient")

	// First: tenant A inserts with the shared key.
	rwA1 := postMessage(t, rA, tokenA, convA.String(), map[string]string{
		"content":         "tenant A message",
		"idempotency_key": sharedKey,
	})
	if rwA1.Code != http.StatusCreated {
		t.Fatalf("tenant A first POST: expected 201, got %d", rwA1.Code)
	}
	mA1 := decodeMessage(t, rwA1)

	// Tenant B inserts with the same key — must NOT collide with tenant A's row.
	rwB1 := postMessage(t, rB, tokenB, convB.String(), map[string]string{
		"content":         "tenant B message",
		"idempotency_key": sharedKey,
	})
	if rwB1.Code != http.StatusCreated {
		t.Fatalf("tenant B POST (same key): expected 201, got %d (cross-tenant collision!)", rwB1.Code)
	}
	mB1 := decodeMessage(t, rwB1)

	if mA1.ID == mB1.ID {
		t.Fatal("tenant isolation violated: same idempotency_key under different tenants returned same message ID")
	}

	// Tenant A's second POST with the same key → dedupe (200, same ID as mA1).
	rwA2 := postMessage(t, rA, tokenA, convA.String(), map[string]string{
		"content":         "tenant A message",
		"idempotency_key": sharedKey,
	})
	if rwA2.Code != http.StatusOK {
		t.Fatalf("tenant A second POST (dedupe): expected 200, got %d", rwA2.Code)
	}
	mA2 := decodeMessage(t, rwA2)
	if mA2.ID != mA1.ID {
		t.Fatalf("tenant A dedupe: expected same ID %s, got %s", mA1.ID, mA2.ID)
	}

	// Verify tenant B also dedupes correctly.
	rwB2 := postMessage(t, rB, tokenB, convB.String(), map[string]string{
		"content":         "tenant B message",
		"idempotency_key": sharedKey,
	})
	if rwB2.Code != http.StatusOK {
		t.Fatalf("tenant B second POST (dedupe): expected 200, got %d", rwB2.Code)
	}
	mB2 := decodeMessage(t, rwB2)
	if mB2.ID != mB1.ID {
		t.Fatalf("tenant B dedupe: expected same ID %s, got %s", mB1.ID, mB2.ID)
	}
}
