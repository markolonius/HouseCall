# Development Workflow — Spec-Driven, Agent-Orchestrated

HouseCall is built with an **OpenSpec → beads → worktree → coder/tester/reviewer → PR**
loop, driven from a single interactive Claude Code session on the dev machine
(a Mac mini). You approve specs and merge PRs; an orchestrator agent does the
rest.

## Why this shape

- **OpenSpec answers _what_ to build.** Every feature is an approved change
  proposal under `openspec/changes/<id>/` with `proposal.md`, `design.md`, and
  a phased `tasks.md`. Nothing gets implemented without an approved proposal.
- **beads answers _where we are_.** Tasks become beads issues in a dependency
  graph so the orchestrator always knows the next unblocked unit of work and
  never loses that state between sessions.
- **GitHub is the collaboration surface.** Beads issues are mirrored to GitHub
  Issues; each phase lands as one pull request you review and merge.

## Hard constraint: no headless mode

This workflow never shells out to `claude -p` / SDK headless runs. The
orchestrator is the **main interactive session** (the `/run-phase` command),
and it dispatches the coder/tester/reviewer as **native Claude Code
subagents** via the Task tool. That works on every plan and on both the CLI
and web — nothing depends on headless automation.

## Reproducible environment

The goal is "no dependency surprises" without the overhead of Nix or
devcontainers — which don't help anyway, because **Xcode cannot be
containerized or Nix-ified** (it needs Apple's signed toolchain native on
macOS). So the iOS half is always native; we pin everything else instead:

| Concern | How it's pinned | File |
|---|---|---|
| Go version | `mise` + the `go.mod` `toolchain` directive | [`.tool-versions`](../.tool-versions) |
| Postgres | Docker (`postgres:16-alpine`), matches RDS 16 | [`backend/docker-compose.yml`](../backend/docker-compose.yml) |
| Xcode | `.xcode-version`, selected via `xcodes` | [`.xcode-version`](../.xcode-version) |
| brew tools | declarative Brewfile (`brew bundle check` detects drift) | [`Brewfile`](../Brewfile) |
| Everything | `scripts/doctor.sh` preflight | [`scripts/doctor.sh`](../scripts/doctor.sh) |

What we deliberately **don't** use: Nix/devbox/flakes and VS Code
devcontainers — they reproduce the Go side but not Xcode, so they double the
mental model for no real gain on a solo, mixed Go+iOS project.

The tradeoff of hard pinning: when production moves (a new Go or Xcode major),
you update the pin deliberately (`.tool-versions` / `.xcode-version`) rather
than letting brew drag you along silently. That ~30 min of occasional
housekeeping is the price of not debugging "works on my machine."

**Keeping Xcode pinned:** disable automatic Xcode updates (App Store →
Settings) and install versions with `xcodes install <v> && xcodes select <v>`.
When you intentionally move, update `.xcode-version` to match
`xcodebuild -version` (you can do `xcodebuild -version | awk 'NR==1{print $2}'
> .xcode-version`). `doctor.sh` warns (does not fail) on a mismatch.

## One-time setup

```bash
scripts/dev-bootstrap.sh     # brew bundle, mise(Go), Docker Postgres, migrate, bd init, doctor
gh auth login                # authenticate the GitHub CLI
scripts/doctor.sh            # green/red preflight — run before each session
```

## Running a phase

From an interactive session at the repo root:

```
/run-phase <change-id> <phase-number>
# e.g.
/run-phase add-cloud-platform-mvp 3
```

That single command:

1. Seeds beads from `tasks.md` (`scripts/openspec-to-beads.sh`) — idempotent.
2. Mirrors beads → GitHub Issues (`scripts/beads-sync-github.sh`).
3. Creates a worktree + branch `claude/<change-id>-phase-<N>`.
4. For each ready task in the phase, runs the pipeline:
   - **coder** subagent implements the one task and commits.
   - **tester** subagent runs `go test` / `xcodebuild test`; failures loop back
     to the coder (max 3 rounds).
   - **reviewer** subagent reviews the diff for correctness + HIPAA/security;
     blocking findings loop back to the coder.
   - On pass+approve: close the bead, close the mirrored issue, tick the task.
5. Pushes the branch and opens **one PR for the phase**. You review and merge.

The orchestrator runs autonomously and only stops for genuine forks — an
ambiguous spec, an architectural decision, or a task that fails after 3
repair rounds.

## The pieces

| Path | Role |
|---|---|
| `.claude/commands/run-phase.md` | The orchestrator playbook (the one command you run) |
| `.claude/agents/coder.md` | Implements one bead, commits; never pushes |
| `.claude/agents/tester.md` | Runs the test suites; returns PASS/FAIL |
| `.claude/agents/reviewer.md` | Correctness + HIPAA/security review of the diff |
| `scripts/dev-bootstrap.sh` | One-time Mac mini environment setup |
| `scripts/openspec-to-beads.sh` | `tasks.md` → beads graph (idempotent) |
| `scripts/beads-sync-github.sh` | beads ↔ GitHub Issues mirror |
| `.beads/github-map.tsv` | Committed bead-id → issue-number mapping |

## Conventions & guardrails

- **Don't bypass the pipeline.** To implement a phase, use `/run-phase`; don't
  invoke the coder/tester/reviewer subagents by hand. The orchestrator owns
  git, beads, the GitHub mirror, and the ship decision.
- **One PR per phase.** Branch is `claude/<change-id>-phase-<N>`; the
  orchestrator never pushes to `main` and never force-pushes.
- **HIPAA is enforced at review time.** PHI must never reach logs, audit
  metadata, or error strings; every store query is tenant-scoped. The reviewer
  treats any violation as blocking.
- **beads is the source of truth** for task state; the GitHub mirror is
  one-way (beads → GitHub).

## First-run caveat

The helper scripts target the documented `bd` interface but were authored
without a live `bd` to test against. On first run, confirm the flags against
your installed version (`bd --help`, `bd create --help`, `bd ready --help`)
and adjust the three scripts if a flag name differs — they're deliberately
small and readable for exactly this reason.
