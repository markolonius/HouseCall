// Package api implements the Core API: auth, REST endpoints, and the
// WebSocket hub. All routes are tenant-scoped via the requireAuth middleware.
package api

import (
	"github.com/go-chi/chi/v5"
	"github.com/markolonius/housecall/backend/internal/agent"
	"github.com/markolonius/housecall/backend/internal/audit"
	"github.com/markolonius/housecall/backend/internal/store"
)

// Router holds shared dependencies for all HTTP handlers.
type Router struct {
	store   *store.Store
	hub     *Hub
	secret  []byte
	audit   *audit.Writer
	drafter *agent.Drafter
}

// New constructs a Router. secret is the HMAC-SHA256 key used to sign and
// verify JWTs; it must be non-empty (validated at startup in cmd/server).
// Wire the Drafter after construction via SetDrafter to break the circular
// dependency (Router → Drafter → Router as PhysicianNotifier).
func New(s *store.Store, secret []byte) *Router {
	return &Router{
		store:  s,
		hub:    newHub(),
		secret: secret,
		audit:  audit.New(s),
	}
}

// SendToPhysicians broadcasts event to all physicians connected via WebSocket
// in the given tenant. It implements agent.PhysicianNotifier so the Router can
// be passed directly to agent.NewDrafter in cmd/server.
func (rt *Router) SendToPhysicians(tenantID string, event []byte) {
	rt.hub.SendToPhysicians(tenantID, event)
}

// SendToPatient delivers event to the patient identified by patientID in the
// given tenant. It implements agent.PatientNotifier so the Router can be
// passed directly to agent.NewDrafter in cmd/server. The caller is
// responsible for ensuring the event payload contains only identifiers — never
// message content or other PHI.
func (rt *Router) SendToPatient(tenantID, patientID string, event []byte) {
	rt.hub.SendToPatient(tenantID, patientID, event)
}

// SetDrafter wires the AI Agent Runtime drafter after construction. This
// breaks the circular dependency between Router (which needs the Drafter) and
// the Drafter (which needs the Router as a PhysicianNotifier): construct the
// Router first — with a nil drafter — then construct the Drafter pointing at
// the Router, then call SetDrafter.
func (rt *Router) SetDrafter(d *agent.Drafter) { rt.drafter = d }

// Mount registers all API and WebSocket routes on r.
func (rt *Router) Mount(r chi.Router) {
	// Unauthenticated.
	r.Post("/api/auth/login", rt.handleLogin)
	r.Post("/api/auth/register", rt.handleRegister)

	// WebSocket — JWT validated inside handleWS on the initial request.
	r.Get("/ws", rt.handleWS)

	// Authenticated REST.
	r.Group(func(r chi.Router) {
		r.Use(rt.requireAuth)

		r.Get("/api/conversations", rt.handleListConversations)
		r.Post("/api/conversations", rt.handleCreateConversation)

		r.Get("/api/conversations/{id}/messages", rt.handleListMessages)
		r.Post("/api/conversations/{id}/messages", rt.handleCreateMessage)

		r.Get("/api/recommendations", rt.handleListRecommendations)
		r.Get("/api/recommendations/{id}", rt.handleGetRecommendation)
		r.Post("/api/recommendations/{id}/review", rt.handleReviewRecommendation)
	})
}
