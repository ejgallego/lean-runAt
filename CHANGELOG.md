# Changelog

## Unreleased

Current milestone summary:

- add isolated `$/lean/runAt` execution with internal proof-first, command-fallback basis selection
- keep the public request minimal: `textDocument`, `position`, `text`
- keep the public success payload typed: `success`, `messages`, `traces`, optional `proofState`
- route request-level failures through transport errors instead of the success payload
- validate out-of-document positions as `invalidParams`
- cover stale edit, close, cancellation, and multi-document ordering with repo-local scenario tests
- add optional follow-up handles with wrong-document and stale-worker invalidation coverage
- move most handle coverage into the text scenario DSL, keeping only the successor-handle-on-failure assertion in the Lean API test
- propagate cooperative Lean cancel tokens into isolated command/proof execution and document the non-preemptive model
- add a thin broker/client pair for local agent-driven `runAt` and Rocq goal workflows without speaking raw LSP directly
- add minimal Rocq broker support through `coq-lsp` only, using `proof/goals` over full-text LSP sync
- expose Rocq `proof/goals.command` through broker `goals.text` for intermediate-state probing of tactic prefixes such as `a` in `a; b`
- add a Lean `deps` broker call for workspace dependency-cone planning
- add `lean-save` / `lean-close-save` as a zero-build save path: serialize current worker artifacts directly and write the Lake module trace without shelling out to `lake build`
- make `lean-sync` a real diagnostics barrier and return a compact Lean `fileProgress` summary for the synced version
- add in-memory broker stats with per-backend/per-op counts and latency summaries
- add a small evaluation helper script and document additional upstream Rocq petanque capabilities such as notation analysis
- document conservative multi-file Lean rebuild discipline until stale-dependency integration improves
- add CI running `lake build` and the LSP test surface
