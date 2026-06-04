package api

import (
	"time"

	"github.com/markolonius/housecall/backend/internal/jwtutil"
)

const tokenTTL = 24 * time.Hour

// errInvalidToken is an alias of the shared sentinel so existing api code and
// errors.Is checks keep working unchanged.
var errInvalidToken = jwtutil.ErrInvalidToken

// rawClaims is the JWT payload shape. It aliases jwtutil.Claims so the API and
// the web app share one definition and can never drift apart.
type rawClaims = jwtutil.Claims

// issueToken creates an HS256 JWT containing the supplied claims, delegating to
// the shared jwtutil implementation. The Cognito JWKS swap (production)
// replaces verifyToken without touching issueToken or any domain code.
func issueToken(secret []byte, c AuthClaims) (string, error) {
	return jwtutil.Issue(secret, rawClaims{
		TenantID:  c.TenantID.String(),
		ActorID:   c.ActorID.String(),
		ActorType: c.ActorType,
	}, tokenTTL)
}

// verifyToken validates an HS256 JWT and returns its decoded claims. Returns
// errInvalidToken for any tamper, format, or expiry issue.
func verifyToken(secret []byte, token string) (rawClaims, error) {
	return jwtutil.Verify(secret, token)
}
