// Package jwtutil is the single implementation of the HMAC-SHA256 (HS256) JWT
// issue/verify used by the Core API and the physician web app. Both transports
// import it so the token format and verification logic cannot drift apart.
//
// The claim schema is intentionally tiny (short field names) to keep tokens
// small. The signing path hardcodes the {"alg":"HS256"} header, so a token can
// never select a different algorithm; verification recomputes the HMAC and
// compares in constant time (hmac.Equal).
//
// Production note: a Cognito JWKS swap replaces Verify only — Issue and the
// rest of the codebase are unaffected.
package jwtutil

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// ErrInvalidToken is returned for any tamper, malformed, or expired token.
var ErrInvalidToken = errors.New("jwtutil: invalid token")

// Claims is the JSON payload carried in the JWT. Field names are kept short to
// minimise token size and MUST stay stable across both transports.
type Claims struct {
	TenantID  string `json:"tid"`
	ActorID   string `json:"sub"`
	ActorType string `json:"act"` // "patient" | "physician"
	Exp       int64  `json:"exp"`
}

// Issue creates an HS256 JWT whose Exp is set to now+ttl. The Exp field of the
// supplied claims is ignored and overwritten.
func Issue(secret []byte, c Claims, ttl time.Duration) (string, error) {
	c.Exp = time.Now().Add(ttl).Unix()
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	enc := hdr + "." + base64.RawURLEncoding.EncodeToString(payload)
	return enc + "." + sign(secret, enc), nil
}

// Verify validates an HS256 JWT and returns its decoded claims. It returns
// ErrInvalidToken for any format, signature, or expiry problem.
func Verify(secret []byte, token string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return Claims{}, ErrInvalidToken
	}
	msg := parts[0] + "." + parts[1]
	if !hmac.Equal([]byte(sign(secret, msg)), []byte(parts[2])) {
		return Claims{}, ErrInvalidToken
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Claims{}, ErrInvalidToken
	}
	var c Claims
	if err := json.Unmarshal(raw, &c); err != nil {
		return Claims{}, ErrInvalidToken
	}
	if time.Now().Unix() > c.Exp {
		return Claims{}, ErrInvalidToken
	}
	return c, nil
}

func sign(secret []byte, msg string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(msg))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
