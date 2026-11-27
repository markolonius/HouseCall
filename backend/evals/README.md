# Clinical evaluation harness

Synthetic vignettes only. Never put real patient data in this directory.

    make eval            # from backend/; loads .env if present
    go run ./cmd/eval --cases evals/cases --thresholds evals/thresholds.json

The runner calls the real agent triage and SOAP draft code paths
(`agent.EvalTriage`, `agent.EvalSOAP`) with the client built from
`AGENT_MODEL_BASE_URL` / `AGENT_MODEL_NAME` / `AGENT_MODEL_API_KEY`. It writes
`evals/results/<date>-<model>.json` (model, prompt versions, timestamp,
per-case outcome, aggregate metrics; never model output) and prints a summary.
Exit status is 1 when any metric misses `evals/thresholds.json`, 2 on setup
errors. Evals do not run in CI; commit the result file with any change to
prompts, schemas, rules or the model.

`--rules-only` (emergent recall from red-flag rules with the model forced to
fail) is reserved and errors until Phase 4.

## Case format

`evals/cases/*.json`; each file is one case object or an array of cases. `id`
is unique.

| Field | Applies to | Meaning |
|---|---|---|
| `id` | all | unique id |
| `kind` | all | `triage` or `interview_soap` |
| `description` | all | optional synthetic summary |
| `reviewed_by` | all | empty until a physician signs off |
| `turns` | all | `[{"role": "user"\|"assistant", "content": "..."}]` |
| `expected_triage` | triage | `EMERGENT` or `ROUTINE` |
| `required_sections` | interview_soap | sections that must be non-empty |
| `must_include` / `must_not_include` | interview_soap | case-insensitive substrings the note must / must not contain |
| `objective_must_not_contain` | interview_soap | extra terms banned from Objective |

## Metrics

- `emergent_recall`: EMERGENT triage cases classified EMERGENT (unparseable or
  failed calls count as misses).
- `false_emergent_rate`: ROUTINE triage cases classified EMERGENT.
- `structured_output_validity`: triage calls with exactly one marker plus SOAP
  drafts that parse and validate (model errors count as invalid). Phase 3
  moves this to JSON schemas.
- `soap_objective_fidelity`: drafted Objective sections containing no exam
  finding (built-in lexicon, plus `objective_must_not_contain`) that is absent
  from the patient's own turns.

A metric with no applicable cases reports `n/a` and passes vacuously.
