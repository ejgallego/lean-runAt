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
By default, the harness uses `~/.codex/worktrees/lean-beam` rather than `/tmp` so task
worktrees survive reboots.

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

## Sandboxed Wrapper Path

This wrapper path is easy to break accidentally, so keep the mental model simple.

What was broken:

- Codex-style wrapper calls run in separate PID-isolated sandboxes.
- A later wrapper call could look at the daemon pid in the registry and think the daemon was dead,
  even when the daemon was still alive and answering on its TCP endpoint.
- If one wrapper call started the daemon and then exited while sibling wrapper calls were still
  using it, that exit could tear the daemon down mid-flight.

What the fix does:

- if the registry endpoint still answers, treat the daemon as live even if the recorded pid looks
  wrong in the current sandbox
- if a wrapper call started the daemon, keep that wrapper call alive until overlapping sibling
  wrapper calls for the same project root drain
- the regression for this path is
  [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh)

What this does not promise:

- it does not promise the daemon will still be alive after all sandboxed wrapper calls have exited
- the guarantee is narrower: overlapping wrapper requests on the same root should survive correctly

## Recommended Test Order

- broker protocol / stream / barrier changes: `bash tests/test-broker-fast.sh`
- wrapper / install / bundle-resolution changes: `bash tests/test-broker-slow.sh`
- Rocq broker / wrapper changes: `bash tests/test-broker-rocq.sh`
- risky local install or wrapper validation: `bash scripts/validate-defensive.sh`
- shell changes: `bash scripts/lint-shell.sh`

Use `bash tests/test-broker.sh` when you want the aggregate broker signal.

## Lean 4.28 Compatibility Shims

Current validated support includes Lean `v4.28.0`, which requires two local compatibility shims.
When support for `v4.28.0` is eventually dropped, re-check and likely simplify these spots:

- `RunAt/Protocol.lean`, `RunAt/Internal/SaveSupport.lean`, and `RunAt/Internal/DirectImports.lean`:
  `FileSource` instances route through `Lean.Lsp.fileSource p.textDocument` so the same code works
  across the older `FileIdent` return type in `v4.28.0` and the newer `DocumentUri` API.
- `Beam/Broker/LakeSave.lean`: `hashOfHashable` / `addHashablePureTrace` exist because Lake
  `v4.28.0` lacks the newer generic `ComputeHash [Hashable α]` instance that makes plain
  `addPureTrace mod.name` and `addPureTrace mod.pkg.id?` work upstream in newer Lean versions.

## Process

For commit, PR, and author identity guidance, see [CONTRIBUTING.md](../CONTRIBUTING.md).
