# runAt

`runAt` is an alpha Lean LSP extension with optional local Beam daemon and command layers on top.

This repository is public because the code is useful, but it is still mostly a personal
experiment. Expect rough edges, moving interfaces, and workflow changes while the core ideas
settle.

## Status

- alpha code
- one small public Lean request at the center: `$/lean/runAt`
- optional follow-up handle APIs and the local Beam daemon exist, but they should also be treated as alpha
- packaging and workspace integration are still conservative

Current scope, limitations, and short-term direction live in [docs/STATUS.md](docs/STATUS.md).

## Interface Layers

The stack has several layers. They are related, but they are not the same interface.

### 1. Lean LSP Extension

The core layer is a Lean-side LSP extension:

- `$/lean/runAt`
- `$/lean/runWith`
- `$/lean/releaseHandle`
- `$/lean/fileProgress` notifications

This is the most direct layer if you are building a TypeScript or Python agent that already knows
how to speak JSON-RPC/LSP to Lean and wants the smallest typed execution surface.

The public request and response types live in [RunAt/Protocol.lean](RunAt/Protocol.lean).
The server-side implementation lives in [RunAt/Plugin.lean](RunAt/Plugin.lean).

Minimal request shape:

```json
{
  "jsonrpc": "2.0",
  "id": 17,
  "method": "$/lean/runAt",
  "params": {
    "textDocument": { "uri": "file:///path/to/Foo.lean" },
    "position": { "line": 10, "character": 2 },
    "text": "exact trivial"
  }
}
```

That is the layer a TypeScript or Python client would call directly if it already owns the LSP
session and document lifecycle.

### 2. Local Beam Daemon

On top of the Lean extension, this repo ships a single-root local Beam daemon:

- `lake exe beam-daemon`
- `lake exe beam-client`

These internal binaries implement the local Beam daemon for Lean workflows.

The Beam daemon owns:

- project-root scoping
- long-lived Lean session management
- single-root request routing
- wrapper-friendly request/response transport

The default transport is localhost TCP. Unix socket transport exists, but it is still experimental
and is not the recommended path for user-facing workflow guidance yet.

The daemon protocol lives in [Beam/Broker/Protocol.lean](Beam/Broker/Protocol.lean).
The implementation lives in [Beam/Broker/Server.lean](Beam/Broker/Server.lean).
For programmatic local consumers, the preferred stream surface is
`beam-client request-stream`, not the wrapper's human stderr formatting.

### 3. Commands And Helpers

On top of the Beam daemon, this repo ships local command surfaces:

- `lake exe beam-cli`
- [scripts/lean-beam](scripts/lean-beam)
- [scripts/lean-beam-search](scripts/lean-beam-search)

This is the intended local entry point for experimentation today.

These commands own:

- daemon startup and shutdown
- toolchain-keyed bundle management
- sync / save / close convenience commands
- handle-based search helpers for shell workflows

### 4. Future MCP Layer

MCP is not implemented yet, but it is the likely future agent-facing layer above the current LSP and
Beam-daemon stack. The current design note is in [MCP_PLAN.md](MCP_PLAN.md).

The intended relationship is:

- LSP extension as the core typed execution layer
- Beam daemon as the local session/orchestration layer
- commands/helpers as the current practical UX
- MCP as a future agent-native projection layer

## User Manual Scope

This README documents the Lean user-facing surface only.

Some non-Lean tooling still lives in this repository for internal experimentation. It is not part
of the public user manual here, and it may move out into separate repositories later.

## What It Does

At a given document position, `runAt` tries to recover a proof basis first. If that is not
available, it falls back to command execution.

The base request stays small:

```json
{
  "textDocument": { "uri": "file:///path/to/File.lean" },
  "position": { "line": 10, "character": 2 },
  "text": "exact trivial"
}
```

The success payload is typed and small:

- `success`
- `messages`
- `traces`
- optional `proofState`
- optional `handle`

Request-level failures such as invalid parameters, stale document state, cancellation, or internal
faults are reported as transport errors rather than as a normal success payload.

The concrete public types live in [RunAt/Protocol.lean](RunAt/Protocol.lean).

## Lean-Run-At Semantics

`lean-beam run-at` is a speculative execution request against one current saved file snapshot. It is
not a source edit operation.

Three common misreadings to avoid:

- a successful `lean-beam run-at` does not imply a full-file diagnostics barrier for the rest of the
  file; use `lean-beam sync` when you need diagnostics for the current saved file version
- a successful `lean-beam run-at` does not make its speculative text become the basis of the next probe;
  use `lean-beam run-at-handle` plus `lean-beam run-with` / `lean-beam run-with-linear` when exact continuation
  matters
- probing at an indented empty line does not make the wrapper synthesize indentation for you; the
  speculative text is taken as provided, so include the exact whitespace-sensitive text yourself or
  edit the file normally

In short:

- `lean-beam run-at` is for trying Lean text without editing the file
- `lean-beam sync` is the explicit on-disk edit barrier with diagnostics
- handle commands are the alpha path for chaining speculative state exactly
- separate `lean-beam run-at` calls do not chain through hidden state; exact chaining requires
  `lean-beam run-at-handle` plus `lean-beam run-with` or `lean-beam run-with-linear`

For worked examples and the current “commit speculative result” workflow, see:

- [skills/lean-beam/references/lean-run-at-semantics.md](skills/lean-beam/references/lean-run-at-semantics.md)
- [skills/lean-beam/references/commit-speculative.md](skills/lean-beam/references/commit-speculative.md)
- [skills/lean-beam/references/anti-patterns.md](skills/lean-beam/references/anti-patterns.md)
- [skills/lean-beam/references/workflow-details.md](skills/lean-beam/references/workflow-details.md)

## Position Semantics

`runAt` uses Lean/LSP `Position` semantics for `line` and `character`.

For the CLI, that means the `lean-beam run-at` and `lean-beam run-at-handle` arguments are passed straight
through as the request `position`; they are not reinterpreted as editor-specific line numbers,
byte offsets, or parser-token offsets.

Two failure modes matter:

- `position ... is outside the document`: the requested line/character is not a valid Lean/LSP
  position for the current file text
- `no command or tactic snapshot`: the position is in the document, but Lean has no usable
  execution basis there for `lean-beam run-at`

Practical consequence:

- line `0` is the first line, and character `0` is the first UTF-16 code unit on that line
- on a truly empty line, only character `0` is valid; character `1` is already outside the document
- on an indented blank line, use the actual existing indentation width if you probe after the spaces,
  or use character `0` and include the indentation in the speculative text yourself
- valid probe positions are not arbitrary file coordinates; `lean-beam run-at` needs a command basis or
  proof/tactic snapshot there, or one Lean can recover from nearby syntax
- positions inside proof bodies usually work for tactic execution
- positions on standalone comments, blank lines, and many declaration headers do not have a usable
  snapshot
- nearby whitespace or comment positions may still work when Lean can recover a neighboring command
  or proof basis, but that should not be assumed
- these position errors do not by themselves mean the daemon is unhealthy

## Compared To REPL

A reasonable mental model is "REPL-like execution over Lean's live LSP document state".

Compared to [leanprover-community/repl](https://github.com/leanprover-community/repl), `runAt`
recovers its execution basis from a cursor position in the current file instead of asking clients
to manage explicit environment or proof-state ids themselves.

## Repository Contents

- [RunAt/Plugin.lean](RunAt/Plugin.lean): Lean LSP extension implementation
- [RunAt/Protocol.lean](RunAt/Protocol.lean): public request and response structures
- [Beam/Broker/](Beam/Broker): local Beam-daemon support for Lean workflows
- [Beam/Cli.lean](Beam/Cli.lean): public `beam` CLI and daemon orchestration
- [RunAtTest/](RunAtTest): scenario, handle, and daemon regression support
- [scripts/lean-beam](scripts/lean-beam): thin wrapper around the `beam-cli` executable
- [scripts/lean-beam-search](scripts/lean-beam-search): shell helper for handle-based search workflows
- [tests/](tests): interactive, scenario, and daemon regression coverage
- [AGENTS.md](AGENTS.md): repo-specific instructions for coding agents

## Build

```bash
lake build
```

The package builds the `RunAt` library as a shared library so it can be loaded as a Lean plugin.

## Test

```bash
bash tests/test.sh
```

Optional daemon smoke coverage:

```bash
bash tests/test-broker-fast.sh
bash tests/test-broker-slow.sh
bash tests/test-broker.sh
bash scripts/lint-shell.sh
```

`tests/test-broker-fast.sh` is the quick broker/stream contract suite.
`tests/test-broker-slow.sh` covers wrapper/install/bundle-heavy paths.
`tests/test-broker.sh` runs both.
`scripts/lint-shell.sh` runs the repository shell lint pass with `shellcheck`.

The public test path documented here is Lean-focused. Internal experimental tooling may have extra
coverage in-tree, but it is not part of this README.

More detail on the current testing approach and gaps lives in [docs/TESTING.md](docs/TESTING.md).

## Which Layer To Use

Use the Lean LSP extension if:

- you are writing a TypeScript or Python client directly against Lean's JSON-RPC/LSP transport
- you want the smallest typed surface
- you are comfortable managing document state and requests yourself

Use the Beam daemon layer if:

- you want one long-lived local process per project root
- you want a simpler local request/response transport than raw LSP
- you want the CLI to own session lifecycle and request transport
- you are happy to stay on the default localhost TCP transport for now

Use the commands/helpers if:

- you want the easiest local workflow today
- you are scripting from bash or another process runner
- you want `lean-beam sync`, `lean-beam save`, or handle search helpers without writing your own adapter

## Quick Start

Today the practical outside-user surface is the command layer.

From another Lean project, call the wrapper by absolute path:

```bash
/path/to/lean-beam/scripts/lean-beam ensure
/path/to/lean-beam/scripts/lean-beam run-at "Foo.lean" 10 2 "exact trivial"
```

If you want the wrapper on `PATH`, install it with:

```bash
./scripts/install-beam.sh
```

See [Installation And Resolution](#installation-and-resolution) for the full install procedure,
installed layout, and bundle resolution rules.

For outside users today, the practical client surface is the command layer. The installed skills are
optional agent add-ons on top of that command path, rather than part of the required CLI install.

The installed skill entrypoints are:

- Lean skill surface: [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md)
- Rocq skill surface (experimental, low-profile): [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md)

For the Lean skill, the current command families are inspection (`lean-beam hover`, `lean-beam goals-*`),
speculative execution (`lean-beam run-at`), real-edit boundary and checkpointing (`lean-beam sync`,
`lean-beam save`, `lean-beam close-save`), and alpha follow-up continuation (`lean-beam run-at-handle`,
`lean-beam run-with`, `lean-beam run-with-linear`, `lean-beam release`, `lean-beam-search`).

First workflow to remember:

- inspect existing code with `lean-beam hover`
- inspect existing proof state with `lean-beam goals-prev` / `lean-beam goals-after`
- try speculative Lean text with `lean-beam run-at`
- after a real edit saved to disk, run `lean-beam sync` on that same file or module path
- use `lean-beam save` only for a synced workspace module path such as `MyPkg/Sub/Module.lean`;
  `lean-beam close-save` is the same checkpoint plus close
- `lean-beam save` validates and checkpoints only the module you save; it does not validate downstream
  importers
- `lean-beam sync` / `lean-beam save` / `lean-beam close-save` stream errors by default; add `+full` when you also want warnings, info, and hints
- for tooling, use `beam-client request-stream`; wrapper `stderr` is human-facing
- for daemon or save-state trouble, inspect `lean-beam open-files` and `lean-beam doctor`

Current local packaging is:

- one installer for the `lean-beam` wrapper and self-contained runtime, with optional bundled Codex and
  Claude skill installation flags
- the documented agent-facing workflow here is Lean-only
- repo-local `AGENTS.md` guidance for Codex
- repo-local `CLAUDE.md` importing the same guidance for Claude Code

Future distribution work is:

- evaluate a smoother published distribution path, likely GitHub-backed install for Codex and plugin marketplace packaging for Claude

## Installation And Resolution

### Install

Use `./scripts/install-beam.sh` as the supported install path today.

Installation procedure:

1. Ensure `elan` is on `PATH`.
2. Run `./scripts/install-beam.sh` for the base runtime.
3. Optionally add `--toolchain <toolchain>` one or more times to prebuild explicit supported Lean
   bundles, or `--all-supported` to prebuild the full supported allowlist.
4. Optionally rerun with `--codex`, `--claude`, or `--all-skills` to install the bundled agent
   skills.
5. Ensure `~/.local/bin` is on `PATH`, then restart Codex or Claude Code if you installed skills.

That installer:

- puts `lean-beam` in `~/.local/bin`
- puts `lean-beam-search` in `~/.local/bin`
- stages an immutable runtime under `BEAM_INSTALL_ROOT`, defaulting to `~/.local/share/beam`
- points `~/.local/bin/lean-beam` and `lean-beam-search` at `BEAM_INSTALL_ROOT/current`
- requires `elan` on `PATH` and prebuilds the selected supported Lean bundle(s) under
  `BEAM_INSTALL_ROOT/state/install-bundles`
- requires `BEAM_INSTALL_ROOT` to be absolute when overridden
- refuses to replace a real directory at the public wrapper link paths
- installs bundled skills only when you pass `--codex`, `--claude`, or `--all-skills`

Optional skill install commands:

```bash
./scripts/install-beam.sh --codex
./scripts/install-beam.sh --claude
./scripts/install-beam.sh --all-skills
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.29.0-rc6
./scripts/install-beam.sh --all-supported
```

Those flags install the bundled Lean and Rocq skills into `$CODEX_HOME/skills` or
`~/.codex/skills`, and/or `$CLAUDE_HOME/skills` or `~/.claude/skills`.

### Installed Layout

The important terminology is:

- installed runtime: the staged wrapper and binary payload under `BEAM_INSTALL_ROOT/current`
- installed bundle: the prebuilt toolchain-keyed bundle stored under
  `BEAM_INSTALL_ROOT/state/install-bundles`
- local runtime bundle: the same kind of toolchain-keyed bundle, but built on demand for one target project under that project's `.beam` state

There is not a separate "global plugin" mode. `lean-beam` always resolves a full Lean bundle for one
toolchain, containing the Beam daemon binary, the CLI client binary, and the Lean plugin shared
library. The only question is which cache location provides that bundle first.

### Resolution Order

Resolution order for Lean is:

1. Installed wrapper resolution: the installer writes `~/.local/bin/lean-beam` as a symlink to
   `BEAM_INSTALL_ROOT/current/bin/lean-beam`; that wrapper sets `BEAM_HOME` to the installed runtime
   and `BEAM_INSTALL_BUNDLE_DIR` to `BEAM_INSTALL_ROOT/state/install-bundles` unless you override
   them explicitly.
2. Project-root resolution: `lean-beam --root PATH ...` uses that root directly; otherwise the CLI
   searches upward from the current directory for a Lean project root.
3. Installed-bundle lookup: if `BEAM_INSTALL_BUNDLE_DIR` is set, only that installed cache root is
   checked. The installed wrapper sets this to `BEAM_INSTALL_ROOT/state/install-bundles` by
   default.
4. `lean-beam` only serves Lean toolchains listed in `supported-lean-toolchains`. Use
   `lean-beam supported-toolchains` to inspect that allowlist.
5. If a matching installed bundle already exists for a supported target Lean toolchain, `lean-beam`
   uses it.
6. If no installed bundle matches, `lean-beam` falls back to the local runtime bundle cache under
   `BEAM_BUNDLE_DIR` when set, otherwise under `<root>/.beam/bundles`, and builds that bundle on
   demand for that supported toolchain.
7. Unsupported toolchains fail early before bundle reuse or build.
8. Daemon control metadata lives under `BEAM_CONTROL_DIR` when set, otherwise under
   `<root>/.beam`, with one daemon registry per project root. Under `BEAM_CONTROL_DIR`, `lean-beam`
   uses a per-root subdirectory rather than writing the registry file directly at the top level.

In practice this means:

- use the installed bundle when your project's Lean toolchain matches a bundle that was prebuilt by
  the installer
- use the local runtime bundle only as fallback for a supported toolchain that is not already
  available in the installed cache
- expect first-run latency and possibly network access only on that supported local fallback path
- expect unsupported toolchains to fail immediately instead of trying an opportunistic build
- do not think of the installed cache and the local runtime cache as different plugin types; they are
  the same bundle format in two locations

## Commands

The current local command surface sits on top of the Beam daemon:

- `lake exe beam-cli`
- `scripts/lean-beam`
- `scripts/lean-beam-search`

`lean-beam` is the intended Lean entry point for experimentation. The Lean CLI owns project-root
inference, daemon lifecycle, registry handling, and toolchain-keyed bundle selection. The shell
wrapper is only a thin launcher for that executable. `lean-beam-search` is a small shell helper on
top of the handle commands.
For Lean probes, `lean-beam run-at` wraps the standalone method `$/lean/runAt`, and handle
follow-ups map to `$/lean/runWith` / `$/lean/releaseHandle`.

Chaining rule:

- repeated `lean-beam run-at` calls are independent speculative probes on the current saved file snapshot
- if exact speculative continuation matters, use `lean-beam run-at-handle` and continue with
  `lean-beam run-with` or `lean-beam run-with-linear`

Common commands:

```bash
lean-beam ensure
lean-beam run-at "Foo.lean" 10 2 "exact trivial"
lean-beam run-at-handle "Foo.lean" 10 2 "constructor"
lean-beam hover "Foo.lean" 10 2
lean-beam goals-prev "Foo.lean" 10 2
lean-beam goals-after "Foo.lean" 10 2
lean-beam sync "MyPkg/Sub/Module.lean"
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam deps "Foo.lean"
lean-beam save "MyPkg/Sub/Module.lean"
lean-beam close-save "MyPkg/Sub/Module.lean"
lean-beam open-files
lean-beam supported-toolchains
lean-beam doctor
```

Read the Lean wrapper surface as this progression:

- `lean-beam hover` inspects existing semantic information at one position
- `lean-beam goals-prev` / `lean-beam goals-after` inspect existing proof state at one tactic position
- `lean-beam run-at` tries one speculative Lean snippet on the current saved file snapshot
- `lean-beam sync` is the explicit barrier after a real edit saved to disk
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`, useful when a tracked file needs a fresh basis after upstream changes
- `lean-beam save` is `lean-beam sync` plus a zero-build checkpoint for one synced workspace module
- `lean-beam save` validates only that saved module; it does not validate downstream importers
- `lean-beam close-save` is `lean-beam save` plus closing the tracked file afterward

Important wrapper rules:

- separate `lean-beam run-at` calls do not chain through hidden state
- exact speculative chaining requires `lean-beam run-at-handle` plus `lean-beam run-with` or
  `lean-beam run-with-linear`
- `lean-beam save` is module-oriented, not file-oriented; standalone `.lean` files outside the workspace
  package graph are valid `lean-beam sync` targets but not valid `lean-beam save` targets
- if daemon or save-state behavior looks wrong, inspect `lean-beam open-files` and `lean-beam doctor`
  before assuming the wrapper is confused
- `lean-beam sync` transport success means the diagnostics barrier completed, not that the file is
  error-free; `result.errorCount` / `result.warningCount` summarize fresh streamed diagnostics for
  this request, while `result.saveReady` plus `result.stateErrorCount` /
  `result.stateCommandErrorCount` summarize current save-readiness
- when `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may also include
  `error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan` as a cheap
  direct-import recovery hint based on broker-tracked saved dependency boundaries
- by default `lean-beam sync`, `lean-beam refresh`, `lean-beam save`, and `lean-beam close-save` stream only error diagnostics; `+full`
  widens that set to warnings, info, and hints
- wrapper `stderr` is human-facing; `beam-client request-stream` is the machine-readable
  streamed surface

`open-files` reports the files currently tracked by the live daemon for the current project,
including `saved` / `notSaved`, direct Lean deps when available, checkpoint/save eligibility fields,
and the last compact `fileProgress` observed for that tracked version. `lean-beam doctor` is the
companion operational check for daemon health, toolchain support state, bundle source, and bundle
key inputs.

The wrapper also exposes alpha handle commands for exact continuation from speculative state, and
the install script exposes `lean-beam-search` as a shorter shell helper on top of those same
handle commands.

For programmatic consumers, the supported machine-readable surface is the broker JSON stream, not
the human stderr formatting. Use `beam-client request-stream ...`, which emits one compact JSON
`StreamMessage` per line on stdout with `kind = diagnostic | fileProgress | response`; the final
`response` message arrives last. For example:

```bash
beam-client --port 8765 request-stream \
  '{"op":"sync_file","root":"/path/to/root","path":"Foo.lean","fullDiagnostics":true}'
```

That mode is the preferred local machine interface for tools that need streamed diagnostics or
progress.

If the Lean worker cannot finish the diagnostics barrier, for example because imported targets are
stale and rebuild failure prevents a stable session, `lean-beam sync` fails instead of reporting a
partial success response. `lean-beam save` and `lean-beam close-save` refuse to proceed past that incomplete
barrier. For Lean sync failures, the JSON error may include a direct-import hint in `error.data`:
`staleDirectDeps` names direct imports whose saved checkpoint is newer than the target file's last
successful sync boundary, `saveDeps` narrows that to imports that still need `lean-beam save`, and
`recoveryPlan` gives the ordered `save` / `refresh` / `lake build` fallback steps.

Expert-only unstable broker escape hatches such as `lean-beam request-at` are documented separately in
[docs/experimental.md](docs/experimental.md).

For workflow examples and edge cases, see:

- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md)
- [skills/lean-beam/references/lean-run-at-semantics.md](skills/lean-beam/references/lean-run-at-semantics.md)
- [skills/lean-beam/references/commit-speculative.md](skills/lean-beam/references/commit-speculative.md)
- [skills/lean-beam/references/workflow-details.md](skills/lean-beam/references/workflow-details.md)

## Non-Goals

- not yet a stable long-term public API beyond the small alpha surface described here
- not a workspace-wide incremental build replacement
- not a persistent multi-step proof session protocol for clients

## Notes

- Daemon state lives in the long-running daemon process, not in the short-lived `lean-beam` command.
- The wrapper keeps one daemon per project root and records it in `<root>/.beam/beam-daemon.json` by
  default. If your project root is read-only, set `BEAM_CONTROL_DIR` to a writable path to keep
  daemon control metadata outside the project.
- `lean-beam open-files` reports the daemon's currently tracked documents for that project. If there is
  no live daemon yet, there is nothing to report.
- `lean-beam shutdown` only stops the current project's daemon; other project daemons are unaffected.
- Lean plugin loading currently relies on shared-library support with `-Dexperimental.module=true`.
- Lean bundles are toolchain-keyed. The wrapper does not try to make one `.so` work across multiple
  Lean toolchains; instead it builds and reuses one cached bundle per toolchain.
- Supported Lean toolchains are listed in `supported-lean-toolchains`.
- The supported fast path is the toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs and the installer prebuilds that bundle by default.
- Unsupported Lean toolchains fail early. Use `lean-beam supported-toolchains` to list the current
  allowlist and `lean-beam doctor` to inspect the selected toolchain, bundle source, and bundle
  key inputs.
- Bundle rebuild keys use the selected toolchain, platform, and a source hash over the runtime
  source tree plus `lean-toolchain`, `lake-manifest.json`, and `supported-lean-toolchains`.
- Bundle rebuild keys intentionally do not hash the full `.lake/packages` checkout tree.
- If no installed bundle matches a supported toolchain, the wrapper tries a local fallback
  `lake build`. On a cold machine this may need network access to fetch dependencies.
- The first use of a supported but not-yet-prebuilt Lean toolchain may therefore take noticeably
  longer while the matching local fallback bundle is built.
- The daemon is intentionally conservative across multi-file edits.
- If you edit a file that is imported by the current target file, do not trust downstream `runAt`
  results after `lean-beam save`; `lean-beam save` validates only the saved module, so rebuild before trusting
  importers.
- Opening a downstream file is not evidence that it is fresh.
- Maintainer note: `RunAtTest/Broker/SmokeTest.lean` can compile disproportionately slowly after
  `lake clean`, likely due to Lean-generated C shape plus `clang -O3`; if that regresses again,
  prefer splitting the smoke coverage further rather than growing one giant test body.
- This is a real current limitation, not a hidden implementation detail: Lean does not yet expose a
  better restart-required / stale-dependency hook for plugins here, so outside users should expect
  manual rebuild discipline across dependency boundaries.

## License

Apache-2.0. This repo uses the same license as Lean; see [LICENSE](LICENSE).
