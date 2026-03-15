# runAt

`runAt` is an alpha Lean LSP extension with a local `lean-beam` workflow layer on top.

This repository is public because the code is useful, but it is still experimental. The central
idea is small, typed, isolated execution for Lean, with a conservative local broker and wrapper for
practical workflows.

## What This Repo Is For

- one small Lean request at the center: `$/lean/runAt`
- a local Beam broker and CLI for Lean workflows
- a narrow auxiliary Rocq goal-probe surface through the same `lean-beam` wrapper
- agent-oriented local workflows built around the installed wrapper, not around raw editor state

Current scope, limitations, and direction live in [docs/STATUS.md](docs/STATUS.md).

## Start Here

- using the project as a human: stay in this README, then go to [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md) for the Lean workflow contract
- contributing as a human: read [CONTRIBUTING.md](CONTRIBUTING.md), then [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- working as an AI agent or reviewing agent workflow: start with [AGENTS.md](AGENTS.md), then the relevant skill doc

## Human-Facing Surface

For most users, the practical entry point is `lean-beam`.

Common Lean commands:

```bash
lean-beam ensure
lean-beam hover "Foo.lean" 10 2
lean-beam goals-prev "Foo.lean" 10 2
lean-beam run-at "Foo.lean" 10 2 "exact trivial"
lean-beam sync "MyPkg/Sub/Module.lean"
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam save "MyPkg/Sub/Module.lean"
```

Read those commands like this:

- `lean-beam run-at` tries speculative Lean text without editing the file
- `lean-beam sync` is the explicit on-disk edit barrier after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers

When `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may include
`error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan` to suggest a
cheap direct-import recovery path before falling back to `lake build`.

Detailed Lean workflow guidance lives in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).
The narrower Rocq surface lives in [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md).

## Install

Use the installer from the repo root:

```bash
./scripts/install-beam.sh
```

Optional flags:

```bash
./scripts/install-beam.sh --codex
./scripts/install-beam.sh --claude
./scripts/install-beam.sh --all-skills
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.29.0-rc6
./scripts/install-beam.sh --all-supported
```

The installer:

- puts `lean-beam` and `lean-beam-search` in `~/.local/bin`
- stages an immutable runtime under `BEAM_INSTALL_ROOT`, default `~/.local/share/beam`
- prebuilds supported Lean bundle(s) under `BEAM_INSTALL_ROOT/state/install-bundles`
- installs bundled agent skills only when requested

More install and runtime-resolution detail lives in [docs/STATUS.md](docs/STATUS.md) and
[skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).

## Which Layer To Use

- Use the Lean LSP extension directly if you already own the LSP session and want the smallest typed
  surface.
- Use the Beam broker if you want one long-lived local process per project root.
- Use `lean-beam` if you want the practical workflow surface today.

The public request and response types live in [RunAt/Protocol.lean](RunAt/Protocol.lean). The Lean
plugin implementation lives in [RunAt/Plugin.lean](RunAt/Plugin.lean).

## Build And Test

Build:

```bash
lake build
```

Core tests:

```bash
bash tests/test.sh
```

Broker and wrapper suites:

```bash
bash tests/test-broker-fast.sh
bash tests/test-broker-slow.sh
bash tests/test-broker.sh
bash scripts/lint-shell.sh
```

More detail on test coverage and gaps lives in [docs/TESTING.md](docs/TESTING.md).

## Documentation Map

- [docs/STATUS.md](docs/STATUS.md): current scope, limitations, and direction
- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md): Lean workflow contract
- [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md): auxiliary Rocq workflow surface
- [CONTRIBUTING.md](CONTRIBUTING.md): commit, PR, and contributor workflow guidance
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): AI-first maintainer workflow and harness guidance
- [docs/TESTING.md](docs/TESTING.md): test coverage and gaps
- [docs/experimental.md](docs/experimental.md): unstable experimental surfaces
- [AGENTS.md](AGENTS.md): repo-specific agent instructions

## License

Apache-2.0. See [LICENSE](LICENSE).
