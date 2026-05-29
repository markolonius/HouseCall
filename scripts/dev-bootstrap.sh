#!/usr/bin/env bash
#
# dev-bootstrap.sh — one-time HouseCall dev environment setup for a Mac mini.
#
# Idempotent: safe to re-run. Installs prerequisites via Homebrew, provisions
# the local Postgres role + databases, applies migrations, and initializes the
# beads issue graph + Claude Code integration.
#
# Usage:  scripts/dev-bootstrap.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || warn "This script targets macOS; continuing anyway."

command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh then re-run."

brew_install() {
  local pkg="$1"
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    log "$pkg already installed"
  else
    log "installing $pkg"
    brew install "$pkg"
  fi
}

log "Checking Homebrew packages"
brew_install go
brew_install postgresql@16
brew_install gh
brew_install jq
brew_install beads   # Steve Yegge's bd issue tracker

# Make sure this shell can see the keg-only postgres binaries.
export PATH="$(brew --prefix postgresql@16)/bin:$PATH"

# --- postgres ----------------------------------------------------------------

log "Starting Postgres service"
brew services start postgresql@16 >/dev/null 2>&1 || warn "could not start postgresql@16 service"

# Wait for the server to accept connections.
for _ in $(seq 1 30); do
  if pg_isready -q -h localhost -p 5432 2>/dev/null; then break; fi
  sleep 1
done
pg_isready -q -h localhost -p 5432 2>/dev/null || die "Postgres is not accepting connections on localhost:5432"

log "Ensuring 'housecall' role and databases exist"
psql -v ON_ERROR_STOP=1 -d postgres >/dev/null <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'housecall') THEN
    CREATE ROLE housecall LOGIN PASSWORD 'housecall';
  END IF;
END
$$;
SQL

ensure_db() {
  local db="$1"
  if psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" postgres | grep -q 1; then
    log "database $db already exists"
  else
    log "creating database $db"
    createdb -O housecall "$db"
  fi
}
ensure_db housecall
ensure_db housecall_test

# --- migrations --------------------------------------------------------------

log "Applying migrations"
( cd backend && make migrate )

# --- beads -------------------------------------------------------------------

if [[ ! -d .beads ]]; then
  log "Initializing beads"
  bd init
else
  log "beads already initialized (.beads present)"
fi

log "Wiring beads <-> Claude Code"
bd setup claude >/dev/null 2>&1 || warn "bd setup claude failed (non-fatal); run it manually if needed"

# --- gh ----------------------------------------------------------------------

if gh auth status >/dev/null 2>&1; then
  log "GitHub CLI authenticated"
else
  warn "GitHub CLI not authenticated. Run 'gh auth login' before using the beads<->GitHub mirror."
fi

cat <<'NEXT'

Bootstrap complete.

Next steps:
  1. (if prompted) run:  gh auth login
  2. Sanity-check the backend:
       cd backend && make test          # needs Postgres up (it is)
  3. Drive a phase autonomously from an interactive Claude Code session:
       /run-phase add-cloud-platform-mvp 3

NEXT
