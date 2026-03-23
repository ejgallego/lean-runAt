# Testing

The current test story is good for an alpha repository, but it is recent and mostly end-to-end.

Most of the harness was built over March 10-11, 2026. Coverage is strongest around externally
visible behavior: request semantics, stale-state handling, cancellation, handle invalidation, and
Beam daemon integration.

## Current Coverage

- interactive file-anchored regressions through [tests/test.sh](../tests/test.sh)
- multi-document and async behavior through the scenario DSL in [tests/scenario](../tests/scenario)
- programmable scenario coverage through [RunAt/Scenario.lean](../RunAt/Scenario.lean)
- shuffled concurrent workload coverage through [RunAt/ScenarioStressTest.lean](../RunAt/ScenarioStressTest.lean)
- follow-up handle coverage through [tests/scenario/handleDsl.scn](../tests/scenario/handleDsl.scn),
  [tests/scenario/handleLinearDsl.scn](../tests/scenario/handleLinearDsl.scn),
  [tests/scenario/handleNestedBranchDsl.scn](../tests/scenario/handleNestedBranchDsl.scn),
  [tests/scenario/handleProofBranchDsl.scn](../tests/scenario/handleProofBranchDsl.scn),
  [tests/scenario/handleSearchCancelDsl.scn](../tests/scenario/handleSearchCancelDsl.scn),
  [tests/scenario/handleCancelDsl.scn](../tests/scenario/handleCancelDsl.scn), and
  [tests/scenario/handleInvalidationDsl.scn](../tests/scenario/handleInvalidationDsl.scn)
- handle-specific API assertions in [RunAt/HandleApiTest.lean](../RunAt/HandleApiTest.lean) and
  [RunAt/HandleRestartTest.lean](../RunAt/HandleRestartTest.lean)
- nested handle failure-shape assertions in
  [RunAt/NestedHandleFailureTest.lean](../RunAt/NestedHandleFailureTest.lean)
- fast Beam daemon smoke coverage in [tests/test-broker-fast.sh](../tests/test-broker-fast.sh),
  including completed barrier progress vs partial request progress expectations
- GitHub Actions main coverage in [.github/workflows/ci.yml](../.github/workflows/ci.yml), whose
  Linux job set now also runs on `macos-latest`
- GitHub Actions broker smoke coverage on both Ubuntu and macOS through the matrixed
  `broker-fast` job in [.github/workflows/ci.yml](../.github/workflows/ci.yml)
- slower wrapper/install coverage in [tests/test-broker-slow.sh](../tests/test-broker-slow.sh)
- experimental Lean broker `request_at` coverage through
  [RunAtTest/Broker/SmokeTest.lean](../RunAtTest/Broker/SmokeTest.lean) and
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), including whitelisted request
  success, stdin JSON extras, stats accounting, and rejection of user-supplied `textDocument` /
  `position` overrides
- explicit `lean-beam sync` regression coverage for diagnostics-wait behavior and compact
  `fileProgress.done` reporting in [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh),
  including stale-import cases where the diagnostics barrier must fail instead of reporting a
  partial success
- wrapper coverage for alpha Lean handle mint / continue / linear-continue / release flows in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- wrapper coverage for the installed `lean-beam-search` helper in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- zero-build save regression coverage in [tests/test-broker-save-olean.sh](../tests/test-broker-save-olean.sh),
  including exact-target replay, downstream importer reuse after daemon shutdown, and a timed
  race where a mid-save edit must leave the saved module stale for later `lake build`
- repo-local Codex worktree discipline coverage in [tests/test-codex-harness.sh](../tests/test-codex-harness.sh),
  which checks maintainer workflow helpers that start new tasks in dedicated worktrees and reject
  the primary checkout unless explicitly overridden
- lightweight search-workload latency reporting in
  [RunAtTest/Scenario/SearchWorkloadReport.lean](../RunAtTest/Scenario/SearchWorkloadReport.lean)
  and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

## Search-Style Coverage

The repo now has a seeded MCTS-style proof-search regression in
[RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean).

That test exercises:

- repeated playouts from one preserved proof handle
- non-linear branching from the same recovered basis
- linear continuation on derived handles
- semantic-failure probes that must not mutate preserved handles
- linear failure probes that must consume the current handle
- cancellation on branched proof-search handles, including preserved-parent reuse and linear-handle consumption
- explicit release of explored side branches
- stale invalidation of live search handles after a document edit
- nested semantic failures that preserve proof-state payloads, suppress successor handles, and still distinguish non-linear from linear handle reuse

This sits on top of earlier search-enabling coverage:

- non-linear proof branching in
  [tests/scenario/handleProofBranchDsl.scn](../tests/scenario/handleProofBranchDsl.scn)
- programmable request orchestration through [RunAt/Scenario.lean](../RunAt/Scenario.lean)
- shuffled concurrent workload coverage in
  [RunAt/ScenarioStressTest.lean](../RunAt/ScenarioStressTest.lean)
- nested multi-goal cursor corner cases in
  [tests/interactive/proofNestedConstructorOrder.lean](../tests/interactive/proofNestedConstructorOrder.lean),
  [tests/interactive/proofNestedBulletWhitespace.lean](../tests/interactive/proofNestedBulletWhitespace.lean), and
  [tests/interactive/proofNestedRightSibling.lean](../tests/interactive/proofNestedRightSibling.lean)
- nested right-sibling handle continuation in
  [tests/scenario/handleNestedRightBranchDsl.scn](../tests/scenario/handleNestedRightBranchDsl.scn)

What still does not exist:

- a benchmark-style test for much larger search trees
- a search test that models a full UCT scoring policy rather than seeded playout branching
- performance assertions around many thousands of successor handles

So the current state is: the repo now tests a real search-style handle workflow, but it is still a
correctness regression, not yet a performance benchmark.

## Broker Suites

- start with [tests/test-broker-fast.sh](../tests/test-broker-fast.sh) for broker-stream, barrier,
  and request-stream contract changes; this is the quickest broker signal
- add [tests/test-broker-slow.sh](../tests/test-broker-slow.sh) when the change touches wrapper,
  install, or bundle-resolution behavior
- use [tests/test-broker-rocq.sh](../tests/test-broker-rocq.sh) for Rocq broker and wrapper
  coverage, including `coq-lsp` discovery from project-local `_opam` roots and the active PATH
- use [tests/test-broker.sh](../tests/test-broker.sh) to execute both suites together before
  landing a broader broker-facing change
- use [scripts/lint-shell.sh](../scripts/lint-shell.sh) when you change shell wrappers, installer,
  or shell-based test harnesses; CI runs the same `shellcheck` pass

## Important Next Gap

If Monte Carlo style proof search is an important use case, the next missing regression is a larger
search workload that:

- starts from one preserved proof basis
- performs many more `runWith` playouts than the current seeded regression
- branches both linearly and non-linearly at greater depth
- mixes semantic failure, success, cancellation, and stale invalidation
- verifies that old and successor handles behave correctly under heavier branching pressure
- begins to approximate realistic tree-policy plus playout workloads rather than a small correctness loop

That would move the repo from “search-style correctness coverage exists” toward “search workloads
are stressed in a way that looks like real proof search.”
