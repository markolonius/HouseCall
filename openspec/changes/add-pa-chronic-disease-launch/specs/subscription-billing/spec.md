# Specification: Subscription Billing

## ADDED Requirements

### Requirement: Cash-Pay Subscription Tiers

The system SHALL offer three cash-pay monthly subscription tiers keyed to
the number of chronic conditions a patient is enrolled in: `$29/month` for
one condition, `$39/month` for two conditions, `$49/month` for three or
more conditions. The tier SHALL be derived from the patient's
`patient_conditions` rows at signup and SHALL be re-evaluated when
conditions are added or removed.

#### Scenario: A single-condition patient lands on the $29 tier

- **GIVEN** a patient enrolled in `hypertension` only
- **WHEN** the billing service computes their tier
- **THEN** the tier is `one_condition` priced at `$29/month`

#### Scenario: A two-condition patient lands on the $39 tier

- **GIVEN** a patient enrolled in `diabetes_t2` and `hyperlipidemia`
- **WHEN** the billing service computes their tier
- **THEN** the tier is `two_condition` priced at `$39/month`

#### Scenario: A three-condition patient lands on the $49 tier

- **GIVEN** a patient enrolled in `diabetes_t2`, `hypertension`, and
  `hyperlipidemia`
- **WHEN** the billing service computes their tier
- **THEN** the tier is `three_condition` priced at `$49/month`

---

### Requirement: Stripe-Backed Subscription Lifecycle

The system SHALL create a Stripe customer and subscription per patient
through the Stripe Go SDK. The Stripe customer record SHALL contain only an
opaque internal patient identifier and the subscription tier name. No PHI
SHALL be sent to Stripe, including but not limited to: patient name, email,
date of birth, condition list, medications, or any clinical data.

#### Scenario: A new patient subscription is created without PHI

- **WHEN** the billing service creates a Stripe customer and subscription
  for a patient
- **THEN** the Stripe customer metadata contains only the opaque internal
  patient identifier
- **AND** the Stripe subscription metadata contains only the tier name
- **AND** no patient email, name, condition, or other PHI is transmitted
  to Stripe

#### Scenario: Stripe webhook updates subscription status

- **GIVEN** a Stripe `customer.subscription.updated` webhook is received
- **WHEN** the webhook handler verifies the signature and processes the
  payload
- **THEN** the corresponding `subscriptions` row's `status` and
  `current_period_end` are updated
- **AND** no other table is modified

#### Scenario: A Stripe webhook with an invalid signature is rejected

- **GIVEN** a webhook request whose signature does not match the
  configured Stripe webhook secret
- **WHEN** the webhook endpoint validates the signature
- **THEN** the request is rejected with HTTP 400
- **AND** no `subscriptions` row is modified

---

### Requirement: Subscription-Gated Clinical Access

The system SHALL refuse every patient-facing clinical endpoint when the
requesting patient does not have a subscription whose `status` is one of
`trialing` or `active`. Endpoints for intake, eligibility-check,
waitlist, and billing itself SHALL remain reachable without an active
subscription so that the patient can complete the sign-up flow and resume
billing if it lapses.

#### Scenario: An unsubscribed patient cannot send a clinical message

- **GIVEN** a patient whose `subscriptions.status` is `incomplete` or
  `canceled` or absent
- **WHEN** the patient calls a clinical endpoint such as `POST /messages`
- **THEN** the request is rejected with HTTP 402 (Payment Required)
- **AND** no message is persisted
- **AND** no audit event is written beyond the rejection itself

#### Scenario: A subscribed patient is allowed through

- **GIVEN** a patient whose `subscriptions.status` is `active`
- **WHEN** the patient calls a clinical endpoint
- **THEN** the request proceeds normally

#### Scenario: Billing and intake remain reachable while unsubscribed

- **GIVEN** a patient with no active subscription
- **WHEN** the patient calls the intake, eligibility-check, waitlist, or
  billing endpoints
- **THEN** the request proceeds normally
