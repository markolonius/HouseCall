package agent

import (
	"context"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// This file holds the database-free seams shared by the Drafter and the
// evaluation runner (cmd/eval). The Drafter builds its model calls through
// these helpers, so the evals exercise the same prompts and parsers as
// production rather than re-implemented copies. Nothing here logs content.

func storeMessagesToModel(msgs []store.Message) []Message {
	out := make([]Message, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, Message{Role: m.Role, Content: m.Content})
	}
	return out
}

// triageModelMessages prepends TriageSystemPrompt to the conversation history.
func triageModelMessages(history []Message) []Message {
	out := make([]Message, 0, len(history)+1)
	out = append(out, Message{Role: "system", Content: TriageSystemPrompt})
	return append(out, history...)
}

// soapModelMessages prepends SOAPDraftSystemPrompt to the conversation history.
func soapModelMessages(history []Message) []Message {
	out := make([]Message, 0, len(history)+1)
	out = append(out, Message{Role: "system", Content: SOAPDraftSystemPrompt})
	return append(out, history...)
}

// generateSOAPPayload runs the generate -> parse -> validate cycle with up to
// soapDraftMaxAttempts fresh generations. Transport/model errors are returned
// immediately; a parse/validation error is returned only after the last
// attempt. It returns the raw text of the final attempt alongside the payload.
func generateSOAPPayload(ctx context.Context, mc ModelClient, modelMsgs []Message) (string, domain.SOAPPayload, error) {
	var text string
	var payload domain.SOAPPayload
	var parseErr error
	for attempt := 0; attempt < soapDraftMaxAttempts; attempt++ {
		var err error
		text, err = completeFor(ctx, mc, TurnSOAP, modelMsgs)
		if err != nil {
			return "", domain.SOAPPayload{}, err
		}
		payload, parseErr = parseSOAPSections(text)
		if parseErr == nil {
			if vErr := payload.Validate(); vErr != nil {
				parseErr = vErr
			}
		}
		if parseErr == nil {
			break
		}
	}
	if parseErr != nil {
		return "", domain.SOAPPayload{}, parseErr
	}
	return text, payload, nil
}

// EvalTriage runs the production triage classification call over history and
// returns the parsed outcome; the raw model text is deliberately not returned (PHI).
// A non-nil error means the model call failed; TriageUnparseable means the
// output carried neither or both markers.
func EvalTriage(ctx context.Context, mc ModelClient, history []Message) (TriageOutcome, error) {
	raw, err := completeFor(ctx, mc, TurnTriage, triageModelMessages(history))
	if err != nil {
		return TriageUnparseable, err
	}
	return parseTriageTurn(raw), nil
}

// EvalSOAP runs the production SOAP draft call (including its retry policy)
// over history. A *ParseError / validation error means the structured output
// was invalid after all attempts.
func EvalSOAP(ctx context.Context, mc ModelClient, history []Message) (domain.SOAPPayload, error) {
	_, payload, err := generateSOAPPayload(ctx, mc, soapModelMessages(history))
	return payload, err
}

// EvalPromptVersions reports the current prompt version constants for result
// provenance.
func EvalPromptVersions() map[string]string {
	return map[string]string{
		"triage":     TriageSystemPromptVersion,
		"interview":  InterviewSystemPromptVersion,
		"soap_draft": SOAPDraftSystemPromptVersion,
	}
}

// String renders a TriageOutcome as EMERGENT, ROUTINE or UNPARSEABLE.
func (o TriageOutcome) String() string {
	switch o {
	case TriageEmergent:
		return "EMERGENT"
	case TriageRoutine:
		return "ROUTINE"
	}
	return "UNPARSEABLE"
}
