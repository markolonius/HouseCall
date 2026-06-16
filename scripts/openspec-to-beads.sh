#!/usr/bin/env bash
#
# openspec-to-beads.sh — seed the beads issue graph from an OpenSpec change's
# tasks.md. One bead per task, chained with dependency edges so `bd ready`
# surfaces exactly the next unblocked task in document order.
#
# Idempotent: a bead whose title begins with the marker "[<change-id>#<num>]"
# is treated as already-seeded and skipped, so re-running only adds new tasks.
#
# Usage:  scripts/openspec-to-beads.sh <change-id>
#
# Task recognition (handles both formats used in this repo):
#   "### Task 2.1: Auth"          -> num=2.1  title="Auth"      (house style)
#   "- [ ] 1.1 Implement schema"  -> num=1.1  title="Implement schema"
#
# NOTE: bd's exact flag surface should be confirmed against the installed
# version on first run (`bd --help`, `bd create --help`). The commands below
# use the documented interface (bd create / dep add / list --json).
#
set -euo pipefail

CHANGE_ID="${1:-}"
[[ -n "$CHANGE_ID" ]] || { echo "usage: $0 <change-id>" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TASKS="openspec/changes/$CHANGE_ID/tasks.md"
[[ -f "$TASKS" ]] || { echo "no tasks file: $TASKS" >&2; exit 1; }
command -v bd >/dev/null 2>&1 || { echo "bd (beads) not found; run scripts/dev-bootstrap.sh" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found; run scripts/dev-bootstrap.sh" >&2; exit 1; }

marker() { printf '[%s#%s]' "$CHANGE_ID" "$1"; }   # marker "2.1" -> [change#2.1]

# Return the bead id whose title starts with the given marker, or empty.
# Use --all so CLOSED beads are matched too; otherwise re-seeding a change
# whose earlier-phase tasks are already done would recreate them as new
# duplicates and tangle the dependency chain.
bead_id_for() {
  local m="$1"
  bd list --all --json 2>/dev/null \
    | jq -r --arg m "$m" '.[] | select(.title | startswith($m)) | .id' \
    | head -n1
}

# Parse tasks.md into "num<TAB>title" lines, preserving document order.
parse_tasks() {
  # Prefer the "### Task N.M: Title" house style.
  if grep -qE '^### Task [0-9]+\.[0-9]+:' "$TASKS"; then
    sed -nE 's/^### Task ([0-9]+\.[0-9]+):[[:space:]]*(.*)$/\1\t\2/p' "$TASKS"
  else
    # Fallback: canonical OpenSpec "- [ ] N.M Title".
    sed -nE 's/^- \[[ xX]\] ([0-9]+\.[0-9]+)[[:space:]]+(.*)$/\1\t\2/p' "$TASKS"
  fi
}

prev_id=""
created=0
skipped=0

while IFS=$'\t' read -r num title; do
  [[ -n "$num" ]] || continue
  m="$(marker "$num")"
  id="$(bead_id_for "$m")"

  if [[ -z "$id" ]]; then
    full_title="$m $title"
    # Phase number drives priority lightly: earlier phases slightly higher.
    phase="${num%%.*}"
    id="$(bd create "$full_title" -p 1 --json 2>/dev/null | jq -r '.id // empty')"
    [[ -n "$id" ]] || { echo "failed to create bead for $m (check 'bd create' flags)" >&2; exit 1; }
    echo "created  $m -> $id  (phase $phase)"
    created=$((created + 1))
  else
    echo "skipped  $m -> $id  (exists)"
    skipped=$((skipped + 1))
  fi

  # Chain: this task depends on the previous task in document order.
  if [[ -n "$prev_id" && -n "$id" ]]; then
    bd dep add "$id" "$prev_id" >/dev/null 2>&1 || true   # tolerate duplicate edge
  fi
  prev_id="$id"
done < <(parse_tasks)

echo "done: $created created, $skipped existing"
echo "next: scripts/beads-sync-github.sh   # mirror beads -> GitHub issues"
