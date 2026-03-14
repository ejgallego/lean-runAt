# Lean Workflow Details

Use this reference when the task needs more than the default loop in `SKILL.md`.

## Position Semantics

- `runat lean-run-at` and `runat lean-run-at-handle` take Lean/LSP `Position` coordinates as
  `<line> <character>`
- the wrapper passes those coordinates through directly; they are not editor-specific line numbers,
  byte offsets, or parser-token offsets
- line `0` is the first line, and character `0` is the first UTF-16 code unit on that line
- on a truly empty line, only character `0` is valid; character `1` is already out of range
- on an indented blank line, either probe after the existing spaces using that exact character
  offset, or probe at character `0` and include the indentation in the text yourself
- `position ... is outside the document` means the requested coordinate is not a valid Lean/LSP
  position for the current on-disk file
- `no command or tactic snapshot` means the coordinate is in the document, but Lean has no usable
  execution basis there
- valid probe positions are not arbitrary file coordinates; `lean-run-at` needs a command basis or
  proof/tactic snapshot at that position, or one Lean can recover from nearby syntax
- positions inside proof bodies are the safest choice for tactic probes
- standalone comments, blank lines, and many declaration headers often do not have a usable basis
- nearby whitespace/comments may still work when Lean can recover a neighboring basis, but do not
  assume that from arbitrary file positions
- those errors do not by themselves mean the CLI daemon is unhealthy
- known-good proof probe in this repo:
  `runat lean-run-at "tests/interactive/proofBasisBefore.lean" 2 2 "exact trivial"`

## Command Details

Continue from a stored handle:

```bash
printf '%s\n' "$HANDLE_JSON" | runat lean-run-with "Foo.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | runat lean-run-with-linear "Foo.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | runat lean-release "Foo.lean" -
```

Short search helper:

```bash
runat-lean-search mint "Foo.lean" 10 2 "constructor"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search branch "Foo.lean" "constructor"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search playout "Foo.lean" "exact trivial" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search release "Foo.lean"
```

Inspect dependency order for multi-file edits:

```bash
runat lean-deps "Foo.lean"
```

Inspect Lean type/term information at a specific position:

```bash
runat lean-hover "Foo.lean" 10 2
```

Inspect Lean proof goals at an existing tactic position:

```bash
runat lean-goals-prev "Foo.lean" 10 2
runat lean-goals-after "Foo.lean" 10 2
```

These commands return structured goals in `result.goals`. A solved state uses
`result.goals = []`.

Checkpoint one synced workspace module without a full project build:

```bash
runat lean-save "MyPkg/Sub/Module.lean"
runat lean-close-save "MyPkg/Sub/Module.lean"
```

These commands require a synced file that belongs to the current Lake workspace and resolves to a
module in the package graph. A standalone `.lean` file that the daemon can open but Lake cannot map
to a module is a valid `lean-sync` target, but not a valid `lean-save` target.

## Save Eligibility

When `lean-save` is valid:

- the file has already been synced successfully
- the file belongs to the current Lake workspace package graph
- Lake resolves that path to a module
- `lean-save` means checkpointing a synced Lake module; it does not mean saving editor buffers or
  writing source text to disk

What is not a valid checkpoint target:

- a standalone `.lean` file at repo root that is outside the package module graph
- any file the daemon can open but Lake cannot map to a workspace module

## Source-File And Execution Model

- `runat lean-run-at` and `runat lean-deps` do not edit `Foo.lean`
- `runat lean-hover` is the stable read-only semantic inspection command for an existing position
- `runat lean-goals-prev` and `runat lean-goals-after` are the stable read-only proof-state
  inspection commands for an existing tactic position
- `lean-goals-prev` / `lean-goals-after` return `result.goals`, not speculative execution output,
  and do not accept speculative text
- `runat` only sees the on-disk file, not unsaved editor buffers
- actual source edits happen through the normal file-edit workflow
- after every real source edit to a Lean file, save the file in the normal editor/file sense and
  then run `runat lean-sync "Foo.lean"`
- treat `lean-sync` as the explicit supported boundary between real file edits and CLI daemon
  session state
- `lean-sync` returns compact JSON on stdout, including final `result.errorCount` /
  `result.warningCount`, and streams human diagnostics on stderr
- if imported targets are stale or the Lean worker cannot finish that diagnostics barrier,
  `lean-sync` fails; do not treat a failed sync as safe to follow with `lean-save`
- `lean-sync` keeps machine-readable JSON on stdout; interactive progress text goes to stderr
- every `runat lean-run-at` request is an isolated read-only probe against one on-disk document
  version
- `runat lean-run-at-handle` is the same style of isolated probe, but asks Lean to retain follow-up
  state
- `runat lean-run-with` preserves the current handle and branches from it
- `runat lean-run-with-linear` consumes the current handle and returns a successor handle for linear
  continuation
- `runat lean-release` explicitly drops a preserved handle
- `runat-lean-search` is a small convenience wrapper around these same commands
- the request may wait for the Lean snapshot at the requested position to finish elaborating; this
  is normal
- the probe does not mutate the document's real elaboration state and does not create hidden state
  for the next probe
- the CLI daemon may implicitly open or resync the file from disk before a probe, but that is not
  the supported readiness barrier after edits
- use `lean-sync` when the workflow needs an explicit ready/fresh boundary; `lean-run-at` only
  waits for the snapshot it needs
- if the same document changes while a request or stored handle is pending, expect
  `contentModified` or handle invalidation instead of hidden reuse
- `lean-save` / `lean-close-save` checkpoint the current synced Lake module only; they do not
  rebuild reverse dependencies or make downstream files fresh by themselves

## Diagnostics, Progress, And Request IDs

- `lean-sync`, `lean-save`, and `lean-close-save` always stream fresh diagnostics for the current
  request
- by default they stream only errors
- add `+full` to widen the current request to warnings, info, and hints
- the final JSON does not replay streamed diagnostics
- when `lean-save` or `lean-close-save` returns `invalidParams` for document errors, the transport
  `error.message` includes a compact preview of underlying diagnostics and/or command messages
- wrapper `stderr` is the human-facing diagnostic surface
- `runAt-cli-client request-stream ...` is the machine-facing streamed surface
- do not parse wrapper `stderr` in tooling
- `RUNAT_PROGRESS` controls stderr progress output for slow calls
- by default, progress prints when stderr is a TTY
- set `RUNAT_PROGRESS=1` to force progress output in scripts or CI
- `RUNAT_REQUEST_ID=<id>` attaches optional request metadata to the broker request
- the final stdout JSON echoes it as `clientRequestId`
- streamed stderr progress/diagnostic lines are annotated as `runat[<id>]: ...`
- a second live request using the same id is rejected with `invalidParams`
- `runat cancel <id>` cancels an in-flight broker request by that `clientRequestId`
- when `RUNAT_REQUEST_ID` is set, `Ctrl-C` asks the broker to cancel that request before the local
  CLI exits

## File Progress And Readiness

Treat `fileProgress` as observability, not as proof that every call is a full barrier.

```bash
runat ensure lean
sync_out="$(runat lean-sync "Foo.lean")"
printf '%s\n' "$sync_out"

probe_out="$(runat lean-run-at "Foo.lean" 10 2 "exact trivial")"
printf '%s\n' "$probe_out"
```

Interpretation:

- after `lean-sync`, expect top-level `fileProgress.done = true`
- successful `lean-sync` transport does not mean the file is error-free; inspect final
  `result.errorCount` / `result.warningCount` for the authoritative summary and streamed diagnostics
  for the actual Lean messages and ranges
- if `lean-sync` fails with an incomplete diagnostics barrier, fix the stale or broken dependency
  state before relying on `lean-save` or downstream probes
- after `lean-run-at`, top-level `fileProgress` may exist with `done = false`; that is normal
  because the request only waited for its own target snapshot
- use `lean-hover` for stable semantic inspection and `lean-goals-prev` / `lean-goals-after` for
  existing proof state; use `lean-run-at` only when you need speculative execution
- if you need a real ready/fresh boundary after edits, use `lean-sync`, not a successful probe

## Cost Model

Write the on-disk document as `prefix ++ E ++ suffix`.

- `N := |prefix| + |E| + |suffix|` is the full document length
- `C := |E|` is the changed region length
- the wrapper is cheap only after the per-root daemon and matching bundle already exist
- `lean-run-at`, `lean-run-at-handle`, `lean-run-with`, and `lean-release` do not edit the file;
  they are speculative checks on one current snapshot, so their cost is not a workspace rebuild cost
- `lean-sync` always transmits the full current file text to Lean, so the wire/update cost is
  `O(N)`, not `O(C)`, even when `C << N`
- `lake build Foo.lean` is also at least `O(N)` in the target file length for that file
- the intended win is avoiding repeated `lake build` loops and repeated cold starts, not making
  one-file rebuild asymptotically sublinear
- `lean-save` and `lean-close-save` checkpoint one synced module after a completed barrier; they do
  not rebuild reverse dependencies and they do not turn workspace freshness into an `O(C)` problem
- first-use bundle resolution is the expensive outlier: if no installed bundle matches the
  toolchain, `runat` may build a local fallback bundle under `<root>/.runat/bundles`, which is real
  `lake build`
- if imported targets are stale or broken, `lean-sync` / `lean-save` fail instead of silently
  paying dependency-cone rebuild cost

## Dependency Edits And Rebuild Boundary

If you edit `A.lean` and `B.lean` imports `A.lean`, a successful probe in `B.lean` is not enough by
itself to prove the dependency cone is fresh.

```bash
runat ensure lean
runat lean-deps "B.lean"

# make a real edit in A.lean and save the source file to disk
runat lean-sync "A.lean"
runat lean-run-at "B.lean" 12 2 "#check someNameFromA"
```

Rules:

- the downstream probe in `B.lean` may still be a bad basis for trust after editing `A.lean`
- after dependency edits, prefer a rebuild or checkpoint before trusting downstream results
- once the task is “refresh a dependency cone” rather than “probe one edited file”, stop and run
  `lake build`

Use `lake build` when:

- you edited a dependency and now need trustworthy downstream results
- repeated probing is no longer clarifying the situation
- stale-state or rebuild trouble keeps appearing
- you are doing a final validation pass before considering the work done

## Stats And Signs Of Good Use

Use:

```bash
runat open-files
runat stats
runat reset-stats
```

`runat open-files` shows the files currently tracked by the CLI daemon for the current project,
along with `saved` / `notSaved`, direct Lean deps when available, whether the current synced version
has been checkpointed with `lean-save`, and Lean save preflight fields `saveEligible`,
`saveReason`, and, when applicable, `saveModule`. For files the CLI daemon already knows about, the
wrapper checks that status incrementally against the current on-disk text, and `open-files` also
reports the last compact `fileProgress` observed for that tracked version.

Stats are in-memory only and scoped to the current project CLI daemon.

The CLI daemon is helping if:

- many local probes happen before one edit
- `lake build` is not the inner loop
- stats show more `lean-run-at` / `lean-save` than full builds
