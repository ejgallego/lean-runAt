---
name: lean-beam
description: Use this when an AI should work on an external Lean project through the installed `lean-beam` wrapper, giving it direct efficient access to Lean's proof engine to avoid rebuilds through cheap speculative checks and zero-build module checkpoints.
---

# Lean Beam

Use this skill for Lean projects when you want the AI to replace repeated `lake build` loops with cheap speculative Lean probes, optional follow-up handle execution, and targeted file checkpoints.

This is the Lean-only skill. It should stay focused on Lean and should not require Rocq setup or Rocq concepts.
Do not factor shared Lean/Rocq skill instructions into a common helper; duplicate short guidance if
both skills need it.

## Setup

From the `lean-beam` repo root:

```bash
./scripts/install-beam.sh --codex
```

Use `--claude` instead when installing for Claude Code, or `--all-skills` when you want both agent
skill sets.

The installer puts `lean-beam` and `lean-beam-search` in `~/.local/bin`, stages the self-contained
runtime under `BEAM_INSTALL_ROOT` (default `~/.local/share/beam`), requires `elan` on `PATH`,
prebuilds the pinned `lean-toolchain` bundle under `BEAM_INSTALL_ROOT/state/install-bundles` by
default, supports `--toolchain <toolchain>` and `--all-supported` for explicit supported bundle
selection, and installs the bundled skills only for the agent flags you request.

Restart Codex or Claude Code after installation.

For the authoritative install and bundle-resolution order, see the `Installation And Resolution`
section in the repo [README](../../README.md).

## Skill Surface

This skill documents the supported Lean-facing `lean-beam` workflow surface. Use the smallest command
family that fits the task.

Supported command families:

- bootstrap the Lean backend: `lean-beam ensure`
- inspect existing code or proof state: `lean-beam hover`, `lean-beam goals-prev`, `lean-beam goals-after`
- inspect file, dependency, or daemon state: `lean-beam deps`, `lean-beam open-files`, `lean-beam doctor`, `lean-beam stats`,
  `lean-beam reset-stats`
- try one isolated speculative Lean snippet: `lean-beam run-at`
- continue from one exact speculative state: `lean-beam run-at-handle`, `lean-beam run-with`,
  `lean-beam run-with-linear`, `lean-beam release`
- refresh or checkpoint one tracked workspace module: `lean-beam sync`, `lean-beam refresh`, `lean-beam save`, `lean-beam close-save`
- run shell-oriented search loops over the same handle APIs: `lean-beam-search`

What to treat as the default public skill surface:

- default and stable enough for normal use: `lean-beam hover`, `lean-beam goals-prev`, `lean-beam goals-after`,
  `lean-beam run-at`, `lean-beam sync`, `lean-beam refresh`
- narrower but supported wrapper surface: `lean-beam deps`, `lean-beam open-files`, `lean-beam doctor`,
  `lean-beam stats`, `lean-beam reset-stats`, `lean-beam save`, `lean-beam close-save`
- alpha support APIs: `lean-beam run-at-handle`, `lean-beam run-with`, `lean-beam run-with-linear`,
  `lean-beam release`, `lean-beam-search`

Core workflow contract:

- use `lean-beam`, not raw JSON and not raw LSP
- `lean-beam` only sees the on-disk file, not unsaved editor buffers
- after every real Lean source edit: save the file normally, then run `lean-beam sync`
- use `lean-beam save` only for a synced workspace module path in the current Lake workspace package
  graph, for example `MyPkg/Sub/Module.lean`
- `lean-beam save` validates and checkpoints only the module you save; it does not validate importers of
  that module
- treat wrapper `stderr` as human-facing only; use stdout JSON or `beam-client request-stream`
  for machine-readable automation
- do not assume hidden mutable session state carries across unrelated requests

## Prompting Contract

Prefer the smallest command that matches the actual task:

- use `lean-beam hover` when you want semantic information about existing code at one position
- use `lean-beam goals-prev` or `lean-beam goals-after` when you want existing proof state at one tactic
  position
- use `lean-beam run-at` when you want to try one speculative Lean snippet without editing the file
- for `lean-beam run-at`, `lean-beam hover`, and `lean-beam goals-*`, treat `<line> <character>` as Lean/LSP
  coordinates: line `0` is the first line, character `0` is the first UTF-16 code unit, and on a
  truly empty line only character `0` is valid
- use `lean-beam run-at-handle` and then `lean-beam run-with` or `lean-beam run-with-linear` only when exact
  speculative continuation matters
- for multiline speculative text, prefer `--stdin` as the normal path; use `--text-file <path>`
  when the text already lives in a file
- for handle-based continuation, prefer `--handle-file <path>` as the normal path; deeper shell-loop
  variants such as stdin handle piping live in the reference docs
- do not expect one `lean-beam run-at` call to become the basis of the next one automatically
- use `lean-beam sync` right after every real saved edit before the next speculative probe
- use `lean-beam save` or `lean-beam close-save` only for a synced workspace module path such as
  `MyPkg/Sub/Module.lean`

Stop probing and change tactics when:

- the speculative result now needs to become real source: edit the file, save it, then `lean-beam sync`
- repeated `lean-beam run-at` probes are no longer clarifying the problem
- you edited a dependency and now need trustworthy downstream results; `lean-beam save` only validates
  the module you save, not downstream importers
- stale-state, `contentModified`, or rebuild trouble keeps appearing; inspect with `lean-beam open-files`
  and `lean-beam doctor`
- if `lean-beam sync` fails with `syncBarrierIncomplete`: inspect `error.data.staleDirectDeps`,
  `error.data.saveDeps`, and `error.data.recoveryPlan`; save only the listed direct deps that still
  need checkpointing, then `lean-beam refresh "Target.lean"` if the plan says to;
  if this repeats across multiple dependency hops, escalate to `lake build`

When those conditions hold, prefer a real edit plus `lean-beam sync`, or escalate to `lake build` when
the task has become dependency freshness or final validation across importers rather than one-file
probing.

## Lean-Run-At Semantics

`lean-beam run-at` is a speculative execution request against one saved file snapshot. Read it as
"try this Lean text here", not as "edit the file here".

What `lean-beam run-at` does not do:

- it does not edit the source file or create a new on-disk baseline for the next request
- it does not make the speculative text become the basis of the next `lean-beam run-at` call
- it does not wait for or return the full diagnostics barrier for the rest of the file
- it does not replay full-file diagnostics in its final JSON payload
- it does not auto-indent or synthesize leading spaces when you probe at an indented empty line
- it does not reinterpret blank-line coordinates; if the line is truly empty then character `1` is
  already out of range

Use the right tool for each goal:

- if you made a real edit and want fresh file diagnostics: save the file, then use `lean-beam sync`
- if you want exact continuation from speculative state: mint a handle with `lean-beam run-at-handle`,
  then continue with `lean-beam run-with` or `lean-beam run-with-linear`
- for handle-based commands, `--handle-file <path>` is the easiest way to avoid inlining handle json
- if surface syntax depends on indentation or layout: pass the exact text you want Lean to parse, or
  make a real edit in the file instead of expecting the wrapper to fill whitespace for you

Open [references/lean-run-at-semantics.md](references/lean-run-at-semantics.md) when the task needs
concrete examples for:

- full-file diagnostics after a speculative probe
- chaining speculative state across multiple calls
- indentation-sensitive or newline-sensitive probes on blank or layout-sensitive lines

Open [references/workflow-details.md](references/workflow-details.md) when the task needs the shell-oriented
details for:

- `--text-file`, `--`, or stdin-handle piping variants
- handle-file versus stdin-handle tradeoffs
- debugging-oriented wrapper details instead of the normal path

Open [references/commit-speculative.md](references/commit-speculative.md) when the task needs the
current workflow for turning a good speculative probe into a real saved edit.

Open [references/anti-patterns.md](references/anti-patterns.md) when you want a short checklist of
what Lean agents should not assume about `lean-beam run-at`, `lean-beam sync`, handles, or dependency edits.

## Lean Wrapper

Use `lean-beam`, not raw JSON and not raw LSP.

`lean-beam` for Lean:

- infers the target project root from the current directory or `--root`
- keeps one Beam daemon per project root and records it in `<root>/.beam/beam-daemon.json`
  - in sandboxed or read-only project trees, set `BEAM_CONTROL_DIR` to a writable directory; `lean-beam` uses a per-root subdirectory there
- resolves a toolchain-keyed Lean bundle, preferring the installed beam bundle cache and
  falling back to a project-local runtime bundle under `<root>/.beam/bundles` or `BEAM_BUNDLE_DIR`
- only serves Lean toolchains listed in `supported-lean-toolchains`
- owns Beam daemon startup, shutdown, and registry handling
- resolves Lean with `elan which lean`
- builds a local fallback bundle only when no matching installed bundle exists for the target supported Lean toolchain
- fails early on unsupported Lean toolchains; use `lean-beam supported-toolchains` to inspect the allowlist
- restarts the Beam daemon if the effective Lean startup configuration for that root changes
- `lean-beam shutdown`, `lean-beam stats`, and `lean-beam reset-stats` apply to the current project only
- wrapper commands talk to the per-project Beam daemon over localhost TCP; they are not direct in-process Lean calls

`lean-beam` is more than a one-shot probe:

- the common path is still a single isolated `lean-beam run-at` request, which wraps the standalone Lean
  method `$/lean/runAt`
- the underlying Lean side can also retain follow-up state through opaque handles for continuation
  and branching when one-shot probing is not enough, through follow-up methods
  `$/lean/runWith` and `$/lean/releaseHandle`
- treat handles as alpha support APIs: useful, real, and powerful, but more fragile than the base
  request
- handles are document-bound and are invalidated by same-document edits, close, worker restart, or
  Beam daemon restart
- do not present handles as the main story unless the task actually needs continuation from the
  exact speculative state

Default rules:

- use `lean-beam`, not raw JSON and not raw LSP
- start with `lean-beam run-at`
- after every real source edit: save the file to disk normally, then `lean-beam sync`
- if exact continuation matters: mint a handle
- if search branches: use `lean-beam run-with`, `lean-beam run-with-linear`, and `lean-beam release`
- if you want shorter shell commands for search loops: use `lean-beam-search`
- if bundle resolution or startup looks wrong: check `lean-beam doctor` before guessing

## Fast Path

If you only remember one workflow, use this one:

```bash
lean-beam ensure

# inspect existing code or proof state
lean-beam hover "Foo.lean" 10 2
lean-beam goals-prev "Foo.lean" 10 2

# try speculative Lean text without editing the file
lean-beam run-at "Foo.lean" 10 2 "exact trivial"
# for multiline probes, prefer stdin
printf 'example : True := by\n  trivial\n' | lean-beam run-at "Foo.lean" 10 2 --stdin

# after every real edit saved to disk, on that same workspace module path
lean-beam sync "MyPkg/Sub/Module.lean"
lean-beam refresh "MyPkg/Sub/Module.lean"

# only for a synced workspace module path, after a successful sync
lean-beam save "MyPkg/Sub/Module.lean"
```

Read the save path as a progression, not as three unrelated commands:

- `lean-beam sync` establishes the synced, diagnostics-complete snapshot for the current on-disk file
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`; use it when a tracked file needs a fresh basis after upstream changes
- `lean-beam save` is `lean-beam sync` plus a zero-build checkpoint for that synced workspace module
- `lean-beam save` validates only that saved module; it does not validate downstream importers
- `lean-beam close-save` is `lean-beam save` plus closing the tracked file afterward

Diagnostic defaults on that path:

- `lean-beam sync`, `lean-beam refresh`, `lean-beam save`, and `lean-beam close-save` always stream fresh diagnostics for the current request
- by default they stream only errors
- add `+full` to widen the current request to warnings, info, and hints
- the final JSON does not replay streamed diagnostics
- when `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may include
  `error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan` as a cheap
  recovery hint based on direct imports whose saved checkpoint is newer than the target's last
  successful sync boundary
- `lean-beam sync` final JSON reports fresh streamed counts in `result.errorCount` /
  `result.warningCount`, and current save-readiness in `result.saveReady` plus
  `result.stateErrorCount` / `result.stateCommandErrorCount`
- when `lean-beam save` or `lean-beam close-save` fails with `invalidParams` because the document still has
  errors, `error.message` includes a compact preview of underlying diagnostics and/or command
  messages

Surface rule:

- wrapper `stderr` is the human-facing diagnostic surface
- wrapper `stderr` may distinguish request-level failures from a completed request whose payload
  failed inside Lean; use stdout JSON for machine decisions
- `beam-client request-stream ...` is the machine-facing streamed surface
- do not parse wrapper `stderr` in tooling

## Quick Picks

Use this when you are deciding between commands:

- human checking existing code: `lean-beam hover`
- human checking existing proof state: `lean-beam goals-prev` / `lean-beam goals-after`
- human trying speculative Lean text: `lean-beam run-at`
- human after a real saved edit: `lean-beam sync`
- human checkpointing one synced module: `lean-beam save` or `lean-beam close-save`
- human diagnosing daemon or save-state trouble: `lean-beam open-files` and `lean-beam doctor`
- tooling that wants streamed diagnostics or progress: `beam-client request-stream ...`

## References

Open these only when the task needs the detail:

- [references/lean-run-at-semantics.md](references/lean-run-at-semantics.md):
  common `lean-beam run-at` confusion cases, chaining, indentation-sensitive and newline-sensitive probes
- [references/commit-speculative.md](references/commit-speculative.md):
  how to turn a good speculative probe into a real saved edit today
- [references/anti-patterns.md](references/anti-patterns.md):
  short “do not assume this” checklist for common agent mistakes
- [references/mcts-search.md](references/mcts-search.md):
  handle-based branching, linear playouts, release patterns
- [references/workflow-details.md](references/workflow-details.md):
  position semantics, save eligibility, file-progress interpretation, stats, dependency and rebuild rules

## Policy

- prefer `lean-beam run-at` before editing when feasible
- treat `lean-beam sync` as mandatory after every real Lean file edit before the next speculative probe
- do not assume one successful probe changes the basis of the next one; each probe starts from the current synced snapshot
- when continuation really matters, prefer an explicit stored handle over hoping the next probe will
  recover the same internal basis by accident
- prefer `lean-beam save` / `lean-beam close-save` over a full `lake build` when only one file needs checkpointing
- treat `lean-beam save` as a single-module checkpoint, not as dependency-cone validation
- use `lake build` for initial failure discovery, coarse checkpoints, and final validation
- if you edit a dependency of the target file, `lean-beam save` is not enough for downstream trust;
  rebuild before trusting importers
- if daemon/save-state behavior looks wrong, inspect `lean-beam open-files` and `lean-beam doctor`
  before assuming the wrapper is confused
- if a file is open in the Beam daemon, do not edit it out of band without following with `lean-beam sync` or a close/reopen workflow
- if Lean reports stale state, `contentModified`, or rebuild trouble unexpectedly, stop and report it explicitly
