package web

// token.go adapts the shared jwtutil HS256 JWT helpers to the web app's typed
// session claims. The actual issue/verify logic lives in internal/jwtutil and
// is shared with the Core API (api/jwt.go) so the token format and verification
// cannot drift between transports.

import (
	"time"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/jwtutil"
	"github.com/markolonius/housecall/backend/internal/store"
)

// errInvalidWebToken aliases the shared sentinel so existing web code and
// errors.Is checks keep working unchanged.
var errInvalidWebToken = jwtutil.ErrInvalidToken

// sessionTTL mirrors the API token TTL so the cookie and the embedded JWT
// expire together.
const sessionTTL = 24 * time.Hour

// webClaims is the decoded JWT payload used by the physician web app.
type webClaims struct {
	TenantID  store.TenantID
	ActorID   uuid.UUID
	ActorType string // always "physician" for web sessions
}

// rawWebClaims is the JSON payload shape, aliased to the shared jwtutil.Claims
// so the web app and Core API share a single definition.
type rawWebClaims = jwtutil.Claims

// issueWebToken creates an HS256 JWT with the default session TTL.
func issueWebToken(secret []byte, c webClaims) (string, error) {
	return issueWebTokenWithTTL(secret, c, sessionTTL)
}

// issueWebTokenWithTTL creates an HS256 JWT that expires after ttl from now.
// A negative ttl produces an already-expired token (useful for tests).
func issueWebTokenWithTTL(secret []byte, c webClaims, ttl time.Duration) (string, error) {
	return jwtutil.Issue(secret, rawWebClaims{
		TenantID:  c.TenantID.String(),
		ActorID:   c.ActorID.String(),
		ActorType: c.ActorType,
	}, ttl)
}

// verifyWebToken validates an HS256 JWT and returns its decoded claims.
// Returns errInvalidWebToken for any tamper, format, or expiry issue.
func verifyWebToken(secret []byte, token string) (rawWebClaims, error) {
	return jwtutil.Verify(secret, token)
}
