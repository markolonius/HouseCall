# Proposal: Agent Safety, Structured Output and Evaluation

## Why

The AI Agent Runtime works end to end on a local `medgemma:4b`, but four gaps
make it unsafe to change models or prompts, and unsafe to rely on for triage:

1. **No evaluation harness.** `docs/ARCHITECTURE.md` §6 calls one
   non-optional. Nothing measures SOAP-note quality or how many emergencies
   triage catches, so a model or prompt change cannot be judged before it
   ships.
2. **Triage depends on the model alone and fails open.** In
   `add-agent-care-loop`, red-flag triage is one model call whose output is
   parsed for `<EMERGENT>`. If the call errors or the output is unparseable,
   the runtime proceeds with a routine interview turn. A patient describing
   crushing chest pain is then interviewed politely if the model misformats.
3. **Free-text markers.** Interview completion (`ReadyForNoteMarker`), triage
   (`<EMERGENT>`) and the new-complaint marker are detected by scanning model
   text. Commit `280bbf2` already had to work around small-model formatting
   drift.
4. **No provenance.** A recommendation does not record which model or prompt
   version drafted it, so a physician or an auditor cannot tell, and an eval
   regression cannot be traced to the recommendations it affected.

The development model is moving from `medgemma:4b` on the dev Mac to
**MedGemma 27B on a dedicated local inference machine** on the LAN, with AWS as
the later production host. The runtime must reach a remote host by
configuration, and refuse an unsafe endpoint in production.

## What Changes

- **MODIFIED** `ai-agent-runtime` / Local Model Endpoint Integration: the
  endpoint may be a LAN inference host; the runtime checks it at startup and,
  in production, refuses any endpoint that is not HTTPS.
- **ADDED** Structured Model Output: interview turns, SOAP drafts, triage and
  plan-relay turns are requested as JSON matching a schema and validated before
  use, with one repair retry and a fail-safe on failure.
- **ADDED** Deterministic Red-Flag Pre-Screen: a physician-reviewed rule set
  runs before model triage. A rule hit is emergent regardless of the model,
  including when the model call fails.
- **ADDED** Recommendation Provenance: each recommendation stores the model name
  and prompt version that drafted it; the physician queue shows them.
- **ADDED** Clinical Evaluation Harness: a versioned set of synthetic clinical
  vignettes and a runner (`make eval`) that reports triage recall, false
  emergent rate and SOAP validity against the configured model, with pass
  thresholds that gate model and prompt changes.

## Impact

- **Affected specs**: `ai-agent-runtime`, `physician-web-app`.
- **Affected code**: `backend/internal/agent` (client, drafter, prompts,
  outcome parsers, new `redflags` and `eval` packages), `backend/cmd/eval`
  (new), `backend/migrations` (recommendation provenance columns),
  `backend/internal/store`, `backend/internal/web` (queue rendering),
  `backend/docker-compose.yml`, `backend/.env.example`, `backend/README.md`.
- **Dependencies**: `add-agent-care-loop` must be merged and archived first;
  this change rewrites its triage, relay and new-complaint parsing.
- **Out of scope**: choosing the AWS hosting option (see `design.md`), JEPA or
  other signal models, model fine-tuning, LLM-as-judge scoring.

## Success Criteria

- Against MedGemma 27B on the inference machine, `make eval` passes all
  thresholds in `design.md`, and the baseline report is committed.
- Every emergent vignette in the eval set is caught by rule, model, or both
  (100% recall), including with the model endpoint deliberately failing.
- No model output reaches a parser as free text; every model turn is
  schema-validated or rejected.
- Every new recommendation shows its model and prompt version in the
  physician queue.
