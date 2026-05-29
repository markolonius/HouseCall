# Design: PA Chronic-Disease Launch

## Context

This change is the first clinical-domain layer on top of the generic
physician-in-loop platform delivered by `add-cloud-platform-mvp`. It is
written for a solo physician-founder operating in Pennsylvania, against the
strategic decisions captured in `docs/LAUNCH_STRATEGY.md`. The design choices
below favor explicit, boring patterns over flexibility, on the assumption
that the cost of a second state or a second clinical area is paid by a
future change proposal, not by speculative abstraction now.

## Goals / Non-Goals

### Goals
- Make the cloud MVP loop operational for a real PA cardiometabolic chronic-
  disease practice.
- Establish patterns (intake → eligibility → billing → enrollment → protocol-
  driven care) that future state and condition expansion can reuse without
  rewriting the data model.
- Surface PA-specific compliance (PA-PC entity, license verification, PDMP)
  as discrete, auditable checkpoints rather than implicit conventions.

### Non-Goals
- Generic multi-state eligibility engine. PA is hardcoded as the only
  eligible state in Phase 1; future states are added by future changes that
  evolve the eligibility surface.
- Generic protocol DSL. Phase 1 protocols are encoded as versioned Go
  packages, one per condition. A protocol DSL is justified only when the
  founder is no longer the only protocol author.
- Insurance billing, GLP-1 protocols, controlled-substance prescribing.
- Real external service integration (Stripe, Surescripts, Labcorp). The
  surfaces ship; the wires are added in separate, smaller changes once
  vendor selections and BAAs are finalized.

## Decisions

### Decision: State eligibility is a hardcoded allowlist, not a configuration
PA is the only eligible state in this change. The eligibility check is a Go
constant + a database constraint, not a runtime-configurable table. Adding a
second state intentionally requires a code change and a new specification
proposal so that the legal and operational work that always accompanies a
new state cannot be skipped by editing a config row in production.

**Alternatives considered**: a `state_eligibility` table that ops can edit
at runtime. Rejected — the legal-track work that *must* precede serving a
new state (state board registration of the PC, malpractice endorsement,
license, friendly-PC or self-owned PC verification in CPOM states, PDMP
enrollment) cannot be enforced by a database row. Coupling it to a code
change makes the engineering review the forcing function.

### Decision: Subscription billing uses Stripe; no PHI flows to Stripe
Stripe is the cash-pay billing primitive. The Stripe customer record
contains only an opaque internal patient identifier and the subscription
tier name. Patient name, email, condition list, and any clinical data
remain in the HouseCall backend. Email for receipts is sent by the
HouseCall backend, not by Stripe templates that would require the patient's
email to be on Stripe's side.

**Alternatives considered**: Stripe Customer Portal for self-service
cancellation. Deferred — Phase 1 supports cancellation by patient request
through the support channel; Customer Portal can be added without re-
architecting once the email-segregation pattern is hardened.

### Decision: Pricing tiers map to condition-count bundles
- $29 / month — one condition (diabetes OR hypertension OR hyperlipidemia)
- $39 / month — two of the three
- $49 / month — all three (or any addition of a future condition into the
  bundle)

Pricing is keyed to *number of conditions enrolled*, not to the specific
conditions. This keeps the billing surface trivial and lets the protocol
library evolve independently.

**Alternatives considered**: usage-based or per-prescription pricing.
Rejected — predictable monthly cost is a positioning principle
(`docs/POSITIONING.md`).

### Decision: Protocols are versioned Go packages, one per condition
`internal/protocols/diabetes_t2`, `internal/protocols/hypertension`,
`internal/protocols/hyperlipidemia`. Each exports a pure function
`Recommend(ctx, patient_state, recent_vitals, current_meds, recent_labs)
([]DraftRecommendation, error)` returning a slice of
`DraftRecommendation` values that the AI Agent Runtime then turns into
`Recommendation` rows in `PENDING_REVIEW`. Protocol version is stamped on
every recommendation produced so a future protocol change is auditable.

**Alternatives considered**: a YAML/JSON protocol DSL interpreted at
runtime. Rejected for Phase 1 — the protocols are authored by one person
(the founder), edited under code review, and tested with the rest of the
backend. A DSL adds an interpreter and a separate review surface for zero
current benefit.

### Decision: The AI Agent Runtime gets a strategy-selection layer
The cloud MVP's runtime has a single strategy (generic guidance). This
change adds a strategy-selection layer that, given a patient message or
check-in, picks the chronic-disease protocol strategies matching the
patient's enrolled conditions and runs them in addition to (or instead of,
when the message is a vitals check-in) the generic guidance strategy. The
selection logic is hardcoded for Phase 1; a plug-in registry is deferred.

### Decision: Vitals check-ins are server-scheduled, push-delivered
The backend owns the check-in schedule (weekly during titration, monthly at
maintenance, with titration state tracked per (patient, condition) pair).
When a check-in is due, the backend creates a check-in conversation thread
and delivers an APNs push to the patient. The patient submits vitals
inline in the check-in conversation; the AI agent processes the
submission against the protocol the same way as any other patient
message.

**Alternatives considered**: client-scheduled check-ins driven by the iOS
app. Rejected — clinical adherence requires server-side audit of whether a
check-in was sent, opened, and responded to. The client cannot be trusted
for the schedule.

### Decision: Lab orders and prescriptions are payload types on the
existing `Recommendation` entity, not separate entities
The cloud MVP already defines `Recommendation.payload_type` ∈
{`guidance`, `prescription`, `lab_order`, `referral`}. This change is the
first producer of `prescription` and `lab_order` payloads. Keeping them as
recommendation payloads means the same physician-in-loop state machine
(`DRAFT → PENDING_REVIEW → APPROVED/MODIFIED/REJECTED → DELIVERED`)
governs them — no parallel review queue to maintain. Lab fulfillment
status and prescription transmission status are tracked on satellite
tables (`lab_order_fulfillments`, `prescription_transmissions`) keyed by
recommendation id; in Phase 1 those tables exist with manual status
updates pending vendor integration.

### Decision: PA-PC entity stamp is a non-nullable column, not a join
Every clinical record (`recommendations`, `prescriptions`, `lab_orders`,
`vitals_readings`, `intake_submissions`, `check_in_responses`) carries a
non-null `clinical_entity_id` referencing a tiny `clinical_entities` table.
Phase 1 has one row: the PA-PC. A new state requires inserting a new row
*and* a code change in the state-eligibility allowlist. The column is
populated by middleware at write time from the patient's resident state, so
no handler can forget to set it.

### Decision: PDMP acknowledgment ships even though Phase 1 has no
controlled substances
The PDMP acknowledgment surface (a physician-side modal that records
"physician acknowledges PDMP review for patient X on date Y for medication
class Z") is implemented and reachable in the prescribing UI even though
the Phase 1 formulary contains no controlled substances. This avoids a
quiet skip the day a controlled substance is added to a protocol.

### Decision: PA license verification is a periodic batch job, not a
real-time check
On a daily schedule the backend queries the configured PA State Board of
Medicine lookup (TBD: PA DOS Bureau of Professional and Occupational
Affairs portal or NPDB Practitioner Data Bank) for the founder physician's
license status and expiration date. The result is cached and surfaced on
the physician web app's status bar. If the cached status is `expired` or
`disciplinary action`, the physician-in-loop state machine refuses every
`APPROVED` / `MODIFIED` transition with a state-board-status error.

**Alternatives considered**: real-time check on every transition. Rejected
— state-board lookups are slow, rate-limited, and not always available;
caching plus a hard gate on the cached status is sufficient and avoids
production outages when the lookup endpoint is down.

## Risks / Trade-offs

- **Stripe BAA timing.** If the BAA is not executed before launch, billing
  cannot ship. Mitigation: implement billing against a Stripe test account
  in development; gate production rollout on BAA execution as a tasks-list
  prerequisite.
- **Protocol clinical safety.** A bug in `chronic-disease-protocols` could
  produce unsafe drafts. Mitigation: every recommendation is gated by the
  physician-in-loop state machine — drafts never reach patients without
  physician approval. Defense-in-depth: protocol tests assert known-good
  outputs against curated patient fixtures.
- **License-lookup endpoint volatility.** PA's license lookup is not a
  contracted API. Mitigation: design the verifier as a pluggable interface
  with a manual-override path (the founder can mark "verified through
  YYYY-MM-DD" with an attached PDF of the official lookup result) so that
  endpoint changes don't block prescribing.
- **Hardcoded PA eligibility creates re-work for state #2.** This is
  deliberate. The re-work is a small Go change plus a new spec proposal,
  which is the right shape of friction for adding a state.

## Migration Plan

This change has no production deployments to migrate from — it is the first
clinical-domain layer.

For development environments:
1. `add-cloud-platform-mvp` migrations run first.
2. This change's migrations add `intake_submissions`, `patient_conditions`,
   `clinical_entities`, `subscriptions`, `vitals_readings`,
   `check_in_schedules`, `check_in_responses`, `lab_order_fulfillments`,
   `prescription_transmissions`, `pdmp_acknowledgments`,
   `physician_license_status`.
3. Seed data inserts the PA-PC `clinical_entities` row and the founder
   physician's record with `states_licensed = {'PA'}`.

## Open Questions

- PA license verification source: PA DOS portal scrape vs. NPDB query
  vs. manual-only with attached PDF for Phase 1?
- Stripe price IDs: created in Stripe dashboard or via Stripe API at
  deploy time? (Decision affects whether tier definitions live in code or
  in Stripe.)
- Check-in cadence titration-vs-maintenance state: tracked per (patient,
  condition) pair (recommended) or per patient overall? Per-condition is
  more accurate but adds complexity; per-patient is simpler but couples
  cadences across conditions.
- Waitlist capture for non-PA patients: email-only, or full intake captured
  for marketing? Privacy posture pushes toward email-only.
