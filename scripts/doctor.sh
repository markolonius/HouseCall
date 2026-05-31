#!/usr/bin/env bash
#
# doctor.sh — fast preflight check of the HouseCall dev environment.
# Run it before /run-phase. Green/red checklist; exits non-zero if any
# REQUIRED check fails. Warnings (e.g. Xcode version drift) do not fail.
#
# Usage:  scripts/doctor.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Make mise-managed tools (go) visible to this non-interactive shell.
export PATH="$HOME/.local/share/mise/shims:$PATH"

GREEN='\033[1;32m'; RED='\033[1;31m'; YEL='\033[1;33m'; NC='\033[0m'
fail=0

ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
bad()  { printf "${RED}✗${NC} %s\n" "$*"; fail=1; }
warn() { printf "${YEL}!${NC} %s\n" "$*"; }

# --- Go (via mise / go.mod toolchain) ---------------------------------------
want_go="$(awk '/^golang /{print $2}' .tool-versions 2>/dev/null)"
if command -v go >/dev/null 2>&1; then
  have_go="$(go version | awk '{print $3}' | sed 's/go//')"
  if [[ -n "$want_go" && "$have_go" != "$want_go"* ]]; then
    warn "go $have_go (expected $want_go from .tool-versions — go.mod toolchain will still fetch the pinned compiler)"
  else
    ok "go $have_go"
  fi
else
  bad "go not found (run scripts/dev-bootstrap.sh; ensure mise is activated in your shell)"
fi

# --- Xcode ------------------------------------------------------------------
want_xc="$(cat .xcode-version 2>/dev/null || true)"
if command -v xcodebuild >/dev/null 2>&1; then
  have_xc="$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')"
  if [[ -n "$want_xc" && "$have_xc" != "$want_xc" ]]; then
    warn "Xcode $have_xc (.xcode-version pins $want_xc — update one to match: 'xcodes select $want_xc' or edit .xcode-version)"
  else
    ok "Xcode $have_xc"
  fi
else
  warn "xcodebuild not found (fine if you're only doing backend work)"
fi

# --- Colima + Postgres ------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  bad "docker CLI not found (run scripts/dev-bootstrap.sh)"
elif ! docker info >/dev/null 2>&1; then
  bad "Docker socket unreachable (start the runtime: 'colima start')"
else
  ok "Docker socket reachable (Colima)"
  # Is Postgres reachable on localhost:5432? Pure-bash TCP probe, no client needed.
  if (exec 3<>/dev/tcp/localhost/5432) 2>/dev/null; then
    ok "Postgres reachable on localhost:5432"
    exec 3>&- 2>/dev/null || true
  else
    bad "Postgres not reachable on :5432 (start it: cd backend && make db-up)"
  fi
fi

# --- CLIs the orchestrator needs --------------------------------------------
for tool in gh jq bd; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool present"
  else
    bad "$tool not found (run scripts/dev-bootstrap.sh)"
  fi
done

# --- GitHub auth ------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI authenticated"
  else
    bad "GitHub CLI not authenticated (run 'gh auth login')"
  fi
fi

echo
if [[ "$fail" -eq 0 ]]; then
  printf "${GREEN}Environment looks good.${NC} You can run: /run-phase <change-id> <phase>\n"
else
  printf "${RED}One or more required checks failed.${NC} Fix the ✗ items above.\n"
fi
exit "$fail"
