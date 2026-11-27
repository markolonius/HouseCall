package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// TestPromptVersionsPinned fails when a prompt's text changes without its
// version constant being bumped. On a deliberate change: bump the version
// constant next to the prompt, then update the hash here.
func TestPromptVersionsPinned(t *testing.T) {
	cases := []struct {
		name, text, version, hash string
	}{
		{"TriageSystemPrompt", TriageSystemPrompt, TriageSystemPromptVersion, "fbf421e2c9b0930663486eaa8c59f2e4726e9a48a37a2cdc23a78b29f799c9d1"},
		{"InterviewSystemPrompt", InterviewSystemPrompt, InterviewSystemPromptVersion, "646b6d6feac3a352d40d9632e5a0b83b78219343d59af45eefc1ae899ed1e9d8"},
		{"SOAPDraftSystemPrompt", SOAPDraftSystemPrompt, SOAPDraftSystemPromptVersion, "2668e54c613c4156debecd0a152f612ac21c9d220993d52288d5e85a9c045aff"},
		{"RelaySystemPrompt", RelaySystemPrompt, RelaySystemPromptVersion, "bc31e5d27a35ec3303e3a47c0b21d75ff6ebf6481a8989bd56c36e485e63fa55"},
	}
	for _, c := range cases {
		sum := sha256.Sum256([]byte(c.text))
		got := hex.EncodeToString(sum[:])
		if got != c.hash {
			t.Errorf("%s: prompt text changed (version %q, sha256 %s) — bump its version constant and update this hash", c.name, c.version, got)
		}
	}
}
