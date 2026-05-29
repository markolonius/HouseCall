# Brewfile — declarative Homebrew dependencies for HouseCall dev on macOS.
#
#   brew bundle            # install everything listed here
#   brew bundle check      # report whether anything is missing (drift check)
#   brew bundle cleanup    # (careful) list formulae NOT in this file
#
# Deliberately minimal. Go is managed by mise (see .tool-versions) so it is
# NOT listed here — that keeps the Go version pinned regardless of brew state.
# Postgres runs in Docker (backend/docker-compose.yml), not via brew, so it is
# not listed either. beads is installed by scripts/dev-bootstrap.sh (its brew
# formula/tap is not assumed stable yet).

tap "xcodesorg/made"   # `xcodes` — install/select specific Xcode versions

brew "mise"            # tool-version manager (pins Go via .tool-versions)
brew "gh"              # GitHub CLI (PRs, issue mirror)
brew "jq"              # JSON parsing in the orchestration scripts
brew "xcodes"          # pin/select Xcode (see .xcode-version)

cask "docker"          # Docker Desktop — runs the local Postgres
