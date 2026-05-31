# Proposal: PA Chronic-Disease Launch — Clinical Surface on Top of the Cloud MVP

## Why

The `add-cloud-platform-mvp` change proves the generic physician-in-loop loop
with `guidance`-typed recommendations, but it cannot accept payment, cannot
route patients by state, cannot draft a prescription or a lab order, and has
no concept of a chronic-disease protocol. Before any real Pennsylvania
patient can be onboarded under the launch decisions in
`docs/LAUNCH_STRATEGY.md`, those gaps must be closed by a chronic-disease-
specific clinical, billing, and compliance surface that sits on top of the
MVP loop. This change adds that surface for a single state (PA) and a
single clinical area (cardiometabolic chronic disease) so a solo
physician-founder can operate the first real patient cohort end-to-end.

## What Changes

- **NEW**: Patient intake flow with hardcoded PA-only state-eligibility gate
  and waitlist capture for non-PA prospects.
- **NEW**: Cash-pay Stripe subscription billing at $29 / $39 / $49 tiers
  keyed to enrolled-condition count; no PHI sent to Stripe.
- **NEW**: Versioned chronic-disease protocol library (diabetes T2,
  hypertension, hyperlipidemia) producing prescription and lab-order drafts
  alongside guidance.
- **NEW**: Server-scheduled vitals check-ins with per-(patient, condition)
  titration-vs-maintenance cadence and home-vitals capture.
- **NEW**: Lab-order recommendation payload type with patient-facing action
  card and manual fulfillment-status tracking.
- **NEW**: e-Prescribing surface — prescription recommendation payload type,
  physician sign-and-approve UI, patient-facing prescription card.
- **NEW**: Pennsylvania clinical compliance — PA-PC entity stamp on every
  clinical record, daily license-status verification with hard gate on
  physician actions, PDMP acknowledgment inline with controlled-substance
  prescribing.
- **NEW**: First consumers of the cloud-MVP `prescription` and `lab_order`
  payload types and the AI Agent Runtime's strategy extension point.

## Impact

- **Affected specs**: seven NEW capabilities (`patient-intake`,
  `subscription-billing`, `chronic-disease-protocols`, `vitals-check-ins`,
  `lab-order-requests`, `eprescribing`, `pa-clinical-compliance`). No
  existing specs modified.
- **Affected code**: new Go backend modules (`internal/intake`,
  `internal/billing`, `internal/protocols`, `internal/checkins`,
  `internal/laborders`, `internal/eprescribing`, `internal/pa_compliance`);
  new iOS screens (intake, paywall, check-in, action cards); new physician
  web app screens (prescribing, lab-order review, PDMP modal).
- **Dependencies**: `add-cloud-platform-mvp` must be implemented and
  archived first. Stripe BAA, PA-PC + PBC entity formation, founder
  license + DEA verification, malpractice + telemedicine endorsement, and
  PA PDMP enrollment are operational prerequisites (tracked in `tasks.md`,
  not delivered code in this change).
- **Out of scope**: multi-state expansion, GLP-1 protocols, insurance
  billing, real external integrations (Stripe webhook receipt is in scope
  but BAA execution is not; lab and Surescripts surfaces ship without
  external wires), controlled-substance prescribing, pediatric care.

## Overview

Add the chronic-disease-specific clinical, billing, and compliance surface
required to operate HouseCall as a real Pennsylvania cash-pay primary-care
practice for cardiometabolic conditions (diabetes, hypertension,
hyperlipidemia). This change sits **on top of** `add-cloud-platform-mvp`: that
MVP proves the generic physician-in-loop loop with `guidance`-typed
recommendations; this change adds the patient onboarding flow, subscription
billing, chronic-disease protocol library, periodic vitals check-ins,
physician-approved lab and prescribing surfaces, and PA-specific clinical
compliance that turn the loop into a practice.

The change is scoped to a single state (PA) and a single clinical area
(cardiometabolic chronic disease) so that the first real patient cohort can be
operated by a solo physician-founder. Multi-state expansion and GLP-1
weight-management protocols are explicitly out of scope and are tracked as
separate future changes.

## Strategic Context

The strategic decisions that shape this proposal are recorded in
`docs/LAUNCH_STRATEGY.md` (committed in this branch):

- **Launch state**: Pennsylvania. Physician-founder holds an unrestricted PA
  license + DEA. PA is moderate-CPOM but the founder can self-own the PC,
  bypassing the friendly-PC / MSO structure.
- **Legal entity**: PA Professional Corporation (clinical) + Delaware Public
  Benefit Corporation (technology) with a Management Services Agreement
  between them. All clinical records belong to the PA-PC.
- **Clinical focus**: cardiometabolic chronic disease — diabetes (Type 2),
  hypertension, hyperlipidemia, and combinations. Phase 1 medication formulary
  is metformin, SGLT2 inhibitors, ACE inhibitors / ARBs, statins, and
  beta-blockers. **GLP-1s are deferred** pending FDA compounding-list
  stability.
- **Pricing**: cash-pay $29 / $39 / $49 monthly tiers tied to condition
  bundles. No insurance billing in this slice.
- **Clinician**: founder is sole clinician for Phase 1; capacity ceiling
  ~150–250 active patients before clinician #2 is hired.

## Motivation

### Business Need
The `add-cloud-platform-mvp` change proves the technical loop end-to-end but
produces only generic `guidance` recommendations. It cannot accept payment, it
cannot route a patient by state, it cannot draft a prescription or a lab
order, and it has no concept of a chronic-disease protocol. Before any real PA
patient can be onboarded, those gaps must be closed.

### User Value
- **Patients** can sign up, pay, declare their condition(s) and current
  regimen, and receive condition-specific care plans rather than generic chat.
- **Physician-founder** can review condition-specific draft prescriptions and
  lab orders alongside guidance, with PA-specific compliance acknowledgments
  inline, rather than reviewing only free-text guidance.

### Technical Drivers
- The Recommendation `payload_type`-discriminated payload already exists in
  the cloud MVP data model. This change is the first consumer of the
  `prescription` and `lab_order` payload types.
- The chronic-disease protocols are the first concrete agent strategy beyond
  generic guidance — they exercise the AI Agent Runtime's strategy extension
  point.
- PA-specific compliance (license verification, PDMP acknowledgment, PA-PC
  entity stamping on clinical records) is the first instance of a pattern
  that future state-expansion changes will reuse.

## Proposed Changes

### New Capabilities

1. **`patient-intake`** — Pre-payment intake flow: state-of-residence gate (PA
   only), demographics, condition selection (diabetes / hypertension /
   hyperlipidemia / combinations), baseline vitals, current medications,
   allergies, and most-recent lab results. Patients in non-PA states are
   shown a "we're not yet available in your state" path with a waitlist
   capture.

2. **`subscription-billing`** — Stripe-backed cash-pay subscriptions at
   $29 / $39 / $49 monthly tiers, mapped to condition bundles
   (single-condition / two-condition / three-condition). No PHI in Stripe
   metadata. Access to the care surface is gated on an active subscription.
   Actual Stripe BAA execution is a dependency, not scope.

3. **`chronic-disease-protocols`** — A versioned protocol library encoding
   titration rules for the Phase 1 formulary (metformin, SGLT2 inhibitors,
   ACE/ARBs, statins, beta-blockers). The AI Agent Runtime consumes protocols
   matching the patient's enrolled conditions to draft `prescription` and
   `lab_order` payload recommendations alongside `guidance`.

4. **`vitals-check-ins`** — Scheduled patient check-ins (weekly during
   titration, monthly at maintenance) that prompt the patient for home vitals
   (BP, fasting glucose, weight) and surface a check-in conversation that the
   AI agent processes against the patient's protocol.

5. **`lab-order-requests`** — Physician-approved lab order recommendations
   (basic metabolic panel, lipid panel, HbA1c, urine albumin, LFTs) that
   surface to the patient as a "lab order ready" action card with the
   recommended panel, supporting documents, and a list of acceptable
   fulfillment paths (Labcorp, Quest, Getlabs). Actual external lab
   integration is a dependency, not scope.

6. **`eprescribing`** — Physician-approved prescription recommendations
   surfaced in a prescribing UI within the physician web app. The MVP
   surface captures the prescription (drug, dose, sig, quantity, refills,
   pharmacy) and produces a signed clinical record; actual Surescripts
   transmission is a dependency, not scope.

7. **`pa-clinical-compliance`** — PA-specific clinical compliance:
   PA-PC entity identification on every clinical record, PA medical license
   verification for the prescribing physician (state board lookup + expiry
   tracking), and a PA Prescription Drug Monitoring Program (PDMP)
   acknowledgment that the physician must check inline with every controlled-
   substance prescription. Phase 1 formulary contains no controlled
   substances, but the acknowledgment surface ships so it is exercised before
   the first controlled-substance protocol is added.

### Modified Capabilities

None in this proposal. The MVP capabilities (`core-api`, `physician-in-loop`,
`ai-agent-runtime`, `physician-web-app`, `ios-cloud-sync`) are consumed as
they exist after `add-cloud-platform-mvp` lands. Where this change introduces
new behaviour into those capabilities (e.g., the AI Agent Runtime gaining a
chronic-disease protocol strategy), the new behaviour lives in *this*
change's capabilities and is wired in via the extension points the MVP
already defines.

## Impact Assessment

### User Impact
- Patients gain a real signup-and-pay flow, condition-specific care, scheduled
  check-ins, and lab + prescription action cards. Non-PA patients see a clear
  "not available in your state yet" message with waitlist capture.
- Physician-founder gains a condition-aware review queue, a prescribing UI,
  and PA compliance prompts inline with clinical actions.

### Technical Impact
- New backend modules (Go): `internal/intake`, `internal/billing`,
  `internal/protocols`, `internal/checkins`, `internal/laborders`,
  `internal/eprescribing`, `internal/pa_compliance`.
- New iOS screens: intake flow, paywall, check-in prompt, lab-order card,
  prescription card.
- New physician web app screens: prescribing UI, lab-order review, PDMP
  acknowledgment modal.
- New external dependency: Stripe SDK (server-side) under a BAA.

### Compliance Impact
- All new PHI-bearing tables (`intake_submissions`, `patient_conditions`,
  `vitals_readings`, `lab_orders`, `prescriptions`, `pdmp_acknowledgments`)
  are tenant-scoped and audit-logged consistent with the cloud-MVP invariants.
- The PA-PC entity stamp on every clinical record establishes the legal
  custody chain for state-board audits.
- No PHI is transmitted to Stripe; only an opaque customer identifier and the
  subscription tier name. Stripe BAA must be executed before launch.

## Out of Scope

- **Multi-state expansion** (FL, TN, GA, AZ, NC). Tracked separately as a
  future change once PA is validated.
- **GLP-1 protocols.** Deferred until FDA compounding posture stabilizes.
- **Insurance billing.** Cash-pay only.
- **Actual external integrations.** Stripe webhook receipt is in scope;
  Stripe BAA execution is not. Lab-order surface is in scope; Labcorp /
  Quest / Getlabs API integration is not. Prescription record + UI is in
  scope; Surescripts transmission is not. These are dependencies tracked in
  `tasks.md` but not delivered code in this change.
- **Controlled-substance prescribing.** Phase 1 formulary has none.
- **Pediatric care.** Adults 18+ only.

## Dependencies

- **`add-cloud-platform-mvp` must be implemented and archived first.** This
  change extends the MVP's data model and runtime; without the MVP in place,
  this change has no foundation.
- **Stripe BAA** executed before patient onboarding goes live.
- **PA medical license verification source** (PA State Board of Medicine
  lookup or NPDB) selected before `pa-clinical-compliance` implementation.
- **PA-PC and PBC entity formation** completed before any patient onboards
  (legal-track, not engineering-track).

## Success Criteria

- A PA-resident adult can sign up, pay, complete intake, declare a condition,
  receive a physician-approved care plan with a lab order and a prescription,
  attend a scheduled check-in, and receive a titration recommendation — all
  without leaving the app.
- A non-PA-resident is blocked at intake with a clear message and a
  waitlist-capture path.
- The physician-founder sees a review queue containing condition-aware draft
  recommendations of all three payload types (`guidance`, `lab_order`,
  `prescription`) and can approve / modify / reject each.
- Every clinical record carries the PA-PC entity identifier and a verified
  prescribing-physician license reference.
