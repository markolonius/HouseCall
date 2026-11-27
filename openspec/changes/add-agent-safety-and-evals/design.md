# Design: Agent Safety, Structured Output and Evaluation

## Context

- One OpenAI-compatible client (`agent/client.go`), configured by
  `AGENT_MODEL_BASE_URL`, `AGENT_MODEL_NAME`, `AGENT_MODEL_API_KEY`, with a 60s
  per-call timeout. `docker-compose.yml` points it at
  `http://host.docker.internal:11434/v1` (Ollama on the dev Mac).
- Development moves to MedGemma 27B (text, instruction-tuned) served from a
  separate inference machine on the LAN. The serving stack on that machine
  (llama.cpp / llama-swap, vLLM or Ollama) is the developer's choice; the
  runtime only assumes the OpenAI-compatible `/v1/chat/completions` API.
- Production will run on AWS. That decision is not made in this change, and the
  runtime stays endpoint-agnostic so it remains a configuration change.

## Decisions

### 1. Endpoint configuration and the production guard

- `AGENT_MODEL_BASE_URL` accepts any host, so the LAN inference machine is set
  in `backend/.env` (for example `http://10.0.0.20:8080/v1`). Compose stops
  hardcoding `host.docker.internal`.
- At startup the runtime calls `GET {base}/models` once. If the endpoint is
  unreachable or does not list `AGENT_MODEL_NAME`, it logs a warning with the
  host only (never the API key) and keeps running. Drafting then fails safe
  per the existing "model endpoint is unavailable" scenario.
- When `APP_ENV=production`, the runtime refuses to start unless the base URL
  is `https://`. Plain HTTP is allowed only outside production.
- Per-call timeouts: triage 15s (it blocks the patient's reply), interview 60s,
  SOAP draft 120s (27B on one GPU is slower), relay 60s. Each is
  overridable by environment variable.

**Data rule for development.** The LAN link to the inference machine is plain
HTTP. Development and evaluation therefore use synthetic data only: seeded
patients and the eval vignettes. No real patient data is sent to the inference
machine. This is a working rule for the developer, recorded in
`backend/README.md`, not something the code can enforce.

### 2. Structured output

Each model turn type gets a JSON Schema:

| Turn | Schema (fields) |
|---|---|
| Interview | `{"action": "ask" \| "ready_for_note", "question": string}` |
| SOAP draft | `{"subjective", "objective", "assessment", "plan": string}` (matches the existing `soap_note` payload) |
| Triage | `{"classification": "EMERGENT" \| "ROUTINE", "reason_code": string}` |
| Plan relay | `{"reply": string, "new_complaint": boolean}` |

- Requests send `response_format: {"type": "json_schema", ...}`. Servers that
  support it (vLLM guided decoding, llama.cpp schema grammars, recent Ollama)
  constrain generation. Others ignore it, so the runtime always validates the
  response itself and never trusts the server to have enforced the schema.
- Invalid JSON or a schema mismatch triggers one repair retry that resends the
  conversation plus the validation error. A second failure is a turn failure:
  no recommendation or patient message is created, and an
  `ai_interaction_failed` audit event is written (the existing fail-safe).
- `parseInterviewTurn`, `parseTriageTurn` and the relay marker parser are
  replaced by schema decoding. The marker constants are deleted.
- `reason_code` is a short enum-like code (for example `chest_pain`), never
  free text, so it is safe to put in audit metadata.

### 3. Deterministic red-flag pre-screen

- A rule set in `backend/internal/agent/redflags/` (Go source plus an embedded
  JSON file) maps phrase patterns to categories, for example: chest pain with
  shortness of breath or radiation, stroke signs (face droop, arm weakness,
  speech change), suicidal ideation or self-harm intent, anaphylaxis signs,
  severe bleeding, loss of consciousness, severe shortness of breath.
- The rules aim for high recall and accept false positives. A false positive
  costs the patient an "if this is an emergency, call 911" message and the
  physician an urgent notification. A false negative can cost a life.
- Negation handling is deliberately minimal: an explicit "no chest pain"
  immediately preceding the phrase does not match; anything more ambiguous
  matches.
- The order in `INTAKE` becomes: rules → model triage → interview. A rule hit
  is emergent and skips model triage. Without a rule hit, model triage runs; a
  model `EMERGENT` is emergent. A model failure without a rule hit keeps the
  care-loop behaviour (proceed and audit), because the rules have already
  screened the message.
- The physician-founder reviews and signs off the rule set. The rule file
  records a version and the reviewer, and the version is logged with each
  emergent event.

### 4. Provenance

- Migration adds `model_name text` and `prompt_version text` to
  `recommendations` (nullable for existing rows).
- Prompt versions are constants next to each prompt in `prompt.go` (for example
  `soap-draft/2026-12-01`). Changing a prompt's text without changing its
  version constant fails a unit test that hashes the prompt text.
- The queue shows "Drafted by MedGemma 27B · prompt soap-draft/2026-12-01".

### 5. Evaluation harness

- `backend/evals/cases/*.json`: synthetic vignettes only, each with the patient
  turns and expected labels (`expected_triage`, required SOAP sections, facts
  that must or must not appear).
- Initial set: at least 30 emergent and 30 routine triage vignettes, including
  near-misses ("chest tightness after a workout last week, now resolved"), and
  at least 15 full interview-to-SOAP cases.
- `go run ./cmd/eval` (wrapped by `make eval`) runs every case against the
  configured endpoint and writes `backend/evals/results/<date>-<model>.json`
  plus a summary table.
- Thresholds, checked by the runner (non-zero exit on failure):

  | Metric | Threshold |
  |---|---|
  | Emergent recall (rules + model) | 100% |
  | Emergent recall with model endpoint forced to fail (rules only) | ≥ 90% |
  | False emergent rate on routine set | ≤ 15% |
  | Structured output validity after repair | 100% |
  | SOAP: objective section contains no exam findings absent from the vignette | 100% (rule check) |

- Evals do not run in CI (GitHub runners have no GPU). They run locally before
  merging any change to prompts, schemas, rules or the model, and the result
  file is committed with that change so regressions are visible in review.

## AWS later (informational, not decided here)

The runtime already reduces this to configuration. Options when production
starts:

1. **MedGemma 27B self-hosted on AWS** behind vLLM: SageMaker endpoint or a GPU
   EC2 instance in the PHI VPC. The bf16 weights are roughly 54 GB, so this
   needs a large-memory GPU or 8-bit/FP8 quantisation on a 48 GB card; size and
   price it when production is scheduled. Keeps "PHI never leaves our AWS
   account" literally true and has a fixed monthly cost from day one.
2. **A hosted model on AWS Bedrock** under the AWS BAA: no GPU to run, pay per
   call, data stays in AWS. Changes the positioning wording from "in-house AI"
   to "AI inside our AWS boundary".

Either option is re-validated with the same `make eval` thresholds before it
serves a patient.

## Risks

- **27B latency.** A single-GPU 27B model may take tens of seconds for a SOAP
  draft. Drafting is already async, but triage is in the patient's reply path;
  it gets the shortest timeout, and rule hits do not wait for the model.
- **Eval set bias.** Vignettes written by one person reflect that person's
  blind spots. The physician-founder writes or reviews every vignette, and the
  near-miss cases are added deliberately.
- **Rule false positives** may annoy patients with benign mentions. That is
  accepted for launch; tune with eval data, never by loosening recall.
