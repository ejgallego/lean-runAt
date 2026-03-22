# Lean Workflow Details

Use this reference when the task needs more than the default loop in `SKILL.md`.

## Position Semantics

- `lean-beam run-at` and `lean-beam run-at-handle` take Lean/LSP `Position` coordinates as
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
- valid probe positions are not arbitrary file coordinates; `lean-beam run-at` needs a command basis or
  proof/tactic snapshot at that position, or one Lean can recover from nearby syntax
- positions inside proof bodies are the safest choice for tactic probes
- standalone comments, blank lines, and many declaration headers often do not have a usable basis
- nearby whitespace/comments may still work when Lean can recover a neighboring basis, but do not
  assume that from arbitrary file positions
- those errors do not by themselves mean the Beam daemon is unhealthy
- known-good proof probe in this repo:
  `lean-beam run-at "tests/interactive/proofBasisBefore.lean" 2 2 "exact trivial"`

## Command Details

Continue from a stored handle:

```bash
# `--handle-file` avoids inlining handle json and frees stdin for continuation text
lean-beam run-with "Foo.lean" --handle-file handle.json "exact trivial"
lean-beam run-with-linear "Foo.lean" --handle-file handle.json "exact trivial"
lean-beam release "Foo.lean" --handle-file handle.json

# stdin handle flow remains supported when it fits your shell loop better
printf '%s\n' "$HANDLE_JSON" | lean-beam run-with "Foo.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam run-with-linear "Foo.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam release "Foo.lean" -
```

Short search helper:

```bash
lean-beam-search mint "Foo.lean" 10 2 "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search branch "Foo.lean" "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search playout "Foo.lean" "exact trivial" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search release "Foo.lean"
```

Inspect dependency order for multi-file edits:

```bash
lean-beam deps "Foo.lean"
```

Inspect Lean type/term information at a specific position:

```bash
lean-beam hover "Foo.lean" 10 2
```

Inspect Lean proof goals at an existing tactic position:

```bash
lean-beam goals-prev "Foo.lean" 10 2
lean-beam goals-after "Foo.lean" 10 2
```

These commands return structured goals in `result.goals`. A solved state uses
`result.goals = []`.

Checkpoint one synced workspace module without a full project build:

```bash
lean-beam save "MyPkg/Sub/Module.lean"
lean-beam close-save "MyPkg/Sub/Module.lean"
```

These commands require a synced file that belongs to the current Lake workspace and resolves to a
module in the package graph. A standalone `.lean` file that the daemon can open but Lake cannot map
to a module is a valid `lean-beam sync` target, but not a valid `lean-beam save` target.

## Save Eligibility

When `lean-beam save` is valid:

- the file has already been synced successfully
- the file belongs to the current Lake workspace package graph
- Lake resolves that path to a module
- `lean-beam save` means checkpointing a synced Lake module; it does not mean saving editor buffers or
  writing source text to disk

What is not a valid checkpoint target:

- a standalone `.lean` file at repo root that is outside the package module graph
- any file the daemon can open but Lake cannot map to a workspace module

## Source-File And Execution Model

- `lean-beam run-at` and `lean-beam deps` do not edit `Foo.lean`
- `lean-beam hover` is the stable read-only semantic inspection command for an existing position
- `lean-beam goals-prev` and `lean-beam goals-after` are the stable read-only proof-state
  inspection commands for an existing tactic position
- `lean-beam goals-prev` / `lean-beam goals-after` return `result.goals`, not speculative execution output,
  and do not accept speculative text
- `beam` only sees the on-disk file, not unsaved editor buffers
- actual source edits happen through the normal file-edit workflow
- after every real source edit to a Lean file, save the file in the normal editor/file sense and
  then run `lean-beam sync "Foo.lean"`
- use `lean-beam refresh "Foo.lean"` when a tracked file needs `lean-beam close` plus `lean-beam sync`
  as one step, especially after saving an upstream dependency
- treat `lean-beam sync` as the explicit supported boundary between real file edits and Beam daemon
  session state
- `lean-beam sync` returns compact JSON on stdout, including final `result.errorCount` /
  `result.warningCount`, and streams human diagnostics on stderr
- if imported targets are stale or the Lean worker cannot finish that diagnostics barrier,
  `lean-beam sync` fails; do not treat a failed sync as safe to follow with `lean-beam save`
- `lean-beam sync` keeps machine-readable JSON on stdout; interactive progress text goes to stderr
- every `lean-beam run-at` request is an isolated read-only probe against one on-disk document
  version
- `lean-beam run-at-handle` is the same style of isolated probe, but asks Lean to retain follow-up
  state
- `lean-beam run-with` preserves the current handle and branches from it
- `lean-beam run-with-linear` consumes the current handle and returns a successor handle for linear
  continuation
- `lean-beam release` explicitly drops a preserved handle
- `lean-beam-search` is a small convenience wrapper around these same commands
- the request may wait for the Lean snapshot at the requested position to finish elaborating; this
  is normal
- the probe does not mutate the document's real elaboration state and does not create hidden state
  for the next probe
- the Beam daemon may implicitly open or resync the file from disk before a probe, but that is not
  the supported readiness barrier after edits
- use `lean-beam sync` when the workflow needs an explicit ready/fresh boundary; `lean-beam run-at` only
  waits for the snapshot it needs
- if the same document changes while a request or stored handle is pending, expect
  `contentModified` or handle invalidation instead of hidden reuse
- `lean-beam save` / `lean-beam close-save` checkpoint the current synced Lake module only; they do not
  rebuild reverse dependencies or make downstream files fresh by themselves
## Diagnostics, Progress, And Request IDs

- `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` always stream fresh diagnostics for the current
  request
- by default they stream only errors
- add `+full` to widen the current request to warnings, info, and hints
- the final JSON does not replay streamed diagnostics
- when `lean-beam save` or `lean-beam close-save` returns `invalidParams` for document errors, the transport
  `error.message` includes a compact preview of underlying diagnostics and/or command messages
- wrapper `stderr` is the human-facing diagnostic surface
- `beam-client request-stream ...` is the machine-facing streamed surface
- do not parse wrapper `stderr` in tooling
- `BEAM_PROGRESS` controls stderr progress output for slow calls
- by default, progress prints when stderr is a TTY
- set `BEAM_PROGRESS=1` to force progress output in scripts or CI
- `BEAM_REQUEST_ID=<id>` attaches optional request metadata to the broker request
- the final stdout JSON echoes it as `clientRequestId`
- streamed stderr progress/diagnostic lines are annotated as `beam[<id>]: ...`
- a second live request using the same id is rejected with `invalidParams`
- `beam cancel <id>` cancels an in-flight broker request by that `clientRequestId`
- when `BEAM_REQUEST_ID` is set, `Ctrl-C` asks the broker to cancel that request before the local
  CLI exits

## File Progress And Readiness

Treat `fileProgress` as observability, not as proof that every call is a full barrier.

```bash
lean-beam ensure
sync_out="$(lean-beam sync "Foo.lean")"
printf '%s\n' "$sync_out"

probe_out="$(lean-beam run-at "Foo.lean" 10 2 "exact trivial")"
printf '%s\n' "$probe_out"
```

Interpretation:

- after `lean-beam sync`, expect top-level `fileProgress.done = true`
- successful `lean-beam sync` transport does not mean the file is error-free; inspect
  `result.errorCount` / `result.warningCount` for fresh streamed diagnostics in this request, and
  inspect `result.saveReady` plus `result.stateErrorCount` / `result.stateCommandErrorCount` for
  current save-readiness
- if `lean-beam sync` fails with an incomplete diagnostics barrier, inspect the JSON
  `error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan`; those hints are
  based on direct imports whose saved checkpoint is newer than the target file's last successful
  sync boundary
- follow `error.data.saveDeps` only for the listed direct deps that still need checkpointing, then
  `lean-beam refresh` the stale target before relying on downstream probes
- after `lean-beam run-at`, top-level `fileProgress` may exist with `done = false`; that is normal
  because the request only waited for its own target snapshot
- use `lean-beam hover` for stable semantic inspection and `lean-beam goals-prev` / `lean-beam goals-after` for
  existing proof state; use `lean-beam run-at` only when you need speculative execution
- if you need a real ready/fresh boundary after edits, use `lean-beam sync`, not a successful probe

Recovery loop for `syncBarrierIncomplete`:

```bash
# target T failed: lean-beam sync "T.lean"

# 1) if error.data.saveDeps lists direct deps that still need checkpointing, save them
lean-beam save "U.lean"

# 2) force the target tracked document to refresh its basis, then retry
lean-beam refresh "T.lean"
```

Practical boundary:

- use `lean-beam deps "T.lean"` to inspect direct imports when choosing likely upstream modules
- this is a targeted recovery loop, not a full dependency scheduler
- if retries keep walking additional modules, or if you need final workspace trust, stop and run
  `lake build`

## Cost Model

Write the on-disk document as `prefix ++ E ++ suffix`.

- `N := |prefix| + |E| + |suffix|` is the full document length
- `C := |E|` is the changed region length
- the wrapper is cheap only after the per-root daemon and matching bundle already exist
- `lean-beam run-at`, `lean-beam run-at-handle`, `lean-beam run-with`, and `lean-beam release` do not edit the file;
  they are speculative checks on one current snapshot, so their cost is not a workspace rebuild cost
- `lean-beam sync` always transmits the full current file text to Lean, so the wire/update cost is
  `O(N)`, not `O(C)`, even when `C << N`
- `lake build Foo.lean` is also at least `O(N)` in the target file length for that file
- the intended win is avoiding repeated `lake build` loops and repeated cold starts, not making
  one-file rebuild asymptotically sublinear
- `lean-beam save` and `lean-beam close-save` checkpoint one synced module after a completed barrier; they do
  not rebuild reverse dependencies and they do not turn workspace freshness into an `O(C)` problem
- first-use bundle resolution is the expensive outlier: if no installed bundle matches the
  toolchain, `beam` may build a local fallback bundle under `<root>/.beam/bundles`, which is real
  `lake build`
- if imported targets are stale or broken, `lean-beam sync` / `lean-beam save` fail instead of silently
  paying dependency-cone rebuild cost

## Dependency Edits And Rebuild Boundary

If you edit `A.lean` and `B.lean` imports `A.lean`, a successful probe in `B.lean` is not enough by
itself to prove the dependency cone is fresh.

```bash
lean-beam ensure
lean-beam deps "B.lean"

# make a real edit in A.lean and save the source file to disk
lean-beam sync "A.lean"
lean-beam run-at "B.lean" 12 2 "#check someNameFromA"
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
lean-beam open-files
lean-beam stats
lean-beam reset-stats
```

`lean-beam open-files` shows the files currently tracked by the Beam daemon for the current project,
along with `saved` / `notSaved`, direct Lean deps when available, whether the current synced version
has been checkpointed with `lean-beam save`, and Lean save preflight fields `saveEligible`,
`saveReason`, and, when applicable, `saveModule`. For files the Beam daemon already knows about, the
wrapper checks that status incrementally against the current on-disk text, and `open-files` also
reports the last compact `fileProgress` observed for that tracked version.

Stats are in-memory only and scoped to the current project Beam daemon.

The Beam daemon is helping if:

- many local probes happen before one edit
- `lake build` is not the inner loop
- stats show more `lean-beam run-at` / `lean-beam save` than full builds
