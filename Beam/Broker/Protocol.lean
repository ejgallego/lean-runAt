/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.LSP.Todo
import Beam.Workspace.Protocol

open Lean

namespace Beam.Broker

abbrev WorkspaceId := Beam.Workspace.WorkspaceId

instance : Repr Lsp.DiagnosticSeverity where
  reprPrec severity _ :=
    match severity with
    | .error => "error"
    | .warning => "warning"
    | .information => "information"
    | .hint => "hint"

inductive Op where
  | ensure
  | openDocs
  | cancel
  | updateFile
  | syncFile
  | refreshFile
  | close
  | runAt
  | hover
  | signatureHelp
  | definition
  | references
  | documentSymbols
  | workspaceSymbols
  | codeActionResolve
  | saveOlean
  | goals
  | todo
  | runWith
  | release
  | initWorkspace
  | listWorkspaces
  | dropWorkspace
  | stats
  | resetStats
  | shutdown
  deriving Inhabited, BEq, Repr

def Op.all : Array Op := #[
  .ensure, .openDocs, .cancel, .updateFile, .syncFile, .refreshFile, .close, .runAt,
  .hover, .signatureHelp, .definition, .references, .documentSymbols, .workspaceSymbols,
  .codeActionResolve, .saveOlean, .goals, .todo, .runWith, .release, .initWorkspace,
  .listWorkspaces, .dropWorkspace, .stats, .resetStats, .shutdown
]

def Op.key : Op → String
  | .ensure => "ensure"
  | .openDocs => "open_docs"
  | .cancel => "cancel"
  | .updateFile => "update_file"
  | .syncFile => "sync_file"
  | .refreshFile => "refresh_file"
  | .close => "close"
  | .runAt => "run_at"
  | .hover => "hover"
  | .signatureHelp => "signature_help"
  | .definition => "definition"
  | .references => "references"
  | .documentSymbols => "document_symbols"
  | .workspaceSymbols => "workspace_symbols"
  | .codeActionResolve => "code_action_resolve"
  | .saveOlean => "save_olean"
  | .goals => "goals"
  | .todo => "todo"
  | .runWith => "run_with"
  | .release => "release"
  | .initWorkspace => "init_workspace"
  | .listWorkspaces => "list_workspaces"
  | .dropWorkspace => "drop_workspace"
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
    | .str "update_file" => .ok .updateFile
    | .str "sync_file" => .ok .syncFile
    | .str "refresh_file" => .ok .refreshFile
    | .str "close" => .ok .close
    | .str "run_at" => .ok .runAt
    | .str "hover" => .ok .hover
    | .str "signature_help" => .ok .signatureHelp
    | .str "definition" => .ok .definition
    | .str "references" => .ok .references
    | .str "document_symbols" => .ok .documentSymbols
    | .str "workspace_symbols" => .ok .workspaceSymbols
    | .str "code_action_resolve" => .ok .codeActionResolve
    | .str "save_olean" => .ok .saveOlean
    | .str "goals" => .ok .goals
    | .str "todo" => .ok .todo
    | .str "run_with" => .ok .runWith
    | .str "release" => .ok .release
    | .str "init_workspace" => .ok .initWorkspace
    | .str "list_workspaces" => .ok .listWorkspaces
    | .str "drop_workspace" => .ok .dropWorkspace
    | .str "stats" => .ok .stats
    | .str "reset_stats" => .ok .resetStats
    | .str "shutdown" => .ok .shutdown
    | j => .error s!"expected Beam daemon op, got {j.compress}"

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
  | before
  | after
  deriving Inhabited, BEq, Repr

def GoalMode.key : GoalMode → String
  | .before => "before"
  | .after => "after"

instance : ToJson GoalMode where
  toJson mode := toJson mode.key

instance : FromJson GoalMode where
  fromJson?
    | .str "before" => .ok .before
    | .str "after" => .ok .after
    | j => .error s!"expected goal mode 'before' or 'after', got {j.compress}"

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
  workspaceId : WorkspaceId
  backend : Backend
  epoch : Nat
  session : String
  raw : Json
  deriving Inhabited, FromJson, ToJson

/-- Select which user-facing Lean diagnostic severities a request may display. -/
inductive DiagnosticScope where
  | errors
  | all
  deriving Inhabited, BEq, Repr

def DiagnosticScope.key : DiagnosticScope → String
  | .errors => "errors"
  | .all => "all"

instance : ToJson DiagnosticScope where
  toJson scope := toJson scope.key

instance : FromJson DiagnosticScope where
  fromJson?
    | .str "errors" => .ok .errors
    | .str "all" => .ok .all
    | json => .error s!"expected diagnostic scope 'errors' or 'all', got {json.compress}"

structure Request where
  op : Op
  backend : Backend := .lean
  workspaceId? : Option WorkspaceId := none
  workspaceMode? : Option Beam.Workspace.InitMode := none
  clientRequestId? : Option String := none
  cancelRequestId? : Option String := none
  root? : Option String := none
  path? : Option String := none
  version? : Option Nat := none
  line? : Option Nat := none
  character? : Option Nat := none
  endLine? : Option Nat := none
  endCharacter? : Option Nat := none
  text? : Option String := none
  query? : Option String := none
  includeDeclaration? : Option Bool := none
  kinds? : Option (Array Beam.LSP.Todo.TodoKind) := none
  suggest? : Option Beam.LSP.Todo.TodoSuggestMode := none
  storeHandle? : Option Bool := none
  linear? : Option Bool := none
  mode? : Option GoalMode := none
  compact? : Option Bool := none
  ppFormat? : Option GoalPpFormat := none
  diagnosticScope? : Option DiagnosticScope := none
  diagnosticsInResult? : Option Bool := none
  saveArtifacts? : Option Bool := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  rocqCmd? : Option String := none
  handle? : Option Handle := none
  codeAction? : Option Lsp.CodeAction := none
  deriving Inhabited

inductive WorkspaceScope where
  | none
  | optional
  | required
  deriving BEq, Repr

/-- Describe whether a broker operation is process-wide or resolves one workspace. -/
def Op.workspaceScope : Op → WorkspaceScope
  | .cancel | .listWorkspaces | .resetStats | .shutdown => .none
  | .openDocs | .stats => .optional
  | .ensure | .updateFile | .syncFile | .refreshFile | .close | .runAt | .hover
  | .signatureHelp | .definition | .references | .documentSymbols | .workspaceSymbols
  | .codeActionResolve | .saveOlean | .goals | .todo | .runWith | .release
  | .initWorkspace | .dropWorkspace => .required

private def Op.optionalRequestFields (op : Op) : Array String :=
  #["clientRequestId"] ++
  (match op.workspaceScope with
  | .none => #[]
  | .optional | .required => #["workspaceId"]) ++
  match op with
  | .ensure => #["root"]
  | .openDocs | .stats => #["root"]
  | .cancel => #["cancelRequestId"]
  | .updateFile => #["root", "path"]
  | .syncFile | .refreshFile =>
      #["root", "path", "diagnosticScope", "diagnosticsInResult"]
  | .close => #["root", "path", "diagnosticScope", "saveArtifacts"]
  | .runAt =>
      #["root", "path", "version", "line", "character", "text", "storeHandle"]
  | .hover | .signatureHelp | .definition =>
      #["root", "path", "version", "line", "character"]
  | .references =>
      #["root", "path", "version", "line", "character", "includeDeclaration"]
  | .documentSymbols => #["root", "path", "version"]
  | .workspaceSymbols => #["root", "query"]
  | .codeActionResolve => #["root", "path", "version", "codeAction"]
  | .saveOlean => #["root", "path", "diagnosticScope"]
  | .goals =>
      #[
        "root", "path", "version", "line", "character", "text", "mode", "compact",
        "ppFormat"
      ]
  | .todo =>
      #[
        "root", "path", "version", "line", "character", "endLine", "endCharacter", "kinds",
        "suggest"
      ]
  | .runWith =>
      #["root", "path", "text", "storeHandle", "linear", "handle"]
  | .release => #["root", "path", "handle"]
  | .initWorkspace =>
      #["workspaceMode", "root", "leanCmd", "leanPlugin", "rocqCmd"]
  | .dropWorkspace => #[]
  | .listWorkspaces | .resetStats | .shutdown => #[]

private def Op.usesBackend : Op → Bool
  | .ensure | .updateFile | .syncFile | .refreshFile | .close | .runAt | .hover
  | .signatureHelp | .definition | .references | .documentSymbols | .workspaceSymbols
  | .codeActionResolve | .saveOlean | .goals | .todo | .runWith | .release => true
  | .openDocs | .cancel | .initWorkspace | .listWorkspaces | .dropWorkspace | .stats
  | .resetStats | .shutdown => false

private def optionalJsonField [ToJson α] (name : String) : Option α → List (String × Json)
  | some value => [(name, toJson value)]
  | none => []

private def Request.optionalJsonFields (req : Request) : List (String × Json) :=
  optionalJsonField "workspaceId" req.workspaceId? ++
  optionalJsonField "workspaceMode" req.workspaceMode? ++
  optionalJsonField "clientRequestId" req.clientRequestId? ++
  optionalJsonField "cancelRequestId" req.cancelRequestId? ++
  optionalJsonField "root" req.root? ++
  optionalJsonField "path" req.path? ++
  optionalJsonField "version" req.version? ++
  optionalJsonField "line" req.line? ++
  optionalJsonField "character" req.character? ++
  optionalJsonField "endLine" req.endLine? ++
  optionalJsonField "endCharacter" req.endCharacter? ++
  optionalJsonField "text" req.text? ++
  optionalJsonField "query" req.query? ++
  optionalJsonField "includeDeclaration" req.includeDeclaration? ++
  optionalJsonField "kinds" req.kinds? ++
  optionalJsonField "suggest" req.suggest? ++
  optionalJsonField "storeHandle" req.storeHandle? ++
  optionalJsonField "linear" req.linear? ++
  optionalJsonField "mode" req.mode? ++
  optionalJsonField "compact" req.compact? ++
  optionalJsonField "ppFormat" req.ppFormat? ++
  optionalJsonField "diagnosticScope" req.diagnosticScope? ++
  optionalJsonField "diagnosticsInResult" req.diagnosticsInResult? ++
  optionalJsonField "saveArtifacts" req.saveArtifacts? ++
  optionalJsonField "leanCmd" req.leanCmd? ++
  optionalJsonField "leanPlugin" req.leanPlugin? ++
  optionalJsonField "rocqCmd" req.rocqCmd? ++
  optionalJsonField "handle" req.handle? ++
  optionalJsonField "codeAction" req.codeAction?

instance : ToJson Request where
  toJson req := Json.mkObj <|
    [("op", toJson req.op)] ++
    (if req.op.usesBackend then [("backend", toJson req.backend)] else []) ++
    req.optionalJsonFields

private def requireRequestJsonFields (op : Op) : Json → Except String Unit
  | .obj fields =>
      let backendFields := if op.usesBackend then #["backend"] else #[]
      let allowed := #["op"] ++ backendFields ++ op.optionalRequestFields
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"broker op '{op.key}' accepts no undeclared or unrelated fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"broker request must be an object, got {other.compress}"

private def Request.presentOptionalFields (req : Request) : Array String :=
  req.optionalJsonFields.toArray.map (fun (field, _) => field)

/-- Reject request fields that have no meaning for the selected broker operation. -/
def Request.validateFields (req : Request) : Except String Unit := do
  let allowed := req.op.optionalRequestFields
  let unexpected := req.presentOptionalFields.filter fun field => !allowed.contains field
  unless unexpected.isEmpty do
    throw s!"broker op '{req.op.key}' accepts no unrelated fields: {String.intercalate ", " unexpected.toList}"
  if !req.op.usesBackend && req.backend != .lean then
    throw s!"broker op '{req.op.key}' does not select a backend"
  if (req.op == .stats || req.op == .openDocs) && req.root?.isSome && req.workspaceId?.isNone then
    throw s!"broker op '{req.op.key}' requires 'workspaceId' when 'root' is present"

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
    requireRequestJsonFields op j
    let backend ←
      match ← optionalField? (α := Backend) j "backend" with
      | some backend => pure backend
      | none => pure .lean
    let workspaceId? ← optionalField? (α := WorkspaceId) j "workspaceId"
    let workspaceMode? ← optionalField? (α := Beam.Workspace.InitMode) j "workspaceMode"
    let clientRequestId? ← optionalField? (α := String) j "clientRequestId"
    let cancelRequestId? ← optionalField? (α := String) j "cancelRequestId"
    let root? ← optionalField? (α := String) j "root"
    let path? ← optionalField? (α := String) j "path"
    let version? ← optionalField? (α := Nat) j "version"
    let line? ← optionalField? (α := Nat) j "line"
    let character? ← optionalField? (α := Nat) j "character"
    let endLine? ← optionalField? (α := Nat) j "endLine"
    let endCharacter? ← optionalField? (α := Nat) j "endCharacter"
    let text? ← optionalField? (α := String) j "text"
    let query? ← optionalField? (α := String) j "query"
    let includeDeclaration? ← optionalField? (α := Bool) j "includeDeclaration"
    let kinds? ← optionalField? (α := Array Beam.LSP.Todo.TodoKind) j "kinds"
    let suggest? ← optionalField? (α := Beam.LSP.Todo.TodoSuggestMode) j "suggest"
    let storeHandle? ← optionalField? (α := Bool) j "storeHandle"
    let linear? ← optionalField? (α := Bool) j "linear"
    let mode? ← optionalField? (α := GoalMode) j "mode"
    let compact? ← optionalField? (α := Bool) j "compact"
    let ppFormat? ← optionalField? (α := GoalPpFormat) j "ppFormat"
    let diagnosticScope? ← optionalField? (α := DiagnosticScope) j "diagnosticScope"
    let diagnosticsInResult? ← optionalField? (α := Bool) j "diagnosticsInResult"
    let saveArtifacts? ← optionalField? (α := Bool) j "saveArtifacts"
    let leanCmd? ← optionalField? (α := String) j "leanCmd"
    let leanPlugin? ← optionalField? (α := String) j "leanPlugin"
    let rocqCmd? ← optionalField? (α := String) j "rocqCmd"
    let handle? ← optionalField? (α := Handle) j "handle"
    let codeAction? ← optionalField? (α := Lsp.CodeAction) j "codeAction"
    let request : Request := {
      op, backend, workspaceId?, workspaceMode?, clientRequestId?, cancelRequestId?,
      root?, path?, version?, line?, character?, endLine?, endCharacter?,
      text?, query?, includeDeclaration?, kinds?, suggest?, storeHandle?,
      linear?, mode?, compact?, ppFormat?, diagnosticScope?, diagnosticsInResult?,
      saveArtifacts?, leanCmd?, leanPlugin?, rocqCmd?, handle?, codeAction?
    }
    request.validateFields
    pure request

structure Error where
  code : String
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

structure SyncFileProgress where
  updates : Nat := 0
  done : Bool := true
  /-- Earliest one-based line in Lean's current processing ranges, when any range is active. -/
  rangeStartLine? : Option Nat := none
  /-- One-based upper line bound from Lean's processing ranges; not the source file line count. -/
  rangeEndLine? : Option Nat := none
  deriving Inhabited, FromJson, ToJson, BEq, Repr

namespace SyncFileProgress

def rangeText? (progress : SyncFileProgress) : Option String :=
  match progress.rangeStartLine?, progress.rangeEndLine? with
  | some startLine, some endLine => some s!"range={startLine}..{endLine}"
  | some startLine, none => some s!"rangeStartLine={startLine}"
  | none, some endLine => some s!"rangeEndLine={endLine}"
  | none, none => none

def displayDetails (progress : SyncFileProgress) (includeDoneTrue : Bool := true) : String :=
  let rangePrefix :=
    match progress.rangeText? with
    | some text => text ++ " "
    | none => ""
  let doneSuffix :=
    if progress.done then
      if includeDoneTrue then
        " done=true"
      else
        ""
    else
      " done=false"
  s!"{rangePrefix}updates={progress.updates}{doneSuffix}"

end SyncFileProgress

private def requireOnlyJsonFields
    (label : String)
    (allowed : Array String) : Json → Except String Unit
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"{label} accepts no undeclared fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"{label} must be an object, got {other.compress}"

structure SyncDiagnosticCounts where
  error : Nat := 0
  warning : Nat := 0
  information : Nat := 0
  hint : Nat := 0
  unknown : Nat := 0
  deriving Inhabited, BEq, Repr

def SyncDiagnosticCounts.total (counts : SyncDiagnosticCounts) : Nat :=
  counts.error + counts.warning + counts.information + counts.hint + counts.unknown

instance : ToJson SyncDiagnosticCounts where
  toJson counts := Json.mkObj [
    ("error", toJson counts.error),
    ("warning", toJson counts.warning),
    ("information", toJson counts.information),
    ("hint", toJson counts.hint),
    ("unknown", toJson counts.unknown),
    ("total", toJson counts.total)
  ]

instance : FromJson SyncDiagnosticCounts where
  fromJson? json := do
    requireOnlyJsonFields "sync diagnostic counts"
      #["error", "warning", "information", "hint", "unknown", "total"] json
    let errorCount ← json.getObjValAs? Nat "error"
    let warning ← json.getObjValAs? Nat "warning"
    let information ← json.getObjValAs? Nat "information"
    let hint ← json.getObjValAs? Nat "hint"
    let unknown ← json.getObjValAs? Nat "unknown"
    let total ← json.getObjValAs? Nat "total"
    let severityTotal := errorCount + warning + information + hint + unknown
    unless total == severityTotal do
      throw s!"sync diagnostic count total {total} does not match severity sum {severityTotal}"
    pure {
      error := errorCount
      warning
      information
      hint
      unknown
    }

structure SyncBlockingDiagnostic where
  range : Lsp.Range
  severity? : Option Lsp.DiagnosticSeverity := some .error
  message : String
  saveBlocking : Bool := false
  completionBlocking : Bool := false
  deriving Inhabited, ToJson, BEq, Repr

instance : FromJson SyncBlockingDiagnostic where
  fromJson? json := do
    requireOnlyJsonFields "sync blocking diagnostic"
      #["range", "severity", "message", "saveBlocking", "completionBlocking"] json
    let range ← json.getObjValAs? Lsp.Range "range"
    let severity? ← optionalField? (α := Lsp.DiagnosticSeverity) json "severity"
    let message ← json.getObjValAs? String "message"
    let saveBlocking? ← optionalField? (α := Bool) json "saveBlocking"
    let completionBlocking? ← optionalField? (α := Bool) json "completionBlocking"
    pure {
      range
      severity?
      message
      saveBlocking := saveBlocking?.getD false
      completionBlocking := completionBlocking?.getD false
    }

structure SyncBlockingCommandMessage where
  message : String
  saveBlocking : Bool := true
  completionBlocking : Bool := false
  deriving Inhabited, ToJson, BEq, Repr

instance : FromJson SyncBlockingCommandMessage where
  fromJson? json := do
    requireOnlyJsonFields "sync blocking message"
      #["message", "saveBlocking", "completionBlocking"] json
    let message ← json.getObjValAs? String "message"
    let saveBlocking? ← optionalField? (α := Bool) json "saveBlocking"
    let completionBlocking? ← optionalField? (α := Bool) json "completionBlocking"
    pure {
      message
      saveBlocking := saveBlocking?.getD true
      completionBlocking := completionBlocking?.getD false
    }

structure SyncResultReadiness where
  saveReady : Bool := true
  reason : String := "ok"
  /-- Number of save-blocking errors, including command messages that have no diagnostic. -/
  blockingErrorCount : Nat := 0
  blockingDiagnostics : Array SyncBlockingDiagnostic := #[]
  blockingMessages : Array SyncBlockingCommandMessage := #[]
  deriving Inhabited, ToJson, BEq, Repr

instance : FromJson SyncResultReadiness where
  fromJson? json := do
    requireOnlyJsonFields "sync readiness"
      #["saveReady", "reason", "blockingErrorCount", "blockingDiagnostics", "blockingMessages"]
      json
    let saveReady ← json.getObjValAs? Bool "saveReady"
    let reason ← json.getObjValAs? String "reason"
    let blockingErrorCount ← json.getObjValAs? Nat "blockingErrorCount"
    let blockingDiagnostics ←
      json.getObjValAs? (Array SyncBlockingDiagnostic) "blockingDiagnostics"
    let blockingMessages ←
      json.getObjValAs? (Array SyncBlockingCommandMessage) "blockingMessages"
    pure {
      saveReady
      reason
      blockingErrorCount
      blockingDiagnostics
      blockingMessages
    }

structure StreamDiagnostic where
  path : String
  uri : String
  version? : Option Int := none
  severity? : Option Lsp.DiagnosticSeverity := none
  range : Lsp.Range
  message : String
  saveBlocking? : Option Bool := none
  completionBlocking : Bool := false
  deriving Inhabited, ToJson

instance : FromJson StreamDiagnostic where
  fromJson? json := do
    requireOnlyJsonFields "stream diagnostic"
      #[
        "path", "uri", "version", "severity", "range", "message", "saveBlocking",
        "completionBlocking"
      ] json
    let path ← json.getObjValAs? String "path"
    let uri ← json.getObjValAs? String "uri"
    let version? ← optionalField? (α := Int) json "version"
    let severity? ← optionalField? (α := Lsp.DiagnosticSeverity) json "severity"
    let range ← json.getObjValAs? Lsp.Range "range"
    let message ← json.getObjValAs? String "message"
    let saveBlocking? ← optionalField? (α := Bool) json "saveBlocking"
    let completionBlocking? ← optionalField? (α := Bool) json "completionBlocking"
    pure {
      path
      uri
      version?
      severity?
      range
      message
      saveBlocking?
      completionBlocking := completionBlocking?.getD false
    }

structure SyncResultDiagnostics where
  counts : SyncDiagnosticCounts := {}
  items? : Option (Array StreamDiagnostic) := none
  deriving Inhabited

instance : ToJson SyncResultDiagnostics where
  toJson diagnostics :=
    Json.mkObj <|
      [("counts", toJson diagnostics.counts)] ++
      match diagnostics.items? with
      | some items => [("items", toJson items)]
      | none => []

instance : FromJson SyncResultDiagnostics where
  fromJson? json := do
    requireOnlyJsonFields "sync diagnostics" #["counts", "items"] json
    let counts ← json.getObjValAs? SyncDiagnosticCounts "counts"
    let items? ← optionalField? (α := Array StreamDiagnostic) json "items"
    pure { counts, items? }

structure SyncFileResult where
  path : String
  version : Nat
  diagnostics : SyncResultDiagnostics := {}
  readiness : SyncResultReadiness := {}
  deriving Inhabited

structure UpdateFileResult where
  version : Nat
  changed : Bool := false
  deriving Inhabited, FromJson, ToJson, BEq, Repr

structure CodeActionResolveResult where
  version : Nat
  codeAction : Lsp.CodeAction
  deriving FromJson, ToJson

instance : ToJson SyncFileResult where
  toJson result :=
    Json.mkObj <|
      [
        ("path", toJson result.path),
        ("version", toJson result.version),
        ("diagnostics", toJson result.diagnostics),
        ("readiness", toJson result.readiness)
      ]

instance : FromJson SyncFileResult where
  fromJson? json := do
    requireOnlyJsonFields "sync result" #["path", "version", "diagnostics", "readiness"] json
    let path ← json.getObjValAs? String "path"
    let version ← json.getObjValAs? Nat "version"
    let diagnostics ← json.getObjValAs? SyncResultDiagnostics "diagnostics"
    let readiness ← json.getObjValAs? SyncResultReadiness "readiness"
    pure {
      path
      version
      diagnostics
      readiness
    }

/-- Stable broker result for a successfully published Lean checkpoint. -/
structure SaveOleanResult where
  module : String
  sourceHash : String
  olean : String
  ilean : String
  c : String
  trace : String
  oleanServer? : Option String := none
  oleanPrivate? : Option String := none
  ir? : Option String := none
  bc? : Option String := none
  sync : SyncFileResult
  deriving Inhabited

def SaveOleanResult.path (result : SaveOleanResult) : String :=
  result.sync.path

def SaveOleanResult.version (result : SaveOleanResult) : Nat :=
  result.sync.version

instance : ToJson SaveOleanResult where
  toJson result :=
    Json.mkObj <|
      [
        ("path", toJson result.path),
        ("module", toJson result.module),
        ("version", toJson result.version),
        ("sourceHash", toJson result.sourceHash),
        ("olean", toJson result.olean),
        ("ilean", toJson result.ilean),
        ("c", toJson result.c),
        ("trace", toJson result.trace)
      ] ++
      (match result.oleanServer? with
      | some path => [("oleanServer", toJson path)]
      | none => []) ++
      (match result.oleanPrivate? with
      | some path => [("oleanPrivate", toJson path)]
      | none => []) ++
      (match result.ir? with
      | some path => [("ir", toJson path)]
      | none => []) ++
      (match result.bc? with
      | some path => [("bc", toJson path)]
      | none => []) ++
      [("sync", toJson result.sync)]

instance : FromJson SaveOleanResult where
  fromJson? json := do
    requireOnlyJsonFields "save result" #[
      "path", "module", "version", "sourceHash", "olean", "ilean", "c", "trace",
      "oleanServer", "oleanPrivate", "ir", "bc", "sync"
    ] json
    let path ← json.getObjValAs? String "path"
    let module ← json.getObjValAs? String "module"
    let version ← json.getObjValAs? Nat "version"
    let sourceHash ← json.getObjValAs? String "sourceHash"
    let olean ← json.getObjValAs? String "olean"
    let ilean ← json.getObjValAs? String "ilean"
    let c ← json.getObjValAs? String "c"
    let trace ← json.getObjValAs? String "trace"
    let oleanServer? ← optionalField? (α := String) json "oleanServer"
    let oleanPrivate? ← optionalField? (α := String) json "oleanPrivate"
    let ir? ← optionalField? (α := String) json "ir"
    let bc? ← optionalField? (α := String) json "bc"
    let sync ← json.getObjValAs? SyncFileResult "sync"
    unless path == sync.path do
      throw s!"save result path '{path}' does not match sync path '{sync.path}'"
    unless version == sync.version do
      throw s!"save result version {version} does not match sync version {sync.version}"
    pure {
      module
      sourceHash
      olean
      ilean
      c
      trace
      oleanServer?
      oleanPrivate?
      ir?
      bc?
      sync
    }

/-- Stable broker result for an artifact save followed by closing the mirrored document. -/
structure CloseSaveResult where
  saved : SaveOleanResult
  deriving Inhabited

def CloseSaveResult.closed (_ : CloseSaveResult) : Bool :=
  true

instance : ToJson CloseSaveResult where
  toJson result := Json.mkObj [
    ("closed", toJson result.closed),
    ("saved", toJson result.saved)
  ]

instance : FromJson CloseSaveResult where
  fromJson? json := do
    requireOnlyJsonFields "close-save result" #["closed", "saved"] json
    let closed ← json.getObjValAs? Bool "closed"
    let saved ← json.getObjValAs? SaveOleanResult "saved"
    unless closed do
      throw "close-save result requires 'closed' to be true"
    pure { saved }

/-- A successful broker payload or a typed broker error, with shared response observations. -/
inductive Response where
  | successResult
      (result : Json)
      (fileProgress? : Option SyncFileProgress)
      (clientRequestId? : Option String)
  | errorResult
      (error : Error)
      (fileProgress? : Option SyncFileProgress)
      (clientRequestId? : Option String)
  deriving Inhabited

def Response.ok : Response → Bool
  | .successResult .. => true
  | .errorResult .. => false

def Response.result? : Response → Option Json
  | .successResult result .. => some result
  | .errorResult .. => none

def Response.error? : Response → Option Error
  | .successResult .. => none
  | .errorResult error .. => some error

def Response.fileProgress? : Response → Option SyncFileProgress
  | .successResult _ fileProgress? _
  | .errorResult _ fileProgress? _ => fileProgress?

def Response.clientRequestId? : Response → Option String
  | .successResult _ _ clientRequestId?
  | .errorResult _ _ clientRequestId? => clientRequestId?

instance : ToJson Response where
  toJson resp :=
    let payloadFields :=
      match resp with
      | .successResult result _ _ => [("ok", toJson true), ("result", result)]
      | .errorResult error _ _ => [("ok", toJson false), ("error", toJson error)]
    Json.mkObj <| payloadFields ++
      (match resp.fileProgress? with
      | some progress => [("fileProgress", toJson progress)]
      | none => []) ++
      (match resp.clientRequestId? with
      | some clientRequestId => [("clientRequestId", toJson clientRequestId)]
      | none => [])

instance : FromJson Response where
  fromJson? j := do
    requireOnlyJsonFields "Beam daemon response"
      #["ok", "result", "error", "fileProgress", "clientRequestId"] j
    let result? ← optionalField? (α := Json) j "result"
    let error? ← optionalField? (α := Error) j "error"
    let fileProgress? ← optionalField? (α := SyncFileProgress) j "fileProgress"
    let clientRequestId? ← optionalField? (α := String) j "clientRequestId"
    let ok ← j.getObjValAs? Bool "ok"
    if ok then
      match result?, error? with
      | some result, none => pure <| .successResult result fileProgress? clientRequestId?
      | _, some _ => throw "invalid Beam daemon response: ok=true must not include 'error'"
      | none, none => throw "invalid Beam daemon response: ok=true must include 'result'"
    else
      match result?, error? with
      | none, some error => pure <| .errorResult error fileProgress? clientRequestId?
      | some _, _ => throw "invalid Beam daemon response: ok=false must not include 'result'"
      | none, none => throw "invalid Beam daemon response: ok=false must include 'error'"

def syncBarrierIncompleteCode : String :=
  "syncBarrierIncomplete"

def saveTraceStaleCode : String :=
  "saveTraceStale"

def saveUnsupportedSetupCode : String :=
  "saveUnsupportedSetup"

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
    | j => .error s!"expected Beam daemon stream kind, got {j.compress}"

/-- One decoded broker stream event with exactly the payload selected by its wire `kind`. -/
inductive StreamMessage where
  | response (response : Response)
  | fileProgress (clientRequestId? : Option String) (progress : SyncFileProgress)
  | diagnostic (clientRequestId? : Option String) (diagnostic : StreamDiagnostic)
  deriving Inhabited

instance : ToJson StreamMessage where
  toJson
    | .response resp => Json.mkObj [
        ("kind", toJson StreamKind.response),
        ("response", toJson resp)
      ]
    | .fileProgress clientRequestId? progress =>
        Json.mkObj <| [
          ("kind", toJson StreamKind.fileProgress),
          ("fileProgress", toJson progress)
        ] ++ optionalJsonField "clientRequestId" clientRequestId?
    | .diagnostic clientRequestId? streamDiagnostic =>
        Json.mkObj <| [
          ("kind", toJson StreamKind.diagnostic),
          ("diagnostic", toJson streamDiagnostic)
        ] ++ optionalJsonField "clientRequestId" clientRequestId?

instance : FromJson StreamMessage where
  fromJson? json := do
    requireOnlyJsonFields "Beam stream message"
      #["kind", "response", "fileProgress", "diagnostic", "clientRequestId"] json
    let kind ← json.getObjValAs? StreamKind "kind"
    let response? ← optionalField? (α := Response) json "response"
    let fileProgress? ← optionalField? (α := SyncFileProgress) json "fileProgress"
    let diagnostic? ← optionalField? (α := StreamDiagnostic) json "diagnostic"
    let clientRequestId? ← optionalField? (α := String) json "clientRequestId"
    match kind with
    | .response =>
        match response?, fileProgress?, diagnostic? with
        | some response, none, none =>
            if clientRequestId?.isSome then
              throw "Beam response stream message carries clientRequestId only in its response payload"
            else
              pure <| .response response
        | _, _, _ =>
            throw "Beam response stream message requires only a 'response' payload"
    | .fileProgress =>
        match response?, fileProgress?, diagnostic? with
        | none, some progress, none => pure <| .fileProgress clientRequestId? progress
        | _, _, _ =>
            throw "Beam fileProgress stream message requires only a 'fileProgress' payload"
    | .diagnostic =>
        match response?, fileProgress?, diagnostic? with
        | none, none, some streamDiagnostic =>
            pure <| .diagnostic clientRequestId? streamDiagnostic
        | _, _, _ =>
            throw "Beam diagnostic stream message requires only a 'diagnostic' payload"

def Response.success (result : Json) : Response :=
  .successResult result none none

def Response.error (code : String) (message : String := "") (data? : Option Json := none) : Response :=
  .errorResult { code, message, data? } none none

def Response.withFileProgress
    (resp : Response)
    (fileProgress : SyncFileProgress) : Response :=
  match resp with
  | .successResult result _ clientRequestId? =>
      .successResult result (some fileProgress) clientRequestId?
  | .errorResult error _ clientRequestId? =>
      .errorResult error (some fileProgress) clientRequestId?

def Response.setClientRequestId (resp : Response) (clientRequestId? : Option String) : Response :=
  match resp with
  | .successResult result fileProgress? _ =>
      .successResult result fileProgress? clientRequestId?
  | .errorResult error fileProgress? _ =>
      .errorResult error fileProgress? clientRequestId?

def Response.setClientRequestIdIfSome
    (resp : Response)
    (clientRequestId? : Option String) : Response :=
  resp.setClientRequestId (clientRequestId? <|> resp.clientRequestId?)

def Request.resolvedWorkspaceId? (req : Request) : Option WorkspaceId :=
  match req.workspaceId?, req.handle? with
  | some workspaceId, _ => some workspaceId
  | none, some handle => some handle.workspaceId
  | none, none => none

def Request.requireWorkspaceId (req : Request) : Except String WorkspaceId := do
  let some workspaceId := req.resolvedWorkspaceId?
    | throw "workspaceId is required"
  unless Beam.Workspace.validWorkspaceId workspaceId do
    throw "workspaceId must be non-empty"
  pure workspaceId

def Request.requireRoot (req : Request) : Except String System.FilePath := do
  let some root := req.root?
    | throw "missing 'root'"
  pure <| System.FilePath.mk root

def Request.requirePath (req : Request) : Except String System.FilePath := do
  let some path := req.path?
    | throw "missing 'path'"
  pure <| System.FilePath.mk path

def Request.requireVersion (req : Request) : Except String Nat := do
  let some version := req.version?
    | throw "missing 'version'"
  pure version

def Request.requireText (req : Request) : Except String String := do
  let some text := req.text?
    | throw "missing 'text'"
  pure text

def Request.requireQuery (req : Request) : Except String String := do
  let some query := req.query?
    | throw "missing 'query'"
  pure query

def Request.requireCodeAction (req : Request) : Except String Lsp.CodeAction := do
  let some codeAction := req.codeAction?
    | throw "missing 'codeAction'"
  pure codeAction

def Request.requireLine (req : Request) : Except String Nat := do
  let some line := req.line?
    | throw "missing 'line'"
  pure line

def Request.requireCharacter (req : Request) : Except String Nat := do
  let some character := req.character?
    | throw "missing 'character'"
  pure character

def Request.requireEndLine (req : Request) : Except String Nat := do
  let some line := req.endLine?
    | throw "missing 'endLine'"
  pure line

def Request.requireEndCharacter (req : Request) : Except String Nat := do
  let some character := req.endCharacter?
    | throw "missing 'endCharacter'"
  pure character

def Request.requireCancelRequestId (req : Request) : Except String String := do
  let some cancelRequestId := req.cancelRequestId?
    | throw "missing 'cancelRequestId'"
  pure cancelRequestId

def Request.requireHandle (req : Request) : Except String Handle := do
  let some handle := req.handle?
    | throw "missing 'handle'"
  pure handle

end Beam.Broker
