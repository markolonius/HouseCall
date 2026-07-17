// Package store is the only Postgres access path in the backend. Every
// PHI-bearing query takes a TenantID and includes it in the WHERE clause.
// No query path may omit it. ErrNotFound is returned when a row matching
// the tenant + key is absent — including the case where the row exists
// under a different tenant, which to this tenant is indistinguishable
// from non-existence by design.
package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrNotFound = errors.New("store: not found")

type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

func (s *Store) Pool() *pgxpool.Pool { return s.pool }

// --- tenants (not tenant-scoped: tenants is the root) ---

func (s *Store) CreateTenant(ctx context.Context, kind, name string) (Tenant, error) {
	var t Tenant
	err := s.pool.QueryRow(ctx,
		`INSERT INTO tenants (kind, name) VALUES ($1, $2)
		 RETURNING id, kind, name, created_at`,
		kind, name,
	).Scan(&t.ID, &t.Kind, &t.Name, &t.CreatedAt)
	return t, err
}

// --- patients ---

func (s *Store) CreatePatient(ctx context.Context, tenant TenantID, p Patient) (Patient, error) {
	err := s.pool.QueryRow(ctx,
		`INSERT INTO patients (tenant_id, email, full_name, state, password_hash)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, tenant_id, email, full_name, state, password_hash, created_at`,
		tenant.UUID(), p.Email, p.FullName, p.State, p.PasswordHash,
	).Scan(&p.ID, &p.TenantID, &p.Email, &p.FullName, &p.State, &p.PasswordHash, &p.CreatedAt)
	return p, err
}

func (s *Store) GetPatient(ctx context.Context, tenant TenantID, id uuid.UUID) (Patient, error) {
	var p Patient
	err := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, email, full_name, state, password_hash, created_at
		   FROM patients
		  WHERE tenant_id = $1 AND id = $2`,
		tenant.UUID(), id,
	).Scan(&p.ID, &p.TenantID, &p.Email, &p.FullName, &p.State, &p.PasswordHash, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Patient{}, ErrNotFound
	}
	return p, err
}

func (s *Store) GetPatientByEmail(ctx context.Context, tenant TenantID, email string) (Patient, error) {
	var p Patient
	err := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, email, full_name, state, password_hash, created_at
		   FROM patients
		  WHERE tenant_id = $1 AND email = $2`,
		tenant.UUID(), email,
	).Scan(&p.ID, &p.TenantID, &p.Email, &p.FullName, &p.State, &p.PasswordHash, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Patient{}, ErrNotFound
	}
	return p, err
}

// --- physicians ---

func (s *Store) CreatePhysician(ctx context.Context, tenant TenantID, p Physician) (Physician, error) {
	err := s.pool.QueryRow(ctx,
		`INSERT INTO physicians (tenant_id, email, full_name, states_licensed, password_hash)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, tenant_id, email, full_name, states_licensed, password_hash, created_at`,
		tenant.UUID(), p.Email, p.FullName, p.StatesLicensed, p.PasswordHash,
	).Scan(&p.ID, &p.TenantID, &p.Email, &p.FullName, &p.StatesLicensed, &p.PasswordHash, &p.CreatedAt)
	return p, err
}

func (s *Store) GetPhysician(ctx context.Context, tenant TenantID, id uuid.UUID) (Physician, error) {
	var p Physician
	err := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, email, full_name, states_licensed, password_hash, created_at
		   FROM physicians
		  WHERE tenant_id = $1 AND id = $2`,
		tenant.UUID(), id,
	).Scan(&p.ID, &p.TenantID, &p.Email, &p.FullName, &p.StatesLicensed, &p.PasswordHash, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Physician{}, ErrNotFound
	}
	return p, err
}

func (s *Store) GetPhysicianByEmail(ctx context.Context, tenant TenantID, email string) (Physician, error) {
	var p Physician
	err := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, email, full_name, states_licensed, password_hash, created_at
		   FROM physicians
		  WHERE tenant_id = $1 AND email = $2`,
		tenant.UUID(), email,
	).Scan(&p.ID, &p.TenantID, &p.Email, &p.FullName, &p.StatesLicensed, &p.PasswordHash, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Physician{}, ErrNotFound
	}
	return p, err
}

// --- care relationships ---

func (s *Store) CreateCareRelationship(ctx context.Context, tenant TenantID, patientID, physicianID uuid.UUID) (CareRelationship, error) {
	var cr CareRelationship
	err := s.pool.QueryRow(ctx,
		`INSERT INTO care_relationships (tenant_id, patient_id, physician_id, active)
		 VALUES ($1, $2, $3, true)
		 RETURNING id, tenant_id, patient_id, physician_id, active, created_at`,
		tenant.UUID(), patientID, physicianID,
	).Scan(&cr.ID, &cr.TenantID, &cr.PatientID, &cr.PhysicianID, &cr.Active, &cr.CreatedAt)
	return cr, err
}

// ListPatientsByPhysician returns the slim PanelPatient read model for the
// physician's active care relationships. It does not select password_hash or
// email so credentials/extra PHI never enter the web panel's template context.
func (s *Store) ListPatientsByPhysician(ctx context.Context, tenant TenantID, physicianID uuid.UUID) ([]PanelPatient, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT p.id, p.tenant_id, p.full_name, p.state
		   FROM patients p
		   JOIN care_relationships cr
		     ON cr.tenant_id = p.tenant_id
		    AND cr.patient_id = p.id
		  WHERE p.tenant_id = $1
		    AND cr.physician_id = $2
		    AND cr.active = true
		  ORDER BY p.created_at`,
		tenant.UUID(), physicianID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PanelPatient
	for rows.Next() {
		var p PanelPatient
		if err := rows.Scan(&p.ID, &p.TenantID, &p.FullName, &p.State); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// --- conversations ---

func (s *Store) CreateConversation(ctx context.Context, tenant TenantID, patientID uuid.UUID, title string) (Conversation, error) {
	var c Conversation
	err := s.pool.QueryRow(ctx,
		`INSERT INTO conversations (tenant_id, patient_id, title)
		 VALUES ($1, $2, $3)
		 RETURNING id, tenant_id, patient_id, title, care_phase, created_at, updated_at`,
		tenant.UUID(), patientID, title,
	).Scan(&c.ID, &c.TenantID, &c.PatientID, &c.Title, &c.CarePhase, &c.CreatedAt, &c.UpdatedAt)
	return c, err
}

func (s *Store) GetConversation(ctx context.Context, tenant TenantID, id uuid.UUID) (Conversation, error) {
	var c Conversation
	err := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, patient_id, title, care_phase, created_at, updated_at
		   FROM conversations
		  WHERE tenant_id = $1 AND id = $2`,
		tenant.UUID(), id,
	).Scan(&c.ID, &c.TenantID, &c.PatientID, &c.Title, &c.CarePhase, &c.CreatedAt, &c.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Conversation{}, ErrNotFound
	}
	return c, err
}

func (s *Store) ListConversationsByPatient(ctx context.Context, tenant TenantID, patientID uuid.UUID) ([]Conversation, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, tenant_id, patient_id, title, care_phase, created_at, updated_at
		   FROM conversations
		  WHERE tenant_id = $1 AND patient_id = $2
		  ORDER BY updated_at DESC`,
		tenant.UUID(), patientID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Conversation
	for rows.Next() {
		var c Conversation
		if err := rows.Scan(&c.ID, &c.TenantID, &c.PatientID, &c.Title, &c.CarePhase, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// --- messages ---

func (s *Store) CreateMessage(ctx context.Context, tenant TenantID, conversationID uuid.UUID, role, content string) (Message, error) {
	var m Message
	err := s.pool.QueryRow(ctx,
		`INSERT INTO messages (tenant_id, conversation_id, role, content)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, tenant_id, conversation_id, role, content, idempotency_key, created_at`,
		tenant.UUID(), conversationID, role, content,
	).Scan(&m.ID, &m.TenantID, &m.ConversationID, &m.Role, &m.Content, &m.IdempotencyKey, &m.CreatedAt)
	return m, err
}

// CreateMessageIdempotent inserts a message with the given idempotency key.
// If a message already exists for (tenant_id, conversation_id, idempotency_key),
// the existing row is returned without inserting a duplicate and the second
// return value is true (dedupe hit). This is safe under concurrent replay:
// two goroutines racing on the same key converge on the same row.
//
// Callers MUST NOT write a message.created audit event when deduped == true;
// the event was already written for the original insert.
func (s *Store) CreateMessageIdempotent(
	ctx context.Context,
	tenant TenantID,
	conversationID uuid.UUID,
	role, content string,
	idempotencyKey string,
) (msg Message, deduped bool, err error) {
	// INSERT ... ON CONFLICT DO NOTHING, then SELECT the existing row.
	// This is a single-round-trip approach that is race-safe: the first
	// caller inserts, subsequent callers get 0 rows from INSERT and then
	// read the already-committed row.
	const q = `
		INSERT INTO messages (tenant_id, conversation_id, role, content, idempotency_key)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (tenant_id, conversation_id, idempotency_key)
		    WHERE idempotency_key IS NOT NULL
		DO NOTHING
		RETURNING id, tenant_id, conversation_id, role, content, idempotency_key, created_at`

	row := s.pool.QueryRow(ctx, q, tenant.UUID(), conversationID, role, content, idempotencyKey)
	scanErr := row.Scan(&msg.ID, &msg.TenantID, &msg.ConversationID, &msg.Role, &msg.Content, &msg.IdempotencyKey, &msg.CreatedAt)

	if scanErr == nil {
		// Fresh insert — the RETURNING clause provided the new row.
		return msg, false, nil
	}
	if !errors.Is(scanErr, pgx.ErrNoRows) {
		// Unexpected error.
		return Message{}, false, scanErr
	}

	// ErrNoRows means DO NOTHING fired — the row already exists.
	// Fetch it so the caller gets the original server-assigned ID.
	fetchErr := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, conversation_id, role, content, idempotency_key, created_at
		   FROM messages
		  WHERE tenant_id = $1
		    AND conversation_id = $2
		    AND idempotency_key = $3`,
		tenant.UUID(), conversationID, idempotencyKey,
	).Scan(&msg.ID, &msg.TenantID, &msg.ConversationID, &msg.Role, &msg.Content, &msg.IdempotencyKey, &msg.CreatedAt)
	// Paranoia guard: under READ COMMITTED the conflicting row is always
	// visible to this SELECT after ON CONFLICT DO NOTHING, so ErrNoRows
	// here is effectively unreachable in normal operation.
	if errors.Is(fetchErr, pgx.ErrNoRows) {
		return Message{}, false, ErrNotFound
	}
	return msg, true, fetchErr
}

func (s *Store) ListMessagesByConversation(ctx context.Context, tenant TenantID, conversationID uuid.UUID) ([]Message, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, tenant_id, conversation_id, role, content, idempotency_key, created_at
		   FROM messages
		  WHERE tenant_id = $1 AND conversation_id = $2
		  ORDER BY created_at`,
		tenant.UUID(), conversationID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.TenantID, &m.ConversationID, &m.Role, &m.Content, &m.IdempotencyKey, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// --- recommendations ---

func (s *Store) CreateRecommendation(ctx context.Context, tenant TenantID, r Recommendation) (Recommendation, error) {
	err := s.pool.QueryRow(ctx,
		`INSERT INTO recommendations
		   (tenant_id, conversation_id, patient_id, state, payload_type, payload, draft_content)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 RETURNING id, tenant_id, conversation_id, patient_id, state, payload_type, payload,
		           draft_content, final_content, reviewed_by, reviewed_at, created_at`,
		tenant.UUID(), r.ConversationID, r.PatientID, r.State, r.PayloadType, r.Payload, r.DraftContent,
	).Scan(&r.ID, &r.TenantID, &r.ConversationID, &r.PatientID, &r.State, &r.PayloadType, &r.Payload,
		&r.DraftContent, &r.FinalContent, &r.ReviewedBy, &r.ReviewedAt, &r.CreatedAt)
	return r, err
}

func (s *Store) GetRecommendation(ctx context.Context, tenant TenantID, id uuid.UUID) (Recommendation, error) {
	var r Recommendation
	err := s.pool.QueryRow(ctx,
		`SELECT id, tenant_id, conversation_id, patient_id, state, payload_type, payload,
		        draft_content, final_content, reviewed_by, reviewed_at, created_at
		   FROM recommendations
		  WHERE tenant_id = $1 AND id = $2`,
		tenant.UUID(), id,
	).Scan(&r.ID, &r.TenantID, &r.ConversationID, &r.PatientID, &r.State, &r.PayloadType, &r.Payload,
		&r.DraftContent, &r.FinalContent, &r.ReviewedBy, &r.ReviewedAt, &r.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Recommendation{}, ErrNotFound
	}
	return r, err
}

func (s *Store) ListRecommendationsByState(ctx context.Context, tenant TenantID, state string) ([]Recommendation, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, tenant_id, conversation_id, patient_id, state, payload_type, payload,
		        draft_content, final_content, reviewed_by, reviewed_at, created_at
		   FROM recommendations
		  WHERE tenant_id = $1 AND state = $2
		  ORDER BY created_at`,
		tenant.UUID(), state,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Recommendation
	for rows.Next() {
		var r Recommendation
		if err := rows.Scan(&r.ID, &r.TenantID, &r.ConversationID, &r.PatientID, &r.State, &r.PayloadType, &r.Payload,
			&r.DraftContent, &r.FinalContent, &r.ReviewedBy, &r.ReviewedAt, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// --- recommendations (additional) ---

// ListRecommendationsByPhysician returns recommendations in the given state
// for all patients who have an active care relationship with this physician,
// within the tenant. This is the physician's review queue.
func (s *Store) ListRecommendationsByPhysician(ctx context.Context, tenant TenantID, physicianID uuid.UUID, state string) ([]Recommendation, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT r.id, r.tenant_id, r.conversation_id, r.patient_id, r.state,
		        r.payload_type, r.payload, r.draft_content, r.final_content,
		        r.reviewed_by, r.reviewed_at, r.created_at
		   FROM recommendations r
		   JOIN care_relationships cr
		     ON cr.tenant_id = r.tenant_id
		    AND cr.patient_id = r.patient_id
		  WHERE r.tenant_id = $1
		    AND cr.physician_id = $2
		    AND cr.active = true
		    AND r.state = $3
		  ORDER BY r.created_at`,
		tenant.UUID(), physicianID, state,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Recommendation
	for rows.Next() {
		var r Recommendation
		if err := rows.Scan(&r.ID, &r.TenantID, &r.ConversationID, &r.PatientID, &r.State,
			&r.PayloadType, &r.Payload, &r.DraftContent, &r.FinalContent,
			&r.ReviewedBy, &r.ReviewedAt, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetRecommendationForPhysician returns the recommendation only when the
// patient named in it has an active care relationship with physicianID in the
// given tenant. It mirrors the JOIN used in ListRecommendationsByPhysician so
// that the write path (review) enforces the same access control as the read
// (list) path. ErrNotFound is returned when the recommendation does not exist,
// belongs to another tenant, or the physician has no active care relationship
// with the patient — the three cases are indistinguishable to the caller by
// design (no information disclosure).
func (s *Store) GetRecommendationForPhysician(ctx context.Context, tenant TenantID, physicianID uuid.UUID, id uuid.UUID) (Recommendation, error) {
	var r Recommendation
	err := s.pool.QueryRow(ctx,
		`SELECT r.id, r.tenant_id, r.conversation_id, r.patient_id, r.state,
		        r.payload_type, r.payload, r.draft_content, r.final_content,
		        r.reviewed_by, r.reviewed_at, r.created_at
		   FROM recommendations r
		   JOIN care_relationships cr
		     ON cr.tenant_id = r.tenant_id
		    AND cr.patient_id = r.patient_id
		  WHERE r.tenant_id = $1
		    AND r.id = $2
		    AND cr.physician_id = $3
		    AND cr.active = true`,
		tenant.UUID(), id, physicianID,
	).Scan(&r.ID, &r.TenantID, &r.ConversationID, &r.PatientID, &r.State,
		&r.PayloadType, &r.Payload, &r.DraftContent, &r.FinalContent,
		&r.ReviewedBy, &r.ReviewedAt, &r.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Recommendation{}, ErrNotFound
	}
	return r, err
}

// TxWriter is the minimum write interface needed inside a transaction. It is
// satisfied by *TxStore in production and by test fakes that do not require a
// real database connection.
type TxWriter interface {
	UpdateRecommendationState(ctx context.Context, tenant TenantID, id uuid.UUID, state string, reviewedBy *uuid.UUID, finalContent *string) error
	UpdateRecommendationRejection(ctx context.Context, tenant TenantID, id uuid.UUID, reviewedBy uuid.UUID, reason string) error
	CreateAuditEvent(ctx context.Context, tenant TenantID, e AuditEvent) error
	TransitionCarePhase(ctx context.Context, tenant TenantID, conversationID uuid.UUID, from, to CarePhase) error
}

// TxStore wraps a pgx.Tx and exposes the write methods needed for atomic
// multi-operation sequences (e.g. state transition + audit event). Obtain
// one via Store.Txn.
type TxStore struct {
	tx pgx.Tx
}

// Txn executes fn inside a transaction. fn receives a *TxStore with which
// it may call write methods. The transaction is committed if fn returns nil;
// rolled back otherwise.
func (s *Store) Txn(ctx context.Context, fn func(*TxStore) error) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := fn(&TxStore{tx: tx}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// TxnW executes fn inside a transaction, passing a TxWriter interface value
// rather than the concrete *TxStore. This allows callers that accept a
// store.TxWriter (e.g. internal/review) to share the same transaction without
// an import cycle. The transaction is committed if fn returns nil; rolled back
// otherwise.
func (s *Store) TxnW(ctx context.Context, fn func(TxWriter) error) error {
	return s.Txn(ctx, func(tx *TxStore) error {
		return fn(tx)
	})
}

// CreateRecommendation inserts a new recommendation within tx.
// Use this when the create must be atomic with a subsequent state update
// and audit event (e.g. the agent drafting flow: DRAFT → PENDING_REVIEW + audit).
func (ts *TxStore) CreateRecommendation(ctx context.Context, tenant TenantID, r Recommendation) (Recommendation, error) {
	err := ts.tx.QueryRow(ctx,
		`INSERT INTO recommendations
		   (tenant_id, conversation_id, patient_id, state, payload_type, payload, draft_content)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 RETURNING id, tenant_id, conversation_id, patient_id, state, payload_type, payload,
		           draft_content, final_content, reviewed_by, reviewed_at, created_at`,
		tenant.UUID(), r.ConversationID, r.PatientID, r.State, r.PayloadType, r.Payload, r.DraftContent,
	).Scan(&r.ID, &r.TenantID, &r.ConversationID, &r.PatientID, &r.State, &r.PayloadType, &r.Payload,
		&r.DraftContent, &r.FinalContent, &r.ReviewedBy, &r.ReviewedAt, &r.CreatedAt)
	return r, err
}

// UpdateRecommendationState sets the state (and optionally reviewed_by,
// reviewed_at, final_content) for a recommendation within tx.
//
// reviewed_at is only stamped when reviewedBy is non-nil — i.e. when a human
// physician performs the review. Agent-driven transitions (reviewedBy == nil,
// e.g. DRAFT→PENDING_REVIEW) must leave reviewed_at NULL so the Phase 5
// physician queue can use "reviewed_at IS NOT NULL" as a reliable human-review
// proxy.
func (ts *TxStore) UpdateRecommendationState(ctx context.Context, tenant TenantID, id uuid.UUID, state string, reviewedBy *uuid.UUID, finalContent *string) error {
	_, err := ts.tx.Exec(ctx,
		`UPDATE recommendations
		    SET state         = $3,
		        reviewed_by   = $4,
		        reviewed_at   = CASE WHEN $4::uuid IS NOT NULL THEN NOW() ELSE reviewed_at END,
		        final_content = $5
		  WHERE tenant_id = $1 AND id = $2`,
		tenant.UUID(), id, state, reviewedBy, finalContent,
	)
	return err
}

// UpdateRecommendationRejection sets the recommendation to REJECTED, stamps
// reviewed_by/reviewed_at, and stores the physician's rejection reason —
// within tx, atomically with the audit event and the AWAITING_REVIEW→INTAKE
// care-phase reset (see internal/review.Execute). This is a dedicated method
// rather than an addition to UpdateRecommendationState because
// rejection_reason is written on no other transition. final_content is
// deliberately left untouched (stays nil) — a REJECTED recommendation is
// never patient-visible.
func (ts *TxStore) UpdateRecommendationRejection(ctx context.Context, tenant TenantID, id uuid.UUID, reviewedBy uuid.UUID, reason string) error {
	_, err := ts.tx.Exec(ctx,
		`UPDATE recommendations
		    SET state            = 'REJECTED',
		        reviewed_by      = $3,
		        reviewed_at      = NOW(),
		        rejection_reason = $4
		  WHERE tenant_id = $1 AND id = $2`,
		tenant.UUID(), id, reviewedBy, reason,
	)
	return err
}

// CreateMessage inserts a message within tx. Use this when the message
// insert must be atomic with other writes in the same transaction — e.g. the
// SOAP draft commit, which persists the fixed patient-facing acknowledgement
// message atomically with the recommendation and the INTAKE→AWAITING_REVIEW
// care-phase transition (task 2.2).
func (ts *TxStore) CreateMessage(ctx context.Context, tenant TenantID, conversationID uuid.UUID, role, content string) (Message, error) {
	var m Message
	err := ts.tx.QueryRow(ctx,
		`INSERT INTO messages (tenant_id, conversation_id, role, content)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, tenant_id, conversation_id, role, content, idempotency_key, created_at`,
		tenant.UUID(), conversationID, role, content,
	).Scan(&m.ID, &m.TenantID, &m.ConversationID, &m.Role, &m.Content, &m.IdempotencyKey, &m.CreatedAt)
	return m, err
}

// ErrInvalidCarePhaseTransition is returned by TransitionCarePhase when the
// requested (from, to) pair is not one of the edges the care-phase state
// machine allows. No row is mutated when this error is returned.
var ErrInvalidCarePhaseTransition = errors.New("store: invalid care phase transition")

// allowedCarePhaseTransitions enumerates every legal care-phase edge (see
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Conversation Care Phase State Machine"). Any (from, to) pair not present
// here — including same-state pairs like INTAKE→INTAKE — is disallowed.
var allowedCarePhaseTransitions = map[CarePhase]map[CarePhase]bool{
	CarePhaseIntake:         {CarePhaseAwaitingReview: true},
	CarePhaseAwaitingReview: {CarePhasePlanDelivered: true, CarePhaseIntake: true},
	CarePhasePlanDelivered:  {CarePhaseIntake: true},
}

// TransitionCarePhase moves a conversation's care_phase from `from` to `to`
// within tx, atomically with whatever other writes the caller composes in the
// same transaction (e.g. SOAP draft commit, recommendation delivery,
// rejection). The edge is validated against allowedCarePhaseTransitions
// before any query runs, so a disallowed edge returns
// ErrInvalidCarePhaseTransition without touching the database.
//
// The UPDATE is additionally scoped by `WHERE care_phase = from`, a
// compare-and-swap guard: if the row's current phase has already moved on
// (e.g. a racing writer), zero rows are affected and ErrNotFound is
// returned instead of silently overwriting a phase the caller didn't
// observe. The WHERE clause is also tenant-scoped, so a call made under the
// wrong tenant id matches zero rows and leaves the row untouched.
func (ts *TxStore) TransitionCarePhase(ctx context.Context, tenant TenantID, conversationID uuid.UUID, from, to CarePhase) error {
	if !allowedCarePhaseTransitions[from][to] {
		return ErrInvalidCarePhaseTransition
	}
	tag, err := ts.tx.Exec(ctx,
		`UPDATE conversations
		    SET care_phase = $4
		  WHERE tenant_id = $1 AND id = $2 AND care_phase = $3`,
		tenant.UUID(), conversationID, string(from), string(to),
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// CreateAuditEvent writes an audit event within tx. PHI must not appear in
// e.EventType or e.Metadata.
func (ts *TxStore) CreateAuditEvent(ctx context.Context, tenant TenantID, e AuditEvent) error {
	if e.Metadata == nil {
		e.Metadata = mustJSON(map[string]any{})
	}
	_, err := ts.tx.Exec(ctx,
		`INSERT INTO audit_events (tenant_id, actor_type, actor_id, event_type, metadata)
		 VALUES ($1, $2, $3, $4, $5)`,
		tenant.UUID(), e.ActorType, e.ActorID, e.EventType, e.Metadata,
	)
	return err
}

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

// --- audit events ---

func (s *Store) CreateAuditEvent(ctx context.Context, tenant TenantID, e AuditEvent) (AuditEvent, error) {
	if e.Metadata == nil {
		e.Metadata = []byte("{}")
	}
	err := s.pool.QueryRow(ctx,
		`INSERT INTO audit_events (tenant_id, actor_type, actor_id, event_type, metadata)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, tenant_id, actor_type, actor_id, event_type, metadata, created_at`,
		tenant.UUID(), e.ActorType, e.ActorID, e.EventType, e.Metadata,
	).Scan(&e.ID, &e.TenantID, &e.ActorType, &e.ActorID, &e.EventType, &e.Metadata, &e.CreatedAt)
	return e, err
}
