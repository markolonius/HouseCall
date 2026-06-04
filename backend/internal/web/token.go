package web

// token.go contains the JWT issue/verify helpers for the web package.
// The JWT format is identical to the Core API's (api/jwt.go): HS256 with the
// same rawClaims JSON shape, so a token issued here can be verified by the
// Core API middleware if needed. The logic is not shared via import because
// api.issueToken / api.verifyToken are unexported; the implementation is
// small enough to duplicate without risk of divergence. Any future change to
// the claim schema must be applied in both places.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/store"
)

var errInvalidWebToken = errors.New("web: invalid token")

// sessionTTL mirrors the API token TTL so the cookie and the embedded JWT
// expire together.
const sessionTTL = 24 * time.Hour

// webClaims is the decoded JWT payload used by the physician web app.
type webClaims struct {
	TenantID  store.TenantID
	ActorID   uuid.UUID
	ActorType string // always "physician" for web sessions
}

// rawWebClaims is the JSON representation stored in the JWT payload. Field
// names match api/jwt.go rawClaims so tokens are interoperable.
type rawWebClaims struct {
	TenantID  string `json:"tid"`
	ActorID   string `json:"sub"`
	ActorType string `json:"act"`
	Exp       int64  `json:"exp"`
}

// issueWebToken creates an HS256 JWT with the default session TTL.
func issueWebToken(secret []byte, c webClaims) (string, error) {
	return issueWebTokenWithTTL(secret, c, sessionTTL)
}

// issueWebTokenWithTTL creates an HS256 JWT that expires after ttl from now.
// A negative ttl produces an already-expired token (useful for tests).
func issueWebTokenWithTTL(secret []byte, c webClaims, ttl time.Duration) (string, error) {
	rc := rawWebClaims{
		TenantID:  c.TenantID.String(),
		ActorID:   c.ActorID.String(),
		ActorType: c.ActorType,
		Exp:       time.Now().Add(ttl).Unix(),
	}
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payload, err := json.Marshal(rc)
	if err != nil {
		return "", err
	}
	enc := hdr + "." + base64.RawURLEncoding.EncodeToString(payload)
	return enc + "." + webJWTSign(secret, enc), nil
}

// verifyWebToken validates an HS256 JWT and returns its decoded claims.
// Returns errInvalidWebToken for any tamper, format, or expiry issue.
func verifyWebToken(secret []byte, token string) (rawWebClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return rawWebClaims{}, errInvalidWebToken
	}
	msg := parts[0] + "." + parts[1]
	if webJWTSign(secret, msg) != parts[2] {
		return rawWebClaims{}, errInvalidWebToken
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return rawWebClaims{}, errInvalidWebToken
	}
	var rc rawWebClaims
	if err := json.Unmarshal(raw, &rc); err != nil {
		return rawWebClaims{}, errInvalidWebToken
	}
	if time.Now().Unix() > rc.Exp {
		return rawWebClaims{}, errInvalidWebToken
	}
	return rc, nil
}

func webJWTSign(secret []byte, msg string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(msg))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
