# Lean Beam

Lean Beam provides a Claude/Codex skill and local workflow layer for efficient interaction with
Lean 4. Under the hood, it combines a Lean 4 LSP server extension, the `$/lean/runAt` request for
cheap speculative execution, and a thin local broker that exposes a more idiomatic CLI and agent
surface over Lean's LSP and Beam-specific extensions.

Lean Beam is aimed at agent-heavy workflows such as proof repair,
porting from other systems to Lean, proof-search experimentation
including Monte Carlo Tree Search (MCTS), and autoformalization. For
agents making many edits to Lean files, Lean Beam can provide
asymptotic savings over repeating `lake build` after every change; see
the [cost model and workflow details](skills/lean-beam/references/workflow-details.md#cost-model).

Lean Beam started as a personal internal project and is now published for public use. It is not an
official Lean FRO product, the code remains experimental, and you should use it at your own risk.

Feedback is welcome; feel free to open issues or let us know what you think on Zulip.

## Install

Run the installer from the repo root:

```bash
./scripts/install-beam.sh
```

That installs:

- `lean-beam` and `lean-beam-search` into `~/.local/bin`
- an immutable runtime under `BEAM_INSTALL_ROOT`, default `~/.local/share/beam`
- a prebuilt bundle for the repo-pinned supported Lean toolchain

Use `--codex`, `--claude`, or `--all-skills` to install the bundled agent skills:

```bash
./scripts/install-beam.sh --codex
./scripts/install-beam.sh --claude
./scripts/install-beam.sh --all-skills
```

Use `--toolchain <toolchain>` or `--all-supported` to prebuild additional validated Lean bundles:

```bash
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.29.0-rc6
./scripts/install-beam.sh --all-supported
```

## Supported Toolchains

Lean Beam only serves Lean toolchains listed in [`supported-lean-toolchains`](supported-lean-toolchains).
Inspect the validated allowlist with:

```bash
lean-beam supported-toolchains
```

The current repo allowlist is:

```text
leanprover/lean4:v4.29.0-rc6
leanprover/lean4:v4.29.0-rc5
```

If you are unsure which runtime bundle is active or why a toolchain is rejected, use:

```bash
lean-beam doctor
```

## Agent-Facing Surface

For most agent-oriented workflows, the practical entry point is `lean-beam` together with the
workflow guidance in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).

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

Multiline and handle-oriented wrapper ergonomics:

```bash
# for multiline probe text, prefer stdin
printf 'example : True := by\n  trivial\n' | lean-beam run-at "Foo.lean" 10 2 --stdin

# for exact continuation, prefer a handle file
lean-beam run-at-handle "Foo.lean" 10 2 "constructor"
lean-beam run-with "Foo.lean" --handle-file handle.json "exact trivial"
```

Read those flags like this:

- `--stdin` is the normal multiline path for speculative Lean text
- `--handle-file <path>` is the normal handle path for exact continuation and release
- deeper shell-oriented variants and debugging knobs live in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md) and the linked reference docs

When `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may include
`error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan` to suggest a
cheap direct-import recovery path before falling back to `lake build`.

Detailed Lean workflow guidance lives in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).
The narrower Rocq surface lives in [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md).

## Which Layer To Use

- Use `lean-beam` plus the installed skills if you want the practical agent workflow that integrates with Codex or Claude out of the box
- Use the Beam broker if you want one long-lived local process per project root while keeping a narrower local protocol than raw LSP
- Use the Lean LSP extension directly if you already own the LSP session and want the smallest typed surface, or if you want to build custom agents doing MCTS or other advanced setups

The public request and response types live in [RunAt/Protocol.lean](RunAt/Protocol.lean). The Lean
plugin implementation lives in [RunAt/Plugin.lean](RunAt/Plugin.lean).

## How The Code Is Organized

- `RunAt`: Lean LSP server plugin providing the `$/lean/runAt` request for speculative execution at arbitrary document points
- `Beam`: local broker, daemon/client pair, and CLI wrappers exposing a narrower agent-facing surface over LSP and Beam-specific extensions
- `skills`: installed Claude/Codex workflow guidance built around `lean-beam`
- Rocq support: a narrow auxiliary goal-probe surface through the same `lean-beam` wrapper, useful when porting from Rocq to Lean
- `tests`: scenario-DSL coverage for LSP-level behavior, concurrent stress coverage, broker and wrapper regression suites, and install/runtime validation

## Local Build And Test (for development)

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
bash tests/test-broker-rocq.sh
bash tests/test-broker.sh
bash scripts/lint-shell.sh
```

GitHub Actions currently validates the main CI job set from
[.github/workflows/ci.yml](.github/workflows/ci.yml) on both Ubuntu and macOS.

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
