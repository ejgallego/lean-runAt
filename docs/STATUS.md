# Status

Lean Beam is preview beta software. The repository is public for collaboration, early use, and
feedback, but interfaces and installation details may still change before a stable release.

This page summarizes what users can rely on today. Exact setup instructions live in
[SETUP.md](SETUP.md), exact MCP behavior lives in [MCP.md](MCP.md), and exact sync, save, progress,
and diagnostic behavior lives in [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md). The pre-stable
compatibility policy lives in [COMPATIBILITY.md](COMPATIBILITY.md).

The main product idea remains small: run speculative Lean text at a saved-file position without
mutating the user's real document state. The conceptual request is:

```text
runAt(pos, "lean text")
```

Beam adds a thin local layer around Lean LSP plus Beam-specific Lean extensions. The Lean plugin
provides low-level facts; the local Beam layer exposes them through the `lean-beam` CLI, broker
runtime, MCP server, and installed agent skills.

## Current Scope

### Core Lean Surface

Currently supported:

- speculative Lean execution through `$/lean/runAt`, exposed as `lean-beam run-at` and MCP
  `lean_run_at`
- internal proof-first, command-fallback basis selection with no public mode flag
- typed responses containing messages, traces, optional proof state, and optional follow-up handles
- follow-up execution through `$/lean/runWith`, `$/lean/releaseHandle`, wrapper commands, and
  matching MCP tools
- actionable file inspection through `$/lean/todo`, `lean-beam todo`, and MCP `lean_todo`, including
  versioned code-action resolution
- selected Lean/LSP-style navigation through the same wrapper and MCP projections: hover, signature
  help, definitions, references, document and workspace symbols, and goal inspection
- saved-file update, synchronization, and development checkpoints through `lean-beam update`,
  `lean-beam sync`, `lean-beam refresh`, `lean-beam save`, and `lean-beam close-save`

The base `runAt` path is the main API story. Follow-up handles and search helpers are useful
pre-stable extensions, but they are not the center of the product contract.

### CLI, Broker, And Runtime

The normal human and agent entry point is the installed `lean-beam` wrapper. It resolves the current
project root, talks to a local Beam daemon, and reports structured JSON on stdout. The broker owns
isolated workspaces, their Lean sessions, document mirrors, handles, sync and save history, and
metrics.

The wrapper currently supports:

- saved-file update, sync, run-at, todo, navigation, and checkpoint commands
- daemon inspection through `lean-beam open-files`, `lean-beam stats`, and `lean-beam doctor`
- runtime identity through `lean-beam --version`
- conservative installed-state maintenance through `lean-beam prune`
- structured report cards through `lean-beam feedback-report`

Programmatic local consumers should prefer the broker JSON stream exposed by
`beam-client request-stream`. Wrapper stderr is human-facing and may change as diagnostic text
improves.

### MCP And Agent Integration

The installed `lean-beam-mcp` server is an experimental stdio MCP projection over the same Beam
operation layer. It is not a raw Lean LSP proxy and does not expose arbitrary LSP methods.

Currently supported:

- stateless MCP `2026-07-28`, with initialization-based MCP `2025-11-25` available during the
  transition
- explicit local workspace descriptors on every workspace-bound call, with lazy runtime caching
  and explicit eviction through `lean_drop_workspace`
- projected Lean tools for update, sync, refresh, run-at, handles, navigation, todo and code-action
  resolution, save, close, and workspace symbols
- utility tools such as `beam_version`, `beam_stats`, and `beam_feedback_report`
- concurrent independent tool calls, exact request-ID routing, and cooperative cancellation of
  active broker work
- ordered progress notifications for calls with `_meta.progressToken` and incremental Lean
  diagnostic log notifications for sync-style calls
- `lean-beam-mcp --self-check <lean-file>` for installed-path verification
- bundled Lean skills for supported agent clients, with optional Rocq skills when installed with
  `--rocq-skill`

The generated MCP tool list and exact client semantics are documented in [MCP.md](MCP.md).

### Rocq Surface

Rocq support is intentionally narrow. Beam exposes optional goal probes through `coq-lsp`, mainly
for Rocq-to-Lean porting workflows. It is not a Rocq analogue of the Lean speculative execution
layer. Rocq setup and workflow details live in [ROCQ.md](ROCQ.md).

### Coverage

The repository includes regression coverage for isolation, stale state, cancellation, handle
invalidation, broker and wrapper behavior, installation, MCP conformance, and supported toolchains.
The suite map and exact commands live in [TESTING.md](TESTING.md).

## Current Contracts

### Request Isolation

Each speculative Lean request behaves like an isolated sandbox:

- it does not mutate the document's real elaboration state
- it does not rely on side effects from previous speculative requests
- it does not leak hidden mutable state through the base API
- continuation state is retained only when the caller explicitly asks for a follow-up handle

Handles are workspace- and document-bound. Same-document edits, document close, worker or daemon
restart, and workspace eviction invalidate them. Separate `lean-beam run-at` calls do not chain
through hidden state.

### Saved Files And Versions

Beam operates on saved files, not unsaved editor buffers. Position and range operations are
version-bound: callers update or sync a file, then pass the returned document version to later
probes. If Beam reports `contentModified`, update or sync again and retry with the accepted current
version.

`lean-beam sync` is the diagnostics and readiness barrier after a real saved edit. `lean-beam save`
adds a zero-build development checkpoint for one synced Lake module. `lean-beam close-save`
checkpoints and then closes the tracked file. The exact fields, readiness rules, and failure shapes
live in [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md).

### Compatibility

During beta, compatibility is intentionally narrow. Exact validated Lean toolchains, compatible
release lines, runtime and install metadata, advertised MCP revisions, and explicitly documented
client requirements are the named compatibility targets. CLI and MCP surfaces remain discoverable
through help text, installed skill text, and MCP `tools/list`. See
[COMPATIBILITY.md](COMPATIBILITY.md).

## Known Limitations

### Toolchains And Distribution

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading and runtime bundles are toolchain-keyed, not toolchain-agnostic.
- Exact CI-validated Lean toolchains are listed in
  [validated-lean-toolchains](../validated-lean-toolchains). Canonical RC and patch variants from
  [compatible-lean-release-lines](../compatible-lean-release-lines) are admitted separately, and
  explicitly custom elan-linked toolchains require installer registration.
- First use of an accepted but not-yet-prebuilt toolchain may need to build and qualify a local
  fallback bundle. On a cold machine, that build may require network access.
- Beam is installed separately today; it is not yet distributed with Lean.

### Runtime And Sandbox Behavior

- In sandboxed agent environments, daemon startup can require elevated permissions even when the
  installed bundle and project-local paths resolve correctly.
- A startup failure reporting `operation not permitted` through `.beam/beam-daemon-startup.log` is
  usually an environment restriction, not a bundle-resolution mismatch.
- Daemon disappearance errors include registry and log context and write a bounded set of incident
  records under `.beam/daemon-failures/` or the per-root `BEAM_CONTROL_DIR` directory.
- A standalone daemon exits if its canonical project root disappears; later requests fail root
  validation instead of starting a replacement daemon for the missing path.
- Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- Beam workspaces are local. Remote workspaces and same-source multi-toolchain mirrors are not
  implemented.

### MCP

- MCP `2026-07-28` is the preferred protocol. Initialization-based `2025-11-25` remains an explicit
  transition target; older revisions are not advertised or tested.
- Workspace-bound calls require an explicit local descriptor. Dropping a workspace invalidates its
  proof handles; a later request recreates the runtime lazily.
- Lazy runtime creation and workspace eviction remain serialized even though ordinary tool calls
  can run concurrently.
- The Streamable HTTP bridge is test-only; the product entry point remains stdio.
- Exact concurrency, cancellation, progress, logging, annotation, and closed-schema behavior lives
  in [MCP.md](MCP.md).

### Sync, Save, And Staleness

- A zero-build checkpoint covers one module; it is not whole-workspace freshness evidence.
- Structured Lake options, dynamic libraries, and plugins are supported when the Lean file worker
  has already applied them. Batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`.
- Beam does not detect Lake workspace configuration changes during a running Lean session. After
  changing a lakefile, manifest, package override, toolchain, Lean options, plugins, or dynamic
  libraries, run `lean-beam shutdown` before the next server command.
- A checkpoint captures the Lean server's accepted environment. Final batch evidence should come
  from a clean CI `lake build`, or from the one-time local batch-validation sequence documented in
  [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).
- Editing a dependency can make downstream speculative results stale until rebuild or checkpoint.
  Beam does not yet implement Lean's dynamic watched-file registration for source changes that never
  pass through Beam synchronization.
- Some stale-dependency recovery hints remain broker-derived rather than coming directly from
  Lean's native watchdog and file-worker state.

### Rocq

- Rocq support is limited to goal inspection through `coq-lsp`.
- Rocq does not expose a corresponding sync, save, or speculative execution layer through Beam.

## Direction

The current focus is to stabilize the small public surface into dependable agent tooling for daily
Lean work and prepare it for distribution with Lean:

- keep the base `runAt` request small, typed, and isolated
- keep CLI and MCP as thin projections over shared typed operation adapters
- reduce packaging, installation, and workspace rough edges
- improve dependency freshness and readiness using stronger Lean- or Lake-owned signals when they
  become available
- keep daemon conveniences useful without expanding the public API prematurely
- continue exercising Beam in real agent workflows and harden the failures those workflows expose
