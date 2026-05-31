# Proposal: Production Security Hardening

> **Status: Backlog placeholder.** This is a tracking stub, not an
> approval-ready proposal. `design.md`, `tasks.md`, and capability spec deltas
> will be authored when this change is prioritized for execution. It exists so
> the production-security work surfaced in `docs/ARCHITECTURE.md` §12 is
> visible in the OpenSpec backlog and not lost between the MVP and Phase 1
> production-readiness.

## Overview

Implement the production security and ransomware-hardening controls that
HouseCall must have in place before the first real patient connects to a
production environment. Scope spans backups, identity hardening, endpoint and
email security, network segmentation, patching, supply chain, detection and
response, third-party risk, and adoption of a recognized healthcare cyber
framework.

## Motivation

### Business Need
Healthcare is the most-attacked sector. Change Healthcare (Feb 2024) — ~$2.87B
impact, single Citrix server without MFA; CommonSpirit, Ascension, and the
ongoing AHA reporting all point the same direction. HHS is moving from
voluntary guidance to mandated baselines (HPH CPGs). A HIPAA-regulated
production launch without these controls is not viable — both from an
operational-risk and from a regulatory standpoint.

### User Value
- **Patients**: their PHI is meaningfully protected against the threat that
  actually materializes in this sector — ransomware and supply-chain
  compromise.
- **Physicians / clinical staff**: clinical operations survive an incident
  because backups are restorable and IR is rehearsed, not improvised under
  duress.
- **HouseCall as an organization**: a recognized framework (HPH CPGs / NIST
  CSF 2.0 / HITRUST) is increasingly required by cyber insurance, partner
  due diligence, and HHS enforcement discretion.

### Technical Drivers
- The MVP (`add-cloud-platform-mvp`) deliberately scopes out production
  security — it runs locally with no real PHI. Without an explicit follow-on,
  these controls slip the gap between MVP and Phase 1 production.
- Several controls have direct AWS architectural consequences (separate
  backup account, S3 Object Lock, KMS, GuardDuty/Security Hub, Verified
  Access / Identity Center, separate production VPC topology) and should be
  designed before, not after, production infrastructure is provisioned.

## Proposed Changes

### New Capabilities (to be specified)
1. `backup-and-recovery` — 3-2-1-1 backups with one immutable/offline copy,
   S3 Object Lock in compliance mode in a separate AWS account, restore-drill
   cadence.
2. `identity-hardening` — phishing-resistant MFA (WebAuthn/FIDO2), SSO with
   conditional access, just-in-time admin elevation, no shared accounts.
   Builds on ADR-002 (Zitadel).
3. `endpoint-and-email-security` — EDR on every endpoint, modern email
   security (sandboxing, URL rewriting), DMARC/SPF/DKIM enforcement, macro
   policy.
4. `network-segmentation` — clinical / corporate / dev plane separation,
   production data tier isolation, egress controls.
5. `patch-management` — CISA KEV-driven SLA and exposure minimization.
6. `supply-chain-security` — SBOMs, dependency scanning, signed container
   images, pinned bases, GitHub branch protection + signed commits, secrets
   in KMS / Secrets Manager, CI without standing prod credentials.
7. `detection-and-response` — central audit pipeline → SIEM, behavioural
   detections, 24/7 monitoring (MDR), pre-signed DFIR retainer, rehearsed IR
   plan, HHS/OCR 60-day breach-notification playbook.
8. `third-party-risk-management` — BAA + security review for every
   PHI-adjacent vendor, vendor-compromise plan.
9. `compliance-framework-adoption` — HHS HPH CPGs as the target with NIST
   CSF 2.0 or HITRUST CSF as the map and HICP/405(d) as the healthcare
   playbook.

### Modified Capabilities
- TBD — likely modifies the production deployment surface of `core-api`,
  `physician-web-app`, and `ai-agent-runtime` once they exist (auth, logging,
  secret handling).

## Impact Assessment

### User Impact
None at MVP time. At production-launch time, the impact is invisible-when-
working: faster MFA enrolment, restricted remote access, occasional MDR
follow-ups. Materially visible only during an incident, where the impact is
"the org survives".

### Technical Impact
Significant AWS infrastructure work (separate accounts, KMS, S3 Object Lock,
GuardDuty/Security Hub, network topology), tooling acquisition (EDR, email
security, SIEM/MDR, DFIR retainer), and process work (IR plan, tabletop
exercises, vendor BAA review). Cross-functional — engineering, IT, security,
legal, compliance.

### Compliance Impact
Brings HouseCall in line with the HHS HPH Cybersecurity Performance Goals
(currently encouraged, trending toward mandatory) and the recognized
safe-harbor frameworks under HHS enforcement discretion. Required for HIPAA
defensibility in 2026+.

## Alternatives Considered

To be expanded when this change is promoted from backlog. Initial framing:
adopting **NIST CSF 2.0** vs. **HITRUST CSF** vs. **HICP/405(d)** as the
primary map is the main framework-level decision; the underlying technical
controls are largely the same across all three.

## Success Criteria

### Functional Requirements
To be specified per capability when promoted from backlog.

### Non-Functional Requirements
- An external audit or readiness assessment maps HouseCall to the chosen
  framework with no critical gaps.
- Documented and tested RTO / RPO for the production data tier.
- Documented and tabletop-exercised IR plan.

### Quality Gates
- `openspec validate add-production-security-hardening --strict` passes (once
  promoted to a full proposal).
- An external readiness assessment against HHS HPH CPGs (or chosen
  equivalent) signs off before production launch.

## Timeline & Dependencies

### Prerequisites
- The MVP (`add-cloud-platform-mvp`) is informative but not blocking — most of
  this work is parallelizable.
- Production AWS account structure must be designed before
  `backup-and-recovery` can be built (separate accounts, KMS, organizations).

### Dependencies
- Vendor selections: EDR, email security, SIEM/MDR, DFIR retainer.
- BAA negotiation with each PHI-adjacent vendor.

### Estimated Effort
TBD — large, multi-quarter, cross-functional. To be sized when promoted.

## Open Questions
- **Primary framework**: HHS HPH CPGs as the bar plus NIST CSF 2.0 as the map,
  or HITRUST CSF (more rigorous, more expensive, third-party-attestable), or
  HICP/405(d) (healthcare-specific, recognized safe harbor)?
- **MDR vendor**: in-house SOC vs. managed (Arctic Wolf, Red Canary,
  CrowdStrike Falcon Complete, etc.) — likely managed given org size.
- **Backup RTO / RPO targets** for the production data tier.
- **DFIR retainer**: Mandiant / Unit 42 / Kroll / other.

## Stakeholder Sign-off
- [ ] Engineering
- [ ] Security / compliance owner
- [ ] Legal
- [ ] Executive / budget owner

---

**Change ID**: `add-production-security-hardening`
**Status**: Backlog
**Created**: 2026-05-15
**Author**: HouseCall Team
