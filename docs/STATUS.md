# Status

Lean Beam is alpha code and still mostly a personal experiment.

The repository is public for collaboration and reuse, but it is not yet a polished or stable
general-purpose product. The main goal is still a small, type-safe, isolated execution surface for
Lean, with a thin local Beam daemon around it for low-cost experimentation.

## Current Scope

- standalone Lean plugin for `$/lean/runAt`
- internal proof-first, command-fallback basis selection
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- local Beam daemon/client pair for Lean and Rocq workflows
- alpha Lean wrapper commands for follow-up handle continuation and release
- installed `lean-beam-search` helper for shorter shell branching/playout workflows
- explicit Lean `lean-beam sync` Beam-daemon barrier with diagnostics wait and compact `fileProgress` reporting
- `lean-beam open-files` Beam-daemon introspection for tracked documents, including `saved` / `notSaved`,
  direct Lean deps when available, whether the current synced version has been checkpointed with
  `lean-beam save`, and Lean save preflight fields `saveEligible` / `saveReason` / `saveModule`;
  already-known tracked files are checked incrementally against the on-disk text and carry the last
  observed compact `fileProgress`
- compact Lean Beam-daemon `fileProgress` reporting on other slow Lean wrapper calls when matching
  `$/lean/fileProgress` notifications were observed while the request was pending
- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation

## API Notes

The base request is intentionally small:

- one document
- one position
- one Lean text payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

Follow-up handles exist, but they should be treated as alpha support APIs rather than as a frozen
long-term contract. Current handle behavior is:

- opaque
- document-bound
- invalidated by same-document edits
- invalidated by document close
- invalidated by worker restart or Beam daemon restart
- exact continuation requires an explicit handle path; separate `lean-beam run-at` calls do not chain
  through hidden state

The local Beam daemon convenience layer is also still alpha. In particular, `lean-beam sync` is now the
supported on-disk edit barrier for Lean files: it waits for diagnostics for the synced version and
streams fresh diagnostics to clients such as the CLI without replaying them in the final JSON, and
returns a compact `fileProgress` summary rather than exposing the full underlying LSP notification
stream. By default `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` stream only errors for the
current request; `+full` widens that stream to warnings, info, and hints. The Beam daemon now also
forwards compact `fileProgress` updates live to streaming clients. For programmatic local consumers,
the preferred machine-readable surface is the JSON stream exposed
by `beam-client request-stream`; the wrapper stderr format should be treated as human-facing.
Other slow Lean Beam daemon calls may attach a compact top-level `fileProgress` summary when they had
to wait on the same Lean elaboration progress. For non-barrier calls this summary may be partial,
because the request can return before the whole file reaches `done = true`. This should be read as a
Lean-side wrapper contract. The wrapper now also exposes alpha Lean handle commands for
continuation, linear playout, and release; these are useful for search-style workflows but are still
more fragile than the base one-shot request. Rocq support remains narrower and does not currently
expose an equivalent public sync command in the wrapper.

If Lean cannot reach a completed diagnostics barrier for the synced version, for example because an
imported target is stale and rebuild failure kills the worker session, `lean-beam sync` now fails rather
than reporting a partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed past that
incomplete barrier. Lean sync failures may also attach a cheap direct-import recovery hint in
`error.data`, based on broker-tracked saved dependency boundaries, to suggest `save` / `refresh` /
`lake build` next steps without running a full workspace dependency scan.

`lean-beam sync`, `lean-beam save`, and `lean-beam close-save` should be read as a progression rather than as
unrelated commands: `lean-beam sync` establishes the synced diagnostics-complete saved file snapshot,
`lean-beam save` checkpoints that snapshot for one module, and `lean-beam close-save` does the same
checkpoint and then closes the tracked file. This remains a narrower contract than a full batch
rebuild: the save path reports the saved `version` and `sourceHash`. For an unchanged file,
`lake build Foo.lean` should replay that saved module, and Lake should be able to reuse it when
rebuilding importers. If the file changes during the save, the resulting checkpoint remains
coherent for the older snapshot and later `lake build` should rebuild it as stale.

If a speculative probe looks right and should become real source, the current contract is still:
make the real edit in the file, save it, then `lean-beam sync`. The intended future direction is to make
that handoff cheap by reusing speculative execution rather than replaying it from scratch.

`lean-beam save` is module-oriented, not file-oriented. `lean-beam sync` can operate on an arbitrary file the
daemon can open, but `lean-beam save` requires a file that Lake resolves to a module in the current
workspace package graph. Standalone `.lean` files outside that graph are not valid save targets.

## Known Limitations

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Supported Lean toolchains are listed in `supported-lean-toolchains`.
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`,
  because the plugin uses internal Lean APIs.
- The install script prebuilds an installed-skill bundle cache for that pinned toolchain by
  default.
- The install script also accepts `--toolchain <toolchain>` for explicit supported bundles and
  `--all-supported` for the full validated allowlist.
- Runtime requests first try that installed-skill bundle cache, then fall back to a project-local
  runtime bundle under `.beam/bundles/` for supported toolchains.
- Unsupported Lean toolchains fail early instead of attempting an opportunistic build.
- `lean-beam supported-toolchains` lists the validated toolchains, and `lean-beam doctor`
  reports support state, bundle source, and bundle key inputs.
- Bundle rebuild keys intentionally exclude the full `.lake/packages` checkout tree and instead use
  the runtime source tree plus `lean-toolchain`, `lake-manifest.json`, and
  `supported-lean-toolchains`.
- The first use of a supported but not-yet-prebuilt toolchain must still build a matching local
  fallback bundle.
- On a cold machine, that local fallback build may need network access to fetch dependencies.
- In sandboxed agent environments, Beam daemon startup itself may require elevated permissions even when
  the installed bundle and project-local `.beam` paths resolve correctly.
- A startup failure that reports `operation not permitted` through `.beam/beam-daemon-startup.log` is
  usually an environment restriction, not a bundle-resolution mismatch.
- Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- The Beam daemon is single-root and keeps a conservative single active session per backend.
- Zero-build `lean-beam save` helps checkpoint one module, but it is not a whole-workspace freshness
  solution.
- If you edit a dependency of the target file, downstream speculative results should be treated as
  stale until rebuild or checkpoint.
- Lean does not yet expose a better plugin-facing restart-required / stale-dependency hook here, so
  this limitation is currently explicit and user-visible.
- agent-skill distribution currently relies on a local checkout and local install script; it is not
  yet published through a registry or marketplace flow.
- Rocq support is currently limited to goal inspection through `coq-lsp`; it is not yet a full
  stateful execution layer.

## Direction

Near-term work is mostly about hardening and simplifying:

- keep the base `runAt` request small
- preserve strict per-request isolation
- reduce packaging and workspace rough edges
- publish a smoother distribution path, likely GitHub-backed install for Codex and plugin marketplace packaging for Claude
- improve stale-dependency handling
- replace broker-side diagnostics/fileProgress barrier inference with a stronger backend-facing
  readiness primitive, so `lean-beam sync` / `lean-beam save` can trust one authoritative completion signal
  instead of reconstructing barrier completeness from multiple LSP channels
- keep Beam-daemon-side conveniences useful without turning them into a large public surface too early
- add a short comparison against Pantograph in the docs, to clarify where `runAt` fits among nearby Lean tooling

## Roadmap / TODO

Current release priorities:

1. documentation polish for release readiness
2. AI/human harness polish for maintainer workflows
3. stability fixes only where they materially improve release confidence

Near-term TODO:

- finish the human-facing docs split so README stays human-only and maintainer or agent workflow
  detail stays in contributor, development, and skill docs
- decide whether the new README still needs a short architecture note, or whether `docs/STATUS.md`
  plus `docs/DEVELOPMENT.md` are enough
- tighten the AI-first harness story so the preferred maintainer entrypoints are obvious for both
  humans and AI agents
- investigate and fix the intermittent `handleProofBranchDsl` CI failure if it reappears
- surface `syncBarrierIncomplete` recovery hints more clearly in the human-facing CLI path, not just
  in `error.data`
- continue validating every supported Lean toolchain in CI before expanding the allowlist further
- replace the broker's remaining stopgap dependency and readiness logic with stronger Lake or
  backend-facing primitives when Lean exposes them
