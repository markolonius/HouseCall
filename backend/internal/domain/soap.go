package domain

import (
	"encoding/json"
	"errors"
	"strings"
)

// PayloadTypeSOAPNote is the payload_type value for a structured
// Subjective/Objective/Assessment/Plan recommendation.  It is the only
// payload type produced by the clinical interview flow and MUST pass through
// physician review before delivery (the lifecycle machine enforces this).
const PayloadTypeSOAPNote = "soap_note"

// Section key constants for the soap_note JSON payload.  Using named
// constants keeps the prompt, the drafter, and the validator in sync.
const (
	SOAPKeySubjective  = "subjective"
	SOAPKeyObjective   = "objective"
	SOAPKeyAssessment  = "assessment"
	SOAPKeyPlan        = "plan"
)

// SOAPPayload is the structured payload for a soap_note recommendation.
// All four sections are required and must be non-empty strings.
//
// Assessment and Plan are the physician-reviewed clinical fields; they must
// never be delivered to the patient without a state-licensed physician
// transition (APPROVED or MODIFIED).  The lifecycle machine in
// recommendation.go enforces this invariant — this struct does not duplicate
// that logic.
type SOAPPayload struct {
	Subjective string `json:"subjective"`
	Objective  string `json:"objective"`
	Assessment string `json:"assessment"`
	Plan       string `json:"plan"`
}

// Validate returns an error if any of the four required sections is absent,
// empty, or contains only whitespace.  Call this before persisting a soap_note
// recommendation to ensure the payload is structurally complete.
func (s SOAPPayload) Validate() error {
	var missing []string
	if strings.TrimSpace(s.Subjective) == "" {
		missing = append(missing, SOAPKeySubjective)
	}
	if strings.TrimSpace(s.Objective) == "" {
		missing = append(missing, SOAPKeyObjective)
	}
	if strings.TrimSpace(s.Assessment) == "" {
		missing = append(missing, SOAPKeyAssessment)
	}
	if strings.TrimSpace(s.Plan) == "" {
		missing = append(missing, SOAPKeyPlan)
	}
	if len(missing) > 0 {
		return &SOAPValidationError{Missing: missing}
	}
	return nil
}

// ValidateSOAPPayload decodes raw JSON into a SOAPPayload and validates that
// all four sections are present and non-empty.  It is the canonical entry
// point for callers that hold a []byte payload (e.g. the store layer before
// persisting a soap_note recommendation).
func ValidateSOAPPayload(payload []byte) error {
	var sp SOAPPayload
	if err := json.Unmarshal(payload, &sp); err != nil {
		return errors.New("domain: soap_note payload is not valid JSON")
	}
	return sp.Validate()
}

// SOAPValidationError is returned by SOAPPayload.Validate / ValidateSOAPPayload
// when one or more required sections are absent or empty.
type SOAPValidationError struct {
	Missing []string
}

func (e *SOAPValidationError) Error() string {
	msg := "domain: soap_note payload missing required sections:"
	for i, s := range e.Missing {
		if i == 0 {
			msg += " " + s
		} else {
			msg += ", " + s
		}
	}
	return msg
}
