package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

const tokenTTL = 24 * time.Hour

var errInvalidToken = errors.New("api: invalid token")

// rawClaims is the JSON representation stored in the JWT payload. Field names
// are kept short to minimise token size.
type rawClaims struct {
	TenantID  string `json:"tid"`
	ActorID   string `json:"sub"`
	ActorType string `json:"act"` // "patient" | "physician"
	Exp       int64  `json:"exp"`
}

// issueToken creates an HS256 JWT containing the supplied claims. It uses
// only stdlib crypto — the Cognito JWKS swap (production) replaces
// verifyToken without touching issueToken or any domain code.
func issueToken(secret []byte, c AuthClaims) (string, error) {
	rc := rawClaims{
		TenantID:  c.TenantID.String(),
		ActorID:   c.ActorID.String(),
		ActorType: c.ActorType,
		Exp:       time.Now().Add(tokenTTL).Unix(),
	}
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payload, err := json.Marshal(rc)
	if err != nil {
		return "", err
	}
	enc := hdr + "." + base64.RawURLEncoding.EncodeToString(payload)
	return enc + "." + jwtSign(secret, enc), nil
}

// verifyToken validates an HS256 JWT and returns its decoded claims. Returns
// errInvalidToken for any tamper, format, or expiry issue.
func verifyToken(secret []byte, token string) (rawClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return rawClaims{}, errInvalidToken
	}
	msg := parts[0] + "." + parts[1]
	if jwtSign(secret, msg) != parts[2] {
		return rawClaims{}, errInvalidToken
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return rawClaims{}, errInvalidToken
	}
	var rc rawClaims
	if err := json.Unmarshal(raw, &rc); err != nil {
		return rawClaims{}, errInvalidToken
	}
	if time.Now().Unix() > rc.Exp {
		return rawClaims{}, errInvalidToken
	}
	return rc, nil
}

func jwtSign(secret []byte, msg string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(msg))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
