# Tasks: Agent Safety, Structured Output and Evaluation

Prerequisite: `add-agent-care-loop` merged and archived.

## Phase 1 — Remote model endpoint and provenance

- [x] 1.1 Configurable remote endpoint with startup check and production guard
  - Compose reads `AGENT_MODEL_BASE_URL` from `.env` with no hardcoded `host.docker.internal`; `.env.example` documents the LAN inference host and MedGemma 27B model name.
  - Startup `GET /models` check logs host-only warnings; `APP_ENV=production` refuses non-HTTPS endpoints.
  - Per-turn-type timeouts with env overrides.
  - Unit tests for the guard and the timeout selection.
- [ ] 1.2 Recommendation provenance
  - Migration adds `model_name` and `prompt_version` to `recommendations`.
  - Prompt version constants next to each prompt; a test fails if a prompt's text changes without its version.
  - Drafter writes both fields; store round-trip test.
- [ ] 1.3 Show provenance in the physician queue
  - Queue and detail views show model and prompt version; web handler test.
- [ ] 1.4 Document the development data rule (synthetic data only on the LAN inference host) in `backend/README.md`.

## Phase 2 — Evaluation harness

- [ ] 2.1 Eval case format and runner
  - `backend/evals/cases/` JSON format; `cmd/eval` runs cases against the configured endpoint; `make eval`.
  - Writes `backend/evals/results/<date>-<model>.json` and prints a summary; non-zero exit when a threshold fails.
  - Unit tests run the runner against a fake model server.
- [ ] 2.2 Initial vignette set
  - At least 30 emergent and 30 routine triage vignettes (with near-misses) and 15 interview-to-SOAP cases, all synthetic.
  - Each file marked reviewed by the physician-founder.
- [ ] 2.3 Baseline against MedGemma 27B
  - Run `make eval` on the inference machine and commit the result file; record failures as beads rather than tuning in this task.

## Phase 3 — Structured output

- [ ] 3.1 Schema-constrained client calls
  - Client sends `response_format` json_schema and validates every response locally; one repair retry; second failure is a turn failure with `ai_interaction_failed` audit.
  - Unit tests: valid, invalid-then-repaired, invalid twice.
- [ ] 3.2 Interview and SOAP turns use schemas
  - Replace `parseInterviewTurn` and SOAP text parsing; delete `ReadyForNoteMarker`.
- [ ] 3.3 Triage and relay turns use schemas
  - Replace `parseTriageTurn` and the new-complaint marker parser; delete `EmergentMarker`; `reason_code` lands in audit metadata.
- [ ] 3.4 SOAP revision uses the rejection reason
  - After a rejection, the SOAP draft prompt includes the physician's rejection reason as reviewer guidance (today only the interview turn sees it); the reason never reaches the patient or audit metadata.
- [ ] 3.5 Re-run `make eval`; no metric below the Phase 2 baseline; commit the result file.

## Phase 4 — Deterministic red-flag pre-screen

- [ ] 4.1 Rule set and matcher
  - `agent/redflags` package with embedded versioned rule file and minimal negation handling; table-driven tests per category, including negated phrases.
- [ ] 4.2 Wire rules before model triage
  - Rule hit is emergent without a model call; model failure without a rule hit keeps current behaviour; rule version logged with each emergent event.
  - Integration test: endpoint forced to fail, emergent message still produces the emergency message and urgent notification.
- [ ] 4.3 Screen every care phase
  - Rules and model triage run before the normal turn in `AWAITING_REVIEW` and `PLAN_DELIVERED` too (today triage runs only in `INTAKE`); an emergent result replaces the review reminder or relay reply with the referral and notifies physicians.
  - Integration tests for an emergency message in each phase.
- [ ] 4.4 Eval: rules-only mode
  - `make eval --rules-only` (model forced to fail) reports rules-only recall; thresholds from `design.md` pass; commit the result file.
- [ ] 4.5 Physician sign-off recorded in the rule file (version + reviewer).

## Phase 5 — Verification

- [ ] 5.1 Full `make eval` against MedGemma 27B passes every threshold; result committed.
- [ ] 5.2 Manual smoke against the compose stack with the LAN inference host: interview → SOAP → review shows provenance; emergent message triggers the referral with the inference host stopped.
- [ ] 5.3 `openspec validate add-agent-safety-and-evals --strict`; file follow-ups as beads.
