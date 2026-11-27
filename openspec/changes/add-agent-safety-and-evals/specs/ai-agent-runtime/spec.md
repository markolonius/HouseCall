# ai-agent-runtime (delta)

## MODIFIED Requirements

### Requirement: Local Model Endpoint Integration

The AI Agent Runtime SHALL call a configurable OpenAI-compatible model endpoint.
The endpoint URL SHALL be configuration-driven so the same code path serves a
model on the developer's machine, a model on a separate inference host on the
local network, and, later, a production-hosted model. The runtime SHALL check
the configured endpoint once at startup and SHALL continue running if the check
fails. When running in production, the runtime SHALL refuse to start with an
endpoint that does not use HTTPS. The runtime SHALL never log the endpoint's
API key.

#### Scenario: The runtime calls the configured endpoint

**Given** a configured OpenAI-compatible model endpoint
**When** the AI Agent Runtime drafts a recommendation
**Then** it sends the assembled context to that endpoint
**And** it uses the model's response as the recommendation's draft content

#### Scenario: The model endpoint is unavailable

**Given** the configured model endpoint is unreachable or returns an error
**When** the AI Agent Runtime attempts to draft a recommendation
**Then** no Recommendation is created
**And** an `ai_interaction_failed` audit event is written
**And** no error content is presented to the patient as a clinical response

#### Scenario: A LAN inference host is configured

**Given** the endpoint is configured as an HTTP address on the local network
**And** the runtime is not running in production
**When** the runtime starts
**Then** it checks the endpoint and serves requests through it

#### Scenario: Production refuses a plain-HTTP endpoint

**Given** the runtime is running in production
**And** the configured endpoint does not use HTTPS
**When** the runtime starts
**Then** it exits with a configuration error before serving any request

## ADDED Requirements

### Requirement: Structured Model Output

The AI Agent Runtime SHALL request every model turn (interview, SOAP draft,
triage, plan relay) as JSON conforming to a turn-specific schema, and SHALL
validate each response against that schema before acting on it. An invalid
response SHALL be retried once with the validation error; a second invalid
response SHALL be treated as a failed turn that creates no recommendation and
no patient-facing message and writes an `ai_interaction_failed` audit event.

#### Scenario: A valid structured response is used

**Given** the model returns JSON that matches the turn's schema
**When** the runtime processes the turn
**Then** it acts on the decoded fields

#### Scenario: An invalid response is repaired

**Given** the model returns output that does not match the turn's schema
**When** the runtime retries once with the validation error
**And** the retry returns valid JSON
**Then** the runtime acts on the retried response

#### Scenario: A response that stays invalid fails safe

**Given** the model returns invalid output on the first attempt and the retry
**When** the runtime processes the turn
**Then** no recommendation and no patient-facing message are created
**And** an `ai_interaction_failed` audit event is written

### Requirement: Deterministic Red-Flag Pre-Screen

The AI Agent Runtime SHALL screen every patient message against a versioned,
physician-reviewed red-flag rule set before any other processing, in every care
phase (`INTAKE`, `AWAITING_REVIEW` and `PLAN_DELIVERED`), and, when no rule
matches, SHALL run model triage before the phase's normal turn (interview,
review reminder or plan relay). A rule match
SHALL be treated as emergent without consulting the model, and SHALL produce
the emergency-referral message, the urgent physician notification and an audit
event recording the rule-set version and category, even when the model endpoint
is unavailable. The model SHALL NOT be able to downgrade a rule match.

#### Scenario: A rule match is emergent without the model

**Given** a conversation in `INTAKE`
**When** the patient reports chest pain spreading to the arm with shortness of breath
**Then** the patient receives the emergency-referral message
**And** physicians receive an urgent notification
**And** no model triage call is made for that message

#### Scenario: Emergencies are caught with the model down

**Given** the model endpoint is unreachable
**When** a patient message matches a red-flag rule
**Then** the emergency-referral message and urgent notification are still produced

#### Scenario: Emergencies are caught after the interview

**Given** a conversation in `AWAITING_REVIEW` or `PLAN_DELIVERED`
**When** the patient reports crushing chest pain
**Then** the patient receives the emergency-referral message instead of the review reminder or a plan explanation
**And** physicians receive an urgent notification

#### Scenario: An explicitly negated phrase does not match

**Given** a patient message saying "no chest pain, just a stuffy nose"
**When** the pre-screen runs
**Then** the chest-pain rule does not match
**And** model triage runs as normal

### Requirement: Recommendation Provenance

The AI Agent Runtime SHALL record on every recommendation it drafts the model
name and the prompt version that produced it. A prompt's version SHALL change
whenever its text changes.

#### Scenario: A drafted recommendation records its provenance

**Given** the runtime drafts a SOAP-note recommendation
**When** the recommendation is stored
**Then** it carries the configured model name and the SOAP prompt version

### Requirement: Clinical Evaluation Harness

The project SHALL maintain a versioned set of synthetic clinical vignettes and
an evaluation runner that measures, against the configured model endpoint,
emergent-triage recall, false emergent rate, structured-output validity and
SOAP objective-section fidelity, and fails when any metric is below its
threshold. Vignettes SHALL contain no real patient data. Changes to prompts,
schemas, red-flag rules or the model SHALL include an evaluation result.

#### Scenario: The runner reports and gates

**Given** the vignette set and a configured model endpoint
**When** the evaluation runner completes
**Then** it writes a result file with each metric
**And** it exits with failure if any metric is below its threshold

#### Scenario: Rules-only recall is measured

**Given** the evaluation runner is started with the model forced to fail
**When** it runs the triage vignettes
**Then** it reports emergent recall from the red-flag rules alone
