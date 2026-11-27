-- 0006_recommendation_provenance: record which model and prompt version
-- produced each recommendation draft (see
-- openspec/changes/add-agent-safety-and-evals/design.md, Decision 4).
--
-- Both nullable with no default: rows created before this migration have no
-- provenance. Physician/auditor-facing only.

ALTER TABLE recommendations
    ADD COLUMN model_name     text,
    ADD COLUMN prompt_version text;
