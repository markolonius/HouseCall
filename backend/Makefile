.PHONY: build run test migrate seed db-up db-down tidy

DATABASE_URL ?= postgres://housecall:housecall@localhost:5432/housecall?sslmode=disable
TEST_DATABASE_URL ?= postgres://housecall:housecall@localhost:5432/housecall_test?sslmode=disable

build:
	go build ./...

run: build
	DATABASE_URL=$(DATABASE_URL) go run ./cmd/server -cmd serve

migrate:
	DATABASE_URL=$(DATABASE_URL) go run ./cmd/server -cmd migrate

# Seeds one tenant + one physician + one patient + one active care
# relationship. Implemented in Phase 7 (Task 7.1) — placeholder for now.
seed:
	@echo "seed: not yet implemented (Phase 7 Task 7.1)"
	@exit 1

test:
	TEST_DATABASE_URL=$(TEST_DATABASE_URL) go test ./...

tidy:
	go mod tidy
