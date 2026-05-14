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
- **Approach:** Managed services where possible (RDS, S3, Cognito, etc.)
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

### Phase 1 — Foundation
- [ ] Patient iOS app (voice + text chat, basic health dashboard)
- [ ] Physician web app (recommendation queue, basic protocol management)
- [ ] AI agent (text/voice, basic monitoring loop)
- [ ] HealthKit integration
- [ ] Apple Health / patient portal record pull
- [ ] CGM + basic peripheral support
- [ ] Lab result ingestion (LabCorp, Quest)
- [ ] HIPAA-compliant AWS infrastructure
- [ ] DTC subscription model

### Phase 2 — Clinical Depth
- [ ] Multimodal exam (phone mic / camera assessment)
- [ ] AI-assisted protocol builder
- [ ] Lab ordering (physician approval workflow)
- [ ] E-prescribing
- [ ] Escalation / triage layer
- [ ] Practice licensing model
- [ ] Radiology result ingestion

### Phase 3 — Scale & Hardware
- [ ] Epic / Care Everywhere FHIR R4 direct integration
- [ ] Peripheral device kit (hardware bundle with membership)
- [ ] Health system licensing
- [ ] Advanced peripheral support (Eko, Butterfly iQ, etc.)
- [ ] Pediatric support (TBD)

---

## Open Questions

- [ ] Telehealth regulations: which states to launch in first? Physician licensing coverage?
- [ ] E-prescribing vendor selection
- [ ] Accessibility requirements and WCAG compliance scope
- [ ] Pediatric roadmap
- [ ] Membership / subscription pricing model
- [ ] Device kit hardware sourcing and fulfillment
- [ ] AI model selection (multimodal — vision, audio, text)
- [ ] Radiology integration vendors and timeline

---

*Last updated: 2026-03-11*
