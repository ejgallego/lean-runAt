---
name: lean-runat
description: Use this when an AI should work on an external Lean project through the installed `runat` wrapper, giving it direct efficient access to Lean's proof engine to avoid rebuilds through cheap speculative checks and zero-build module checkpoints.
---

# Lean RunAt

Use this skill for Lean projects when you want the AI to replace repeated `lake build` loops with cheap speculative Lean probes, optional follow-up handle execution, and targeted file checkpoints.

This is the Lean-only skill. It should stay focused on Lean and should not require Rocq setup or Rocq concepts.
Do not factor shared Lean/Rocq skill instructions into a common helper; duplicate short guidance if
both skills need it.

## Setup

From the `runAt` repo root:

```bash
./scripts/install-runat.sh --codex
```

Use `--claude` instead when installing for Claude Code, or `--all-skills` when you want both agent
skill sets.

The installer puts `runat` and `runat-lean-search` in `~/.local/bin`, stages the self-contained
runtime under `RUNAT_INSTALL_ROOT` (default `~/.local/share/runat`), requires `elan` on `PATH`,
prebuilds the pinned `lean-toolchain` bundle under `RUNAT_INSTALL_ROOT/state/install-bundles` by
default, supports `--toolchain <toolchain>` and `--all-supported` for explicit supported bundle
selection, and installs the bundled skills only for the agent flags you request.

Restart Codex or Claude Code after installation.

For the authoritative install and bundle-resolution order, see the `Installation And Resolution`
section in the repo [README](../../README.md).

## Skill Surface

This skill documents the supported Lean-facing `runat` workflow surface. Use the smallest command
family that fits the task.

Supported command families:

- bootstrap the Lean backend: `runat ensure lean`
- inspect existing code or proof state: `lean-hover`, `lean-goals-prev`, `lean-goals-after`
- inspect file, dependency, or daemon state: `lean-deps`, `open-files`, `doctor lean`, `stats`,
  `reset-stats`
- try one isolated speculative Lean snippet: `lean-run-at`
- continue from one exact speculative state: `lean-run-at-handle`, `lean-run-with`,
  `lean-run-with-linear`, `lean-release`
- checkpoint one synced workspace module: `lean-sync`, `lean-save`, `lean-close-save`
- run shell-oriented search loops over the same handle APIs: `runat-lean-search`

What to treat as the default public skill surface:

- default and stable enough for normal use: `lean-hover`, `lean-goals-prev`, `lean-goals-after`,
  `lean-run-at`, `lean-sync`
- narrower but supported wrapper surface: `lean-deps`, `open-files`, `doctor lean`, `stats`,
  `reset-stats`, `lean-save`, `lean-close-save`
- alpha support APIs: `lean-run-at-handle`, `lean-run-with`, `lean-run-with-linear`,
  `lean-release`, `runat-lean-search`

Core workflow contract:

- use `runat`, not raw JSON and not raw LSP
- `runat` only sees the on-disk file, not unsaved editor buffers
- after every real Lean source edit: save the file normally, then run `lean-sync`
- use `lean-save` only for a synced workspace module path in the current Lake workspace package
  graph, for example `MyPkg/Sub/Module.lean`
- `lean-save` validates and checkpoints only the module you save; it does not validate importers of
  that module
- treat wrapper `stderr` as human-facing only; use stdout JSON or `runAt-cli-client request-stream`
  for machine-readable automation
- do not assume hidden mutable session state carries across unrelated requests

## Prompting Contract

Prefer the smallest command that matches the actual task:

- use `lean-hover` when you want semantic information about existing code at one position
- use `lean-goals-prev` or `lean-goals-after` when you want existing proof state at one tactic
  position
- use `lean-run-at` when you want to try one speculative Lean snippet without editing the file
- for `lean-run-at`, `lean-hover`, and `lean-goals-*`, treat `<line> <character>` as Lean/LSP
  coordinates: line `0` is the first line, character `0` is the first UTF-16 code unit, and on a
  truly empty line only character `0` is valid
- use `lean-run-at-handle` and then `lean-run-with` or `lean-run-with-linear` only when exact
  speculative continuation matters
- do not expect one `lean-run-at` call to become the basis of the next one automatically
- use `lean-sync` right after every real saved edit before the next speculative probe
- use `lean-save` or `lean-close-save` only for a synced workspace module path such as
  `MyPkg/Sub/Module.lean`

Stop probing and change tactics when:

- the speculative result now needs to become real source: edit the file, save it, then `lean-sync`
- repeated `lean-run-at` probes are no longer clarifying the problem
- you edited a dependency and now need trustworthy downstream results; `lean-save` only validates
  the module you save, not downstream importers
- stale-state, `contentModified`, or rebuild trouble keeps appearing; inspect with `runat open-files`
  and `runat doctor lean`

When those conditions hold, prefer a real edit plus `lean-sync`, or escalate to `lake build` when
the task has become dependency freshness or final validation across importers rather than one-file
probing.

## Lean-Run-At Semantics

`lean-run-at` is a speculative execution request against one saved file snapshot. Read it as
"try this Lean text here", not as "edit the file here".

What `lean-run-at` does not do:

- it does not edit the source file or create a new on-disk baseline for the next request
- it does not make the speculative text become the basis of the next `lean-run-at` call
- it does not wait for or return the full diagnostics barrier for the rest of the file
- it does not replay full-file diagnostics in its final JSON payload
- it does not auto-indent or synthesize leading spaces when you probe at an indented empty line
- it does not reinterpret blank-line coordinates; if the line is truly empty then character `1` is
  already out of range

Use the right tool for each goal:

- if you made a real edit and want fresh file diagnostics: save the file, then use `lean-sync`
- if you want exact continuation from speculative state: mint a handle with `lean-run-at-handle`,
  then continue with `lean-run-with` or `lean-run-with-linear`
- if surface syntax depends on indentation or layout: pass the exact text you want Lean to parse, or
  make a real edit in the file instead of expecting the wrapper to fill whitespace for you

Open [references/lean-run-at-semantics.md](references/lean-run-at-semantics.md) when the task needs
concrete examples for:

- full-file diagnostics after a speculative probe
- chaining speculative state across multiple calls
- indentation-sensitive or newline-sensitive probes on blank or layout-sensitive lines

Open [references/commit-speculative.md](references/commit-speculative.md) when the task needs the
current workflow for turning a good speculative probe into a real saved edit.

Open [references/anti-patterns.md](references/anti-patterns.md) when you want a short checklist of
what Lean agents should not assume about `lean-run-at`, `lean-sync`, handles, or dependency edits.

## Lean Wrapper

Use `runat`, not raw JSON and not raw LSP.

`runat` for Lean:

- infers the target project root from the current directory or `--root`
- keeps one CLI daemon per project root and records it in `<root>/.runat/cli-daemon.json`
  - in sandboxed or read-only project trees, set `RUNAT_CONTROL_DIR` to a writable directory; `runat` uses a per-root subdirectory there
- resolves a toolchain-keyed Lean bundle, preferring the installed runAt bundle cache and
  falling back to a project-local runtime bundle under `<root>/.runat/bundles` or `RUNAT_BUNDLE_DIR`
- only serves Lean toolchains listed in `supported-lean-toolchains`
- owns CLI daemon startup, shutdown, and registry handling
- resolves Lean with `elan which lean`
- builds a local fallback bundle only when no matching installed bundle exists for the target supported Lean toolchain
- fails early on unsupported Lean toolchains; use `runat supported-toolchains lean` to inspect the allowlist
- restarts the CLI daemon if the effective Lean startup configuration for that root changes
- `runat shutdown`, `runat stats`, and `runat reset-stats` apply to the current project only
- wrapper commands talk to the per-project CLI daemon over localhost TCP; they are not direct in-process Lean calls

`runAt` is more than a one-shot probe:

- the common path is still a single isolated `lean-run-at` request
- the underlying Lean side can also retain follow-up state through opaque handles for continuation
  and branching when one-shot probing is not enough
- treat handles as alpha support APIs: useful, real, and powerful, but more fragile than the base
  request
- handles are document-bound and are invalidated by same-document edits, close, worker restart, or
  CLI daemon restart
- do not present handles as the main story unless the task actually needs continuation from the
  exact speculative state

Default rules:

- use `runat`, not raw JSON and not raw LSP
- start with `lean-run-at`
- after every real source edit: save the file to disk normally, then `lean-sync`
- if exact continuation matters: mint a handle
- if search branches: use `lean-run-with`, `lean-run-with-linear`, and `lean-release`
- if you want shorter shell commands for search loops: use `runat-lean-search`
- if bundle resolution or startup looks wrong: check `runat doctor lean` before guessing

## Fast Path

If you only remember one workflow, use this one:

```bash
runat ensure lean

# inspect existing code or proof state
runat lean-hover "Foo.lean" 10 2
runat lean-goals-prev "Foo.lean" 10 2

# try speculative Lean text without editing the file
runat lean-run-at "Foo.lean" 10 2 "exact trivial"

# after every real edit saved to disk, on that same workspace module path
runat lean-sync "MyPkg/Sub/Module.lean"

# only for a synced workspace module path, after a successful sync
runat lean-save "MyPkg/Sub/Module.lean"
```

Read the save path as a progression, not as three unrelated commands:

- `lean-sync` establishes the synced, diagnostics-complete snapshot for the current on-disk file
- `lean-save` is `lean-sync` plus a zero-build checkpoint for that synced workspace module
- `lean-save` validates only that saved module; it does not validate downstream importers
- `lean-close-save` is `lean-save` plus closing the tracked file afterward

Diagnostic defaults on that path:

- `lean-sync`, `lean-save`, and `lean-close-save` always stream fresh diagnostics for the current request
- by default they stream only errors
- add `+full` to widen the current request to warnings, info, and hints
- the final JSON does not replay streamed diagnostics
- when `lean-save` or `lean-close-save` fails with `invalidParams` because the document still has
  errors, `error.message` includes a compact preview of underlying diagnostics and/or command
  messages

Surface rule:

- wrapper `stderr` is the human-facing diagnostic surface
- `runAt-cli-client request-stream ...` is the machine-facing streamed surface
- do not parse wrapper `stderr` in tooling

## Quick Picks

Use this when you are deciding between commands:

- human checking existing code: `lean-hover`
- human checking existing proof state: `lean-goals-prev` / `lean-goals-after`
- human trying speculative Lean text: `lean-run-at`
- human after a real saved edit: `lean-sync`
- human checkpointing one synced module: `lean-save` or `lean-close-save`
- human diagnosing daemon or save-state trouble: `open-files` and `doctor lean`
- tooling that wants streamed diagnostics or progress: `runAt-cli-client request-stream ...`

## References

Open these only when the task needs the detail:

- [references/lean-run-at-semantics.md](references/lean-run-at-semantics.md):
  common `lean-run-at` confusion cases, chaining, indentation-sensitive and newline-sensitive probes
- [references/commit-speculative.md](references/commit-speculative.md):
  how to turn a good speculative probe into a real saved edit today
- [references/anti-patterns.md](references/anti-patterns.md):
  short “do not assume this” checklist for common agent mistakes
- [references/mcts-search.md](references/mcts-search.md):
  handle-based branching, linear playouts, release patterns
- [references/workflow-details.md](references/workflow-details.md):
  position semantics, save eligibility, file-progress interpretation, stats, dependency and rebuild rules

## Policy

- prefer `runat lean-run-at` before editing when feasible
- treat `runat lean-sync` as mandatory after every real Lean file edit before the next speculative probe
- do not assume one successful probe changes the basis of the next one; each probe starts from the current synced snapshot
- when continuation really matters, prefer an explicit stored handle over hoping the next probe will
  recover the same internal basis by accident
- prefer `runat lean-save` / `lean-close-save` over a full `lake build` when only one file needs checkpointing
- treat `lean-save` as a single-module checkpoint, not as dependency-cone validation
- use `lake build` for initial failure discovery, coarse checkpoints, and final validation
- if you edit a dependency of the target file, `lean-save` is not enough for downstream trust;
  rebuild before trusting importers
- if daemon/save-state behavior looks wrong, inspect `runat open-files` and `runat doctor lean`
  before assuming the wrapper is confused
- if a file is open in the CLI daemon, do not edit it out of band without following with `lean-sync` or a close/reopen workflow
- if Lean reports stale state, `contentModified`, or rebuild trouble unexpectedly, stop and report it explicitly
