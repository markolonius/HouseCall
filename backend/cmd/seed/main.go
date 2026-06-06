// cmd/seed inserts the minimum synthetic dataset required for local
// development and end-to-end tests:
//
//   - 1 tenant  (id: 00000000-0000-0000-0000-000000000001)
//   - 1 physician (id: 00000000-0000-0000-0000-000000000010)
//   - 1 patient   (id: 00000000-0000-0000-0000-000000000020)
//   - 1 active care relationship linking them
//
// All IDs and emails are deterministic so the e2e test script can hard-code
// them.  Run `make seed` after `docker compose up` (or `make compose-up`).
//
// Idempotent: rows are inserted with ON CONFLICT DO NOTHING, so re-running
// is safe and produces no duplicate rows.
//
// Credentials (synthetic, non-PHI, dev-only):
//
//	Physician  email: physician@dev.housecall.local  password: PhysicianDev1!
//	Patient    email: patient@dev.housecall.local    password: PatientDev1!
//
// HIPAA note: all data is purely synthetic.  No real patient, physician, or
// tenant information is committed.  Passwords are bcrypt-hashed (cost 12)
// before insertion — the plaintext is never written to the database.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

// Deterministic seed IDs — stable across re-runs and referenced by the e2e
// test script.
var (
	tenantID    = mustParseUUID("00000000-0000-0000-0000-000000000001")
	physicianID = mustParseUUID("00000000-0000-0000-0000-000000000010")
	patientID   = mustParseUUID("00000000-0000-0000-0000-000000000020")
)

const (
	physicianEmail    = "physician@dev.housecall.local"
	physicianPassword = "PhysicianDev1!"
	physicianName     = "Dr. Dev Physician"

	patientEmail    = "patient@dev.housecall.local"
	patientPassword = "PatientDev1!"
	patientName     = "Dev Patient"
	patientState    = "CA"

	// The physician must be licensed in patientState so state-licensing checks
	// pass during the e2e review flow.
	physicianState = "CA"

	bcryptCost = 12
)

func main() {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	defer conn.Close(ctx)

	// Hash passwords before any DB interaction (bcrypt is CPU-intensive).
	physicianHash, err := bcrypt.GenerateFromPassword([]byte(physicianPassword), bcryptCost)
	if err != nil {
		log.Fatalf("hash physician password: %v", err)
	}
	patientHash, err := bcrypt.GenerateFromPassword([]byte(patientPassword), bcryptCost)
	if err != nil {
		log.Fatalf("hash patient password: %v", err)
	}

	// All four inserts run as a single transaction so the DB is never left in
	// a partial state.
	tx, err := conn.Begin(ctx)
	if err != nil {
		log.Fatalf("begin tx: %v", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback(ctx)
		}
	}()

	// 1. Tenant
	_, err = tx.Exec(ctx,
		`INSERT INTO tenants (id, kind, name)
		 VALUES ($1, 'dtc', 'HouseCall Dev Tenant')
		 ON CONFLICT (id) DO NOTHING`,
		tenantID,
	)
	if err != nil {
		log.Fatalf("insert tenant: %v", err)
	}

	// 2. Physician
	_, err = tx.Exec(ctx,
		`INSERT INTO physicians (id, tenant_id, email, full_name, states_licensed, password_hash)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 ON CONFLICT (id) DO NOTHING`,
		physicianID, tenantID,
		physicianEmail, physicianName,
		[]string{physicianState},
		string(physicianHash),
	)
	if err != nil {
		log.Fatalf("insert physician: %v", err)
	}

	// 3. Patient
	_, err = tx.Exec(ctx,
		`INSERT INTO patients (id, tenant_id, email, full_name, state, password_hash)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 ON CONFLICT (id) DO NOTHING`,
		patientID, tenantID,
		patientEmail, patientName,
		patientState,
		string(patientHash),
	)
	if err != nil {
		log.Fatalf("insert patient: %v", err)
	}

	// 4. Care relationship — ON CONFLICT on the unique (tenant_id, patient_id, physician_id) key.
	_, err = tx.Exec(ctx,
		`INSERT INTO care_relationships (tenant_id, patient_id, physician_id, active)
		 VALUES ($1, $2, $3, true)
		 ON CONFLICT (tenant_id, patient_id, physician_id) DO NOTHING`,
		tenantID, patientID, physicianID,
	)
	if err != nil {
		log.Fatalf("insert care_relationship: %v", err)
	}

	if err = tx.Commit(ctx); err != nil {
		log.Fatalf("commit: %v", err)
	}

	// Print the seeded credentials so the operator / e2e script can copy them.
	fmt.Println()
	fmt.Println("=== seed complete ===")
	fmt.Printf("tenant     id:       %s\n", tenantID)
	fmt.Println()
	fmt.Printf("physician  id:       %s\n", physicianID)
	fmt.Printf("           email:    %s\n", physicianEmail)
	fmt.Printf("           password: %s\n", physicianPassword)
	fmt.Printf("           licensed: %s\n", physicianState)
	fmt.Println()
	fmt.Printf("patient    id:       %s\n", patientID)
	fmt.Printf("           email:    %s\n", patientEmail)
	fmt.Printf("           password: %s\n", patientPassword)
	fmt.Printf("           state:    %s\n", patientState)
	fmt.Println()
	fmt.Println("care relationship: active (physician ↔ patient, same tenant)")
	fmt.Println()

	// Verify row counts so the caller can confirm what was inserted.
	printCount(ctx, conn, "tenants", tenantID)
	printCount(ctx, conn, "physicians", physicianID)
	printCount(ctx, conn, "patients", patientID)
	printCRCount(ctx, conn)
}

func printCount(ctx context.Context, conn *pgx.Conn, table string, id uuid.UUID) {
	var n int
	_ = conn.QueryRow(ctx,
		fmt.Sprintf(`SELECT COUNT(*) FROM %s WHERE id = $1`, table), id,
	).Scan(&n)
	fmt.Printf("  %s (id=%s): %d row(s) in DB\n", table, id, n)
}

func printCRCount(ctx context.Context, conn *pgx.Conn) {
	var n int
	_ = conn.QueryRow(ctx,
		`SELECT COUNT(*) FROM care_relationships
		  WHERE patient_id = $1 AND physician_id = $2 AND active = true`,
		patientID, physicianID,
	).Scan(&n)
	fmt.Printf("  care_relationships (patient↔physician, active): %d row(s) in DB\n", n)
}

func mustParseUUID(s string) uuid.UUID {
	u, err := uuid.Parse(s)
	if err != nil {
		panic(fmt.Sprintf("invalid seed UUID %q: %v", s, err))
	}
	return u
}
