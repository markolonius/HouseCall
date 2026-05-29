package store

import (
	"time"

	"github.com/google/uuid"
)

type TenantID uuid.UUID

func (t TenantID) String() string  { return uuid.UUID(t).String() }
func (t TenantID) UUID() uuid.UUID { return uuid.UUID(t) }

type Tenant struct {
	ID        TenantID
	Kind      string
	Name      string
	CreatedAt time.Time
}

type Patient struct {
	ID           uuid.UUID
	TenantID     TenantID
	Email        string
	FullName     string
	State        string
	PasswordHash string
	CreatedAt    time.Time
}

type Physician struct {
	ID             uuid.UUID
	TenantID       TenantID
	Email          string
	FullName       string
	StatesLicensed []string
	PasswordHash   string
	CreatedAt      time.Time
}

type CareRelationship struct {
	ID          uuid.UUID
	TenantID    TenantID
	PatientID   uuid.UUID
	PhysicianID uuid.UUID
	Active      bool
	CreatedAt   time.Time
}

type Conversation struct {
	ID        uuid.UUID
	TenantID  TenantID
	PatientID uuid.UUID
	Title     string
	CreatedAt time.Time
	UpdatedAt time.Time
}

type Message struct {
	ID             uuid.UUID
	TenantID       TenantID
	ConversationID uuid.UUID
	Role           string
	Content        string
	CreatedAt      time.Time
}

type Recommendation struct {
	ID             uuid.UUID
	TenantID       TenantID
	ConversationID uuid.UUID
	PatientID      uuid.UUID
	State          string
	PayloadType    string
	Payload        []byte
	DraftContent   string
	FinalContent   *string
	ReviewedBy     *uuid.UUID
	ReviewedAt     *time.Time
	CreatedAt      time.Time
}

type AuditEvent struct {
	ID        uuid.UUID
	TenantID  TenantID
	ActorType string
	ActorID   *uuid.UUID
	EventType string
	Metadata  []byte
	CreatedAt time.Time
}
