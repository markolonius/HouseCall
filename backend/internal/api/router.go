// Package api implements the Core API: auth, REST endpoints, and the
// WebSocket hub. All routes are tenant-scoped via the requireAuth middleware.
package api

import (
	"github.com/go-chi/chi/v5"
	"github.com/markolonius/housecall/backend/internal/audit"
	"github.com/markolonius/housecall/backend/internal/store"
)

// Router holds shared dependencies for all HTTP handlers.
type Router struct {
	store  *store.Store
	hub    *Hub
	secret []byte
	audit  *audit.Writer
}

// New constructs a Router. secret is the HMAC-SHA256 key used to sign and
// verify JWTs; it must be non-empty (validated at startup in cmd/server).
func New(s *store.Store, secret []byte) *Router {
	return &Router{
		store:  s,
		hub:    newHub(),
		secret: secret,
		audit:  audit.New(s),
	}
}

// Mount registers all API and WebSocket routes on r.
func (rt *Router) Mount(r chi.Router) {
	// Unauthenticated.
	r.Post("/api/auth/login", rt.handleLogin)

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
