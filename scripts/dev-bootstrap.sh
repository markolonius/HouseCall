#!/usr/bin/env bash
#
# dev-bootstrap.sh — one-time HouseCall dev environment setup for a Mac mini.
#
# Idempotent: safe to re-run. Installs prerequisites from the Brewfile, pins Go
# via mise, starts the Dockerized Postgres, applies migrations, and initializes
# the beads issue graph + Claude Code integration. Finishes by running the
# environment doctor.
#
# Usage:  scripts/dev-bootstrap.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || warn "This script targets macOS; continuing anyway."
command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh then re-run."

# --- Homebrew packages (declared in Brewfile) -------------------------------

log "Installing Brewfile dependencies"
brew bundle --file="$REPO_ROOT/Brewfile"

# --- beads (installed separately; brew formula/tap not assumed stable) ------

if command -v bd >/dev/null 2>&1; then
  log "beads already installed"
else
  log "Installing beads"
  brew install beads 2>/dev/null \
    || curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash \
    || die "Could not install beads. See https://github.com/steveyegge/beads"
fi

# --- Go via mise ------------------------------------------------------------

# Activate mise for interactive shells (idempotent).
RC="$HOME/.zshrc"
ACT='eval "$(mise activate zsh)"'
if [[ -f "$RC" ]] && grep -qF "$ACT" "$RC"; then
  log "mise already activated in ~/.zshrc"
else
  log "Adding mise activation to ~/.zshrc"
  printf '\n# mise (tool-version manager)\n%s\n' "$ACT" >> "$RC"
fi

log "Installing pinned toolchains (.tool-versions)"
mise install
# Make mise shims available to the rest of THIS script.
export PATH="$HOME/.local/share/mise/shims:$PATH"
command -v go >/dev/null 2>&1 || die "go still not on PATH after mise install"
log "Using $(go version)"

# --- Xcode (informational) --------------------------------------------------

if command -v xcodebuild >/dev/null 2>&1; then
  have_xc="$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')"
  want_xc="$(cat .xcode-version 2>/dev/null || true)"
  if [[ -n "$want_xc" && "$have_xc" != "$want_xc" ]]; then
    warn "Xcode $have_xc installed but .xcode-version pins $want_xc."
    warn "  Align them: 'xcodes install $want_xc && xcodes select $want_xc', or edit .xcode-version."
  else
    log "Xcode $have_xc matches .xcode-version"
  fi
  warn "Disable automatic Xcode updates (App Store > Settings) so the pin holds."
else
  warn "xcodebuild not found. Install Xcode for iOS work: 'xcodes install $(cat .xcode-version 2>/dev/null)'"
fi

# --- Container runtime (Colima) + Postgres ----------------------------------

# Colima provides the docker socket without Docker Desktop. Start it if it
# isn't already running; this is a no-op if a VM is already up.
if colima status >/dev/null 2>&1; then
  log "Colima already running"
else
  log "Starting Colima"
  colima start
fi

docker info >/dev/null 2>&1 || die "Docker socket unreachable even after 'colima start'. Inspect with 'colima status' and 'colima logs'."

# The Homebrew `docker-compose` formula installs the v2 plugin binary but
# does not symlink it into ~/.docker/cli-plugins/, where the docker CLI
# discovers plugins. Without that, `docker compose ...` is parsed as bare
# `docker` and fails with "unknown shorthand flag: 'd' in -d". Machines that
# previously ran Docker Desktop also tend to have a stale symlink here
# pointing into /Applications/Docker.app — replace it.
PLUGIN_DIR="$HOME/.docker/cli-plugins"
PLUGIN_LINK="$PLUGIN_DIR/docker-compose"
COMPOSE_BIN="$(brew --prefix docker-compose)/bin/docker-compose"
mkdir -p "$PLUGIN_DIR"
if [[ -x "$COMPOSE_BIN" ]]; then
  current_target="$(readlink "$PLUGIN_LINK" 2>/dev/null || true)"
  if [[ "$current_target" != "$COMPOSE_BIN" ]]; then
    log "Wiring docker compose plugin -> $COMPOSE_BIN"
    ln -sfn "$COMPOSE_BIN" "$PLUGIN_LINK"
  else
    log "docker compose plugin already wired"
  fi
else
  warn "docker-compose brew binary not found at $COMPOSE_BIN — 'brew bundle' should have installed it."
fi
docker compose version >/dev/null 2>&1 || die "'docker compose' still not working. Check $PLUGIN_LINK."

# Docker Desktop also leaves "credsStore": "desktop" in ~/.docker/config.json,
# which makes every image pull fail with `docker-credential-desktop: not found`
# once Desktop is uninstalled. Strip it if present; with no auths configured,
# Docker will store any future creds directly in the config file.
DOCKER_CFG="$HOME/.docker/config.json"
if [[ -f "$DOCKER_CFG" ]] && [[ "$(jq -r '.credsStore // ""' "$DOCKER_CFG")" == "desktop" ]]; then
  log "Removing stale 'credsStore: desktop' from $DOCKER_CFG"
  cp "$DOCKER_CFG" "$DOCKER_CFG.bak"
  jq 'del(.credsStore)' "$DOCKER_CFG.bak" > "$DOCKER_CFG"
fi

log "Starting Dockerized Postgres"
( cd backend && make db-up )

# --- Migrations -------------------------------------------------------------

log "Applying migrations"
( cd backend && make migrate )

# --- beads init -------------------------------------------------------------

if [[ -d .beads ]]; then
  log "beads already initialized (.beads present)"
else
  log "Initializing beads"
  bd init
fi
log "Wiring beads <-> Claude Code"
bd setup claude >/dev/null 2>&1 || warn "bd setup claude failed (non-fatal); run it manually if needed"

# --- gh ---------------------------------------------------------------------

gh auth status >/dev/null 2>&1 || warn "GitHub CLI not authenticated. Run 'gh auth login' before the beads<->GitHub mirror."

# --- doctor -----------------------------------------------------------------

echo
log "Running environment doctor"
"$REPO_ROOT/scripts/doctor.sh" || true

cat <<'NEXT'

Bootstrap complete.

If this shell doesn't see `go` yet, open a new terminal (or run:
  eval "$(mise activate zsh)"
) so mise is active, then:

  scripts/doctor.sh                          # re-verify
  /run-phase add-cloud-platform-mvp 3        # drive a phase (interactive session)

NEXT
