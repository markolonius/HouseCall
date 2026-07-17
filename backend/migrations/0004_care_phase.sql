-- 0004_care_phase: add care_phase to conversations so the drafter has a
-- persistent, server-authoritative notion of where an encounter stands
-- (see openspec/changes/add-agent-care-loop/design.md).
--
-- The column is added NOT NULL DEFAULT 'INTAKE' in one step, which also
-- backfills every existing row to 'INTAKE' for free. The two UPDATEs below
-- then promote rows that already have recommendation history, applied in
-- ascending precedence order (DELIVERED last) so a conversation holding both
-- a pending and a delivered recommendation lands on 'PLAN_DELIVERED' —
-- REJECTED never promotes a row, so a conversation with only a rejected
-- recommendation is left at 'INTAKE'.

ALTER TABLE conversations
    ADD COLUMN care_phase text NOT NULL DEFAULT 'INTAKE';

-- Lower precedence: a pending recommendation means the conversation is
-- waiting on physician review.
UPDATE conversations c
   SET care_phase = 'AWAITING_REVIEW'
  FROM recommendations r
 WHERE r.tenant_id = c.tenant_id
   AND r.conversation_id = c.id
   AND r.state = 'PENDING_REVIEW';

-- Higher precedence: a delivered recommendation always wins, overriding the
-- AWAITING_REVIEW set above when a conversation has both.
UPDATE conversations c
   SET care_phase = 'PLAN_DELIVERED'
  FROM recommendations r
 WHERE r.tenant_id = c.tenant_id
   AND r.conversation_id = c.id
   AND r.state = 'DELIVERED';

ALTER TABLE conversations
    ADD CONSTRAINT conversations_care_phase_check
    CHECK (care_phase IN ('INTAKE', 'AWAITING_REVIEW', 'PLAN_DELIVERED'));
