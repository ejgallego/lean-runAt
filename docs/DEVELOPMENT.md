# Development

This repository is AI-first in practice, but the local workflow should work for both humans and AI
agents.

The primary product entry point is `lean-beam`. The local development harness is for maintainers and
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

## Code Organization

- `Beam.LSP`: Lean LSP server plugin code, including the `$/lean/runAt` request for speculative
  execution at saved document positions.
- `Beam`: shared broker, CLI, and MCP layer over Lean LSP plus Beam-specific extensions.
- `skills`: installed workflow guidance for supported agent clients built around `lean-beam`.
- Rocq support: a narrow auxiliary goal-probe surface through the same `lean-beam` wrapper, useful
  when porting from Rocq to Lean.
- `tests`: scenario-DSL coverage for LSP-level behavior, concurrent stress coverage, broker and
  wrapper regression suites, and install/runtime validation.

## Local Workflow

Start from the repo root and prefer dedicated worktrees for new tasks:

```bash
./scripts/codex-harness.sh session start <task-id>
```

That keeps new work off the primary checkout and matches the repository's default Codex workflow.
By default, the harness uses `.codex-worktrees/lean-beam` inside the repo rather than `/tmp` or a
home-global worktree root.

Important local scripts:

- `scripts/codex-harness.sh`: start and manage dedicated task worktrees
- `scripts/codex-session-start.sh`: lower-level helper used by the harness
- `scripts/validate-defensive.sh`: slower guarded validation in a cloned `/tmp` sandbox
- `scripts/lean-beam`: installed wrapper entry point

Preferred maintainer entrypoints:

- new Codex task: `./scripts/codex-harness.sh session start <task-id>`
- risky wrapper/install validation: `bash scripts/validate-defensive.sh`
- public workflow checks: `lean-beam` and the skill docs
- sandboxed repeated wrapper probes: `lean-beam ensure --hold`, then interrupt that foreground
  process when the probe loop is finished
- contributor process questions: [CONTRIBUTING.md](../CONTRIBUTING.md)

## Human And AI Roles

- README is for humans who want to understand and use the project
- [docs/SETUP.md](SETUP.md) is the canonical user path for install, supported toolchains, first CLI
  use, MCP setup, installer locations, and offline notes
- [docs/STATUS.md](STATUS.md) is the public beta scope, limitation, and direction summary
- [docs/MCP.md](MCP.md) owns MCP implementation, protocol, tool-list, and conformance notes
- [docs/SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md) owns the exact sync, refresh, save,
  progress, diagnostics, readiness, and stale-version contract
- [docs/COMPATIBILITY.md](COMPATIBILITY.md),
  [validated-lean-toolchains](../validated-lean-toolchains), and
  [compatible-lean-release-lines](../compatible-lean-release-lines) own compatibility targets
- skills document the installed workflow surface that agents should follow
- `AGENTS.md` carries repo-specific agent instructions
- this document is for maintainers working locally, whether the operator is a human or an AI; do not
  use it as a second source of truth for user-visible setup, status, or protocol behavior
- the Codex harness scripts are maintainer tools, not public product surface

## Change Discipline

- prefer the wrapper or broker client over raw LSP when the task fits
- if a subtle behavior changes, add or update a regression test first
- keep destructive cleanup scoped to owned temp or worktree paths
- if Lean reports stale or rebuild trouble unexpectedly, stop and surface it explicitly

## Common Code Smells

- do not stringify typed errors or responses and later parse the rendered exception text to recover
  control flow; keep `Response`, `BrokerFailure`, or structured error data typed across
  async/pending boundaries, and stringify only at transport, CLI, or diagnostic display edges
- do not add useless backward compatibility support; this pre-stable project has no legacy users, so
  remove obsolete aliases, inferred envelope shapes, and compatibility branches unless they support
  an explicitly listed Lean/Rocq/tooling version or another target named in
  [Compatibility Policy](COMPATIBILITY.md)

## Compatibility Policy

The compatibility policy is [docs/COMPATIBILITY.md](COMPATIBILITY.md). Development changes that add
shims, aliases, permissive decoders, or deprecated fields should name the concrete target there.

## Lean LSP Request Families

[Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean) should stay a thin registration module. Each
request family owns its method constants, JSON payload types, handler, and request-local helpers:

- [Beam/LSP/RunAt.lean](../Beam/LSP/RunAt.lean): `$/lean/runAt`, `$/lean/runWith`, and
  `$/lean/releaseHandle`; handle state lives under
  [Beam/LSP/RunAt](../Beam/LSP/RunAt)
- [Beam/LSP/Goals.lean](../Beam/LSP/Goals.lean): `$/lean/goalsAfter` and `$/lean/goalsPrev`
- [Beam/LSP/Todo.lean](../Beam/LSP/Todo.lean): `$/lean/todo`
- [Beam/LSP/Save.lean](../Beam/LSP/Save.lean): save-readiness helpers and artifact requests
- [Beam/LSP/DiagnosticsBarrier.lean](../Beam/LSP/DiagnosticsBarrier.lean): broker-only diagnostics
  barrier handler returning direct imports from Lean's accepted header snapshot and Lean-side
  save-readiness metadata; the broker decodes the matching small JSON contract without importing
  this handler module

Use `Beam.LSP.Lib.*` only for helpers shared across multiple families, such as request hygiene,
proof-state projection, diagnostics compatibility, and native shared-library naming. Keep
feature-specific mutable state in the owning family.

## Daemon Runtime Safety

The Beam daemon embeds Lean and Lake as libraries. Daemon/importable broker code must treat
process-wide exits as fatal bugs, not as ordinary control flow.

Do not call Lean/Lake APIs from daemon paths when they may call `IO.Process.exit`, `IO.exit`, or an
equivalent process-wide exit. Known hazards include Lake `runBuild` with `noBuild := true`, which is
CLI-oriented and can exit with Lake's no-build status, and `Lake.loadWorkspace` with
`updateToolchain := true`, which can request a Lake restart by exiting the current process. In daemon
code, use exception-returning checks such as `Workspace.checkNoBuild` for preflight decisions, run
follow-up trace computation without `noBuild`, and set `updateToolchain := false` on broker-side
`LoadConfig` literals.

The cheap regression guard is [scripts/check-daemon-safety.sh](../scripts/check-daemon-safety.sh).
It is intentionally conservative and should be updated when a new daemon-safe wrapper around an
exit-capable Lean/Lake API is introduced.

The broker has no default workspace. Every workspace-bound broker request names a workspace or
carries a continuation handle that names one, and daemon startup receives its initial workspace id
explicitly through `--workspace-id`. The public CLI still manages one daemon per project, but that
policy stays in `Beam.Cli`: its request adapter supplies a CLI-owned private identifier. That value
is an implementation detail, not part of the broker protocol. Broker stats and open-document
requests without an id remain process-wide; stats report `uptimeMs` and the `workspaces` map. Every
broker request except `cancel` and `shutdown` is tracked even when it has no client request id;
anonymous requests use an internal admission token so disconnect cancellation cannot affect a later
request. Wrapper requests carry a generated request id so each one can be cancelled by its exact
admission handle. The CLI scopes those requests before sending them.
`Beam.Broker.Op.workspaceScope` is the shared operation classification; CLI and test adapters should
use it instead of maintaining their own operation lists.

Workspace teardown must not wait for backend shutdown while holding `ServerRuntime.state`: reset,
drop, and runtime close detach backend sessions and commit the new workspace state atomically, then
wait for or terminate the detached processes after releasing the mutex. This keeps teardown of one
workspace from blocking state access for every other workspace. Other state transactions, including
session startup and restart, may still perform process I/O while holding that mutex.

## MCP Projection Changes

MCP work should go through the shared Lean operation layer in
[Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) and the typed projection in
[Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean). `Beam.Lean.Operation` owns curated
operations, typed inputs, broker adapters, descriptions, and base schemas. The MCP projection adds
its required workspace descriptor and normalizes result names.

The local descriptor lives in
[Beam/Workspace/Protocol.lean](../Beam/Workspace/Protocol.lean). Every workspace-bound request must
carry `{"workspace":{"root":"/absolute/project"}}`. Resolve it through
[Beam/Lean/Workspace.lean](../Beam/Lean/Workspace.lean), canonicalize it before deriving the private
broker cache key, and never store a current/default workspace in MCP protocol state. MCP server
state owns only the optional shared `ServerRuntime`; workspace membership and canonical roots remain
broker-owned and must be observed through typed broker queries rather than a transport-side mirror.
`ServerState` also owns the runtime-control mutex used by every transport and direct request entry
point. Runtime creation, workspace eviction, and close are serialized there; close first transfers
the runtime out of `ServerState`, then drains it while preventing a competing creation.
In-process MCP lifecycle calls use the broker's typed `initWorkspaceWithConfig` and `dropWorkspace`
results directly; do not route them through broker JSON dispatch and decode them back into the same
types.

CLI and MCP share semantic dispatch, not transport coordination. A daemon accepts one broker request
per socket connection, so the connection itself supplies response routing and disconnect lifetime.
MCP multiplexes requests over one stdio stream, so `Beam.Mcp.StdioServer` must own exact JSON-RPC ID
routing, serialized output, client cancellation, and workspace-control barriers. Both paths converge
on `ServerRuntime.dispatchRequestWithHandle`, whose admission handle is the shared cancellation and
drain boundary. `ServerRuntime` remains transport-agnostic; the daemon's private transport context
owns its endpoint, listener, and stop state. Keep the two ingress coordinators separate unless a
future transport has the same wire-level ownership rules; do not duplicate semantic operation
dispatch above that boundary.

The executable path is split into importable modules:

- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean): current MCP JSON-RPC helpers
- [Beam/Mcp/Options.lean](../Beam/Mcp/Options.lean): executable options and usage
- [Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean): canonical root to broker configuration
- [Beam/Mcp/SelfCheck.lean](../Beam/Mcp/SelfCheck.lean): installed-wrapper self-check
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean): descriptor resolution, lazy runtime dispatch, and
  the synchronous protocol-test seam
- [Beam/Mcp/StdioServer.lean](../Beam/Mcp/StdioServer.lean): permanent stdin reader, concurrent
  coordination, cancellation, cache-control barriers, and serialized output
- [Beam/Mcp/ServerMain.lean](../Beam/Mcp/ServerMain.lean): executable entry point

Keep these stdio invariants explicit:

- only `runStdio` reads stdin
- every stdout message passes through `OutputSink`
- the server emits no JSON-RPC requests to clients
- request IDs preserve their string-versus-integer type and their original JSON spelling
- ordinary calls may overlap; cache eviction is a full stream-order fence and shutdown drains work
- once a request is registered, synchronous setup must either transfer it to an owned worker or
  complete it terminally; worker finalization always retires the request and releases its control
  fence, including after task-start, reporting, or output failures
- ordinary tool calls bind cancellation to the exact broker admission handle; do not reintroduce
  request-ID polling between MCP and the broker
- routing/output locks do not acquire setup, progress, or per-request locks
- JSON-RPC envelopes and current-method parameter objects reject undeclared fields; protocol
  extensions belong in `_meta` or in a deliberately versioned schema change

The installed wrapper passes the matching `beam-cli`; on lazy first use, `Beam.Mcp.Runtime` runs
`beam-cli` with the canonical root to obtain `mcp-config`. Keep bundle selection in that narrow
CLI/runtime boundary. Clients supply descriptors, not raw commands or plugin paths.

When adding an MCP-facing operation:

1. Add or reuse a `Beam.Lean.Operation` with a typed input, broker adapter, description, and closed
   schema.
2. Project it through `Beam.Mcp.Projection` and classify its Beam-managed effects explicitly in
   `ToolName.annotations`, retaining the conservative protocol defaults when uncertain. Do not
   expose raw LSP or generic broker escape hatches.
3. Add CLI projection work separately when the operation also belongs on the CLI.
4. Require the descriptor in the generated MCP schema. Pass only the canonical private key to the
   broker. Do not add init/select/list tools or restore startup-root or Roots fallback.
5. Normalize agent-facing output, including `next_handle`, `proof_state`, and the canonical workspace
   descriptor. Keep errors typed until the transport edge.
6. Treat `lean_drop_workspace` only as idempotent cache eviction. It invalidates that runtime's
   handles; the next descriptor-bound call recreates it lazily. Preserve the canonical descriptor
   recovery path when the project directory or its Lean/Lake markers no longer resolve.
7. Update projection, protocol, and real stdio coverage, including missing/relative descriptors,
   canonical aliases, multi-root isolation, cross-workspace handles, and eviction/recreation.
8. Run the projection/protocol builds and executables, the concurrent stdio scenario,
   `git diff --check`, and `bash tests/test-beam-fast.sh`.

Broker requests remain a shared record for the CLI, MCP projection, and daemon transport, but field
ownership is operation-specific. Update `Op.optionalRequestFields` with every new broker field and
keep `Request.validateFields` at both the JSON decoder and direct dispatch boundary. Do not let an
operation silently ignore a field owned by another operation. The broker protocol's `.cancel`
operation is process-wide and is identified only by `cancelRequestId`; it does not carry a workspace
or root selector.

Broker `Response` and `StreamMessage` values are tagged unions internally. Their explicit JSON
codecs retain the public `ok` and `kind` discriminants while preventing mismatched payloads from
being constructed after decoding; consume stream messages with exhaustive pattern matching rather
than rebuilding optional payload views. Every stream variant uses the same wire `payload` field;
the `kind` discriminant selects its typed decoder. `StreamMessage` owns `clientRequestId` uniformly
for progress, diagnostic, and terminal response variants; semantic `Response` values do not own
transport identity. CLI output may decorate a printed response with a caller-visible request ID only
at that presentation edge. Internal request and pending error channels carry `ResponseFailure`,
never the full response sum; `Response.errorResult` carries that exact failure when a request is
completed. Use the closed `BrokerFailure` code set for failures generated by Beam itself; use
`ResponseFailure` when preserving an exact typed backend error and response metadata.
`Operation.toBrokerRequest` validates every operation input
against its closed `Operation.inputSchema` before typed decoding. Keep sync/refresh and
save/close-save operation inputs separate: only sync-like inputs may carry final diagnostic replay
control. Likewise, keep redundant wire observations derived internally: diagnostic `total` is the
severity sum, save `path` and `version` come from its nested sync result, and a decoded close-save
result is always closed.

Lean/Lake root validation remains shared with the CLI. MCP descriptors use
`Beam.Lean.Workspace.resolveRoot`, which requires absolute paths; ordinary `lean-beam` CLI paths use
`resolveCliRoot`. The MCP executable itself has no startup-root option.

`Beam.Mcp.protocolVersion` is the preferred modern MCP revision;
`Beam.Mcp.perRequestProtocolVersions` is the list returned by discovery and unsupported-version
errors; and `Beam.Mcp.legacyProtocolVersion` is the initialization-based compatibility revision.
Do not add an initialization-only revision to the per-request list. Change any of these only with a
protocol audit: check the upstream MCP schema/changelog, update local protocol tests, run the
Lean-backed stdio harness, update
[docs/MCP.md](MCP.md) and any affected status notes, and run
[tests/test-mcp-modern-sdk.sh](../tests/test-mcp-modern-sdk.sh),
[tests/test-mcp-modern-conformance.sh](../tests/test-mcp-modern-conformance.sh), and the legacy
[tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh) against their revised baselines.

The local Streamable HTTP bridge under [tests/mcp_http_bridge.py](../tests/mcp_http_bridge.py) is a
test/conformance adapter over the stdio executable, not a separate product transport. Keep it thin:
it should translate HTTP status/header rules to the stdio server without adding a second MCP tool
implementation.

The legacy and modern conformance scripts own their package and scenario pins. The modern alpha gate
only runs scenarios that do not require an upstream synthetic tool surface or unadvertised
prompt/resource methods. The real stdio interoperability script separately owns its released
`@modelcontextprotocol/client` pin. Changing a package version or scenario baseline is a protocol
change: update [docs/TESTING.md](TESTING.md), run all affected local scripts, and check the workflow
with `actionlint`.

## Broker Server Boundaries

Keep [Beam/Broker/Server.lean](../Beam/Broker/Server.lean) focused on session lifecycle, request
dispatch, cancellation, document sync, and save barriers. Pure metrics structures and JSON encoding
live in [Beam/Broker/Metrics.lean](../Beam/Broker/Metrics.lean), so adding counters or changing
stats payloads does not require mixing pure reporting code into the process/session runtime.

The broker is not a raw LSP proxy. Its narrow public job is still to expose small Beam requests, but
internally it coordinates several responsibilities around the LSP process:

- the CLI owns process identity: project-root detection, bundle selection, registry files,
  endpoint/root/generation validation, explicit session ownership, startup/shutdown, and
  control-directory locks
- the broker owns request identity: daemon root validation, backend session lifetime, request
  dispatch, cancellation, active-request bookkeeping, transport errors, and the LSP document mirror
- the LSP server and plugin own Lean/Rocq semantic facts: elaboration, diagnostics, progress,
  goals, runAt execution, direct imports, save readiness, and save artifact generation
- Lake owns build graph and trace semantics; broker code may preflight and translate Lake outcomes,
  but daemon paths must not enter Lake APIs that can terminate the process

`ServerRuntime.dispatchRequestWithHandle` is the asynchronous admission boundary for in-process
consumers such as MCP. It validates operation field ownership, registers the request's active
identity, exposes one opaque `RequestHandle`, and owns unregistering that handle on success,
rejection, or exception. A handle uses a per-admission token and must become
inert after that lexical scope, including when a later request reuses the same client request ID.
Keep ordinary daemon and CLI dispatch on
`ServerRuntime.dispatchRequest`; transport layers must not mutate the active-request registry
directly. Pending LSP requests must retain the same per-admission cancellation identity; after a
handle has been validated, never fall back to matching a reusable client request ID. Pass and await
the `PendingRequest` as one value instead of separating its promise from its cancellation reference.
Once that reference is marked, cancellation takes precedence over a concurrent backend failure;
an already-completed backend success remains successful.
After initialization, `sessionReaderLoop` is the backend session's only stdout reader. Shutdown
replies use the same pending-request store and reader loop; do not add a second direct stdout read.

`ServerRuntime.close` is the shared runtime teardown boundary. It closes admission, marks every
admitted request for cancellation, shuts down backend sessions to unblock pending work, waits for
all admitted dispatch scopes to unregister, and performs a final backend sweep so a request that
was between admission and session creation cannot leave a late process behind. Concurrent and
repeated callers wait for the same result. Transport owners decide what triggers closure and how
their listener or stdio connection stops; they must not duplicate broker draining or backend
teardown.

A newly spawned backend remains a provisional resource until its initialization response arrives
within the 30-second startup deadline and the broker sends `initialized`. Any initialization error,
timeout, or notification-write failure terminates and reaps that child before the acquisition fails;
only a fully initialized session enters workspace state. Keep this acquisition bracket intact so
runtime closure never has to discover an unowned provisional process.

The thick part of the broker is request orchestration. For `sync`, `runAt`, `goals`, `runWith`,
`release`, and `save`, the broker reads the source file, updates the LSP document mirror, waits for
the relevant diagnostics/progress barrier when needed, asks the backend for semantic facts, and
shapes the final Beam response. Keep that boundary explicit: the broker may order requests, attach
typed observations such as `fileProgress`, and report stale direct-dependency hints, but save
readiness is a backend/LSP verdict. Do not rebuild or override the save decision from progress,
diagnostic counts, saved-olean bookkeeping, or other broker-side observations.
For checkpoint decisions, the broker passes the expected document version and text hash to the
Lean-side save-artifact request. The broker uses the save-readiness metadata returned by the
diagnostics barrier that already waited for the same document version. Streamed diagnostics and
broker summaries are evidence attached to that verdict, not the authority for it. Lake setup
options, dynamic libraries, and plugins already applied by the file worker are part of that accepted
snapshot. Strong batch-only `moreLeanArgs` are not; reject them with `saveUnsupportedSetup` instead
of rebuilding from the broker.

The saved environment is the accepted Lean server environment, not the result of a new batch
elaboration. This is an intentional development-loop tradeoff: elaborators that inspect
`Lean.Elab.inServer` or otherwise observe server mode can produce a different environment under
`lake build`. Keep readiness and response text scoped to "server snapshot accepted and
checkpointed"; do not describe a Beam save as batch-build or CI success. User and agent docs must
also make clear that routine local work does not require an expensive clean rebuild. Final batch
evidence must come from CI running `lake build` from clean artifacts, or from a one-time clean local
build when no successful clean CI result is available, as defined in
[SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).

Do not remove broker-side ordered file snapshots when thinning orchestration. Beam requests are
path-based and may run concurrently, while LSP document updates are an ordered client stream. The LSP
server can validate ordering only after the broker sends `didOpen` / `didChange`; it cannot know that
one filesystem read is older than another. `FileSyncSnapshot` in
[Beam/Broker/Server.lean](../Beam/Broker/Server.lean) and `syncSnapshotSeq` in
[Beam/Broker/DocumentState.lean](../Beam/Broker/DocumentState.lean) protect that pre-LSP race:
request handlers reserve a sequence number under the broker mutex, read and hash the file outside the
mutex, then ignore a completed snapshot if a newer read has already been applied to the same document.
In-session syncs use sequence zero because they run inside the already-ordered session flow.

Keep readiness claims deliberately narrow: `fileProgress` is an observable LSP progress signal, and
it is a barrier input only for the operations that define a diagnostics/save barrier (`sync`,
`refresh`, `save`, and `close-save`). It is not a general semantic-ready signal, and it is not the
save-readiness authority. Tests that need to prove request overlap, cancellation, startup, or
stale-state transitions should wait on explicit state such as request IDs, response files, registry
files, or fixture sentinels instead of treating progress as a proxy for readiness.

Readiness response helpers and sync/save response shaping live in
[Beam/Broker/Readiness.lean](../Beam/Broker/Readiness.lean). Keep LSP/session IO in
`Beam/Broker/Server.lean`, but put barrier interpretation, top-level `fileProgress` attachment, and
sync/save success or `syncBarrierIncomplete` response construction behind that named boundary. Save
response shaping must preserve the backend save-readiness verdict rather than substituting a
broker-derived decision.

## Sandboxed Wrapper Path

This wrapper path is easy to break accidentally, so keep the mental model simple.

A CLI session descriptor is the schema-versioned `beam-daemon.json` selected by the control
directory. It contains one generation identity, capability, lifecycle, endpoint, and a nonempty
array of frozen workspace bindings. The public owner command currently creates one binding; the
shape permits a future explicitly configured static multi-workspace session without changing
request routing. Exactly one foreground `lean-beam ensure --hold` process owns the generation. It
starts the daemon in a dedicated process session, passes the identity, effective configuration
hash, and random capability through piped stdin, and retains the pipe's write end. Before creating
the lock or descriptor, Beam makes the selected control directory `0700`; the mode-`0600`
descriptor is written through an exclusive random temporary path and publishes `live` or
`draining`. Every wrapper request, including cancellation, generation probes, and shutdown,
presents the capability. The daemon watches the pipe's read end;
EOF closes admission, marks admitted requests for cancellation, shuts down backend sessions, and
stops the listener. There is no heartbeat, lease, or time-based retirement fence.

Ordinary wrapper commands never start a daemon or recompute its desired toolchain/bundle
configuration. Without taking the session mutation lock or creating control files, they select the
canonical root's frozen workspace binding and require an endpoint that answers for that workspace,
root, and exact generation. Atomic descriptor publication plus endpoint authentication makes a
concurrent lifecycle change fail closed. Identity probes have a bounded response deadline. A silent
or malformed endpoint fails closed. Ordinary lookup is observation-only: absent, legacy, malformed,
unsupported, draining, unreachable, or otherwise ambiguous descriptor states are never rewritten
by an attaching command. Persisted PIDs are display-only diagnostics, never probed, signalled, or
used as automatic stale-reclamation proof. Only the foreground owner may force termination, through
its retained child handle and process group.

The owner watches its exact descriptor generation and daemon child. `lean-beam shutdown` changes
that generation from `live` to `draining` under the control lock before sending authenticated
shutdown. Normal holder exit likewise publishes `draining`, closes its pipe, waits for graceful
teardown, and, after the deadline, terminates the owned process group. It removes only the exact
generation after owned cleanup completes. An unexpected daemon or owner exit deliberately leaves
the descriptor fenced: startup does not infer complete process-tree exit from persisted PIDs. Once
the operator establishes that the old session is no longer authoritative,
`lean-beam --root ROOT recover --generation ID` quarantines that exact descriptor without signalling
any recorded process. Opaque legacy, unsupported, or malformed state requires `recover --force`.
A paused holder keeps its pipe open and remains valid without expiry. If the project root
disappears, cleanup uses the already resolved control path without recreating the project.

Human commands may infer the nearest project root. The supported machine stream requires explicit
`--root` and a nonempty `clientRequestId`; its semantic JSON cannot supply `root`, `workspaceId`,
capability, dynamic workspace operations, or process-wide control operations such as `shutdown` and
`resetStats`. The wrapper selects the descriptor binding and injects session metadata. Lifecycle
shutdown remains the dedicated `lean-beam shutdown` command so it can publish `draining` first. Raw
port-oriented `beam-client` requests are maintainer/debug tooling. A wrapper-owned daemon rejects
`initWorkspace`, `listWorkspaces`, and `dropWorkspace`; a separately launched broker retains the
generic multi-workspace surface and has its own explicit owner. Broker runtime ownership is a typed
`ServerMode`: wrapper identity and capability cannot be constructed independently.

The default control directory is `<root>/.beam`, discoverable to project-scoped agents.
`--control-dir DIR` is an exact, stateless selection that every participant must repeat.
`BEAM_CONTROL_ROOT` must be absolute and hashes each canonical root below a writable base for
sandboxed/read-only roots. The selected directory is private to one local account; coordination is
supported between that account's processes, not across a group-shared control directory.

Do not hide policy inside automatic fallback between these locations. A future multi-root CLI owner
should require a stable explicit control directory and freeze all bindings before publication.

Keep these invariants covered:

- only `ensure --hold` may create and publish a wrapper daemon generation
- a second owner is rejected while the current endpoint/root/generation identity is live
- ordinary wrapper commands are read-only with respect to registry and process lifecycle, including
  in ambiguous or unsafe state; they attach to frozen owner configuration rather than recomputing it
- normal holder teardown retains a generation-specific draining fence until owned cleanup completes
  and cannot remove a replacement; abnormal exit leaves the fence for explicit recovery
- recovery of a current descriptor requires both its exact generation and one of its recorded
  workspace roots; a wrong-root caller cannot quarantine another session
- owner EOF, explicit shutdown, and project-root disappearance all close admission before backend
  teardown and complete with bounded child cleanup
- persisted numeric PIDs are never signalled or used for automatic stale reclamation
- every wrapper request is bound to its random generation capability, and transport frame, initial
  request, connection, and task counts are bounded
- request IDs are unique and cancellation is exact within a workspace; per-admission tokens retain
  exact disconnect and close semantics
- the regressions for this path are
  [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh) and
  [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh)

Generic process helpers live in [Beam/System.lean](../Beam/System.lean). Kernel-backed stable file locks live in
[Beam/Cli/Lock.lean](../Beam/Cli/Lock.lean); lock files remain after release so contenders always
coordinate on the same inode, while the kernel releases ownership when a process exits. Project
daemon control mutations use a bounded wait so a live but stuck wrapper process produces owner
diagnostics instead of making another mutation wait silently; ordinary attachment does not take
this lock.
`BEAM_CONTROL_LOCK_TIMEOUT_MS` can shorten or lengthen that wait for local debugging. Bundle build
locks intentionally keep the lower-level unbounded helper because another process may legitimately
be compiling a helper bundle. The shell installer's `.install-lock` remains an atomic directory
compatibility boundary: it is never stale-reaped, and a crashed installer requires explicit
operator recovery. Reusable CLI argument parsing lives in
[Beam/Cli/Args.lean](../Beam/Cli/Args.lean). Project-root inference,
Lean toolchain lookup, and Rocq command discovery live in [Beam/Cli/Project.lean](../Beam/Cli/Project.lean).
Shared filesystem path helpers live in [Beam/Path.lean](../Beam/Path.lean). Use them instead of
copying string-prefix checks or raw `IO.FS.realPath` wrappers:

- `resolveExistingPath` resolves an existing path to its canonical spelling.
- `resolvePathAgainstRoot` resolves an absolute path as-is or a relative path under an already
  resolved root.
- `sameFilePath` compares existing paths through canonical spelling and falls back to exact text
  equality for missing paths.
- `pathRelativeToRoot?` and `pathRelativeToRootOrSelf` derive workspace-relative display/cache paths
  with a real directory-boundary check, so `/tmp/foo` does not accidentally match `/tmp/foobar`.

Keep raw path strings only for JSON payloads, diagnostics, and intentionally stable cache keys.
When symlink or platform-alias behavior matters, resolve paths before deriving workspace-relative
strings.

Direct `IO.asTask`, `BaseIO.asTask`, and `EIO.asTask` calls should make their priority explicit.
Use `Task.Priority.dedicated` for blocking or long-lived IO such as process pipe readers, accepted
client handlers, signal watchers, and streaming callback loops. Lean's regular task pool is bounded
and shared with Lake/elaboration work, so a tiny task that blocks in an OS read can still starve
normal-priority work on low-core runners. The cheap regression guard is
[scripts/check-task-priority.sh](../scripts/check-task-priority.sh).

Shared registry, startup-log, and incident paths live in
[Beam/Daemon/Paths.lean](../Beam/Daemon/Paths.lean). Daemon registry management, explicit owner
lifetime, endpoint selection, and explicit non-signalling recovery live in
[Beam/Cli/DaemonManager.lean](../Beam/Cli/DaemonManager.lean). Broker request plumbing,
progress messages, cancellation-on-interrupt, and response failure notes live in
[Beam/Cli/Broker.lean](../Beam/Cli/Broker.lean). User-facing stdout/stderr formatting helpers live
in [Beam/Cli/Output.lean](../Beam/Cli/Output.lean). Doctor, validated/compatible toolchain registry,
install layout/manifest, and MCP config reporting live in
[Beam/Cli/Info.lean](../Beam/Cli/Info.lean). The command dispatch
table lives in [Beam/Cli/Commands.lean](../Beam/Cli/Commands.lean), and [Beam/Cli/Usage.lean](../Beam/Cli/Usage.lean)
owns the help text. Lean command to broker-request projection lives in
[Beam/Cli/LeanOperation.lean](../Beam/Cli/LeanOperation.lean). Install and bundle layout metadata,
typed manifest parsing, install-root ownership checks, and source/installed/invalid runtime
classification live in [Beam/Cli/InstallLayout.lean](../Beam/Cli/InstallLayout.lean). Conservative
installed-state planning and removal lives in
[Beam/Cli/InstallPrune.lean](../Beam/Cli/InstallPrune.lean). Runtime bundle compatibility imports
live in [Beam/Cli/RuntimeBundle.lean](../Beam/Cli/RuntimeBundle.lean); implementation details are
split under [Beam/Cli/RuntimeBundle](../Beam/Cli/RuntimeBundle). Keep source hashing, resolved
toolchain fingerprinting, metadata acceptance, and fallback bundle builds in their focused
submodules instead of growing the umbrella import. Bundle IDs and metadata must include both the
Beam runtime source hash and the resolved Lean/Lake fingerprint so local custom toolchain relinks
and reported identity changes cannot silently reuse stale helpers. The user-facing model is in
[CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md).

Install manifests describe required staged artifacts, not optional future layout. New manifests
write schema 3 and name creation-time toolchain provenance explicitly. Schema 2 remains readable for
identity and `lean-beam prune`, but installer reuse requires the current schema; the compatibility
window and removal trigger live in [COMPATIBILITY.md](COMPATIBILITY.md).
Keep [Beam/Cli.lean](../Beam/Cli.lean) as the executable entry point: parse top-level options,
resolve `BEAM_HOME`, and delegate to `runCommand`.

Installer shell helpers are split by ownership boundary: generic path/style helpers live in
[scripts/install-lib.sh](../scripts/install-lib.sh), write-location prompting and validation live in
[scripts/install-locations.sh](../scripts/install-locations.sh), and MCP client
registration lives in [scripts/install-mcp.sh](../scripts/install-mcp.sh). Keep new client-specific
registration behavior out of [scripts/install-beam.sh](../scripts/install-beam.sh) unless it is
part of the main install orchestration.

What this does not promise:

- it does not promise the daemon will still be alive after all sandboxed wrapper calls have exited
- the guarantee is narrower: overlapping wrapper requests on the same root should survive correctly

## Recommended Test Order

- LSP request / handle / scenario changes: `bash tests/test-lsp.sh`
- Beam broker protocol / stream / barrier changes: `bash tests/test-beam-fast.sh`
- Beam save replay changes: `bash tests/test-beam-save-olean.sh`
- Beam wrapper / install / bundle-resolution changes: `bash tests/test-beam-slow.sh`
- Beam install / runtime layout changes: `bash tests/test-beam-install.sh`
- supported Lean toolchain changes: `bash tests/test-beam-toolchain-compat.sh <toolchain>`
- Rocq broker / wrapper changes: `bash tests/test-beam-rocq.sh`
- maintainer harness / validation wrapper changes: `bash tests/test-maintainer.sh`
- risky local install or wrapper validation: `bash scripts/validate-defensive.sh`
- shell changes: `bash scripts/lint-shell.sh`

Use `bash tests/test-beam.sh` when you want the aggregate default Beam signal.
Keep the focused scripts as the normal local development loop; the aggregate and slow suites are
broader CI or pre-release signals, not prerequisites for every targeted change.

CI uses Node 24-compatible first-party GitHub Actions majors for checkout, setup-node, and cache.
The MCP SDK and conformance jobs' `node-version` is the JavaScript test runtime and may stay pinned
separately from the action runtime.

## Upstream Lean API Backlog

Beam carries a few local workarounds for missing or version-skewed Lean/Lake APIs. When upstream
support lands, prefer deleting the workaround over preserving compatibility branches.

- Lean file-worker `lake setup-file` progress is currently exposed as ordinary information
  diagnostics with a synthetic file-start range. Beam recognizes Lake build-monitor text such as
  `✔ [1/2] Built ...` so MCP/wrapper clients can see cold Lake setup activity during long syncs
  and `runAt` probes.
  This is deliberately brittle. A typed Lean API or LSP notification for setup/build progress,
  including the module/target caption and completion/failure status, would let Beam stop matching
  diagnostic strings.

## Lean Compatibility Shims

Exact validated Lean toolchains live in
[validated-lean-toolchains](../validated-lean-toolchains), while canonical RC and patch admission
lives in [compatible-lean-release-lines](../compatible-lean-release-lines). Use those registries,
not this maintainer note, as the source of truth. The shims below exist because the current release
window spans Lean/Lake API changes; when that window changes, re-check these spots and prefer
deleting obsolete compatibility code over preserving stale branches.

- `Beam/LSP/RunAt.lean`, `Beam/LSP/Goals.lean`, `Beam/LSP/Todo.lean`, and
  `Beam/LSP/Save.lean`:
  `FileSource` instances route through `Lean.Lsp.fileSource p.textDocument` to bridge the older
  `FileIdent` return type and the newer `DocumentUri` API.
- `Beam/Broker/LakeSave.lean`: `hashOfHashable` / `addHashablePureTrace` exist because Lake
  older supported releases lack the newer generic `ComputeHash [Hashable α]` instance that makes plain
  `addPureTrace mod.name` and `addPureTrace mod.pkg.id?` work upstream in newer Lean versions.
- `Beam/LSP/Save.lean`: `emitCForSavedModule` selects between the older `Lean.IR.emitC` API and
  the newer `Lean.Compiler.LCNF.emitC` API.
- `Beam/LSP/Lib/DiagnosticsCompat.lean`: `collectCurrentDiagnosticsCompat` selects between the
  older `EditableDocument.diagnosticsRef` API and the newer
  `EditableDocumentCore.collectCurrentDiagnostics` API.
- `Beam/Broker/Transport.lean`: the transport uses `Std.Internal.UV.TCP` directly because the async
  TCP wrapper moved from `Std.Internal.Async.TCP` to `Std.Async.TCP`.
- `Beam/Broker/LakeSave.lean`: `mkModuleOutputDescrsCompat` selects between the older
  `ModuleOutputDescrs` record shape and the newer shape with `isModule`.

## Process

For commit, PR, and author identity guidance, see [CONTRIBUTING.md](../CONTRIBUTING.md).
