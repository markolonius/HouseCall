// Package audit writes structured audit events to the store. PHI must never
// appear in eventType or metadata — use only identifiers and event names.
package audit

import (
	"context"
	"encoding/json"
	"log"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/store"
)

// Writer is a thin facade over the store's CreateAuditEvent. Errors are
// logged but not propagated so that audit failures never interrupt the
// clinical flow.
type Writer struct {
	s *store.Store
}

func New(s *store.Store) *Writer { return &Writer{s: s} }

// Write records an audit event. metadata values must be identifiers only —
// no PHI, no free-text clinical content.
func (w *Writer) Write(ctx context.Context, tenant store.TenantID, actorType string, actorID *uuid.UUID, eventType string, metadata map[string]any) {
	m, err := json.Marshal(metadata)
	if err != nil || m == nil {
		m = []byte("{}")
	}
	if _, err := w.s.CreateAuditEvent(ctx, tenant, store.AuditEvent{
		ActorType: actorType,
		ActorID:   actorID,
		EventType: eventType,
		Metadata:  m,
	}); err != nil {
		log.Printf("audit: write failed event=%s: %v", eventType, err)
	}
}
