# Experimental Commands

These commands are expert-only and explicitly unstable.

They do not extend the stable Lean plugin `runAt` surface. They live in the local Beam daemon as
broker-side conveniences for debugging and exploration.

`lean-beam request-at` is an unstable broker escape hatch for expert debugging. It does not widen the
stable `runAt` contract.

Some unsupported or broken compatibility extensions may still exist in the tree for tests or local
maintainer workflows. Treat those as implementation leftovers, not as experimental API candidates.
The current example is the hidden `lean-deps` compatibility alias: you can use it at your own risk
to extract full deps, but there are no guarantees and the information is likely broken.

## `lean-beam request-at`

`lean-beam request-at` forwards a small whitelisted set of standard Lean LSP requests against the current
on-disk file after syncing that file through the Beam daemon.

Prefer the stable `lean-beam hover`, `lean-beam goals-prev`, and `lean-beam goals-after` wrappers for common
read-only inspection. `lean-beam request-at` remains the unstable escape hatch for expert use and for
the other whitelisted methods below.

Use the stable goals commands for proof state. `lean-beam request-at` is not the path for Lean goals.

Current command shape:

```bash
lean-beam request-at <path> <line> <character> <method> [params-json|-]
```

- `<line>` and `<character>` use Lean/LSP `Position` semantics
- `<method>` must currently be one of:
  - `textDocument/definition`
  - `textDocument/hover`
  - `textDocument/references`
- `[params-json|-]` is optional raw JSON
  - omit it for methods such as `textDocument/hover` and `textDocument/definition`
  - pass `-` to read the JSON object from stdin

The Beam daemon injects:

- `textDocument`
- `position`

So user-supplied `params` must be either:

- a JSON object containing only the extra method-specific fields, or
- `null`

The broker rejects `params.textDocument` and `params.position` so one request shape stays tied to
the CLI path/line/character arguments.

Examples:

```bash
lean-beam request-at "SaveSmoke/A.lean" 2 18 textDocument/definition
printf '%s\n' '{"context":{"includeDeclaration":true}}' | \
  lean-beam request-at "SaveSmoke/A.lean" 2 18 textDocument/references -
```

## Stability

This is intentionally not part of the stable `runAt` API contract yet.

Current limits:

- Lean backend only
- read-only request whitelist only
- raw JSON request extras and raw JSON responses
- intended for expert debugging, not normal client integration
- no compatibility promise on the broker payload shape beyond the current experiment

If usage proves real, the likely next step is not “forward everything”. The next step would be
small typed commands for the concrete cases that users actually need.
