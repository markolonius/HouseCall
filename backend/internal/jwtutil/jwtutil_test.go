package jwtutil

import (
	"strings"
	"testing"
	"time"
)

var testSecret = []byte("test-secret-key-do-not-use-in-prod")

func sampleClaims() Claims {
	return Claims{
		TenantID:  "11111111-1111-1111-1111-111111111111",
		ActorID:   "22222222-2222-2222-2222-222222222222",
		ActorType: "physician",
	}
}

func TestIssueVerify_RoundTrip(t *testing.T) {
	tok, err := Issue(testSecret, sampleClaims(), time.Hour)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	got, err := Verify(testSecret, tok)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	want := sampleClaims()
	if got.TenantID != want.TenantID || got.ActorID != want.ActorID || got.ActorType != want.ActorType {
		t.Fatalf("claims = %+v, want %+v", got, want)
	}
	if got.Exp <= time.Now().Unix() {
		t.Fatalf("exp not in the future: %d", got.Exp)
	}
}

func TestVerify_WrongSecret(t *testing.T) {
	tok, _ := Issue(testSecret, sampleClaims(), time.Hour)
	if _, err := Verify([]byte("a-different-secret"), tok); err != ErrInvalidToken {
		t.Fatalf("want ErrInvalidToken, got %v", err)
	}
}

func TestVerify_Expired(t *testing.T) {
	tok, _ := Issue(testSecret, sampleClaims(), -time.Minute)
	if _, err := Verify(testSecret, tok); err != ErrInvalidToken {
		t.Fatalf("want ErrInvalidToken for expired token, got %v", err)
	}
}

func TestVerify_TamperedPayload(t *testing.T) {
	tok, _ := Issue(testSecret, sampleClaims(), time.Hour)
	parts := strings.Split(tok, ".")
	// Swap in a different payload while keeping the original signature.
	forged := "eyJ0aWQiOiJ4In0" // {"tid":"x"} base64url, no padding
	bad := parts[0] + "." + forged + "." + parts[2]
	if _, err := Verify(testSecret, bad); err != ErrInvalidToken {
		t.Fatalf("want ErrInvalidToken for tampered payload, got %v", err)
	}
}

func TestVerify_Malformed(t *testing.T) {
	for _, tok := range []string{"", "a.b", "a.b.c.d", "not-a-token"} {
		if _, err := Verify(testSecret, tok); err != ErrInvalidToken {
			t.Fatalf("want ErrInvalidToken for %q, got %v", tok, err)
		}
	}
}

func TestVerify_BadSignatureEncoding(t *testing.T) {
	tok, _ := Issue(testSecret, sampleClaims(), time.Hour)
	parts := strings.Split(tok, ".")
	bad := parts[0] + "." + parts[1] + ".####"
	if _, err := Verify(testSecret, bad); err != ErrInvalidToken {
		t.Fatalf("want ErrInvalidToken for bad signature, got %v", err)
	}
}
