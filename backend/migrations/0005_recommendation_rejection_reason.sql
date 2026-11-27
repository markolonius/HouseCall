-- 0005_recommendation_rejection_reason: add rejection_reason to
-- recommendations so a physician's reason for rejecting a recommendation can
-- be stored (see openspec/changes/add-agent-care-loop/specs/physician-in-loop/spec.md,
-- "Rejection Reason Capture").
--
-- Nullable with no default: only REJECTED rows will ever have this
-- populated. Non-empty enforcement on rejection is a store-layer concern
-- added alongside the Transition changes, not a schema constraint here.

ALTER TABLE recommendations
    ADD COLUMN rejection_reason text;
