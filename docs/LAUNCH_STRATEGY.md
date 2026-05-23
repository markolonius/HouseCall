# HouseCall — Launch Strategy

**Status:** Living strategy document · **Last updated:** 2026-05-23

Companion to `PROJECT.md` (what we are building) and `POSITIONING.md` (why we
exist in the market). This document covers *where and how we launch
operationally*: state selection, entity structure, clinical staffing sequence,
and the regulatory watch-outs that gate each phase.

---

## 1. Launch State Selection — Criteria

For a chronic-disease, cash-pay ($29–49/month) DTC primary-care product with a
physician-founder, the criteria collapse to a small number of dominant
variables. Most "obvious" criteria (telehealth rules, reimbursement,
competitive density) turn out to be flat across plausible states.

### Criteria ranked by decision weight

1. **Corporate Practice of Medicine (CPOM)** — *dominant*
   - In CPOM states a non-physician-owned corporate entity cannot employ
     physicians. Standard workaround is a "friendly PC" + MSO structure
     (~$30–50k legal setup, ongoing compliance burden, dependency on the
     friendly-PC physician owner).
   - **Strict CPOM:** CA, TX, NY, NJ, IL, CO, IA, OH
   - **Permissive / no CPOM:** FL, AZ, GA, PA, most southern states
   - A licensed physician-founder can self-own the PC and bypass the
     friendly-PC overhead entirely in most CPOM states, including PA.

2. **Chronic-disease TAM (density × absolute count)**
   - Highest *density* (% prevalence): WV, MS, AL, AR, LA (Diabetes Belt).
   - Highest *absolute count* (raw market size): CA, TX, FL, NY.
   - Highest senior population (proxy for chronic disease): FL, ME, WV, AZ.
   - CDC Diabetes Belt: AL, AR, FL, GA, KY, LA, MS, NC, OH, PA, SC, TN, TX,
     VA, WV.

3. **Founder licensure & home-state network**
   - Existing unrestricted license in a workable state eliminates the
     3–9 month state-by-state licensing delay for the launch clinician.

4. **Tax climate** (minor but cumulative)
   - No state income tax: FL, TX, TN, NV, WA, SD, WY, AK.

5. **Multi-state expansion path** — Interstate Medical Licensure Compact (IMLC)
   - Member states allow expedited licenses (~2–4 weeks, ~$700/state) for
     IMLC-eligible physicians vs. 3–9 months state-by-state.
   - PA is an IMLC member. FL, NY, CA, TX are *not*.

### Criteria that proved flat (do not drive state selection)

- **Telehealth practice rules** — Post-COVID, most states permit establishing
  the physician-patient relationship via telehealth, audio-only visits, and
  prescribing non-controlled substances. Controlled-substance prescribing is
  governed federally by the DEA (Ryan Haight Act) and is uniform across states.
- **Reimbursement / payer landscape** — Cash-pay pricing eliminates state
  Medicaid programs and state-regulated insurance markets as variables.
- **Competitive density** — Hims/Ro/Lotus/Done all operate nationwide; no
  state is meaningfully less competitive.

---

## 2. Launch State Decision — Pennsylvania

**Decision:** Launch in Pennsylvania.

### Rationale

- **Founder holds an unrestricted PA physician license + DEA.** Zero licensure
  cost or delay to start. Sole clinician for the first cohort.
- **PA is moderate-CPOM but the physician-founder can self-own the PC.**
  No friendly-PC structure required, saving ~$30–50k legal and ongoing
  compliance overhead.
- **PA is in the CDC Diabetes Belt.** ~13M population, ~1.5M adults with
  diabetes, ~3.5M with hypertension, ~1M with both. At 0.25% conversion to
  cash-pay at $39 ARPU → ~5–10k subscribers / $2.5–5M ARR ceiling in
  year 1 from PA alone. Sufficient runway to validate without crossing state
  lines.
- **PA is an IMLC member.** Foundation for fast multi-state expansion once
  the model is proven.
- **Telehealth-permissive.** Established physician-patient relationship via
  telehealth allowed; audio-only allowed; Medicaid telehealth parity (not
  used in cash-pay, useful later).

### Why not Florida (the on-paper winner)

Florida ranks highest by criteria alone — largest senior + chronic-disease
TAM, permissive CPOM, no income tax, telehealth-permissive, mature
friendly-PC precedent. But:

- Founder is not licensed in FL; license takes months.
- Founder is not physically present; no in-state operational network.
- The PA-vs-FL gap is smaller than the founder-license + sole-clinician
  advantage of PA.

Florida is **expansion state #1**, not the launch state.

### Why not Texas / California

Strict CPOM + not IMLC + founder not licensed. The cost of structure +
licensing outweighs the larger TAM until the model is validated.

---

## 3. Multi-State Expansion Order

Once the PA model is validated (~300+ active patients, retention curves
stable), expand in this order:

| Priority | State | CPOM | IMLC | Diabetes Belt | Senior % | Tax | Notes |
|---|---|---|---|---|---|---|---|
| 1 | **Florida** | Permissive | No | Yes | Highest | None | Largest TAM, separate license, worth the friction |
| 2 | **Tennessee** | Permissive | Yes | Yes | Mid | None | IMLC-expedited license, no income tax |
| 3 | **Georgia** | Permissive | Yes | Yes | Mid | State | IMLC-expedited |
| 4 | **Arizona** | Permissive | Yes | No | High | State | Senior-heavy retiree population |
| 5 | **North Carolina** | Permissive | Yes | Yes | Mid | State | IMLC-expedited |

**Later-stage** (after Series A or proven multi-state operations): TX, CA, NY.
Strict CPOM requires the friendly-PC + MSO structure; payback only at scale.

**Trigger to add state N+1:** When the existing state(s) hit ~70% of
single-clinician capacity *and* a second clinician is hired/onboarded.

---

## 4. Legal Entity Structure

Set up the dual-entity structure on day one — before patient #1 — even though
the founder is the sole clinician. Retrofitting after revenue exists is
expensive and triggers HIPAA business-associate-agreement rework.

### Entities

- **PA-PC (Pennsylvania Professional Corporation)**
  - 100% owned by the physician-founder.
  - Sole physician initially; hires clinicians as the panel grows.
  - All patient encounters, prescriptions, and clinical records live here.
  - Holds the clinical license, malpractice insurance, and DEA registration.

- **PBC (Delaware Public Benefit Corporation, C-corp)**
  - The technology, brand, and operations company.
  - Owns the iOS app, the brand, the customer relationships, the billing
    infrastructure.
  - Investors invest here. Stock and option pool live here.

- **MSA (Management Services Agreement) PBC → PA-PC**
  - PBC provides tech, marketing, admin, billing services to the PA-PC.
  - PA-PC pays PBC a management fee (fair-market-value flat or cost-plus —
    *not* a % of clinical revenue, to stay clear of fee-splitting rules in
    states that prohibit it).
  - Critical to get the fee structure right at $0 revenue. Cheap to set up
    correctly now; expensive to restructure later.

### Cost

- Dual-entity setup with physician-founder owning both: ~**$8–15k legal**.
- Compare to friendly-PC arrangement (outside physician owner):
  **$30–50k legal** + ongoing compliance.
- Ongoing compliance: ~$2–3k/year.

### Why on day one, not at clinician #2

- When the second clinician is hired, the structure is already in place — no
  patient-record migration, no re-papering of contracts, no audit-trail gap.
- Investor due diligence assumes the structure exists. Raising into a
  single-entity setup is messy.
- HIPAA business-associate agreements between PBC (covered-entity vendor) and
  PA-PC (covered entity) need to exist before PHI flows.

---

## 5. Clinical Staffing Sequence

### Phase 1 — Sole Clinician (Founder)

- Founder is the only clinician.
- Capacity: ~150–250 active chronic-disease patients in async-first care
  (15–25 min/patient/month for medication management + messaging).
- Revenue ceiling at this stage: ~$70–120k MRR depending on pricing mix.
- Goal: validate protocols, retention curves, complaint rates, and the
  physician-in-the-loop workflow at human-judgment scale.

### Phase 2 — Hire Clinician #2

**Trigger:** ~150 active patients (begin recruiting), onboard before ~250
patients.

**Hiring options, in order of operational fit:**

1. **Physician Assistant (PA-C)** with PA license under founder's supervision.
   PA scope-of-practice in Pennsylvania permits chronic-disease management,
   prescribing (including controlled substances with DEA), and lab ordering
   under a written collaboration agreement. Lowest cost, strongest leverage
   for the founder's clinical time. Recommended for clinician #2.

2. **Nurse Practitioner (NP)** with PA license. NPs in Pennsylvania have
   slightly more autonomy than PAs but require a collaborative agreement
   with a physician. Good for chronic-disease management. Comparable cost
   to PA-C.

3. **Physician (MD/DO)** — only if the second clinician needs to operate
   independently (e.g., expansion to a non-PA state where the founder is not
   licensed). Higher cost, slower to recruit.

**Employment structure:** W-2 employees of the PA-PC (not the PBC). 1099 is
viable for very part-time coverage but W-2 is cleaner for malpractice,
benefits, and audit trail.

### Phase 3 — Per-State Clinical Lead

When a new state is added, the medical director of record in that state must
be licensed in-state. Options:

- Founder adds the state license (IMLC where applicable).
- Hire an in-state physician as state medical director (W-2 part-time or
  fractional).

---

## 6. Clinical & Regulatory Watch-Outs

### GLP-1s and compounded medications

- GLP-1s (semaglutide / tirzepatide — Ozempic, Wegovy, Mounjaro, Zepbound)
  are not controlled substances but are in active FDA scrutiny.
- The FDA shortage list status determines whether 503A/503B compounding
  pharmacies can legally produce compounded versions. Status changes
  frequently (semaglutide was removed from the shortage list in 2024;
  tirzepatide status changed in 2024–2025).
- **Decision required before launching any weight-management or
  cardiometabolic protocol that includes GLP-1s:**
  - Brand-name only (insurance / cash-pay at retail prices, $900–1,300/mo)?
  - Compounded (cheaper, $200–400/mo) but with shortage-list compliance
    risk?
  - Defer GLP-1s entirely from Phase 1 and focus on non-GLP-1 chronic-
    disease management?
- Recommendation: **defer GLP-1s from Phase 1**. Launch with metformin,
  SGLT2s, ACE/ARB, statins, beta-blockers — well-understood, low
  regulatory volatility, broad applicability. Add GLP-1s in Phase 2 once
  the compounding pharmacy supply chain and FDA posture stabilize.

### Controlled-substance prescribing via telehealth

- Governed federally by the Ryan Haight Act and current DEA telehealth
  flexibilities. Flexibilities have been extended multiple times but are
  tightening.
- **Phase 1 protocols should not depend on controlled-substance
  prescribing.** Chronic-disease management for diabetes/hypertension/
  hyperlipidemia does not require it.

### Async-first vs. synchronous requirements

- Pennsylvania does not require synchronous visits to establish a
  physician-patient relationship. Async messaging + asynchronous
  prescribing is permitted within standard of care.
- Some states require at least one synchronous visit before prescribing —
  factor this into expansion-state protocols.

---

## 7. TAM Reference (Pennsylvania)

| Population | Count (approx.) |
|---|---|
| PA adults | ~10.4M |
| PA adults with diabetes | ~1.5M |
| PA adults with hypertension | ~3.5M |
| PA adults with both diabetes + hypertension | ~1.0M |
| PA adults with obesity | ~3.2M |
| PA adults 65+ | ~2.5M |

**SAM (Serviceable Addressable Market):** PA adults with at least one target
chronic condition, smartphone-equipped, credit-card-equipped, willing to pay
cash for telehealth — order of magnitude 500k–1M.

**SOM Year 1 (Serviceable Obtainable Market):** 0.25–1% capture of SAM →
~1,250–10,000 subscribers. At $39 ARPU/month → ~$0.6M–$4.7M ARR ceiling
in year 1 from PA alone. Sufficient runway to validate without expansion.

---

## 8. Open Decisions

- [ ] Choose initial chronic-disease focus (diabetes-only vs. diabetes +
      hypertension vs. broader cardiometabolic bundle).
- [ ] Pricing: $29 / $39 / $49 / tiered? Tied to which conditions are
      included?
- [ ] GLP-1 stance for Phase 1 (defer recommended above).
- [ ] PA-PC + PBC formation — engage healthcare-corporate counsel.
- [ ] Malpractice carrier selection (telemedicine endorsement required).
- [ ] E-prescribing vendor (Surescripts integration via DrFirst / RXNT /
      direct).
- [ ] Lab partner for at-home draws (Labcorp OnDemand, Quest, Getlabs).
