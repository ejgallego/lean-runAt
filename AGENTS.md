# AGENTS.md

## Purpose

This repository hosts the alpha `runAt` Lean plugin and its local broker tooling.

Treat the repo as public but still experimental: prefer conservative, well-tested changes over
feature sprawl.

Current public status and limitations live in [docs/STATUS.md](docs/STATUS.md).

## Product Priorities

In order:

1. dead-simple public API
2. rock-solid stability
3. type-safe boundaries
4. isolation of each request
5. performance

Performance matters, but not at the cost of correctness or stability.

## Public API Guardrails

The core public request should remain conceptually:

- `runAt(pos, "lean text")`

Rules:

- no required public mode flag for command vs tactic execution
- backend selection is internal
- keep request and response structures small and typed
- use transport errors for invalid params, stale state, cancellation, and internal faults
- avoid exposing internal execution details unless a concrete client need forces it

Follow-up handle APIs exist, but they are alpha extensions around the basic request, not the main
story of the project.

## Execution Model

Each request should behave like an isolated sandbox:

- never mutate the document's real elaboration state
- never depend on side effects from a previous request
- never leak internal mutable state through the base API
- discard derived execution state unless the request explicitly stores a follow-up handle

## Testing Priorities

Tests matter more than cleverness.

Focus on:

- position selection and boundary behavior
- whitespace and comment positions
- proof-vs-command basis selection
- stale snapshot and file-changed behavior
- nested tactic cases
- no state leakage across requests
- cancellation behavior
- handle invalidation when handle behavior is touched

If a behavior is subtle, encode it in tests before optimizing it.

## Skill Boundaries

Keep the Lean and Rocq skills fully separate.

- `lean-beam` must stay Lean-only and must not require Rocq setup or Rocq concepts
- `rocq-beam` must stay Rocq-only and must not require Lean-specific workflow guidance
- do not introduce a shared skill helper, common skill file, or mixed Lean/Rocq skill layer
- if a short instruction is needed in both skills, duplicate it instead of coupling the two skills

## Local Tooling

The repo includes:

- `lake exe beam-daemon`
- `lake exe beam-client`
- `lake exe beam-daemon-smoke-test`
- `lake exe beam-daemon-rocq-smoke-test`
- [scripts/lean-beam](scripts/lean-beam)
- [scripts/codex-harness.sh](scripts/codex-harness.sh)
- [scripts/codex-session-start.sh](scripts/codex-session-start.sh)
- [scripts/validate-defensive.sh](scripts/validate-defensive.sh)

The Codex harness scripts are maintainer workflow helpers for this repository. They are not part of
the public `lean-beam` API or the installed skill surface.

When working locally:

- start new Codex tasks from `./scripts/codex-harness.sh session start <task-id>` so the task runs
  in a dedicated git worktree instead of the primary checkout
- keep destructive shell cleanup scoped to owned temp/worktree paths; do not use broad `rm` or
  `rm -rf` against repo-local `.beam`, install caches, or user homes as part of normal workflows
- for broker protocol / stream / barrier changes, run `bash tests/test-broker-fast.sh` first
- for wrapper / install / bundle-resolution changes, also run `bash tests/test-broker-slow.sh`
- for risky local install / wrapper validation, prefer `bash scripts/validate-defensive.sh` so slow
  suites run in a cloned `/tmp` sandbox with fake homes and guarded path operations
- use `bash tests/test-broker.sh` when you want the aggregate broker suite
- prefer the broker client or wrapper over raw LSP when the task fits
- use Lean `deps` before planning multi-file edits
- use Rocq only through `coq-lsp`
- if a file is open in the broker, do not edit it out of band
- if Lean reports stale or rebuild trouble unexpectedly, stop and surface it loudly

Helpful repo docs:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md)
- [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md)
