# PROJECT.md — Housecall

> AI-powered primary care platform with 24/7 patient monitoring, physician supervision, and a full care loop from evaluation to prescription.

---

## Vision

Housecall provides acute and chronic care similar to a primary care office. Each patient has a dedicated AI agent that monitors and evaluates them continuously. A licensed physician supervises the AI, approves protocols and recommendations, and retains full clinical authority. The AI handles the 24/7 heavy lifting; the physician handles judgment and sign-off.

---

## Core Principles

- **Physician always in the loop.** The AI never acts unilaterally on clinical decisions.
- **Condition-agnostic.** The platform is not limited to specific diseases — it adapts to each patient's needs.
- **Ship first, optimize later.** Take the path of least resistance; upgrade when scale demands it.
- **Licensable from day one.** Architecture must support DTC, solo practices, multi-provider groups, and health systems.

---

## Products

### 1. Patient iOS App
The primary patient-facing surface.

- Voice chat and text interaction with the AI agent
- Multimodal physical exam (phone mic for heart/lung sounds, camera for skin and visual findings)
- Patient health dashboard (EMR-like view of vitals, labs, history, recommendations)
- Notifications and proactive check-ins from the AI agent
- HealthKit integration (Apple Watch: HR, SpO2, ECG, sleep, activity)
- Peripheral device support (CGM, BP cuffs, thermometers — phased in; eventual device kit bundle)

### 2. Physician Web App
Separate web application for clinical oversight.

- Multi-patient panel dashboard
- Real-time recommendation review queue (approve / reject / modify)
- AI-assisted protocol builder (AI drafts patient-specific protocols; physician reviews and approves)
- Lab order approval
- E-prescribing
- Urgent alert queue (escalations from the AI triage layer)
- Support for solo physicians and multi-provider practice models

---

## AI Agent

### Role
Each patient has a dedicated AI agent responsible for:
- Continuous background monitoring (vitals, wearable data, symptom trends)
- Dynamic proactive outreach (frequency and content driven by patient's active conditions)
- Reactive engagement when the patient initiates
- Structured check-ins (e.g. scheduled lab review, medication adherence)
- Multimodal assessment (voice, video, image analysis)
- Generating clinical recommendations for physician review
- Escalation triage (see below)

### Protocol System
- Physician approves an AI-generated protocol per patient (or per condition class)
- Protocol defines: what the agent can assess, what it can recommend, escalation thresholds
- Protocols are patient-specific, AI-drafted, physician-approved
- Platform supports both solo physician protocols and shared practice protocols

### Recommendation Workflow
```
AI evaluates patient
  → generates recommendation
    → pushed to physician review queue (real-time)
      → physician approves / rejects / modifies
        → delivered to patient
```

### Escalation / Triage
- AI detects urgent signal → bypasses normal queue → immediate physician alert (push notification + in-app)
- If physician unreachable or situation is life-threatening → patient prompted to call 911 / emergency services
- Escalation thresholds defined per protocol

---

## Integrations

### Patient Data Ingestion
| Source | Phase | Notes |
|---|---|---|
| Apple Health / HealthKit | Phase 1 | HR, SpO2, ECG, sleep, activity, weight |
| Patient portal pull (CommonWell, Carequality) | Phase 1 | Patient-initiated record retrieval |
| CGM devices (Dexcom, Libre) | Phase 1–2 | Continuous glucose data |
| BP monitors / thermometers | Phase 1–2 | Bluetooth peripherals |
| Epic / Care Everywhere (FHIR R4) | Phase 2+ | Direct API access when scale warrants |
| Peripheral device kit (Housecall-branded) | Future | Shipped with membership; Eko, ultrasound, etc. |

### Lab
| Integration | Capability |
|---|---|
| LabCorp | Result ingestion + AI-recommended orders (physician approval required) |
| Quest Diagnostics | Result ingestion + AI-recommended orders (physician approval required) |

### Radiology
- Result ingestion from radiology practices (phase TBD)

### E-Prescribing
- Physician-initiated via web app
- Integration with e-prescribing network (e.g. Surescripts) — TBD vendor

---

## Go-to-Market

| Model | Description |
|---|---|
| Direct-to-Consumer (DTC) | Patients subscribe directly; matched with a supervising physician |
| Practice License | Solo physician or small practice licenses the platform for their panel |
| Health System License | Enterprise licensing for large practices or health systems |

- **Geography:** US only (initial launch)
- **Patient population:** Adults (18+) initially; pediatric TBD

---

## Infrastructure & Compliance

### Cloud
- **Target:** AWS (HIPAA-eligible services)
- **Approach:** Managed services where possible (RDS, S3, API Gateway, etc.)
- **Identity and LLM inference are self-hosted *within* the AWS BAA boundary**
  (open-source Zitadel for identity, self-hosted MedGemma for inference) — no
  third-party identity or model vendor, so no additional BAA beyond AWS.
- BAA with AWS required before any PHI touches the cloud

### Compliance
- HIPAA compliant architecture from day one
- AI positioned as clinical decision support (physician-supervised) — stays below FDA SaMD threshold
- All AI recommendations require physician approval before reaching the patient

### Key TBDs
- [ ] Specific AWS services / architecture diagram
- [ ] HIPAA BAA executed
- [ ] E-prescribing vendor (Surescripts or equivalent)
- [ ] Telehealth legal review per state (physician licensing, practice scope)
- [ ] Accessibility requirements (WCAG, ADA)

---

## Phased Roadmap (Draft)

> System architecture for the platform is specified separately in
> [`ARCHITECTURE.md`](./ARCHITECTURE.md). Phase 1 cannot start until the
> prerequisites in that document's §10 are met (AWS BAA, identity decision,
> LLM provider + BAA).

### Phase 1 — Cloud Backbone & Physician-in-Loop MVP

**Goal:** prove the core loop end-to-end with one integration — a patient can
chat with their AI agent, the agent drafts a recommendation, a physician reviews
it, and the approved result reaches the patient. Everything else is deferred.

**In scope:**
- [ ] HIPAA-compliant AWS infrastructure (RDS, S3, API Gateway, self-hosted Zitadel — per ARCHITECTURE.md §8)
- [ ] Core API service: patients, conversations, messages, recommendations, protocols
- [ ] Cloud identity + tenant isolation (DTC tenant only for Phase 1)
- [ ] Patient iOS app: cloud sync layer added to existing chat + auth (text chat only)
- [ ] Physician web app: patient panel + recommendation review queue (approve / reject / modify)
- [ ] AI agent: **reactive only** — responds to patient messages, drafts recommendations in `PENDING_REVIEW`
- [ ] Physician-in-loop state machine enforced and audited (ARCHITECTURE.md §4)
- [ ] HealthKit integration (HR, SpO2, sleep, activity) — the one Phase 1 data source
- [ ] DTC subscription model (billing + physician matching)

**Explicitly deferred to Phase 1.5 / Phase 2** (was previously bundled into Phase 1):
- Voice chat, proactive monitoring loop, CGM/BP peripherals, patient portal pulls
  (CommonWell/Carequality), lab ingestion, practice/health-system tenancy

**Phase 1 exit criteria:**
- [ ] 1 supervising physician + 5–10 pilot patients live on the platform
- [ ] Full loop works: patient message → AI recommendation → physician review → patient delivery
- [ ] Zero AI output reaches a patient without a physician state transition (verified by audit log)
- [ ] HealthKit data syncs to the cloud and is visible in the physician panel
- [ ] HIPAA security risk assessment + penetration test passed
- [ ] All ARCHITECTURE.md §9 compliance gates marked "Phase 1" are closed

### Phase 1.5 — Data Breadth
- [ ] Voice chat interaction
- [ ] CGM + basic Bluetooth peripheral support (BP, thermometer)
- [ ] Patient portal record pull (CommonWell, Carequality)
- [ ] Lab result ingestion (LabCorp, Quest) — ingestion only, no ordering

### Phase 2 — Clinical Depth
- [ ] Multimodal exam (phone mic / camera assessment)
- [ ] Proactive AI monitoring loop (scheduled check-ins, threshold evaluation)
- [ ] AI-assisted protocol builder
- [ ] Lab ordering (physician approval workflow)
- [ ] E-prescribing
- [ ] Escalation / triage layer
- [ ] Practice licensing model (multi-provider tenancy)
- [ ] Radiology result ingestion

### Phase 3 — Scale & Hardware
- [ ] Epic / Care Everywhere FHIR R4 direct integration
- [ ] Peripheral device kit (hardware bundle with membership)
- [ ] Health system licensing
- [ ] Advanced peripheral support (Eko, Butterfly iQ, etc.)
- [ ] Pediatric support (TBD)

---

## Open Questions

### Blocks Phase 1
- [ ] FDA SaMD analysis — confirm the "below threshold" assumption with a real review
- [ ] Backend stack for the Core API + AI Agent Runtime (also finalizes the
      identity choice — see Resolved below)

### Resolved (2026-05-14)
- **Launch state:** single state for launch; the specific state is TBD and will
  be set once the supervising physician is confirmed (the physician's licensure
  determines it). The `Physician.statesLicensed` model still supports multiple.
- **Identity provider:** self-hosted **Zitadel** (open source) — runs inside the
  AWS BAA boundary, so no third-party identity vendor and no extra BAA. Chosen
  for native multi-tenant organizations and language-agnostic OIDC. *Caveat:* if
  the backend stack lands on TypeScript, `better-auth` is a viable lighter-weight
  alternative; the final lock rides with the backend-stack decision above.
- **LLM provider:** **MedGemma**, self-hosted. Production runs on AWS GPU
  inference (SageMaker endpoint or EC2/EKS + vLLM) inside the AWS BAA boundary —
  PHI never leaves it, so no model-vendor BAA. Development uses a locally hosted
  model behind the same OpenAI-compatible interface. Phase 1 is text-only, which
  MedGemma's text variant covers. Note: Google ships MedGemma as a developer
  model requiring validation, not a clinical product — this reinforces the
  physician-in-loop design and makes the §6 eval harness non-optional.
- **Pricing:** flat monthly membership.

### Blocks Phase 2
- [ ] E-prescribing vendor selection (Surescripts or equivalent)
- [ ] AI model selection (multimodal — vision, audio, text)
- [ ] Radiology integration vendors and timeline

### Not yet blocking
- [ ] Accessibility requirements and WCAG compliance scope (needed before production launch)
- [ ] Pediatric roadmap
- [ ] Device kit hardware sourcing and fulfillment

---

*Last updated: 2026-05-14*
