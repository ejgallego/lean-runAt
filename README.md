# runAt

`runAt` is an alpha Lean LSP extension with optional local CLI-daemon and command layers on top.

This repository is public because the code is useful, but it is still mostly a personal
experiment. Expect rough edges, moving interfaces, and workflow changes while the core ideas
settle.

## Status

- alpha code
- one small public Lean request at the center: `$/lean/runAt`
- optional follow-up handle APIs and the local CLI daemon exist, but they should also be treated as alpha
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

### 2. Local CLI Daemon

On top of the Lean extension, this repo ships a single-root local CLI daemon:

- `lake exe runAt-cli-daemon`
- `lake exe runAt-cli-client`

These internal binaries implement the local CLI daemon for Lean workflows.

The CLI daemon owns:

- project-root scoping
- long-lived Lean session management
- single-root request routing
- wrapper-friendly request/response transport

The default transport is localhost TCP. Unix socket transport exists, but it is still experimental
and is not the recommended path for user-facing workflow guidance yet.

The daemon protocol lives in [RunAtCli/Broker/Protocol.lean](RunAtCli/Broker/Protocol.lean).
The implementation lives in [RunAtCli/Broker/Server.lean](RunAtCli/Broker/Server.lean).
For programmatic local consumers, the preferred stream surface is
`runAt-cli-client request-stream`, not the wrapper's human stderr formatting.

### 3. Commands And Helpers

On top of the CLI daemon, this repo ships local command surfaces:

- `lake exe runAt`
- [scripts/runat](scripts/runat)
- [scripts/runat-lean-search](scripts/runat-lean-search)

This is the intended local entry point for experimentation today.

These commands own:

- daemon startup and shutdown
- toolchain-keyed bundle management
- sync / save / close convenience commands
- handle-based search helpers for shell workflows

### 4. Future MCP Layer

MCP is not implemented yet, but it is the likely future agent-facing layer above the current LSP and
CLI-daemon stack. The current design note is in [MCP_PLAN.md](MCP_PLAN.md).

The intended relationship is:

- LSP extension as the core typed execution layer
- CLI daemon as the local session/orchestration layer
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

`lean-run-at` is a speculative execution request against one current saved file snapshot. It is
not a source edit operation.

Three common misreadings to avoid:

- a successful `lean-run-at` does not imply a full-file diagnostics barrier for the rest of the
  file; use `lean-sync` when you need diagnostics for the current saved file version
- a successful `lean-run-at` does not make its speculative text become the basis of the next probe;
  use `lean-run-at-handle` plus `lean-run-with` / `lean-run-with-linear` when exact continuation
  matters
- probing at an indented empty line does not make the wrapper synthesize indentation for you; the
  speculative text is taken as provided, so include the exact whitespace-sensitive text yourself or
  edit the file normally

In short:

- `lean-run-at` is for trying Lean text without editing the file
- `lean-sync` is the explicit on-disk edit barrier with diagnostics
- handle commands are the alpha path for chaining speculative state exactly
- separate `lean-run-at` calls do not chain through hidden state; exact chaining requires
  `lean-run-at-handle` plus `lean-run-with` or `lean-run-with-linear`

For worked examples and the current “commit speculative result” workflow, see:

- [skills/lean-runat/references/lean-run-at-semantics.md](skills/lean-runat/references/lean-run-at-semantics.md)
- [skills/lean-runat/references/commit-speculative.md](skills/lean-runat/references/commit-speculative.md)
- [skills/lean-runat/references/anti-patterns.md](skills/lean-runat/references/anti-patterns.md)
- [skills/lean-runat/references/workflow-details.md](skills/lean-runat/references/workflow-details.md)

## Position Semantics

`runAt` uses Lean/LSP `Position` semantics for `line` and `character`.

For the CLI, that means the `lean-run-at` and `lean-run-at-handle` arguments are passed straight
through as the request `position`; they are not reinterpreted as editor-specific line numbers,
byte offsets, or parser-token offsets.

Two failure modes matter:

- `position ... is outside the document`: the requested line/character is not a valid Lean/LSP
  position for the current file text
- `no command or tactic snapshot`: the position is in the document, but Lean has no usable
  execution basis there for `lean-run-at`

Practical consequence:

- line `0` is the first line, and character `0` is the first UTF-16 code unit on that line
- on a truly empty line, only character `0` is valid; character `1` is already outside the document
- on an indented blank line, use the actual existing indentation width if you probe after the spaces,
  or use character `0` and include the indentation in the speculative text yourself
- valid probe positions are not arbitrary file coordinates; `lean-run-at` needs a command basis or
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
- [RunAtCli/Broker/](RunAtCli/Broker): local CLI-daemon support for Lean workflows
- [RunAtCli/Cli.lean](RunAtCli/Cli.lean): public `runat` CLI and daemon orchestration
- [RunAtTest/](RunAtTest): scenario, handle, and daemon regression support
- [scripts/runat](scripts/runat): thin wrapper around the `runAt-cli` executable
- [scripts/runat-lean-search](scripts/runat-lean-search): shell helper for handle-based search workflows
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

Use the CLI daemon layer if:

- you want one long-lived local process per project root
- you want a simpler local request/response transport than raw LSP
- you want the CLI to own session lifecycle and request transport
- you are happy to stay on the default localhost TCP transport for now

Use the commands/helpers if:

- you want the easiest local workflow today
- you are scripting from bash or another process runner
- you want `lean-sync`, `lean-save`, or handle search helpers without writing your own adapter

## Quick Start

Today the practical outside-user surface is the command layer.

From another Lean project, call the wrapper by absolute path:

```bash
/path/to/runAt/scripts/runat ensure lean
/path/to/runAt/scripts/runat lean-run-at "Foo.lean" 10 2 "exact trivial"
```

If you want the wrapper on `PATH`, install it with:

```bash
bash scripts/install-runat-skills.sh
```

See [Installation And Resolution](#installation-and-resolution) for the full install procedure,
installed layout, and bundle resolution rules.

For outside users today, the practical client surface is the command layer. The installed skills are
optional agent add-ons on top of that command path, rather than part of the required CLI install.

The installed skill entrypoints are:

- Lean skill surface: [skills/lean-runat/SKILL.md](skills/lean-runat/SKILL.md)
- Rocq skill surface: [skills/rocq-runat/SKILL.md](skills/rocq-runat/SKILL.md)

For the Lean skill, the current command families are inspection (`lean-hover`, `lean-goals-*`),
speculative execution (`lean-run-at`), real-edit boundary and checkpointing (`lean-sync`,
`lean-save`, `lean-close-save`), and alpha follow-up continuation (`lean-run-at-handle`,
`lean-run-with`, `lean-run-with-linear`, `lean-release`, `runat-lean-search`).

First workflow to remember:

- inspect existing code with `lean-hover`
- inspect existing proof state with `lean-goals-prev` / `lean-goals-after`
- try speculative Lean text with `lean-run-at`
- after a real edit saved to disk, run `lean-sync` on that same file or module path
- use `lean-save` only for a synced workspace module path such as `MyPkg/Sub/Module.lean`;
  `lean-close-save` is the same checkpoint plus close
- `lean-save` validates and checkpoints only the module you save; it does not validate downstream
  importers
- `lean-sync` / `lean-save` / `lean-close-save` stream errors by default; add `+full` when you also want warnings, info, and hints
- for tooling, use `runAt-cli-client request-stream`; wrapper `stderr` is human-facing
- for daemon or save-state trouble, inspect `runat open-files` and `runat doctor lean`

Current local packaging is:

- one installer for the `runat` wrapper and self-contained runtime, with optional bundled Codex and
  Claude skill installation flags
- the documented agent-facing workflow here is Lean-only
- repo-local `AGENTS.md` guidance for Codex
- repo-local `CLAUDE.md` importing the same guidance for Claude Code

Future distribution work is:

- evaluate a smoother published distribution path, likely GitHub-backed install for Codex and plugin marketplace packaging for Claude

## Installation And Resolution

### Install

Use `bash scripts/install-runat-skills.sh` as the supported install path today.

Installation procedure:

1. Ensure `elan` is on `PATH`.
2. Run `bash scripts/install-runat-skills.sh` for the base runtime.
3. Optionally add `--toolchain <toolchain>` one or more times to prebuild explicit supported Lean
   bundles, or `--all-supported` to prebuild the full supported allowlist.
4. Optionally rerun with `--codex`, `--claude`, or `--all-skills` to install the bundled agent
   skills.
5. Ensure `~/.local/bin` is on `PATH`, then restart Codex or Claude Code if you installed skills.

That installer:

- puts `runat` in `~/.local/bin`
- puts `runat-lean-search` in `~/.local/bin`
- stages an immutable runtime under `RUNAT_INSTALL_ROOT`, defaulting to `~/.local/share/runat`
- points `~/.local/bin/runat` and `runat-lean-search` at `RUNAT_INSTALL_ROOT/current`
- requires `elan` on `PATH` and prebuilds the selected supported Lean bundle(s) under
  `RUNAT_INSTALL_ROOT/state/install-bundles`
- requires `RUNAT_INSTALL_ROOT` to be absolute when overridden
- refuses to replace a real directory at the public wrapper link paths
- installs bundled skills only when you pass `--codex`, `--claude`, or `--all-skills`

Optional skill install commands:

```bash
bash scripts/install-runat-skills.sh --codex
bash scripts/install-runat-skills.sh --claude
bash scripts/install-runat-skills.sh --all-skills
bash scripts/install-runat-skills.sh --toolchain leanprover/lean4:v4.29.0-rc6
bash scripts/install-runat-skills.sh --all-supported
```

Those flags install the bundled Lean and Rocq skills into `$CODEX_HOME/skills` or
`~/.codex/skills`, and/or `$CLAUDE_HOME/skills` or `~/.claude/skills`.

### Installed Layout

The important terminology is:

- installed runtime: the staged wrapper and binary payload under `RUNAT_INSTALL_ROOT/current`
- installed bundle: the prebuilt toolchain-keyed bundle stored under
  `RUNAT_INSTALL_ROOT/state/install-bundles`
- local runtime bundle: the same kind of toolchain-keyed bundle, but built on demand for one target project under that project's `.runat` state

There is not a separate "global plugin" mode. `runat` always resolves a full Lean bundle for one
toolchain, containing the CLI daemon binary, the CLI client binary, and the Lean plugin shared
library. The only question is which cache location provides that bundle first.

### Resolution Order

Resolution order for Lean is:

1. Installed wrapper resolution: the installer writes `~/.local/bin/runat` as a symlink to
   `RUNAT_INSTALL_ROOT/current/bin/runat`; that wrapper sets `RUNAT_HOME` to the installed runtime
   and `RUNAT_INSTALL_BUNDLE_DIR` to `RUNAT_INSTALL_ROOT/state/install-bundles` unless you override
   them explicitly.
2. Project-root resolution: `runat --root PATH ...` uses that root directly; otherwise the CLI
   searches upward from the current directory for a Lean project root.
3. Installed-bundle lookup: if `RUNAT_INSTALL_BUNDLE_DIR` is set, only that installed cache root is
   checked. The installed wrapper sets this to `RUNAT_INSTALL_ROOT/state/install-bundles` by
   default.
4. `runat` only serves Lean toolchains listed in `supported-lean-toolchains`. Use
   `runat supported-toolchains lean` to inspect that allowlist.
5. If a matching installed bundle already exists for a supported target Lean toolchain, `runat`
   uses it.
6. If no installed bundle matches, `runat` falls back to the local runtime bundle cache under
   `RUNAT_BUNDLE_DIR` when set, otherwise under `<root>/.runat/bundles`, and builds that bundle on
   demand for that supported toolchain.
7. Unsupported toolchains fail early before bundle reuse or build.
8. Daemon control metadata lives under `RUNAT_CONTROL_DIR` when set, otherwise under
   `<root>/.runat`, with one daemon registry per project root. Under `RUNAT_CONTROL_DIR`, `runat`
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

The current local command surface sits on top of the CLI daemon:

- `lake exe runAt-cli`
- `scripts/runat`
- `scripts/runat-lean-search`

`runat` is the intended local entry point for experimentation. The Lean CLI owns project-root
inference, daemon lifecycle, registry handling, and toolchain-keyed bundle selection. The shell
wrapper is only a thin launcher for that executable. `runat-lean-search` is a small shell helper on
top of the handle commands.

Chaining rule:

- repeated `lean-run-at` calls are independent speculative probes on the current saved file snapshot
- if exact speculative continuation matters, use `lean-run-at-handle` and continue with
  `lean-run-with` or `lean-run-with-linear`

Common commands:

```bash
runat ensure lean
runat lean-run-at "Foo.lean" 10 2 "exact trivial"
runat lean-run-at-handle "Foo.lean" 10 2 "constructor"
runat lean-hover "Foo.lean" 10 2
runat lean-goals-prev "Foo.lean" 10 2
runat lean-goals-after "Foo.lean" 10 2
runat lean-sync "MyPkg/Sub/Module.lean"
runat lean-deps "Foo.lean"
runat lean-save "MyPkg/Sub/Module.lean"
runat lean-close-save "MyPkg/Sub/Module.lean"
runat open-files
runat supported-toolchains lean
runat doctor lean
```

Read the Lean wrapper surface as this progression:

- `lean-hover` inspects existing semantic information at one position
- `lean-goals-prev` / `lean-goals-after` inspect existing proof state at one tactic position
- `lean-run-at` tries one speculative Lean snippet on the current saved file snapshot
- `lean-sync` is the explicit barrier after a real edit saved to disk
- `lean-save` is `lean-sync` plus a zero-build checkpoint for one synced workspace module
- `lean-save` validates only that saved module; it does not validate downstream importers
- `lean-close-save` is `lean-save` plus closing the tracked file afterward

Important wrapper rules:

- separate `lean-run-at` calls do not chain through hidden state
- exact speculative chaining requires `lean-run-at-handle` plus `lean-run-with` or
  `lean-run-with-linear`
- `lean-save` is module-oriented, not file-oriented; standalone `.lean` files outside the workspace
  package graph are valid `lean-sync` targets but not valid `lean-save` targets
- if daemon or save-state behavior looks wrong, inspect `runat open-files` and `runat doctor lean`
  before assuming the wrapper is confused
- `lean-sync` transport success means the diagnostics barrier completed, not that the file is
  error-free; inspect `result.errorCount` and `result.warningCount`
- by default `lean-sync`, `lean-save`, and `lean-close-save` stream only error diagnostics; `+full`
  widens that set to warnings, info, and hints
- wrapper `stderr` is human-facing; `runAt-cli-client request-stream` is the machine-readable
  streamed surface

`open-files` reports the files currently tracked by the live daemon for the current project,
including `saved` / `notSaved`, direct Lean deps when available, checkpoint/save eligibility fields,
and the last compact `fileProgress` observed for that tracked version. `doctor lean` is the
companion operational check for daemon health, toolchain support state, bundle source, and bundle
key inputs.

The wrapper also exposes alpha handle commands for exact continuation from speculative state, and
the install script exposes `runat-lean-search` as a shorter shell helper on top of those same
handle commands.

For programmatic consumers, the supported machine-readable surface is the broker JSON stream, not
the human stderr formatting. Use `runAt-cli-client request-stream ...`, which emits one compact JSON
`StreamMessage` per line on stdout with `kind = diagnostic | fileProgress | response`; the final
`response` message arrives last. For example:

```bash
runAt-cli-client --port 8765 request-stream \
  '{"op":"sync_file","root":"/path/to/root","path":"Foo.lean","fullDiagnostics":true}'
```

That mode is the preferred local machine interface for tools that need streamed diagnostics or
progress.

If the Lean worker cannot finish the diagnostics barrier, for example because imported targets are
stale and rebuild failure prevents a stable session, `lean-sync` fails instead of reporting a
partial success response. `lean-save` and `lean-close-save` refuse to proceed past that incomplete
barrier.

Expert-only unstable broker escape hatches such as `lean-request-at` are documented separately in
[docs/experimental.md](docs/experimental.md).

For workflow examples and edge cases, see:

- [skills/lean-runat/SKILL.md](skills/lean-runat/SKILL.md)
- [skills/lean-runat/references/lean-run-at-semantics.md](skills/lean-runat/references/lean-run-at-semantics.md)
- [skills/lean-runat/references/commit-speculative.md](skills/lean-runat/references/commit-speculative.md)
- [skills/lean-runat/references/workflow-details.md](skills/lean-runat/references/workflow-details.md)

## Non-Goals

- not yet a stable long-term public API beyond the small alpha surface described here
- not a workspace-wide incremental build replacement
- not a persistent multi-step proof session protocol for clients

## Notes

- Daemon state lives in the long-running daemon process, not in the short-lived `runat` command.
- The wrapper keeps one daemon per project root and records it in `<root>/.runat/cli-daemon.json` by
  default. If your project root is read-only, set `RUNAT_CONTROL_DIR` to a writable path to keep
  daemon control metadata outside the project.
- `runat open-files` reports the daemon's currently tracked documents for that project. If there is
  no live daemon yet, there is nothing to report.
- `runat shutdown` only stops the current project's daemon; other project daemons are unaffected.
- Lean plugin loading currently relies on shared-library support with `-Dexperimental.module=true`.
- Lean bundles are toolchain-keyed. The wrapper does not try to make one `.so` work across multiple
  Lean toolchains; instead it builds and reuses one cached bundle per toolchain.
- Supported Lean toolchains are listed in `supported-lean-toolchains`.
- The supported fast path is the toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs and the installer prebuilds that bundle by default.
- Unsupported Lean toolchains fail early. Use `runat supported-toolchains lean` to list the current
  allowlist and `runat doctor lean` to inspect the selected toolchain, bundle source, and bundle
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
  results after `lean-save`; `lean-save` validates only the saved module, so rebuild before trusting
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
