# Testing

The repository now treats testing as three distinct surfaces:

- `LSP`: every method registered by the Lean plugin in [RunAt/Plugin.lean](../RunAt/Plugin.lean)
- `Beam`: broker, daemon/client protocol, CLI wrapper, install/runtime packaging, toolchain support,
  and Rocq support
- `Maintainer`: local workflow helpers and defensive validation wrappers that are not part of the
  product surface

This split is organizational. It is also now the only supported top-level test layout.

## LSP Surface

The LSP surface is everything registered in [RunAt/Plugin.lean](../RunAt/Plugin.lean), including:

- `$/lean/runAt`
- goals-before / goals-after requests
- follow-up handle mint / continue / release requests
- Beam-facing internal LSP helpers such as `saveArtifacts`, `saveReadiness`, and `directImports`

Primary entrypoint:

- [tests/test-lsp.sh](../tests/test-lsp.sh)

Current LSP coverage includes:

- interactive file-anchored regressions through [tests/interactive](../tests/interactive) and
  [RunAtTest/TestRunner.lean](../RunAtTest/TestRunner.lean)
- multi-document and async scenario coverage through [tests/scenario](../tests/scenario) and
  [RunAtTest/ScenarioRunner.lean](../RunAtTest/ScenarioRunner.lean)
- programmable scenario API coverage in [RunAtTest/Scenario/ApiTest.lean](../RunAtTest/Scenario/ApiTest.lean)
- shuffled concurrent workload coverage in
  [RunAtTest/Scenario/StressTest.lean](../RunAtTest/Scenario/StressTest.lean)
- handle API, restart, lifecycle, and nested-failure coverage in
  [RunAtTest/Handle/ApiTest.lean](../RunAtTest/Handle/ApiTest.lean),
  [RunAtTest/Handle/RestartTest.lean](../RunAtTest/Handle/RestartTest.lean),
  [RunAtTest/Handle/LifecycleTest.lean](../RunAtTest/Handle/LifecycleTest.lean), and
  [RunAtTest/Handle/NestedHandleFailureTest.lean](../RunAtTest/Handle/NestedHandleFailureTest.lean)
- full registered LSP request coverage in
  [RunAtTest/RequestSurfaceTest.lean](../RunAtTest/RequestSurfaceTest.lean)
- search-style handle workflows in
  [RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean)
- parallel multi-sorry speculative solve plus atomic batch-edit coverage in
  [RunAtTest/Scenario/ParallelGrindBatchTest.lean](../RunAtTest/Scenario/ParallelGrindBatchTest.lean),
  which currently anchors the outer declarations from the `10` declaration-level `sorry`
  diagnostics, scans the file text for the exact `100` branch-local `sorry` tokens, launches one
  speculative request per token, and then mirrors those exact token replacements in one atomic
  batched `didChange`
- lightweight search-workload latency reporting in
  [RunAtTest/Scenario/SearchWorkloadReport.lean](../RunAtTest/Scenario/SearchWorkloadReport.lean)
  and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

### Kinds Of LSP Tests

The current LSP suite is mostly a black-box integration suite around the Lean server plugin. It is
not primarily a unit-test suite.

The main LSP test kinds are:

- golden file-anchored request tests through
  [tests/interactive](../tests/interactive) and
  [RunAtTest/TestRunner.lean](../RunAtTest/TestRunner.lean), where inline directives drive requests
  and stderr output is diffed against checked-in golden files
- stateful scenario DSL tests through
  [tests/scenario](../tests/scenario) and
  [RunAtTest/ScenarioRunner.lean](../RunAtTest/ScenarioRunner.lean), where `.scn` scripts exercise
  open / change / sync / close / send / await / cancel flows over one or more documents
- programmatic scenario integration tests through
  [RunAtTest/Scenario/ApiTest.lean](../RunAtTest/Scenario/ApiTest.lean) and
  [RunAtTest/RequestSurfaceTest.lean](../RunAtTest/RequestSurfaceTest.lean), where Lean code calls
  the scenario API directly instead of going through the `.scn` DSL
- targeted handle invariant tests through
  [RunAtTest/Handle/ApiTest.lean](../RunAtTest/Handle/ApiTest.lean),
  [RunAtTest/Handle/LifecycleTest.lean](../RunAtTest/Handle/LifecycleTest.lean),
  [RunAtTest/Handle/RestartTest.lean](../RunAtTest/Handle/RestartTest.lean), and
  [RunAtTest/Handle/NestedHandleFailureTest.lean](../RunAtTest/Handle/NestedHandleFailureTest.lean)
- concurrency and stale-state correctness tests through
  [RunAtTest/Scenario/StressTest.lean](../RunAtTest/Scenario/StressTest.lean)
- search-style correctness tests through
  [RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean)
  and the workload-report checks in
  [RunAtTest/Scenario/SearchWorkloadReport.lean](../RunAtTest/Scenario/SearchWorkloadReport.lean)

What the LSP suite currently does not emphasize:

- fine-grained pure unit tests
- property-based tests
- fuzzing
- benchmark-style performance assertions

Run the LSP surface when the change touches:

- request semantics
- proof-vs-command basis selection
- position handling
- cancellation
- handle invalidation or lifecycle
- stale snapshot behavior
- per-request isolation
- any method in [RunAt/Plugin.lean](../RunAt/Plugin.lean)

## Beam Surface

The Beam surface starts above the plugin boundary. It covers:

- broker transport and request contracts
- Beam daemon lifecycle and stream handling
- `lean-beam` CLI and wrapper UX
- save replay, runtime bundle resolution, and install layout
- supported-toolchain validation
- Rocq broker and wrapper behavior

### Default Beam Entrypoints

- [tests/test-beam-fast.sh](../tests/test-beam-fast.sh): fast broker stream, barrier, and request-contract coverage
- [tests/test-beam-slow.sh](../tests/test-beam-slow.sh): wrapper, sandbox-wrapper, and save-replay coverage
- [tests/test-beam-install.sh](../tests/test-beam-install.sh): installer and installed-runtime layout
- [tests/test-beam.sh](../tests/test-beam.sh): aggregate default Beam surface

### Additional Beam Lanes

- [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) `<toolchain>`:
  supported-toolchain bundle validation
- [tests/test-beam-rocq.sh](../tests/test-beam-rocq.sh): Rocq broker and wrapper coverage

Current Beam coverage includes:

- fast Beam daemon smoke, request-stream, save-stream, startup-handshake, and tracked-diagnostic
  dedup coverage through [tests/test-beam-fast.sh](../tests/test-beam-fast.sh),
  [RunAtTest/Broker/SmokeTest.lean](../RunAtTest/Broker/SmokeTest.lean),
  [RunAtTest/Broker/SaveStreamTest.lean](../RunAtTest/Broker/SaveStreamTest.lean),
  [RunAtTest/Broker/RequestStreamContractTest.lean](../RunAtTest/Broker/RequestStreamContractTest.lean),
  [RunAtTest/Broker/StartupHandshakeTest.lean](../RunAtTest/Broker/StartupHandshakeTest.lean), and
  [RunAtTest/Broker/StreamDedupTest.lean](../RunAtTest/Broker/StreamDedupTest.lean)
- wrapper coverage for `lean-run-at`, handle mint / continue / release, progress forwarding,
  hidden compatibility aliases, stats accounting, `doctor`, and stale-import recovery hints in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), which now aggregates the focused
  wrapper slices
  [tests/test-beam-wrapper-probe.sh](../tests/test-beam-wrapper-probe.sh),
  [tests/test-beam-wrapper-runtime.sh](../tests/test-beam-wrapper-runtime.sh),
  [tests/test-beam-wrapper-sync-save.sh](../tests/test-beam-wrapper-sync-save.sh),
  [tests/test-beam-wrapper-handle.sh](../tests/test-beam-wrapper-handle.sh), and
  [tests/test-beam-wrapper-diagnostics.sh](../tests/test-beam-wrapper-diagnostics.sh)
- Linux-only PID-isolated sandbox wrapper coverage in
  [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh)
- zero-build save replay and stale-save race coverage in
  [tests/test-broker-save-olean.sh](../tests/test-broker-save-olean.sh)
- install flow, installed runtime layout, manifest metadata, `supported-toolchains`, and `doctor`
  coverage in [tests/test-beam-install.sh](../tests/test-beam-install.sh)
- supported-toolchain bundle-install coverage in
  [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh)
- Rocq wrapper and broker smoke coverage in
  [tests/test-beam-wrapper-rocq.sh](../tests/test-beam-wrapper-rocq.sh) and
  [RunAtTest/Broker/RocqSmokeTest.lean](../RunAtTest/Broker/RocqSmokeTest.lean)

Run the Beam surface when the change touches:

- Beam broker protocol or transport
- request / progress / diagnostics stream behavior
- Beam daemon session or restart logic
- wrapper CLI behavior
- bundle resolution or install layout
- `doctor`, `supported-toolchains`, or toolchain gating
- save replay or save barrier behavior
- Rocq integration

## Maintainer Surface

The maintainer surface is not part of the public or agent-facing product story. It covers local
workflow helpers that exist to keep contributors and maintainers safe:

- [tests/test-maintainer.sh](../tests/test-maintainer.sh)
- [tests/test-codex-harness.sh](../tests/test-codex-harness.sh)
- [tests/test-validate-defensive.sh](../tests/test-validate-defensive.sh)

The aggregate maintainer runner skips
[tests/test-codex-harness.sh](../tests/test-codex-harness.sh) when the current checkout has tracked
edits, because the harness regression intentionally verifies that new task worktrees start from a
clean primary checkout.

Run these when the change touches:

- [scripts/codex-harness.sh](../scripts/codex-harness.sh)
- [scripts/codex-session-start.sh](../scripts/codex-session-start.sh)
- [scripts/validate-defensive.sh](../scripts/validate-defensive.sh)

These checks are intentionally separate from the default product-surface runners.

## CI Map

The current GitHub Actions workflow in [.github/workflows/ci.yml](../.github/workflows/ci.yml)
maps to the testing surfaces like this:

- `build-and-test`: [tests/test-lsp.sh](../tests/test-lsp.sh)
- `beam-fast`: [tests/test-beam-fast.sh](../tests/test-beam-fast.sh)
- `beam-slow`: [tests/test-beam-slow.sh](../tests/test-beam-slow.sh)
- `beam-install`: [tests/test-beam-install.sh](../tests/test-beam-install.sh)
- `beam-toolchain-compat`: [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) `<toolchain>`
- `beam-rocq`: [tests/test-beam-rocq.sh](../tests/test-beam-rocq.sh)
- `shell-lint`: [scripts/lint-shell.sh](../scripts/lint-shell.sh)

## Coverage Gaps

The main current gaps are:

- the search-style LSP surface still has correctness-heavy coverage, but not a larger benchmark-style
  workload with much deeper branching pressure
- the Beam `deps` path is still mostly covered by happy-path smoke checks even though
  [Beam/Broker/Deps.lean](../Beam/Broker/Deps.lean) is explicitly a stopgap scanner
- maintainer-surface regressions are documented and runnable, but they are still separate from the
  default product CI lanes
