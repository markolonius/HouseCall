---
name: Run Phase
description: Autonomously implement one phase of an approved OpenSpec change (coder per task, test script and one reviewer pass per phase), landing one PR for the phase.
category: Orchestration
tags: [openspec, beads, orchestrator, worktree]
---

You are the **orchestrator**. The user has invoked `/run-phase $ARGUMENTS`.

Parse the arguments as: `<change-id> <phase-number>`
- `$1` = change-id (e.g. `add-cloud-platform-mvp`)
- `$2` = phase number (e.g. `3`)

If either is missing, ask the user for it and stop.

Your job: implement every task in that phase with the coder subagent, gate the phase on `scripts/test.sh` and one reviewer pass over the whole phase diff, then open ONE pull request. Run autonomously — do not stop to ask the user between tasks unless you hit a genuine decision the user must make (ambiguous spec, architectural fork, or repeated unrecoverable failure).

## Authorization (granted by the user invoking this command)
- You MAY: create a worktree + branch, commit, `git push` the phase branch, run the helper scripts, and open ONE PR for the phase.
- You MUST NOT: force-push, commit or push to `main`/default branches, delete branches other than your own worktree, or rewrite published history.

## Preconditions
1. Confirm the change is approved and the phase exists: read `openspec/changes/$1/tasks.md` and locate `## Phase $2`. If the proposal is not approved or the phase doesn't exist, stop and tell the user.
2. Confirm tooling is present: `command -v bd`, `command -v gh`, `command -v jq`, and `gh auth status`. If anything is missing, tell the user to run `scripts/dev-bootstrap.sh` and stop.
3. Confirm Postgres is up (tests need it). Run `scripts/doctor.sh`; if it reports Postgres unreachable, start it with `cd backend && make db-up` and re-check. If Docker itself isn't running, tell the user to start Docker Desktop and stop.
4. Working tree must be clean. If not, stop and report.
5. The previous phase must be merged. Run `git fetch origin`. If `$2` > 1 and `origin/claude/$1-phase-$(($2-1))` exists but is not an ancestor of `origin/main` (`git merge-base --is-ancestor`), stop and tell the user to merge that PR first. Phases are not stacked: every phase branches from `main` and its PR targets `main`, so CI runs on each one.

## Setup
6. Seed/refresh the beads graph (idempotent):
   `scripts/openspec-to-beads.sh $1`
7. Create the phase worktree + branch from up-to-date `main` (guard if it already exists), then `cd` into it for the rest of the run:
   ```
   WT="$HOME/housecall-worktrees/$1-phase$2"
   BR="claude/$1-phase-$2"
   git worktree add "$WT" -b "$BR" origin/main 2>/dev/null || git worktree add "$WT" "$BR" 2>/dev/null || true
   cd "$WT"
   BASE="$(git merge-base HEAD origin/main)"
   ```
   All subsequent work — and the path you pass to subagents — is `$WT`.

## The task loop
Repeat until no phase-$2 beads remain ready:
8. Get the next ready task scoped to this phase. A bead belongs to phase $2 if its title starts with `[$1#$2.`:
   ```
   bd ready --json | jq -r --arg p "[$1#$2." '.[] | select(.title|startswith($p)) | .id' | head -n1
   ```
   If empty, go to "Phase gate".
9. Claim it: `bd update <id> --claim`. Note its title/number.
10. **Dispatch the coder** (subagent_type `coder`) with: the bead id, change-id `$1`, the task number + title, and the worktree path `$WT`. The coder implements the task, runs `scripts/test.sh` itself, and commits. Wait for its summary.
    - If the coder reports it could not get `scripts/test.sh` to pass, send it back once with the failure. If it still fails, stop the loop and report to the user.
    - If it reports `BLOCKED` (DB down, no Xcode for an iOS task), report to the user and stop.
11. Mark the task `- [x]` in `openspec/changes/$1/tasks.md` and commit that edit. Leave the bead open until the phase gate passes. Loop.

There is no per-task tester or reviewer. Do not dispatch one.

## Phase gate
12. Run the suites yourself, no subagent: `scripts/test.sh --base "$BASE"`. Exit 0 = pass, 1 = failure, 2 = blocked by environment. On failure, send the printed output to the coder to fix, then re-run. Cap at **3** rounds; if still failing, stop and report to the user.
13. **Dispatch the reviewer ONCE** (subagent_type `reviewer`) with the worktree path, change-id `$1`, phase `$2`, and base ref `$BASE`. It reviews the whole phase diff.
    - If `REQUEST_CHANGES` with blocking findings, send them to the coder in one batch, re-run step 12, then re-review. Same 3-round cap.
    - Any HIPAA/security/tenant-isolation finding is blocking — never override it autonomously.
14. When `scripts/test.sh` passes and the reviewer returns `APPROVE`: close every bead for the phase, `bd close <id1> <id2> ... --reason="<phase summary>"`.

## Finish
15. Push the branch: `git push -u origin "$BR"` (retry up to 4× with backoff on network errors only).
16. Open ONE PR for the phase with `gh pr create --base main`:
    - Title: `<change-id>: Phase <N> — <phase title>`
    - Body: the phase's task checklist (now ticked), the beads ids closed, non-blocking reviewer notes, and the standard footer.
    - Do not merge it — the user reviews and merges.
17. Report to the user: PR URL, tasks completed, any non-blocking reviewer notes deferred, and that the next phase can start once this PR is merged.

## Notes
- The coder implements and tests; the reviewer reviews once per phase; YOU own git, beads, the worktree, the phase gate, and the ship decision.
- Beads is the only task tracker. Do not run `scripts/beads-sync-github.sh`; the GitHub Issues mirror is retired and the PR body carries the task list.
- Small standalone fixes do not need this command: a plain branch and PR is fine.
- Keep the user informed at phase boundaries and on any stop condition — but don't narrate every individual task round.
- If a task is genuinely ambiguous or needs an architectural call, pause and ask the user rather than guessing.
