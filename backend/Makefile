.PHONY: build run test migrate seed db-up db-down compose-up tidy

DATABASE_URL ?= postgres://housecall:housecall@localhost:5432/housecall?sslmode=disable
TEST_DATABASE_URL ?= postgres://housecall:housecall@localhost:5432/housecall_test?sslmode=disable
# Dev-only default. Override with a strong secret for any shared environment.
JWT_SECRET ?= dev-secret-change-me-in-production

build:
	go build ./...

run: build
	DATABASE_URL=$(DATABASE_URL) JWT_SECRET=$(JWT_SECRET) go run ./cmd/server -cmd serve

migrate:
	DATABASE_URL=$(DATABASE_URL) go run ./cmd/server -cmd migrate

# Start the local Dockerized Postgres and wait until it is healthy.
db-up:
	docker compose up -d --wait postgres

# Stop all compose services. Data persists in the named volume (housecall-pgdata).
db-down:
	docker compose down

# Seeds one tenant + one physician + one patient + one active care relationship.
# Runs the seeder directly against DATABASE_URL (Postgres must already be up).
# Idempotent — safe to re-run.
seed:
	DATABASE_URL=$(DATABASE_URL) go run ./cmd/seed

# Bring up the full compose stack (postgres + server), wait until the server
# is healthy, then seed the database.  One-command local dev setup.
compose-up:
	docker compose up -d --build --wait
	DATABASE_URL=$(DATABASE_URL) go run ./cmd/seed

test:
	TEST_DATABASE_URL=$(TEST_DATABASE_URL) go test ./...

tidy:
	go mod tidy
