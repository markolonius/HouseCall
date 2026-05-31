-- 0001_init: tenants, patients, physicians, care_relationships,
-- conversations, messages, recommendations, audit_events.
--
-- Every PHI-bearing table carries a non-null tenant_id and a FK to tenants.
-- Cross-table FKs are *composite* on (tenant_id, parent_id) so the schema
-- itself rejects rows whose parent belongs to a different tenant. The
-- store layer also includes tenant_id in every WHERE clause; the
-- composite FK is defence-in-depth, not a substitute.
--
-- Postgres row-level security is the production mechanism (see
-- ARCHITECTURE.md §4) and is intentionally not enabled in the MVP —
-- store-layer enforcement plus composite FKs plus tenant-isolation tests
-- are sufficient and simpler at this stage.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE tenants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN ('dtc')),
    name        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE patients (
    id              uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    email           text NOT NULL,
    full_name       text NOT NULL,
    state           char(2) NOT NULL,
    password_hash   text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, email)
);

CREATE TABLE physicians (
    id                  uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    email               text NOT NULL,
    full_name           text NOT NULL,
    states_licensed     text[] NOT NULL CHECK (array_length(states_licensed, 1) >= 1),
    password_hash       text NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, email)
);

CREATE TABLE care_relationships (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    patient_id      uuid NOT NULL,
    physician_id    uuid NOT NULL,
    active          boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, patient_id, physician_id),
    FOREIGN KEY (tenant_id, patient_id)   REFERENCES patients   (tenant_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (tenant_id, physician_id) REFERENCES physicians (tenant_id, id) ON DELETE RESTRICT
);

CREATE TABLE conversations (
    id          uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    patient_id  uuid NOT NULL,
    title       text NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, patient_id) REFERENCES patients (tenant_id, id) ON DELETE RESTRICT
);

CREATE INDEX conversations_tenant_patient_idx
    ON conversations (tenant_id, patient_id, updated_at DESC);

CREATE TABLE messages (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    conversation_id uuid NOT NULL,
    role            text NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content         text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE RESTRICT
);

CREATE INDEX messages_tenant_conversation_idx
    ON messages (tenant_id, conversation_id, created_at);

CREATE TABLE recommendations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    conversation_id uuid NOT NULL,
    patient_id      uuid NOT NULL,
    state           text NOT NULL CHECK (state IN (
                        'DRAFT',
                        'PENDING_REVIEW',
                        'APPROVED',
                        'MODIFIED',
                        'REJECTED',
                        'DELIVERED'
                    )),
    payload_type    text NOT NULL CHECK (payload_type IN (
                        'guidance',
                        'prescription',
                        'lab_order',
                        'referral'
                    )),
    payload         jsonb NOT NULL,
    draft_content   text NOT NULL DEFAULT '',
    final_content   text,
    reviewed_by     uuid,
    reviewed_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (tenant_id, patient_id)      REFERENCES patients      (tenant_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (tenant_id, reviewed_by)     REFERENCES physicians    (tenant_id, id) ON DELETE RESTRICT
);

CREATE INDEX recommendations_tenant_state_idx
    ON recommendations (tenant_id, state, created_at);

CREATE INDEX recommendations_tenant_patient_idx
    ON recommendations (tenant_id, patient_id, created_at DESC);

CREATE TABLE audit_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    actor_type  text NOT NULL CHECK (actor_type IN ('patient', 'physician', 'agent', 'system')),
    actor_id    uuid,
    event_type  text NOT NULL,
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_events_tenant_created_idx
    ON audit_events (tenant_id, created_at DESC);
