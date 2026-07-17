# Design: Agent Care Loop

## Context

The drafter (`backend/internal/agent/drafter.go`) currently has one behaviour
for every patient message: run an interview turn, and either deliver the next
question or draft a SOAP note. The decision is made per-message from model
output plus a turn cap (`decideInterviewAction`), with no persistent notion of
where the encounter stands. All four new behaviours need exactly that missing
notion, so the care-phase state machine is the foundation and everything else
is a per-phase branch.

## Decision: Care phase lives on the server conversation row

`care_phase` is a new column on `conversations`
(`INTAKE | AWAITING_REVIEW | PLAN_DELIVERED`, default `INTAKE`).

- Alternatives considered: deriving phase from the latest recommendation's
  state (fragile — a conversation can hold several recommendations, e.g. a
  rejected one plus its revision; deriving reproduces today's ambiguity that
  caused the double-SOAP bug), or storing phase on the iOS client (violates
  server-authoritative sync; the web portal could not see it).
- Phase transitions happen in the same transaction as the event that causes
  them (SOAP draft commit → `AWAITING_REVIEW`; recommendation `DELIVERED` →
  `PLAN_DELIVERED`; rejection → `INTAKE`), mirroring the atomic
  transition+audit discipline of `physician-in-loop`.

## Decision: Per-phase dispatch replaces the single interview path

`DraftAsync` dispatches on `care_phase`:

- `INTAKE` — today's behaviour (triage screen first, then interview turn or
  SOAP draft). On SOAP draft, also persist the acknowledgement assistant
  message and move to `AWAITING_REVIEW`.
- `AWAITING_REVIEW` — do **not** run the interview or draft again (fixes the
  silent double-draft). Persist a short static "your report is with your
  physician" assistant message. No model call: model output in this phase
  could drift into clinical territory with no physician gate ahead of it.
- `PLAN_DELIVERED` — run the relay prompt (below). A message that raises a
  *new complaint* (relay prompt signals it, mirroring the
  `parseInterviewTurn` marker pattern) transitions the conversation back to
  `INTAKE` and runs an intake turn.

This is deliberately the same extension point the
`add-pa-chronic-disease-launch` strategy-selection layer expects: phase picks
the strategy; that change later adds protocol strategies inside `INTAKE`.

## Decision: Relay grounding is prompt + provenance, not a new delivery gate

The relay answers questions about content that a physician already approved
and delivered, so the physician-in-loop carve-out is not weakened: the agent
still never moves a recommendation forward, and relay context is assembled
**only** from (a) the delivered recommendation's final content and (b) the
conversation history. The relay system prompt constrains output to explaining
the approved plan; anything the plan does not cover must be answered with a
deferral ("that's a question for your physician — I can pass it along") or,
for new complaints, a phase transition back to `INTAKE`.

We considered routing relay answers through `PENDING_REVIEW` like clinical
drafts. Rejected: it would make every "what does twice daily mean?" a
physician queue item, destroying the responsiveness the relay exists to
provide, while the grounding constraint plus the existing "no new clinical
content" prompt discipline covers the risk for guidance payloads. Revisit
when prescription payloads arrive.

## Decision: Rejection spawns a revision; REJECTED stays terminal

The recommendation lifecycle is untouched. Rejection gains a required
`rejection_reason` (stored on the recommendation, audited, never shown to the
patient verbatim). On rejection the conversation returns to `INTAKE` and the
agent runs an interview turn whose prompt includes the reason as reviewer
guidance, asks the patient whatever is missing, and eventually drafts a *new*
recommendation. This keeps the audit trail append-only — no resurrecting
rejected rows — and required zero changes to the `Transition` function's
state table.

## Decision: Triage is a separate cheap classification call

Red-flag screening runs before the interview turn in `INTAKE` as its own
model call with a dedicated prompt returning a strict marker
(`EMERGENT` / `ROUTINE`), same parsing discipline as `parseInterviewTurn`.
On `EMERGENT`: persist a static emergency-referral message (call 911 /
emergency services — standard telehealth safe-harbor text, not model
free-text), emit an urgent `queue.updated` variant to physicians, write an
audit event, and stop the normal turn. Classifier unavailable or unparseable
→ fail open to the normal interview turn (the physician gate is still ahead;
blocking care on a triage outage is worse) and write `ai_interaction_failed`.

## Decision: Delivery tolerates a care-phase CAS miss

Delivery (approve/modify → `DELIVERED`) transitions the conversation
`AWAITING_REVIEW` → `PLAN_DELIVERED` in the same transaction. When the
conversation is *not* observed in `AWAITING_REVIEW` (backfilled/legacy rows,
lost CAS race), the delivery still commits and a
`recommendation.delivered_phase_mismatch` audit event (identifiers only) is
written instead: `care_phase` routes agent behaviour, it is not a gate on a
physician's clinical action. Any other transition error still fails the whole
transaction.

## Risks / Trade-offs

- **Relay hallucination beyond the approved plan** — mitigated by grounding
  context, deferral instruction, and keeping relay scoped to `guidance`
  payloads in this change. Residual risk accepted for MVP; prescription
  payloads will need stricter treatment.
- **Static acknowledgement/emergency text is less "conversational"** — chosen
  deliberately: these are the two spots where model free-text has no
  physician gate ahead of it and no approved content to ground on.
- **Existing conversations lack a phase** — migration backfills:
  `PLAN_DELIVERED` if the conversation has a delivered recommendation,
  `AWAITING_REVIEW` if one is pending, else `INTAKE`.
