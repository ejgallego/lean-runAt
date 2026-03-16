# Development

This repository is AI-first in practice, but the local workflow should work for both humans and AI
agents.

The public product surface is `lean-beam`. The local development harness is for maintainers and
contributors.

## Current Priorities

Current maintainer priorities are:

- keep README human-facing and release-ready
- keep maintainer and agent workflow guidance out of README
- make the harness work well for both humans and AI agents without turning it into public product
  surface
- prefer small targeted fixes over broad refactors unless a release-facing doc or workflow problem
  demands the larger change

## Entry Points

- human user of the project: [README.md](../README.md)
- human contributor: [CONTRIBUTING.md](../CONTRIBUTING.md)
- maintainer using local harness workflows: this document
- AI agent working inside the repo: [AGENTS.md](../AGENTS.md) plus the relevant installed skill doc

If the question is "how do I use the product?", do not start here.
If the question is "how do I work on the repo safely and efficiently?", start here.

## Local Workflow

Start from the repo root and prefer dedicated worktrees for new tasks:

```bash
./scripts/codex-harness.sh session start <task-id>
```

That keeps new work off the primary checkout and matches the repository's default Codex workflow.

Important local scripts:

- `scripts/codex-harness.sh`: start and manage dedicated task worktrees
- `scripts/codex-session-start.sh`: lower-level helper used by the harness
- `scripts/validate-defensive.sh`: slower guarded validation in a cloned `/tmp` sandbox
- `scripts/lean-beam`: public wrapper surface

Preferred maintainer entrypoints:

- new Codex task: `./scripts/codex-harness.sh session start <task-id>`
- risky wrapper/install validation: `bash scripts/validate-defensive.sh`
- public workflow checks: `lean-beam` and the skill docs
- contributor process questions: [CONTRIBUTING.md](../CONTRIBUTING.md)

## Human And AI Roles

- README is for humans who want to understand and use the project
- skills document the installed workflow surface that agents should follow
- `AGENTS.md` carries repo-specific agent instructions
- this document is for maintainers working locally, whether the operator is a human or an AI
- the Codex harness scripts are maintainer tools, not public product surface

## Change Discipline

- prefer the wrapper or broker client over raw LSP when the task fits
- if a subtle behavior changes, add or update a regression test first
- keep destructive cleanup scoped to owned temp or worktree paths
- if Lean reports stale or rebuild trouble unexpectedly, stop and surface it explicitly

## Recommended Test Order

- broker protocol / stream / barrier changes: `bash tests/test-broker-fast.sh`
- wrapper / install / bundle-resolution changes: `bash tests/test-broker-slow.sh`
- Rocq broker / wrapper changes: `bash tests/test-broker-rocq.sh`
- risky local install or wrapper validation: `bash scripts/validate-defensive.sh`
- shell changes: `bash scripts/lint-shell.sh`

Use `bash tests/test-broker.sh` when you want the aggregate broker signal.

## Process

For commit, PR, and author identity guidance, see [CONTRIBUTING.md](../CONTRIBUTING.md).
