/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace RunAtCli.Broker

inductive Op where
  | ensure
  | openDocs
  | cancel
  | syncFile
  | close
  | runAt
  | requestAt
  | deps
  | saveOlean
  | goals
  | runWith
  | release
  | stats
  | resetStats
  | shutdown
  deriving Inhabited, BEq, Repr

def Op.key : Op → String
  | .ensure => "ensure"
  | .openDocs => "open_docs"
  | .cancel => "cancel"
  | .syncFile => "sync_file"
  | .close => "close"
  | .runAt => "run_at"
  | .requestAt => "request_at"
  | .deps => "deps"
  | .saveOlean => "save_olean"
  | .goals => "goals"
  | .runWith => "run_with"
  | .release => "release"
  | .stats => "stats"
  | .resetStats => "reset_stats"
  | .shutdown => "shutdown"

instance : ToJson Op where
  toJson op := toJson op.key

instance : FromJson Op where
  fromJson?
    | .str "ensure" => .ok .ensure
    | .str "open_docs" => .ok .openDocs
    | .str "cancel" => .ok .cancel
    | .str "sync_file" => .ok .syncFile
    | .str "close" => .ok .close
    | .str "run_at" => .ok .runAt
    | .str "request_at" => .ok .requestAt
    | .str "deps" => .ok .deps
    | .str "save_olean" => .ok .saveOlean
    | .str "goals" => .ok .goals
    | .str "run_with" => .ok .runWith
    | .str "release" => .ok .release
    | .str "stats" => .ok .stats
    | .str "reset_stats" => .ok .resetStats
    | .str "shutdown" => .ok .shutdown
    | j => .error s!"expected CLI daemon op, got {j.compress}"

inductive Backend where
  | lean
  | rocq
  deriving Inhabited, BEq, Repr, Ord

instance : ToJson Backend where
  toJson
    | .lean => "lean"
    | .rocq => "rocq"

instance : FromJson Backend where
  fromJson?
    | .str "lean" => .ok .lean
    | .str "rocq" => .ok .rocq
    | j => .error s!"expected backend 'lean' or 'rocq', got {j.compress}"

inductive GoalMode where
  | after
  | prev
  deriving Inhabited, BEq, Repr

def GoalMode.key : GoalMode → String
  | .after => "After"
  | .prev => "Prev"

instance : ToJson GoalMode where
  toJson mode := toJson mode.key

instance : FromJson GoalMode where
  fromJson?
    | .str "After" => .ok .after
    | .str "Prev" => .ok .prev
    | j => .error s!"expected goal mode 'After' or 'Prev', got {j.compress}"

inductive GoalPpFormat where
  | box
  | pp
  | str
  deriving Inhabited, BEq, Repr

def GoalPpFormat.key : GoalPpFormat → String
  | .box => "Box"
  | .pp => "Pp"
  | .str => "Str"

instance : ToJson GoalPpFormat where
  toJson format := toJson format.key

instance : FromJson GoalPpFormat where
  fromJson?
    | .str "Box" => .ok .box
    | .str "Pp" => .ok .pp
    | .str "Str" => .ok .str
    | j => .error s!"expected pp format 'Box', 'Pp', or 'Str', got {j.compress}"

structure Handle where
  backend : Backend
  epoch : Nat
  session : String
  raw : Json
  deriving Inhabited, FromJson, ToJson

structure Request where
  op : Op
  backend : Backend := .lean
  clientRequestId? : Option String := none
  cancelRequestId? : Option String := none
  root? : Option String := none
  path? : Option String := none
  line? : Option Nat := none
  character? : Option Nat := none
  method? : Option String := none
  params? : Option Json := none
  text? : Option String := none
  storeHandle? : Option Bool := none
  linear? : Option Bool := none
  mode? : Option GoalMode := none
  compact? : Option Bool := none
  ppFormat? : Option GoalPpFormat := none
  fullDiagnostics? : Option Bool := none
  saveArtifacts? : Option Bool := none
  handle? : Option Handle := none
  deriving Inhabited, ToJson

private def optionalField? [FromJson α] (j : Json) (field : String) : Except String (Option α) := do
  match j.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

instance : FromJson Request where
  fromJson? j := do
    let op ← j.getObjValAs? Op "op"
    let backend ←
      match ← optionalField? (α := Backend) j "backend" with
      | some backend => pure backend
      | none => pure .lean
    let clientRequestId? ← optionalField? (α := String) j "clientRequestId"
    let cancelRequestId? ← optionalField? (α := String) j "cancelRequestId"
    let root? ← optionalField? (α := String) j "root"
    let path? ← optionalField? (α := String) j "path"
    let line? ← optionalField? (α := Nat) j "line"
    let character? ← optionalField? (α := Nat) j "character"
    let method? ← optionalField? (α := String) j "method"
    let params? ← optionalField? (α := Json) j "params"
    let text? ← optionalField? (α := String) j "text"
    let storeHandle? ← optionalField? (α := Bool) j "storeHandle"
    let linear? ← optionalField? (α := Bool) j "linear"
    let mode? ← optionalField? (α := GoalMode) j "mode"
    let compact? ← optionalField? (α := Bool) j "compact"
    let ppFormat? ← optionalField? (α := GoalPpFormat) j "ppFormat"
    let fullDiagnostics? ← optionalField? (α := Bool) j "fullDiagnostics"
    let saveArtifacts? ← optionalField? (α := Bool) j "saveArtifacts"
    let handle? ← optionalField? (α := Handle) j "handle"
    pure {
      op, backend, clientRequestId?, cancelRequestId?,
      root?, path?, line?, character?, method?, params?, text?, storeHandle?,
      linear?, mode?, compact?, ppFormat?, fullDiagnostics?, saveArtifacts?, handle?
    }

structure Error where
  code : String
  message : String := ""
  deriving Inhabited, FromJson, ToJson

structure SyncFileProgress where
  updates : Nat := 0
  done : Bool := true
  deriving Inhabited, FromJson, ToJson, BEq, Repr

structure SyncFileResult where
  version : Nat
  errorCount : Nat := 0
  warningCount : Nat := 0
  deriving Inhabited, FromJson, ToJson

structure StreamDiagnostic where
  path : String
  uri : String
  version? : Option Int := none
  severity? : Option Lsp.DiagnosticSeverity := none
  range : Lsp.Range
  message : String
  deriving Inhabited, FromJson, ToJson

structure Response where
  ok : Bool := true
  result? : Option Json := none
  error? : Option Error := none
  fileProgress? : Option SyncFileProgress := none
  clientRequestId? : Option String := none
  deriving Inhabited

instance : ToJson Response where
  toJson resp :=
    Json.mkObj <|
      (match resp.result? with
      | some result => [("result", result)]
      | none => []) ++
      (match resp.error? with
      | some err => [("error", toJson err)]
      | none => []) ++
      (match resp.fileProgress? with
      | some progress => [("fileProgress", toJson progress)]
      | none => []) ++
      (match resp.clientRequestId? with
      | some clientRequestId => [("clientRequestId", toJson clientRequestId)]
      | none => [])

instance : FromJson Response where
  fromJson? j := do
    let result? ← optionalField? (α := Json) j "result"
    let error? ← optionalField? (α := Error) j "error"
    let fileProgress? ← optionalField? (α := SyncFileProgress) j "fileProgress"
    let clientRequestId? ← optionalField? (α := String) j "clientRequestId"
    let ok? ← optionalField? (α := Bool) j "ok"
    let ok := ok?.getD error?.isNone
    pure { ok, result?, error?, fileProgress?, clientRequestId? }

def syncBarrierIncompleteCode : String :=
  "syncBarrierIncomplete"

def saveTargetNotModuleCode : String :=
  "saveTargetNotModule"

inductive StreamKind where
  | response
  | fileProgress
  | diagnostic
  deriving Inhabited, BEq, Repr

def StreamKind.key : StreamKind → String
  | .response => "response"
  | .fileProgress => "fileProgress"
  | .diagnostic => "diagnostic"

instance : ToJson StreamKind where
  toJson kind := toJson kind.key

instance : FromJson StreamKind where
  fromJson?
    | .str "response" => .ok .response
    | .str "fileProgress" => .ok .fileProgress
    | .str "diagnostic" => .ok .diagnostic
    | j => .error s!"expected CLI daemon stream kind, got {j.compress}"

structure StreamMessage where
  kind : StreamKind
  response? : Option Response := none
  fileProgress? : Option SyncFileProgress := none
  diagnostic? : Option StreamDiagnostic := none
  clientRequestId? : Option String := none
  deriving Inhabited, FromJson, ToJson

def StreamMessage.mkResponse (resp : Response) : StreamMessage :=
  { kind := .response, response? := some resp, clientRequestId? := resp.clientRequestId? }

def StreamMessage.mkFileProgress
    (clientRequestId? : Option String)
    (progress : SyncFileProgress) : StreamMessage :=
  { kind := .fileProgress, fileProgress? := some progress, clientRequestId? := clientRequestId? }

def StreamMessage.mkDiagnostic
    (clientRequestId? : Option String)
    (streamDiagnostic : StreamDiagnostic) : StreamMessage :=
  { kind := .diagnostic, diagnostic? := some streamDiagnostic, clientRequestId? := clientRequestId? }

def Response.success (result : Json) : Response :=
  { ok := true, result? := some result }

def Response.error (code : String) (message : String := "") : Response :=
  { ok := false, error? := some { code, message } }

def Response.withClientRequestId (resp : Response) (clientRequestId? : Option String) : Response :=
  { resp with clientRequestId? := clientRequestId? <|> resp.clientRequestId? }

def Request.requireRoot (req : Request) : Except String System.FilePath := do
  let some root := req.root?
    | throw "missing 'root'"
  pure <| System.FilePath.mk root

def Request.requirePath (req : Request) : Except String System.FilePath := do
  let some path := req.path?
    | throw "missing 'path'"
  pure <| System.FilePath.mk path

def Request.requireText (req : Request) : Except String String := do
  let some text := req.text?
    | throw "missing 'text'"
  pure text

def Request.requireLine (req : Request) : Except String Nat := do
  let some line := req.line?
    | throw "missing 'line'"
  pure line

def Request.requireCharacter (req : Request) : Except String Nat := do
  let some character := req.character?
    | throw "missing 'character'"
  pure character

def Request.requireMethod (req : Request) : Except String String := do
  let some method := req.method?
    | throw "missing 'method'"
  pure method

def Request.requireCancelRequestId (req : Request) : Except String String := do
  let some cancelRequestId := req.cancelRequestId?
    | throw "missing 'cancelRequestId'"
  pure cancelRequestId

def Request.requireParamsObject (req : Request) : Except String Json := do
  match req.params? with
  | none => pure <| Json.mkObj []
  | some .null => pure <| Json.mkObj []
  | some params@(.obj _) =>
      if (params.getObjVal? "textDocument").isOk then
        throw "'params' must not include 'textDocument'; request_at injects it from <path>"
      if (params.getObjVal? "position").isOk then
        throw "'params' must not include 'position'; request_at injects it from <line>/<character>"
      pure params
  | some _ =>
      throw "'params' must be a JSON object or null"

def Request.requireHandle (req : Request) : Except String Handle := do
  let some handle := req.handle?
    | throw "missing 'handle'"
  pure handle

end RunAtCli.Broker
