-- 0003_soap_note_payload: extend the recommendations payload_type constraint to
-- allow 'soap_note' in addition to the four existing types.
--
-- Postgres inline CHECK constraints receive a generated name
-- (recommendations_payload_type_check) that must be dropped before the
-- replacement can be added.  The new constraint is given the same name so
-- that re-running this migration on a database where it has already been
-- applied produces a clear "constraint already exists" error (rather than
-- silently adding a duplicate), which makes accidental double-application
-- detectable.

ALTER TABLE recommendations
    DROP CONSTRAINT recommendations_payload_type_check;

ALTER TABLE recommendations
    ADD CONSTRAINT recommendations_payload_type_check
    CHECK (payload_type IN (
        'guidance',
        'prescription',
        'lab_order',
        'referral',
        'soap_note'
    ));
