#!/usr/bin/env bash
#
# beads-sync-github.sh — mirror beads issues to GitHub Issues (one-way: beads
# is the source of truth). Open beads with no GitHub issue get one created;
# closed beads have their mirrored issue closed.
#
# The bead-id <-> issue-number mapping is kept in .beads/github-map.tsv, which
# is committed to git so the mapping survives across machines and sessions.
#
# Usage:  scripts/beads-sync-github.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v bd >/dev/null 2>&1 || { echo "bd (beads) not found; run scripts/dev-bootstrap.sh" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh not found; run scripts/dev-bootstrap.sh" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found; run scripts/dev-bootstrap.sh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated; run 'gh auth login'" >&2; exit 1; }

MAP=".beads/github-map.tsv"
mkdir -p "$(dirname "$MAP")"
touch "$MAP"

issue_for_bead() { awk -F'\t' -v b="$1" '$1==b {print $2; exit}' "$MAP"; }

# Iterate every bead as compact JSON objects.
bd list --json | jq -c '.[]' | while read -r bead; do
  id="$(jq -r '.id'     <<<"$bead")"
  title="$(jq -r '.title' <<<"$bead")"
  status="$(jq -r '.status // "open"' <<<"$bead")"
  num="$(issue_for_bead "$id")"

  if [[ -z "$num" ]]; then
    # No mirror yet — create a GitHub issue for any non-closed bead.
    if [[ "$status" != "closed" && "$status" != "done" ]]; then
      num="$(gh issue create \
                --title "$title" \
                --body  "Tracked by beads issue \`$id\`. Managed by the OpenSpec/beads orchestrator; do not edit task scope here." \
                --json number -q '.number')"
      printf '%s\t%s\n' "$id" "$num" >> "$MAP"
      echo "created issue #$num  <- $id"
    fi
    continue
  fi

  # Already mirrored — reconcile state.
  if [[ "$status" == "closed" || "$status" == "done" ]]; then
    state="$(gh issue view "$num" --json state -q '.state' 2>/dev/null || echo UNKNOWN)"
    if [[ "$state" == "OPEN" ]]; then
      gh issue close "$num" -c "Closed automatically: beads issue \`$id\` is $status." >/dev/null
      echo "closed  issue #$num  <- $id"
    fi
  fi
done

echo "sync complete (map: $MAP)"
