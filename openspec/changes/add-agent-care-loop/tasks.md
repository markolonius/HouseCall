# Tasks: add-agent-care-loop

## Phase 1 — Care-phase foundation (server)

- [x] 1.1 Migration: add `care_phase` to `conversations`
      (`INTAKE | AWAITING_REVIEW | PLAN_DELIVERED`, NOT NULL, default
      `INTAKE`) with CHECK constraint; backfill existing rows from
      recommendation history (delivered → `PLAN_DELIVERED`, pending →
      `AWAITING_REVIEW`, else `INTAKE`). Migration test on seeded data.
- [x] 1.2 Migration: add `rejection_reason` (nullable text) to
      `recommendations`.
- [x] 1.3 Store: read/write `care_phase` on conversation CRUD; add
      `TransitionCarePhase` helper that enforces the allowed edges and runs
      inside the caller's transaction. Unit tests for every allowed and
      disallowed edge.
- [x] 1.4 API: include `care_phase` in conversation DTOs (list + single).
      Handler tests assert the field for each phase.

## Phase 2 — Phase dispatch, acknowledgement, double-draft fix

- [x] 2.1 Drafter: dispatch on `care_phase` in `DraftAsync`; `INTAKE` keeps
      today's interview path. Regression: existing interview-flow integration
      tests stay green.
- [x] 2.2 Drafter: on SOAP draft commit, persist the fixed acknowledgement
      assistant message and transition to `AWAITING_REVIEW` in the same
      transaction; push the message to the patient over WS. Tests: ack
      persisted, contains no SOAP content, phase moved atomically.
- [x] 2.3 Drafter: `AWAITING_REVIEW` path persists the fixed
      "report is with your physician" message, no model call, no new
      recommendation. Test reproduces the 2026-07-15 double-draft bug and
      proves it fixed. Close bead `HouseCall-lkzs` when this lands.
- [x] 2.4 Recommendation delivery (`web.go` review handler + `Transition`
      call site): transition conversation to `PLAN_DELIVERED` in the delivery
      transaction. Integration test: approve → phase `PLAN_DELIVERED`.

## Phase 3 — Rejection reason + revision loop

- [x] 3.1 `Transition`: rejection requires non-empty reason; stored +
      audited in the same transaction; conversation returns to `INTAKE`.
      Tests: empty reason refused, reason audited, phase reset.
- [x] 3.2 Web portal: reason textarea on the reject form, required
      client-side and validated server-side (re-render with error when
      empty). Handler tests both paths.
- [x] 3.3 Drafter: `INTAKE` turns include the latest rejection reason (when
      the conversation has a rejected recommendation newer than any
      delivered one) as reviewer guidance in the interview prompt. Tests:
      reason present in model context, absent from patient-facing output.

## Phase 4 — Post-approval plan relay

- [ ] 4.1 Relay system prompt (`prompt.go`): explain-only constraint,
      deferral instruction, new-complaint marker (same marker discipline as
      `parseInterviewTurn`); parser + unit tests for all three outcomes.
- [ ] 4.2 Drafter: `PLAN_DELIVERED` path — assemble context from delivered
      recommendation final content + conversation history, call model,
      persist + push reply. New-complaint marker → transition to `INTAKE`
      and run the intake turn. Integration tests: clarifying question
      answered, off-plan question deferred, new complaint reopens intake.

## Phase 5 — Red-flag triage

- [ ] 5.1 Triage prompt + strict `EMERGENT`/`ROUTINE` parser; unit tests
      including robustness to small-model formatting (see soap_robustness
      pattern).
- [ ] 5.2 Drafter: run triage before `INTAKE` interview turns. Emergent:
      fixed emergency-referral message, urgent `queue.updated` variant,
      audit event, suppress interview turn. Failure: fail open +
      `ai_interaction_failed`. Integration tests for both.

## Phase 6 — Verification

- [ ] 6.1 End-to-end (backend integration test): intake → ack →
      physician reject with reason → targeted re-interview → new draft →
      approve → deliver → relay Q&A → new complaint reopens intake.
- [ ] 6.2 Manual smoke on iOS simulator + web portal against compose stack;
      confirm acknowledgement and relay messages render through existing
      message sync with no iOS changes.
- [ ] 6.3 `openspec validate add-agent-care-loop --strict`; file follow-up
      beads for anything deferred (relay treatment for prescription
      payloads, portal auto-refresh).
