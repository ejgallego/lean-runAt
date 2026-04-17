---
name: rocq-beam
description: Use this when an AI needs the auxiliary Rocq goal-probe surface exposed through the installed `lean-beam` wrapper, giving it cheap coq-lsp proof-state access without treating Rocq support as a separate product.
---

# Rocq Beam

Use this skill when a Rocq project needs the narrow Rocq-facing surface that `lean-beam` already exposes. This is an auxiliary mode of the `lean-beam` toolchain, not a separate product or a second full workflow stack.

The goal is cheap Rocq proof-state inspection through `coq-lsp`, without turning Rocq support into a broad standalone interface.

Do not use `coqtop` or any fallback executor. Only `coq-lsp` is trusted.
This is the Rocq-only skill. It should stay focused on Rocq and should not require Lean-specific
workflow guidance. Do not factor shared Lean/Rocq skill instructions into a common helper;
duplicate short guidance if both skills need it.

## Setup

From the `lean-beam` repo root:

```bash
./scripts/install-beam.sh --codex
```

Use `--claude` instead when installing for Claude Code, or `--all-skills` when you want both agent
skill sets.

The installer puts `lean-beam` in `~/.local/bin`, stages the self-contained runtime under
`BEAM_INSTALL_ROOT` (default `~/.local/share/beam`), requires `elan` on `PATH`, prebuilds the
pinned `lean-toolchain` bundle under `BEAM_INSTALL_ROOT/state/install-bundles`, and installs the
Lean and Rocq bundled skills only for the agent flags you request.

Restart Codex or Claude Code after installation.

## Rocq Setup

Rocq-specific setup:

```bash
cd /path/to/lean-beam
bash tests/setup-rocq-opam.sh
```

## Skill Surface

This skill documents the supported Rocq-facing `lean-beam` workflow surface. Keep the surface narrow:
the current wrapper is for goal inspection against saved files, not for hidden proof-session
mutation.

Supported command families:

- bootstrap the Rocq backend: `lean-beam ensure rocq`
- inspect goals after an existing sentence: `lean-beam rocq-goals-after`
- inspect goals before a sentence or after speculative sentence text within that basis:
  `lean-beam rocq-goals-prev`
- inspect tracked files and daemon state: `lean-beam open-files`, `lean-beam stats`, `lean-beam reset-stats`

What to treat as the current public skill surface:

- default command: `lean-beam rocq-goals-after`
- intermediate-state command: `lean-beam rocq-goals-prev` with extra text when needed
- operational introspection: `lean-beam open-files`, `lean-beam stats`, `lean-beam reset-stats`

Core workflow contract:

- use `lean-beam`, not raw JSON and not raw LSP
- save the `.v` file before every new probe after a real edit
- `lean-beam` only sees the on-disk file, not unsaved editor buffers
- treat `<line> <character>` as LSP-style coordinates for the saved file: line `0` is the first
  line, character `0` is the first character position on that line, and on a truly empty line only
  character `0` is valid
- there is no Rocq `sync` command in the current wrapper
- there is no Rocq handle or continuation surface in the current wrapper
- there is no Rocq `run-at` command in the current wrapper; use the goal probes instead
- do not assume hidden mutable proof-session state carries across requests
- do not use `coqtop` or a fallback executor; only `coq-lsp` is trusted

Use `lean-beam`, not raw JSON and not raw LSP.

`lean-beam` for Rocq:

- infers the target project root from the current directory or `--root`
- keeps one Beam daemon per project root and records it in `<root>/.beam/beam-daemon.json`
  - in sandboxed or read-only project trees, set `BEAM_CONTROL_DIR` to a writable directory
- owns Beam daemon startup, shutdown, and registry handling
- resolves `coq-lsp` from the target project's local `_opam` when available
- starts a Rocq-capable Beam daemon with explicit startup args instead of relying on inherited editor state
- wrapper commands talk to the per-project Beam daemon over localhost TCP; they are not direct in-process Rocq calls
- in Codex-style sandboxes, Beam daemon startup may still require elevated permissions even when all paths resolve correctly
- in the same environments, localhost TCP bind/connect for the Beam daemon and client may also require elevated permissions
- if startup fails with `operation not permitted`, treat that as a sandbox capability problem first, not as a missing install
- `lean-beam shutdown`, `lean-beam stats`, and `lean-beam reset-stats` apply to the current project only

Default rules:

- use `lean-beam`, not raw JSON and not raw LSP
- start with `lean-beam rocq-goals-after`
- save the file before every new probe after a real edit
- keep coordinates 0-based; do not guess editor-specific 1-based lines or columns
- if you think you want a Rocq `run-at`, use `lean-beam rocq-goals-prev` with extra text or `rocq-goals-after` instead
- use `lean-beam rocq-goals-prev` plus text when you need an intermediate state inside a sentence
- do not assume any hidden proof-session state carries across requests

## Workflow

Ensure the Rocq backend:

```bash
lean-beam ensure rocq
lean-beam stats
```

Inspect goals after a sentence:

```bash
lean-beam rocq-goals-after "Demo.v" 2 8
```

Inspect goals before a sentence:

```bash
lean-beam rocq-goals-prev "Demo.v" 2 8
```

For a tactic sentence like `a; b`, inspect the intermediate state after `a` with:

```bash
lean-beam rocq-goals-prev "Demo.v" 2 8 "a."
```

Source-file model:

- `lean-beam rocq-goals-*` does not edit `Demo.v`
- edit the file normally, save it, then probe again
- `lean-beam` only sees the on-disk Rocq file, not unsaved editor buffers
- actual source edits happen through the normal file-edit workflow
- there is no Rocq `sync` command in the current wrapper; saving the file is the important step before the next probe

Execution model:

- every `lean-beam rocq-goals-*` request is an isolated read-only probe against the current saved file
- do not expect hidden mutable proof-session state to carry from one probe to the next
- the Beam daemon may reopen or resync the on-disk file before a probe, but saving the file is still the real boundary you control
- there is no Rocq `lean-beam sync` equivalent in the wrapper, so after edits the important step is: save, then probe again
- if the file changes while a request is pending or `coq-lsp` state becomes stale, expect to rerun from the saved file instead of relying on recovery inside the old request

Default loop:

```bash
lean-beam ensure rocq
lean-beam rocq-goals-after "Demo.v" 12 4

# make a real edit, save the file
lean-beam rocq-goals-after "Demo.v" 12 4
```

Use cases:

1. Inspect the current proof state after a sentence

```bash
lean-beam ensure rocq
lean-beam rocq-goals-after "Demo.v" 12 4
```

2. Inspect an intermediate tactic state inside one sentence

```bash
lean-beam ensure rocq
lean-beam rocq-goals-prev "Demo.v" 12 4 "intro x."
lean-beam rocq-goals-prev "Demo.v" 12 4 "split."
```

3. Check the effect of a small real edit

Save the file first, then probe again from the saved document.

```bash
lean-beam ensure rocq
lean-beam rocq-goals-after "Demo.v" 12 4

# make a real edit in Demo.v and save it
lean-beam rocq-goals-after "Demo.v" 12 4
```

## Policy

- default to `lean-beam rocq-goals-after`
- use `lean-beam rocq-goals-prev` plus text for intermediate-state probing
- keep `ppFormat` as `Str`
- do not treat `lean-beam` as a source editor; actual `.v` edits happen through the normal file-edit workflow
- do not assume one goal probe mutates the basis of the next probe; each request starts from the current saved document state
- if `coq-lsp` reports stale or broken state unexpectedly, stop and report it loudly

## Stats

Use:

```bash
lean-beam open-files
lean-beam stats
lean-beam reset-stats
```

`lean-beam open-files` shows the files currently tracked by the Beam daemon for the current project. For
tracked files the broker already knows about, the wrapper checks status incrementally against the
current on-disk text, and `open-files` also reports the last compact `fileProgress` observed for
that tracked version.

Stats are in-memory only and scoped to the current project Beam daemon.

## Upstream Rocq Features Not Yet Wrapped

Useful `petanque/*` methods we may expose later:

- `petanque/get_state_at_pos`
- `petanque/run_at_pos`
- `petanque/goals`
- `petanque/premises`
- `petanque/ast_at_pos`
- `petanque/list_notations_in_statement`
- `petanque/proof_info_at_pos`
