/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace RunAt

/--
JSON-RPC method name for the standalone `runAt` request.

This is the only public entry point. Backend selection remains internal:

- proof/tactic execution when a proof basis can be recovered at the given position
- command execution otherwise
-/
def method : String := "$/lean/runAt"

/-- JSON-RPC method name for follow-up execution from a stored handle. -/
def runWithMethod : String := "$/lean/runWith"

/-- JSON-RPC method name for explicit follow-up handle release. -/
def releaseHandleMethod : String := "$/lean/releaseHandle"

/-- JSON-RPC method name for read-only goal inspection after the position. -/
def goalsAfterMethod : String := "$/lean/goalsAfter"

/-- JSON-RPC method name for read-only goal inspection before the position. -/
def goalsPrevMethod : String := "$/lean/goalsPrev"

/-- Opaque follow-up handle returned by the server. -/
structure Handle where
  value : String
  deriving FromJson, ToJson

/--
Public request payload for `$/lean/runAt`.

Current frozen request semantics:

- the request is identified only by `textDocument`, `position`, and `text`
- callers do not choose command vs tactic mode
- `position` uses Lean/LSP `Position` semantics against the current open document version
- positions outside the document are invalid request parameters
- request-level failures are reported as transport errors rather than as `Result`
-/
structure Params where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  position : Lean.Lsp.Position
  text : String
  storeHandle? : Option Bool := none
  deriving FromJson, ToJson

-- Lean v4.28 compatibility shim: `Lean.Lsp.FileSource.fileSource` returns `FileIdent` there, but
-- newer Lean versions use `DocumentUri`. When we drop v4.28 support, re-check whether these request
-- types should switch back to the more direct `p.textDocument.uri` style used by newer upstream APIs.
instance : Lean.Lsp.FileSource Params where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Request payload for read-only goal inspection at a file position. -/
structure GoalsParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  position : Lean.Lsp.Position
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource GoalsParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Request payload for `$/lean/runWith`. -/
structure RunWithParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  handle : Handle
  text : String
  storeHandle? : Option Bool := none
  linear? : Option Bool := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource RunWithParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Request payload for `$/lean/releaseHandle`. -/
structure ReleaseHandleParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  handle : Handle
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource ReleaseHandleParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- A user-visible message emitted by isolated execution. -/
structure Message where
  severity : Lean.MessageSeverity
  text : String
  deriving FromJson, ToJson

/--
One hypothesis bundle in a structured proof goal.

Multiple names may share the same type when Lean groups hypotheses for display.
-/
structure GoalHyp where
  names : Array String := #[]
  type : String
  value? : Option String := none
  deriving FromJson, ToJson

/--
One structured proof goal.

This is a compact, stable projection of Lean's interactive goal representation.
-/
structure Goal where
  userName? : Option String := none
  goalPrefix : String := "⊢ "
  target : String
  hyps : Array GoalHyp := #[]
  deriving FromJson, ToJson

/--
Proof-state payload for proof-oriented execution.

This is only present when `runAt` executes against a recovered proof basis.
Command-mode execution does not invent a proof state.
Solved proof states use `goals := #[]`.
-/
structure ProofState where
  goals : Array Goal := #[]
  deriving FromJson, ToJson

/--
Typed success payload for `$/lean/runAt`.

Current frozen response semantics:

- request-level failures are not encoded here; they are transport errors
- `success = true` iff execution completes without any error-severity messages
- semantic Lean failures stay in this payload through `messages`
- no backend tag is exposed in the public payload
- no extra status enum is exposed beyond `success`
- `handle?` is present only when the request asked the server to retain follow-up state
- `proofState?` is present only for proof-oriented execution
- proof goals are structured into target, hypotheses, and optional case name
- solved proof states use `proofState.goals = #[]`
- `traces` stays as a plain array; empty traces are represented as `#[]`
- positions outside the document produce transport `invalidParams`
- in-document positions with no usable command/proof snapshot may also produce transport `invalidParams`
- in-document whitespace/comment positions may still resolve to a nearby execution basis
- editing a document while a request is pending may produce transport `contentModified`
- stale pending requests may produce transport `contentModified`
- explicit cancellation may produce transport `requestCancelled`
- cancellation is cooperative inside isolated execution; prompt `requestCancelled` depends on inner
  elaboration polling Lean interruption
-/
structure Result where
  success : Bool := true
  messages : Array Message := #[]
  traces : Array String := #[]
  handle? : Option Handle := none
  proofState? : Option ProofState := none
  deriving FromJson, ToJson

end RunAt
