package api

import (
	"context"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/store"
)

type ctxKey int

const claimsKey ctxKey = 0

// AuthClaims is the decoded JWT payload injected into every authenticated
// request context by the requireAuth middleware.
type AuthClaims struct {
	TenantID  store.TenantID
	ActorID   uuid.UUID
	ActorType string // "patient" | "physician"
}

func withClaims(ctx context.Context, c AuthClaims) context.Context {
	return context.WithValue(ctx, claimsKey, c)
}

func claimsFromCtx(ctx context.Context) (AuthClaims, bool) {
	c, ok := ctx.Value(claimsKey).(AuthClaims)
	return c, ok
}
