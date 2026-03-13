# Install Redesign Plan

This document is now an implementation/design note for the install redesign work. For the current
user-facing install procedure, layout, and resolution rules, use the README section
`Installation And Resolution`.

## Goal

Replace the current checkout-bound installer with a self-contained local install that keeps the
runtime, wrappers, and caches separate from any developer checkout.

## Problems To Fix

- `~/.local/bin/runat` and `runat-lean-search` are symlinks into one repo checkout.
- The installed wrapper resolves `runAt-cli` from that checkout's `.lake/build`.
- Reinstall deletes repo-local `.runat` bundle caches as a side effect.
- Installed Lean bundles live under agent skill homes, which couples command-line runtime behavior to
  Codex/Claude skill installation.
- Wrapper path resolution must stay portable across GNU and BSD userlands.

## Target Layout

Use one dedicated artifact install root, defaulting to `~/.local/share/runat` and configurable via
`RUNAT_INSTALL_ROOT` at install time:

```text
~/.local/bin/runat
~/.local/bin/runat-lean-search
~/.local/share/runat/
  current -> versions/<payload-sha256>
  versions/<payload-sha256>/
    bin/runat
    bin/runat-lean-search
    libexec/runAt-cli
    libexec/runAt-cli-daemon
    libexec/runAt-cli-client
    manifest.json
  state/install-bundles/<toolchain>/...
```

Notes:

- `current` gives a stable target for `~/.local/bin` symlinks.
- `versions/<payload-sha256>` is immutable once written.
- `state/install-bundles` is stable across reinstall/upgrade and is not tied to skill homes.

## Behavioral Contract

The installer should:

1. Build or locate the required runtime artifacts from the source checkout.
2. Resolve the artifact install root from `RUNAT_INSTALL_ROOT`, defaulting to `~/.local/share/runat`.
3. Copy those artifacts into a new versioned install directory under that root.
4. Install the shipped skill files into agent homes only when explicitly requested.
5. Prebuild the pinned Lean bundle into the install state directory when possible.
6. Update `current` atomically.
7. Point `~/.local/bin/runat` and `runat-lean-search` at the installed wrappers, not the checkout.

The installer should identify each installed runtime by a content checksum, not by a timestamp or
just a git commit. The checksum should be computed from a deterministic manifest of the staged
runtime payload, including:

- wrapper scripts after templating/install-path substitution
- installed binaries under `libexec/`
- shipped skill directories, if included in that install mode
- pinned `lean-toolchain`

This gives stable deduplication for identical installs and avoids treating "same payload, different
checkout path" as a different install.

The installed wrappers should:

- resolve `libexec/runAt-cli` relative to their own installed location
- not depend on the source checkout existing
- avoid `readlink -f`
- set `RUNAT_HOME` to the installed runtime root, not the repo root
- record the resolved artifact install root directly in the installed shell entrypoint so runtime
  resolution does not depend on the original checkout path or ambient cwd inference
- still allow an explicit runtime override for debugging or advanced local workflows

## Shell Implementation Guardrails

The installer is shell-heavy, so the redesign should explicitly keep the shell surface narrow and
defensive:

- prefer small shell wrappers over large inline logic blocks
- quote every variable expansion unless word splitting is required and justified
- use arrays for argv construction instead of string concatenation
- avoid depending on the caller's cwd; resolve all internal paths once and pass absolute paths
- treat the artifact install root as first-class shell configuration, not an inferred side effect of
  the checkout layout
- reject relative install roots and other ambiguous filesystem targets up front
- make all filesystem transitions atomic where possible: stage in a temp dir, validate, then rename
- check required tools explicitly and fail with one targeted message per missing dependency
- do not delete repo-local or user-local state outside the install root unless the user asked for cleanup
- refuse to replace real directories at public wrapper link paths
- keep path resolution portable across GNU and BSD userlands
- keep checksum generation deterministic by sorting manifest inputs and hashing file contents, not mtimes

The runtime should resolve Lean bundles in this order:

1. `RUNAT_INSTALL_BUNDLE_DIR`, if explicitly set
2. installed bundle cache under the install state dir
3. local per-project runtime bundle under `RUNAT_BUNDLE_DIR` or `<root>/.runat/bundles`

Codex and Claude skill installation should become optional add-ons. The command-line install should
remain usable even when neither agent home exists.

## Phase Plan

### Phase 1: Separate Runtime From Checkout

- Add a configurable install-root concept to the shell layer and docs.
- Teach the wrappers to resolve the runtime from the installed tree.
- Stage `runAt-cli`, `runAt-cli-daemon`, and `runAt-cli-client` under `libexec/`.
- Record the resolved artifact install root in the installed wrapper payload at install time.
- Stop deleting repo-local `.runat` directories during install.

Acceptance:

- an installed `runat` still works after the source checkout is moved or removed
- reinstall no longer mutates repo-local caches

### Phase 2: Move Installed Bundle State Out Of Skill Homes

- Introduce one install-owned bundle cache root.
- Update wrapper/CLI resolution docs and tests to prefer that cache.
- Keep the existing env override `RUNAT_INSTALL_BUNDLE_DIR`.
- Remove any requirement that installed bundles live under `lean-runat` skill directories.

Acceptance:

- `runat doctor lean` reports `bundle source: installed` from the new install-owned cache
- command-line use works even if Codex/Claude skills are not installed

### Phase 3: Split Runtime Install From Skill Install

- Make the base installer install the runtime only.
- Add explicit optional `--codex`, `--claude`, and `--all-skills` modes for Codex and Claude skill
  installation.
- Keep a convenience mode that installs runtime plus both skill sets for maintainers.

Acceptance:

- users can install a working CLI without creating `~/.codex` or `~/.claude`
- skill installation remains available but is no longer on the critical path

### Phase 4: Harden Portability And Upgrade Semantics

- Keep wrapper path resolution portable across GNU and BSD userlands and cover it with tests.
- Write a manifest with payload checksum, source commit, toolchain, and artifact paths.
- Make reinstall/upgrade atomic by preparing a new version directory and then switching `current`.
- Add cleanup policy for old `versions/` directories without touching active state.

Acceptance:

- wrapper smoke tests pass on non-GNU userlands
- failed installs do not leave `current` pointing at a partial tree

## Test Plan

Extend `tests/test-install.sh` to cover:

- self-contained wrappers under `~/.local/share/runat/current`
- configurable artifact install root via `RUNAT_INSTALL_ROOT`
- installed command still works after the source checkout is renamed or made unavailable
- base install without Codex/Claude homes
- explicit skill install flags after the base runtime install
- reinstall preserves repo-local `.runat` and installed bundle state
- reinstall with identical payload reuses the same version directory/checksum instead of duplicating it
- missing `elan` fails early with no install side effects
- installed bundle resolution prefers the install-owned cache over local fallback

Add a small wrapper portability test for path resolution so shell behavior does not depend on GNU
`readlink`.

## Migration Notes

- Keep the current `bash scripts/install-runat-skills.sh` entrypoint initially, but change its
  behavior to produce the new install tree and treat skill installation as an explicit opt-in.
- Preserve `RUNAT_HOME`, `RUNAT_INSTALL_BUNDLE_DIR`, `RUNAT_BUNDLE_DIR`, and `RUNAT_CONTROL_DIR`.
- For one transition window, wrapper resolution may still look in the old skill-home install bundle
  locations as a fallback, but docs should mark that path deprecated.
