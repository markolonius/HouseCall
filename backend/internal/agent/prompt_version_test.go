package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// pinnedPromptHashes maps each released prompt version to the sha256 of its
// text. Entries are append-only history: when a prompt's text changes, bump its
// version constant and ADD a new entry here — do not edit an existing hash.
// Pinning by version means editing a prompt and just updating a hash (without
// bumping the version) cannot pass.
var pinnedPromptHashes = map[string]string{
	"triage/2026-11-27":     "fbf421e2c9b0930663486eaa8c59f2e4726e9a48a37a2cdc23a78b29f799c9d1",
	"interview/2026-11-27":  "646b6d6feac3a352d40d9632e5a0b83b78219343d59af45eefc1ae899ed1e9d8",
	"soap-draft/2026-11-27": "2668e54c613c4156debecd0a152f612ac21c9d220993d52288d5e85a9c045aff",
	"relay/2026-11-27":      "bc31e5d27a35ec3303e3a47c0b21d75ff6ebf6481a8989bd56c36e485e63fa55",
}

func TestPromptVersionsPinned(t *testing.T) {
	cases := []struct {
		name, text, version string
	}{
		{"TriageSystemPrompt", TriageSystemPrompt, TriageSystemPromptVersion},
		{"InterviewSystemPrompt", InterviewSystemPrompt, InterviewSystemPromptVersion},
		{"SOAPDraftSystemPrompt", SOAPDraftSystemPrompt, SOAPDraftSystemPromptVersion},
		{"RelaySystemPrompt", RelaySystemPrompt, RelaySystemPromptVersion},
	}
	for _, c := range cases {
		sum := sha256.Sum256([]byte(c.text))
		got := hex.EncodeToString(sum[:])
		want, ok := pinnedPromptHashes[c.version]
		if !ok {
			t.Errorf("%s: version %q has no pinned hash — add a map entry {%q: %q}", c.name, c.version, c.version, got)
			continue
		}
		if got != want {
			t.Errorf("%s: prompt text changed but version %q did not — bump its version constant and add a new map entry (sha256 %s)", c.name, c.version, got)
		}
	}
}
