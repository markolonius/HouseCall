// export_test.go exposes internal symbols needed by web_test (package web_test).
// This file is only compiled during `go test`.
package web

import (
	"context"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/store"
)

// WebClaims is an exported alias so web_test can inspect context values
// returned by WebClaimsFromCtx.
type WebClaims = webClaims

// StoreQuerier is the minimum store interface the Handler needs.
// Exposed so web_test can supply a fake without importing store.Store.
type StoreQuerier interface {
	GetPhysicianByEmail(ctx context.Context, tenant store.TenantID, email string) (store.Physician, error)
	ListPatientsByPhysician(ctx context.Context, tenant store.TenantID, physicianID uuid.UUID) ([]store.PanelPatient, error)
	ListRecommendationsByPhysician(ctx context.Context, tenant store.TenantID, physicianID uuid.UUID, state string) ([]store.Recommendation, error)

	// Review action methods (task 5.3).
	GetRecommendationForPhysician(ctx context.Context, tenant store.TenantID, physicianID, recID uuid.UUID) (store.Recommendation, error)
	GetPhysician(ctx context.Context, tenant store.TenantID, id uuid.UUID) (store.Physician, error)
	GetPatient(ctx context.Context, tenant store.TenantID, id uuid.UUID) (store.Patient, error)
	CreateAuditEvent(ctx context.Context, tenant store.TenantID, e store.AuditEvent) (store.AuditEvent, error)
	TxnW(ctx context.Context, fn func(store.TxWriter) error) error
}

// AuditQuerier is the audit-write interface used by the Handler.
// Exposed so web_test can supply a no-op implementation.
type AuditQuerier interface {
	Write(ctx context.Context, tenant store.TenantID, actorType string, actorID *uuid.UUID, eventType string, metadata map[string]any)
}

// NewWithQuerier constructs a Handler for tests, accepting interface values
// in place of the concrete *store.Store and *audit.Writer.
func NewWithQuerier(sq StoreQuerier, secret []byte, aq AuditQuerier) (*Handler, error) {
	tmpl, err := parseTemplates()
	if err != nil {
		return nil, err
	}
	return &Handler{
		store:     nil,
		secret:    secret,
		audit:     nil,
		templates: tmpl,
		storeQ:    sq,
		auditQ:    aq,
	}, nil
}

// IssueTestToken issues a signed web token with the default TTL. Used by
// web_test to construct session cookies for middleware tests.
func IssueTestToken(secret []byte, tenantID store.TenantID, actorID uuid.UUID, actorType string) (string, error) {
	return issueWebToken(secret, webClaims{
		TenantID:  tenantID,
		ActorID:   actorID,
		ActorType: actorType,
	})
}

// IssueTestTokenWithTTL issues a signed web token with a custom TTL offset.
// Pass a negative duration to produce an already-expired token.
func IssueTestTokenWithTTL(secret []byte, tenantID store.TenantID, actorID uuid.UUID, actorType string, ttl time.Duration) (string, error) {
	return issueWebTokenWithTTL(secret, webClaims{
		TenantID:  tenantID,
		ActorID:   actorID,
		ActorType: actorType,
	}, ttl)
}

// ExportedRequireWebAuth returns the requireWebAuth middleware for use in
// test routes that are registered outside Handler.Mount.
func ExportedRequireWebAuth(h *Handler) func(http.Handler) http.Handler {
	return h.requireWebAuth
}

// WebClaimsFromCtx re-exports the unexported helper for test assertions.
func WebClaimsFromCtx(ctx context.Context) (webClaims, bool) {
	return webClaimsFromCtx(ctx)
}
