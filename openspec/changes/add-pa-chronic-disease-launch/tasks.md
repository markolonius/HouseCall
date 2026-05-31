# Tasks: PA Chronic-Disease Launch

> **Prerequisite**: `add-cloud-platform-mvp` is implemented and archived. All
> task numbering assumes the cloud-MVP migrations, store, API, agent runtime,
> and physician web app exist.

## Phase 1: Schema & Clinical Entity Foundation

### Task 1.1: Clinical entities table
- [ ] Migration: `clinical_entities` (id, legal_name, state, npi_group_id,
      created_at). Seed with the PA-PC row.
- [ ] Add non-null `clinical_entity_id` to `recommendations`,
      `conversations`, and `audit_events`.
- [ ] Write middleware that derives `clinical_entity_id` from the patient's
      resident state at write time; no handler may set it manually.

### Task 1.2: PA-only state eligibility
- [ ] `internal/eligibility` package with `EligibleStates() []string`
      returning `["PA"]` as a hardcoded constant.
- [ ] Database check constraint: `patients.state IN (SELECT state FROM
      clinical_entities)`.
- [ ] Tests: a patient insert with `state = 'NJ'` is rejected with a
      typed `ErrStateNotEligible`.

### Task 1.3: Patient-condition enrollment schema
- [ ] Migration: `patient_conditions` (patient_id, condition, enrolled_at,
      titration_state). `condition` constrained to
      (`diabetes_t2` | `hypertension` | `hyperlipidemia`).
- [ ] Migration: `intake_submissions` (patient_id, submitted_at,
      payload JSONB, encryption envelope id).

**Validation**: migrations apply; eligibility tests pass; middleware test
proves no recommendation can be written without a `clinical_entity_id`.

## Phase 2: Patient Intake

### Task 2.1: Intake API
- [ ] `POST /intake/eligibility-check` — takes a state code; returns
      `eligible: bool` and, when ineligible, a waitlist-capture token.
- [ ] `POST /intake/submit` — accepts demographics, condition selection,
      baseline vitals, current meds, allergies, recent labs.
      Tenant-scoped; encrypted at rest.

### Task 2.2: Waitlist capture
- [ ] `POST /intake/waitlist` — accepts email + state; writes to
      `waitlist_signups`. No PHI stored beyond email.

### Task 2.3: iOS intake flow
- [ ] State-of-residence screen as the first intake step.
- [ ] PA-only path: condition selector, baseline vitals form, meds list,
      allergies list, recent-lab uploader (image + manual entry).
- [ ] Non-PA path: "we're not available in your state yet" screen with
      email waitlist capture.

**Validation**: a UI test completes a PA-eligible intake end-to-end; a
second UI test confirms a non-PA path lands on the waitlist screen.

## Phase 3: Subscription Billing

### Task 3.1: Stripe wiring (test mode)
- [ ] Stripe Go SDK pinned; secret loaded from environment.
- [ ] Three Stripe price IDs created (one-, two-, three-condition tiers).
- [ ] `internal/billing` — create-customer (opaque patient id only),
      create-subscription, webhook verifier.
- [ ] Migration: `subscriptions` (patient_id, stripe_customer_id,
      stripe_subscription_id, tier, status, current_period_end).

### Task 3.2: Pre-payment gating
- [ ] Middleware: every patient-side endpoint other than intake, billing,
      and waitlist refuses requests whose patient has no
      `subscriptions.status IN ('trialing', 'active')`.
- [ ] Webhook handler updates subscription status; ignores all PHI-free
      Stripe metadata.

### Task 3.3: iOS paywall
- [ ] Paywall screen after intake completion: tier display, Stripe
      payment sheet, post-payment confirmation.

**Validation**: a test-mode Stripe checkout produces an active
subscription row; clinical endpoints reject unsubscribed patients.

## Phase 4: Chronic-Disease Protocols

### Task 4.1: Protocol package skeleton
- [ ] `internal/protocols` package with `Recommend(ctx, snapshot)` interface.
- [ ] `diabetes_t2`, `hypertension`, `hyperlipidemia` packages, each
      exporting `Recommend` and a versioned `ProtocolVersion` constant.

### Task 4.2: Titration rules
- [ ] Metformin titration (start, step, max, contraindication checks).
- [ ] SGLT2 inhibitor add-on rules.
- [ ] ACE inhibitor / ARB titration with renal-function gates.
- [ ] Statin selection by ASCVD risk band.
- [ ] Beta-blocker initiation rules.

### Task 4.3: Protocol-driven draft generation
- [ ] Agent runtime strategy-selector: picks protocols matching the
      patient's enrolled conditions and runs them.
- [ ] Each protocol returns zero or more `DraftRecommendation`s typed as
      `guidance`, `prescription`, or `lab_order`.
- [ ] Every recommendation carries the protocol id + version on its
      `metadata` field.

### Task 4.4: Protocol tests
- [ ] Golden-output tests: each protocol against a curated set of patient
      fixtures (newly diagnosed, mid-titration, at-target, contraindication
      present).
- [ ] Property test: every draft produced is one of the three allowed
      payload types and references an allowed Phase 1 formulary medication.

**Validation**: `go test ./internal/protocols/...` green; the agent
runtime, given a real patient message, produces protocol-stamped drafts.

## Phase 5: Vitals & Check-Ins

### Task 5.1: Vitals schema and API
- [ ] Migration: `vitals_readings` (patient_id, type, value, unit,
      taken_at, source). `type` ∈
      (`bp_systolic`, `bp_diastolic`, `glucose_fasting`, `weight`, ...).
- [ ] `POST /vitals` — patient submits a reading; encrypted; audit-logged.

### Task 5.2: Check-in scheduler
- [ ] Migration: `check_in_schedules` (patient_id, condition, cadence,
      next_due_at).
- [ ] Background worker: when `next_due_at < now()`, create a check-in
      conversation thread and queue an APNs push.
- [ ] Migration: `check_in_responses` (schedule_id, conversation_id,
      responded_at).

### Task 5.3: Titration-state cadence
- [ ] Per (patient, condition), `titration_state` ∈ (`titrating`,
      `maintenance`) drives cadence (weekly vs. monthly).
- [ ] Physician approval of a non-titration recommendation may move state
      from `titrating` to `maintenance` (UI control in physician web app).

### Task 5.4: iOS check-in surface
- [ ] APNs push opens the check-in conversation with a vitals form pre-
      attached.
- [ ] Vitals-form submission is delivered as a message in the conversation
      that the agent runtime picks up.

**Validation**: a scheduled check-in lands as a push, the patient submits
vitals, the agent drafts a protocol-stamped recommendation, the physician
sees it in the queue.

## Phase 6: Lab Order Requests

### Task 6.1: Lab order data model
- [ ] Use the existing `Recommendation` row with `payload_type =
      lab_order`. Payload JSONB: panel, indication, fasting required,
      acceptable fulfillment paths.
- [ ] Migration: `lab_order_fulfillments` (recommendation_id, status,
      fulfilled_by, fulfilled_at). Status ∈ (`pending`, `scheduled`,
      `collected`, `resulted`, `cancelled`). Manual updates only in Phase 1.

### Task 6.2: Physician review surface
- [ ] Physician web app: lab-order recommendations render with the
      proposed panel + indication; approve / modify / reject through the
      existing state machine.

### Task 6.3: Patient lab-order card
- [ ] iOS chat: a delivered lab-order recommendation renders as an action
      card with the panel, the indication, and acceptable fulfillment
      paths (Labcorp / Quest / Getlabs). Tapping a path opens a deep link
      or copies a printable lab requisition (PDF generated by the
      backend).

**Validation**: a protocol-produced lab order can be approved, delivered,
and rendered as a patient action card; manual status updates flow
through `lab_order_fulfillments`.

## Phase 7: e-Prescribing Surface

### Task 7.1: Prescription data model
- [ ] Use the existing `Recommendation` row with `payload_type =
      prescription`. Payload JSONB: drug (RxNorm code + display name),
      dose, sig, quantity, refills, pharmacy reference (id + name +
      phone), substitution-allowed flag.
- [ ] Migration: `prescription_transmissions` (recommendation_id, status,
      transmitted_at, transmission_reference). Status ∈ (`drafted`,
      `signed`, `transmitted`, `failed`). Phase 1 only writes `drafted`
      and `signed` (manual transmission outside this slice).

### Task 7.2: Physician prescribing UI
- [ ] Prescription review screen with editable drug, dose, sig, quantity,
      refills, pharmacy.
- [ ] Pharmacy picker (free-text + saved-pharmacies cache for the
      patient).
- [ ] Sign-and-approve action: creates the `signed` transmission row and
      transitions the recommendation to `APPROVED` via the cloud-MVP state
      machine.

### Task 7.3: Patient prescription card
- [ ] iOS chat: a delivered prescription recommendation renders as an
      action card showing drug, dose, sig, pharmacy. (Transmission status
      surfaced when the transmission integration is added in a later
      change.)

**Validation**: a protocol-produced prescription draft can be reviewed,
signed, approved, and rendered as a patient action card.

## Phase 8: PA Clinical Compliance

### Task 8.1: PA license verification
- [ ] `internal/pa_compliance/license_verifier` interface with a
      `Verify(physician_id) (Status, ExpiresAt, error)` method.
- [ ] Phase 1 implementation: a manual-override store —
      `physician_license_status` table populated by a CLI command that
      attaches a PDF of the official lookup result. Pluggable for a future
      automated source.
- [ ] Daily scheduled job calls `Verify`; stale results
      (`> 30 days old` or `status != active`) gate the physician-in-loop
      state machine via a wrapper around the existing `Transition`
      function.

### Task 8.2: Status surface
- [ ] Physician web app status bar shows verified-through date and
      license status. Red indicator when stale or non-active; review
      queue actions disabled.

### Task 8.3: PDMP acknowledgment
- [ ] Migration: `pdmp_acknowledgments` (physician_id, patient_id,
      medication_class, acknowledged_at, lookup_reference).
- [ ] Physician prescribing UI: a PDMP acknowledgment modal opens when
      the medication class is controlled. Phase 1 formulary has none, so
      the modal is reachable through a debug control to exercise the
      surface and a unit test that wires a fake controlled-class
      medication through the flow.

### Task 8.4: Clinical-entity stamping
- [ ] Confirm every clinical write path passes through the middleware
      from Task 1.1; add a per-handler test asserting
      `clinical_entity_id` is set on the resulting row.

**Validation**: a stale-license simulation blocks approvals; a debug-mode
controlled-class prescription requires PDMP acknowledgment; every
clinical record has a non-null `clinical_entity_id` in the test suite.

## Phase 9: End-to-End Verification

### Task 9.1: PA-resident happy path
- [ ] Integration test: PA resident signs up, pays (Stripe test mode),
      completes intake declaring diabetes + hypertension, receives a
      pushed check-in, submits vitals, physician approves a protocol-
      produced prescription + lab order, both delivered to the patient.

### Task 9.2: Non-PA blocked path
- [ ] Integration test: a `state = 'NJ'` signup attempt is rejected at
      intake; waitlist email is captured; no patient row is created.

### Task 9.3: License-status gate
- [ ] Integration test: with the founder's license marked
      `disciplinary_action`, every physician-side `APPROVED` /
      `MODIFIED` transition is rejected and audited.

**Validation**: all three integration tests pass in CI against the
compose-stack backend.

## Dependencies (not engineering deliverables in this change)

- [ ] Stripe BAA executed before any production patient onboarding.
- [ ] PA-PC and Delaware PBC entities formed; MSA executed.
- [ ] Founder physician's PA license + DEA verified and on file.
- [ ] Malpractice insurance with telemedicine endorsement bound.
- [ ] PA PDMP enrollment for the founder physician.
- [ ] Lab vendor selected (Labcorp / Quest / Getlabs) — for fulfillment-path
      copy in the lab-order card; deeper integration is a later change.
