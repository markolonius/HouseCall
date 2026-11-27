#!/usr/bin/env bash
# Runs the test suites relevant to what changed. Used by the coder agent before
# committing and by the /run-phase orchestrator as the phase gate.
#
# Usage:
#   scripts/test.sh              # suites for files changed vs main (+ uncommitted)
#   scripts/test.sh --base REF   # suites for files changed vs REF
#   scripts/test.sh --all        # both suites regardless of what changed
#
# Exit codes: 0 = pass, 1 = build/vet/test failure, 2 = blocked by environment.
# Output is kept short on success; on failure the tail of the log is printed.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BASE=""
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --base) BASE="${2:-}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

SIM="${HOUSECALL_SIMULATOR:-iPhone 17,OS=latest}"
LOG_DIR="$(mktemp -d)"

if [ -z "$BASE" ]; then
  BASE="$(git merge-base HEAD main 2>/dev/null || echo HEAD)"
fi
CHANGED="$( { git diff --name-only "$BASE" 2>/dev/null; git ls-files --others --exclude-standard; } | sort -u)"

RUN_GO=$ALL
RUN_IOS=$ALL
if [ "$ALL" -eq 0 ]; then
  echo "$CHANGED" | grep -q '^backend/' && RUN_GO=1
  echo "$CHANGED" | grep -Eq '^(HouseCall|HouseCallTests|HouseCallUITests|HouseCall\.xcodeproj)/' && RUN_IOS=1
fi

STATUS=0
GO_RESULT="skipped (no backend changes)"
IOS_RESULT="skipped (no iOS changes)"

step() { # step <name> <logfile> <cmd...>
  local name="$1" log="$2"; shift 2
  if "$@" >"$log" 2>&1; then return 0; fi
  echo "--- $name FAILED (last 60 lines of $log) ---"
  tail -n 60 "$log"
  return 1
}

if [ "$RUN_GO" -eq 1 ]; then
  if ! (cd backend && docker compose ps --status running postgres 2>/dev/null | grep -q postgres); then
    echo "BLOCKED: Postgres is not running. Start it with: cd backend && make db-up"
    exit 2
  fi
  if step "go build" "$LOG_DIR/go-build.log" bash -c 'cd backend && go build ./...' \
    && step "go vet" "$LOG_DIR/go-vet.log" bash -c 'cd backend && go vet ./...' \
    && step "go test" "$LOG_DIR/go-test.log" bash -c 'cd backend && make test'; then
    GO_RESULT="ok"
  else
    GO_RESULT="FAIL"; STATUS=1
  fi
fi

if [ "$RUN_IOS" -eq 1 ]; then
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "BLOCKED: xcodebuild not available for iOS changes."
    exit 2
  fi
  if xcodebuild test -scheme HouseCall \
      -destination "platform=iOS Simulator,name=$SIM" \
      -only-testing:HouseCallTests \
      -parallel-testing-enabled NO >"$LOG_DIR/ios-test.log" 2>&1; then
    IOS_RESULT="ok"
  else
    IOS_RESULT="FAIL"; STATUS=1
    echo "--- iOS tests FAILED (failures from $LOG_DIR/ios-test.log) ---"
    grep -E "error:|✘|failed|\*\* TEST FAILED" "$LOG_DIR/ios-test.log" | head -n 60
  fi
fi

echo "GO:  $GO_RESULT"
echo "IOS: $IOS_RESULT"
if [ "$STATUS" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL (logs in $LOG_DIR)"; fi
exit "$STATUS"
