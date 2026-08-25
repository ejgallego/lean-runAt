# Rocq Beam

Rocq Beam is an optional auxiliary tool in the Lean Beam repository. Its purpose is narrow:
help port Rocq developments to Lean by giving agents cheap Rocq proof-state inspection while the
main Lean Beam workflow remains focused on Lean.

Rocq Beam is not a second full execution layer. It exposes saved-file goal probes through
`coq-lsp` and the `lean-beam` wrapper, and it deliberately does not try to mirror Lean
`run-at`, handle continuation, or sync/checkpoint behavior.

## Install

The default agent skill install is Lean-only:

```bash
./scripts/install-beam.sh --codex
./scripts/install-beam.sh --claude
./scripts/install-beam.sh --pi
./scripts/install-beam.sh --opencode
./scripts/install-beam.sh --vibe
./scripts/install-beam.sh --all-skills
```

Install the optional Rocq skill by adding `--rocq-skill` to a selected agent target:

```bash
./scripts/install-beam.sh --codex --rocq-skill
./scripts/install-beam.sh --claude --rocq-skill
./scripts/install-beam.sh --pi --rocq-skill
./scripts/install-beam.sh --opencode --rocq-skill
./scripts/install-beam.sh --vibe --rocq-skill
./scripts/install-beam.sh --all-skills --rocq-skill
```

`--rocq-skill` is only a modifier. It must be paired with `--codex`, `--claude`, `--pi`,
`--opencode`, `--vibe`, `--all-skills`, or an interactive skill target.

General installer locations, MCP registration, and toolchain options are documented in
[SETUP.md](SETUP.md).

## Rocq Setup

Rocq Beam uses `coq-lsp`; do not use `coqtop` as a fallback. The wrapper resolves `coq-lsp` from
the target project's local `_opam` when available, then from `PATH`. You can also set
`BEAM_ROCQ_CMD` to an explicit `coq-lsp` path.

For this repository's local Rocq test fixtures, the helper setup is:

```bash
bash tests/setup-rocq-opam.sh
```

## Workflow

Rocq commands are available through the same installed `lean-beam` wrapper:

```bash
# keep this foreground owner running in one terminal/session
lean-beam ensure rocq --hold

# issue probes from another terminal/session
lean-beam doctor rocq
lean-beam rocq-goals-after "Demo.v" 2 8
lean-beam rocq-goals-prev "Demo.v" 2 8
lean-beam rocq-goals-prev "Demo.v" 2 8 "intro x."
```

The holder is the explicit owner of the wrapper daemon and its `coq-lsp` backend. Interrupt it, or
run `lean-beam shutdown`, when the session is finished. Ordinary wrapper commands attach to that
session and do not start a daemon implicitly.

Use `rocq-goals-after` to inspect goals after an existing sentence. Use `rocq-goals-prev` to
inspect goals before a sentence, or with extra text to inspect an intermediate tactic prefix while
porting a Rocq proof step to Lean.

The source-file model is simple:

- save the `.v` file before each new probe
- coordinates are LSP-style and 0-based
- `lean-beam` only sees the on-disk Rocq file, not unsaved editor buffers
- each goal probe is isolated; do not rely on hidden mutable proof-session state between probes

## Limits

Current Rocq support is goals-only:

- no Rocq `run-at` wrapper command
- no Rocq `sync` wrapper command
- no Rocq handle or continuation surface
- no direct raw-LSP or raw-JSON workflow contract for users
- no fallback executor besides `coq-lsp`

Useful upstream Rocq/Petanque methods such as notation analysis, premises, AST inspection, and
`petanque/run_at_pos` may be considered later, but they are not part of the current Rocq workflow
surface.
