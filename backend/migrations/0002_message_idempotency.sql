-- 0002_message_idempotency: add idempotency_key to messages for safe offline replay.
--
-- The column is nullable so existing rows are unaffected.  A partial unique
-- index (WHERE idempotency_key IS NOT NULL) scopes deduplication to
-- (tenant_id, conversation_id, idempotency_key) — rows without a key are
-- never compared and can be inserted freely.  The partial index also keeps
-- the constraint from matching across tenants or conversations: two different
-- tenants holding the same idempotency_key string do NOT collide.

ALTER TABLE messages
    ADD COLUMN idempotency_key text;

-- Partial unique index: only non-NULL keys participate in the constraint so
-- legacy/server-generated messages (NULL key) are unaffected.
CREATE UNIQUE INDEX messages_idempotency_key_idx
    ON messages (tenant_id, conversation_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
