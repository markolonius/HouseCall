---
name: Run Phase
description: Autonomously implement one phase of an approved OpenSpec change via a coder/tester/reviewer subagent pipeline, landing one PR for the phase.
category: Orchestration
tags: [openspec, beads, orchestrator, worktree]
---

You are the **orchestrator**. The user has invoked `/run-phase $ARGUMENTS`.

Parse the arguments as: `<change-id> <phase-number>`
- `$1` = change-id (e.g. `add-cloud-platform-mvp`)
- `$2` = phase number (e.g. `3`)

If either is missing, ask the user for it and stop.

Your job: drive every task in that phase to a merged-quality state through a coder → tester → reviewer loop, then open ONE pull request for the whole phase. Run autonomously — do not stop to ask the user between tasks unless you hit a genuine decision the user must make (ambiguous spec, architectural fork, or repeated unrecoverable failure).

## Authorization (granted by the user invoking this command)
- You MAY: create a worktree + branch, commit, `git push` the phase branch, run the helper scripts, create/close GitHub issues via the mirror, and open ONE PR for the phase.
- You MUST NOT: force-push, commit or push to `main`/default branches, delete branches other than your own worktree, or rewrite published history.

## Preconditions
1. Confirm the change is approved and the phase exists: read `openspec/changes/$1/tasks.md` and locate `## Phase $2`. If the proposal is not approved or the phase doesn't exist, stop and tell the user.
2. Confirm tooling is present: `command -v bd`, `command -v gh`, `command -v jq`, and `gh auth status`. If anything is missing, tell the user to run `scripts/dev-bootstrap.sh` and stop.
3. Confirm Postgres is up (tests need it). Run `scripts/doctor.sh`; if it reports Postgres unreachable, start it with `cd backend && make db-up` and re-check. If Docker itself isn't running, tell the user to start Docker Desktop and stop.
4. Working tree must be clean. If not, stop and report.

## Setup
5. Seed/refresh the beads graph (idempotent):
   `scripts/openspec-to-beads.sh $1`
6. Mirror beads → GitHub Issues:
   `scripts/beads-sync-github.sh`
7. Create the phase worktree + branch (guard if it already exists), then `cd` into it for the rest of the run:
   ```
   WT="$HOME/housecall-worktrees/$1-phase$2"
   BR="claude/$1-phase-$2"
   git worktree add "$WT" -b "$BR" 2>/dev/null || git worktree add "$WT" "$BR" 2>/dev/null || true
   cd "$WT"
   ```
   All subsequent work — and the path you pass to subagents — is `$WT`.

## The loop
Repeat until no phase-$2 beads remain ready:
8. Get the next ready task scoped to this phase. A bead belongs to phase $2 if its title starts with `[$1#$2.`:
   ```
   bd ready --json | jq -r --arg p "[$1#$2." '.[] | select(.title|startswith($p)) | .id' | head -n1
   ```
   If empty, the phase is done — go to "Finish".
9. Claim it: `bd update <id> --claim`. Note its title/number.
10. **Dispatch the coder** (Task tool, subagent_type `coder`) with: the bead id, change-id `$1`, the task number + title, and the worktree path `$WT`. Wait for it to commit and summarize.
11. **Dispatch the tester** (subagent_type `tester`) with the worktree path. 
    - If `VERDICT: FAIL`, send the failing output back to the coder (same bead) to fix. Re-test. Cap at **3** coder↔tester rounds; if still failing, stop the loop and report to the user with the failure.
    - If `VERDICT: BLOCKED` (e.g. DB down, no Xcode for an iOS-only task), report to the user and stop.
12. **Dispatch the reviewer** (subagent_type `reviewer`) with the worktree path.
    - If `REQUEST_CHANGES` with blocking findings, send them to the coder, then re-test and re-review. Same 3-round cap.
    - Any HIPAA/security/tenant-isolation finding is blocking — never override it autonomously.
13. When tester PASS and reviewer APPROVE: close the bead `bd close <id> "<one-line summary>"`, then re-run `scripts/beads-sync-github.sh` from the repo root to close the mirrored issue. Mark the task `- [x]` in `openspec/changes/$1/tasks.md` (commit that edit too). Loop.

## Finish
14. Push the branch: `git push -u origin "$BR"` (retry up to 4× with backoff on network errors only).
15. Open ONE PR for the phase with `gh pr create`:
    - Title: `<change-id>: Phase <N> — <phase title>`
    - Body: the phase's task checklist (now ticked), the beads ids closed, and the standard footer.
    - Do not merge it — the user reviews and merges.
16. Report to the user: PR URL, tasks completed, any non-blocking reviewer notes deferred, and anything that needs their attention.

## Notes
- Subagents do the implementation/testing/review; YOU own git, beads, the GitHub mirror, the worktree, and the ship decision.
- Keep the user informed at phase boundaries and on any stop condition — but don't narrate every individual task round.
- If a task is genuinely ambiguous or needs an architectural call, pause and ask the user rather than guessing.
