/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Lean.Meta.PPGoal
import Lean.Compiler.IR
import RunAt.ProofSnapshot
import RunAt.Protocol
import RunAt.Internal.SaveArtifacts

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM

namespace RunAt

/--
Root plugin module for the standalone `$/lean/runAt` extension.

The current handler executes the provided Lean text against an isolated basis at a position:

- if a proof state is available, it runs the text as a tactic
- otherwise it runs the text as a command on the enclosing command snapshot
-/
def pluginMethod : String := method

private inductive StoredHandleState where
  | command (snapshot : Snapshots.Snapshot)
  | proof (snapshot : ProofSnapshot)

private structure StoredHandle where
  uri : Lean.Lsp.DocumentUri
  version : Nat
  state : StoredHandleState

private structure HandleStore where
  nextId : Nat := 0
  handles : Std.TreeMap String StoredHandle := {}
  deriving Inhabited

initialize handleStoreRef : IO.Ref HandleStore ← IO.mkRef {}
initialize workerToken : String ← do
  let pid ← IO.Process.getPID
  let startedAt ← IO.monoNanosNow
  pure s!"{pid}-{startedAt}"

private def mkMessage (severity : MessageSeverity) (text : String) : RunAt.Message :=
  { severity, text }

private def trimOutput (text : String) : String :=
  text.trimAscii.toString

private def outputMessage? (output : String) : Option RunAt.Message :=
  let output := trimOutput output
  if output.isEmpty then none else some <| mkMessage .information output

private def errorResult (message : String) (proofState? : Option ProofState := none) : Result :=
  {
    success := false
    messages := #[mkMessage .error message]
    proofState?
  }

private def messagesToProtocol (messages : List Lean.Message) : IO (Array RunAt.Message) := do
  messages.toArray.mapM fun message => do
    return mkMessage message.severity (← message.data.toString)

private def tracesToStrings (traces : List TraceElem) : IO (Array String) := do
  traces.toArray.mapM fun trace => do
    return (← trace.msg.toString)

private def ppExprString (e : Expr) : MetaM String := do
  let e ← if getPPInstantiateMVars (← getOptions) then instantiateMVars e else pure e
  return (← Meta.ppExpr e).pretty

private def ppLetValueString? (tactic : Bool) (value : Expr) : MetaM (Option String) := do
  if ← Lean.Meta.ppGoal.shouldShowLetValue tactic value then
    some <$> ppExprString value
  else
    pure none

private def withGoalCtx (goal : MVarId) (action : LocalContext → MetavarDecl → MetaM α) : MetaM α := do
  let mctx ← getMCtx
  let some mvarDecl := mctx.findDecl? goal
    | throwError "unknown goal {goal.name}"
  let lctx := mvarDecl.lctx |>.sanitizeNames.run' { options := (← getOptions) }
  Meta.withLCtx lctx mvarDecl.localInstances (action lctx mvarDecl)

private def addGoalHypBundle
    (hyps : Array GoalHyp)
    (names : Array String)
    (type : Expr)
    (value? : Option Expr := none)
    (tactic : Bool := false) : MetaM (Array GoalHyp) := do
  if names.isEmpty then
    pure hyps
  else
    let renderedValue? ←
      match value? with
      | some value => ppLetValueString? tactic value
      | none => pure none
    return hyps.push {
      names
      type := ← ppExprString type
      value? := renderedValue?
    }

private def goalOfMVarId (mvarId : MVarId) : MetaM Goal := do
  let ppAuxDecls := (← getOptions).getBool `pp.auxDecls false
  let ppImplDetailHyps := (← getOptions).getBool `pp.implementationDetailHyps false
  withGoalCtx mvarId fun lctx mvarDecl => do
    let tactic := mvarDecl.kind.isSyntheticOpaque
    let pushPending
        (names : Array String)
        (type? : Option Expr)
        (hyps : Array GoalHyp) : MetaM (Array GoalHyp) :=
      if names.isEmpty then
        pure hyps
      else
        match type? with
        | none => pure hyps
        | some type => addGoalHypBundle hyps names type (tactic := tactic)
    let mut pendingNames : Array String := #[]
    let mut prevType? : Option Expr := none
    let mut hyps : Array GoalHyp := #[]
    for localDecl in lctx do
      if !ppAuxDecls && localDecl.isAuxDecl || !ppImplDetailHyps && localDecl.isImplementationDetail then
        continue
      else
        match localDecl with
        | LocalDecl.cdecl _index _fvarId varName type ..
        | LocalDecl.ldecl _index _fvarId varName type (nondep := true) .. =>
            let varName := toString varName
            let type ← instantiateMVars type
            if prevType? == none || prevType? == some type then
              pendingNames := pendingNames.push varName
            else
              hyps ← pushPending pendingNames prevType? hyps
              pendingNames := #[varName]
            prevType? := some type
        | LocalDecl.ldecl _index _fvarId varName type val (nondep := false) .. => do
            let varName := toString varName
            hyps ← pushPending pendingNames prevType? hyps
            let type ← instantiateMVars type
            let val ← instantiateMVars val
            hyps ← addGoalHypBundle hyps #[varName] type (value? := some val) (tactic := tactic)
            pendingNames := #[]
            prevType? := none
    hyps ← pushPending pendingNames prevType? hyps
    let userName? := match mvarDecl.userName with
      | Name.anonymous => none
      | name => some <| toString name.eraseMacroScopes
    return {
      userName?
      goalPrefix := Lean.Meta.getGoalPrefix mvarDecl
      target := ← ppExprString (← instantiateMVars mvarDecl.type)
      hyps
    }

private structure ExecutionArtifacts where
  messages : Array RunAt.Message
  traces : Array String
  hasErrors : Bool

private def mkExecutionArtifacts
    (output : String)
    (messages : List Lean.Message)
    (traces : List TraceElem) : RequestM ExecutionArtifacts := do
  let mut protocolMessages ← messagesToProtocol messages
  if let some outputMessage := outputMessage? output then
    protocolMessages := protocolMessages.push outputMessage
  let protocolTraces ← tracesToStrings traces
  return {
    messages := protocolMessages
    traces := protocolTraces
    hasErrors := protocolMessages.any (fun message => message.severity == .error)
  }

private def mkExecutionResult
    (error? : Option String)
    (artifacts : ExecutionArtifacts)
    (proofState? : Option ProofState := none) : Result :=
  match error? with
  | some error =>
      if artifacts.hasErrors then
        { success := false, messages := artifacts.messages, traces := artifacts.traces, proofState? }
      else
        {
          success := false
          messages := artifacts.messages.push (mkMessage .error error)
          traces := artifacts.traces
          proofState?
        }
  | none =>
      {
        success := !artifacts.hasErrors
        messages := artifacts.messages
        traces := artifacts.traces
        proofState?
      }

private def proofStateOfGoalList (goals : List MVarId) : MetaM ProofState := do
  let goals ← goals.mapM goalOfMVarId
  return { goals := goals.toArray }

private def proofStateOfGoals (goals : List MVarId) (ctxInfo : ContextInfo) : RequestM ProofState := do
  ctxInfo.runMetaM {} <| proofStateOfGoalList goals

private def mkBasisCtxInfo (result : GoalsAtResult) (useAfter : Bool := result.useAfter) : ContextInfo :=
  if useAfter then
    { result.ctxInfo with mctx := result.tacticInfo.mctxAfter }
  else
    { result.ctxInfo with mctx := result.tacticInfo.mctxBefore }

private def basisGoals (result : GoalsAtResult) (useAfter : Bool := result.useAfter) : List MVarId :=
  if useAfter then result.tacticInfo.goalsAfter else result.tacticInfo.goalsBefore

private def basisProofState (result : GoalsAtResult) (useAfter : Bool := result.useAfter) :
    RequestM ProofState := do
  proofStateOfGoals (basisGoals result useAfter) (mkBasisCtxInfo result useAfter)

private def checkRequestCancelled : RequestM Unit := do
  let rc ← readThe RequestContext
  if ← rc.cancelTk.wasCancelledByEdit then
    throw RequestError.fileChanged
  if ← rc.cancelTk.wasCancelledByCancelRequest then
    throw RequestError.requestCancelled

private def withInnerCancelToken (k : IO.CancelToken → RequestM α) : RequestM α := do
  let rc ← readThe RequestContext
  let innerCancelTk ← IO.CancelToken.new
  let finished ← IO.Promise.new
  let finishedTask : ServerTask Bool :=
    finished.resultD () |>.asServerTask |>.mapCheap (fun _ => false)
  let cancelTasks :=
    rc.cancelTk.cancellationTasks.map (·.mapCheap (fun _ => true)) ++ [finishedTask]
  discard <| ServerTask.BaseIO.asTask do
    if ← ServerTask.waitAny cancelTasks then
      innerCancelTk.set
  try
    k innerCancelTk
  finally
    finished.resolve ()

private def runCommandElabMWithCancel
    (snap : Snapshots.Snapshot)
    (doc : DocumentMeta)
    (cancelTk? : Option IO.CancelToken)
    (c : Elab.Command.CommandElabM α) : EIO Exception α := do
  let ctx : Command.Context := {
    cmdPos := snap.stx.getPos? |>.getD 0
    fileName := doc.uri
    fileMap := doc.text
    snap? := none
    cancelTk?
  }
  c.run ctx |>.run' snap.cmdState

private def mkFilePath (path : String) : System.FilePath :=
  System.FilePath.mk path

private def ensureParentDir (path : System.FilePath) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent

private def writeIlean
    (doc : DocumentMeta)
    (headerStx : Syntax)
    (mainModule : Name)
    (trees : Array Elab.InfoTree)
    (ileanFile : System.FilePath) : IO Unit := do
  let references := Lean.Server.findModuleRefs doc.text trees (localVars := false)
  let (moduleRefs, decls) ← references.toLspModuleRefs
  let ilean : Lean.Server.Ilean := {
    module := mainModule
    directImports := Lean.Server.collectImports ⟨headerStx⟩
    references := moduleRefs
    decls
  }
  ensureParentDir ileanFile
  IO.FS.writeFile ileanFile (Json.compress <| toJson ilean)

private def singleLineText (text : String) : String :=
  let parts := text.splitOn "\n"
  let parts := parts.filterMap fun part =>
    let trimmed := part.trimAscii.toString
    if trimmed.isEmpty then none else some trimmed
  String.intercalate " " parts

private def formatErrorDiagnostic (diagnostic : Lean.Widget.InteractiveDiagnostic) : String :=
  let line := diagnostic.range.start.line + 1
  let character := diagnostic.range.start.character + 1
  s!"{line}:{character}: {singleLineText diagnostic.message.stripTags}"

private def summarizeErrorItems (items : Array String) (maxItems : Nat := 3) : String :=
  let limit := Nat.min maxItems items.size
  let shown := items.extract 0 limit
  let extra := items.size - shown.size
  let suffix := if extra > 0 then s!" (and {extra} more)" else ""
  s!"{String.intercalate " | " shown.toList}{suffix}"

private def saveArtifactsErrorMessage
    (diagnosticErrors : Array Lean.Widget.InteractiveDiagnostic)
    (commandErrors : Array String) : String :=
  let detailParts : List String :=
    [
      if !diagnosticErrors.isEmpty then
        some s!"diagnostics: {summarizeErrorItems (diagnosticErrors.map formatErrorDiagnostic)}"
      else
        none,
      if !commandErrors.isEmpty then
        some s!"commandMessages: {summarizeErrorItems commandErrors}"
      else
        none
    ].filterMap id
  if detailParts.isEmpty then
    "cannot save artifacts for a document with errors"
  else
    s!"cannot save artifacts for a document with errors; {String.intercalate "; " detailParts}"

private def saveReadinessDocumentErrorsReason : String :=
  "documentErrors"

private def saveReadinessNotElaboratedReason : String :=
  "documentDidNotElaborateSuccessfully"

private def collectSaveReadiness
    (doc : Lean.Server.FileWorker.EditableDocument) :
    RequestM
      (RunAt.Internal.SaveReadinessResult ×
        Option Elab.Command.State ×
        Array Lean.Widget.InteractiveDiagnostic ×
        Array String) := do
  let diagnostics ← doc.diagnosticsRef.get
  let diagnosticErrors := diagnostics.filter (fun diag => diag.severity? == some .error)
  let some cmdState := Lean.Language.Lean.waitForFinalCmdState? doc.initSnap
    | return ({
      version := doc.meta.version
      diagnosticErrorCount := diagnosticErrors.size
      commandErrorCount := 0
      saveReady := false
      saveReadyReason := saveReadinessNotElaboratedReason
      : RunAt.Internal.SaveReadinessResult
    }, none, diagnosticErrors, #[])
  let mut commandErrors : Array String := #[]
  for msg in cmdState.messages.toList do
    if msg.severity == MessageSeverity.error then
      commandErrors := commandErrors.push (singleLineText (← msg.data.toString))
  let commandErrorCount := commandErrors.size
  let saveReady := diagnosticErrors.isEmpty && commandErrors.isEmpty
  let readiness : RunAt.Internal.SaveReadinessResult := {
    version := doc.meta.version
    diagnosticErrorCount := diagnosticErrors.size
    commandErrorCount := commandErrorCount
    saveReady := saveReady
    saveReadyReason := if saveReady then "ok" else saveReadinessDocumentErrorsReason
  }
  pure (readiness, some cmdState, diagnosticErrors, commandErrors)

private def saveCurrentArtifacts
    (doc : Lean.Server.FileWorker.EditableDocument)
    (snaps : List Snapshots.Snapshot)
    (p : RunAt.Internal.SaveArtifactsParams) : RequestM RunAt.Internal.SaveArtifactsResult := do
  checkRequestCancelled
  let (readiness, cmdState?, diagnosticErrors, commandErrors) ← collectSaveReadiness doc
  unless readiness.saveReady do
    throw <| RequestError.invalidParams (saveArtifactsErrorMessage diagnosticErrors commandErrors)
  let some cmdState := cmdState?
    | throw <| RequestError.invalidParams "document did not elaborate successfully"
  let env := cmdState.env
  let mainModule := env.mainModule
  let oleanFile := mkFilePath p.oleanFile
  let ileanFile := mkFilePath p.ileanFile
  let cFile := mkFilePath p.cFile
  ensureParentDir oleanFile
  ensureParentDir cFile
  Lean.writeModule env oleanFile
  let trees := snaps.toArray.map (·.infoTree)
  writeIlean doc.meta doc.initSnap.stx mainModule trees ileanFile
  let cOutput ← IO.ofExcept <| Lean.IR.emitC env mainModule
  IO.FS.writeFile cFile cOutput
  if let some bcFile := p.bcFile?.map mkFilePath then
    ensureParentDir bcFile
    Lean.IR.emitLLVM env mainModule bcFile.toString
  checkRequestCancelled
  pure {
    written := true
    version := doc.meta.version
    textHash := hash doc.meta.text.source
  }

private def docHandleKey (uri : Lean.Lsp.DocumentUri) : String :=
  s!"{hash uri}"

private structure ParsedHandle where
  docKey : String
  workerKey : String

private def parseHandle? (handle : Handle) : Option ParsedHandle :=
  match handle.value.splitOn ":" with
  | ["runAt", docKey, workerKey, _id] => some { docKey, workerKey }
  | _ => none

private def mkHandleString (uri : Lean.Lsp.DocumentUri) (id : Nat) : String :=
  s!"runAt:{docHandleKey uri}:{workerToken}:{id}"

private def eraseStoredHandle (handle : Handle) : BaseIO Unit := do
  handleStoreRef.modify fun store =>
    { store with handles := store.handles.erase handle.value }

private def validateHandleForCurrentDoc (handle : Handle) : RequestM Unit := do
  let doc ← RequestM.readDoc
  let some parsed := parseHandle? handle
    | throw <| RequestError.invalidParams s!"malformed handle '{handle.value}'"
  if parsed.docKey != docHandleKey doc.meta.uri then
    throw <| RequestError.invalidParams s!"handle '{handle.value}' does not belong to this document"
  if parsed.workerKey != workerToken then
    throw RequestError.fileChanged

private def mintHandle (state : StoredHandleState) : RequestM Handle := do
  let doc ← RequestM.readDoc
  handleStoreRef.modifyGet fun store =>
    let handle : Handle := { value := mkHandleString doc.meta.uri store.nextId }
    let stored : StoredHandle := {
      uri := doc.meta.uri
      version := doc.meta.version
      state
    }
    (handle, {
      nextId := store.nextId + 1
      handles := store.handles.insert handle.value stored
    })

private def releaseStoredHandle (handle : Handle) : RequestM Unit := do
  validateHandleForCurrentDoc handle
  let removed ← handleStoreRef.modifyGet fun store =>
    let existed := (store.handles.get? handle.value).isSome
    (existed, { store with handles := store.handles.erase handle.value })
  if !removed then
    throw <| RequestError.invalidParams s!"unknown handle '{handle.value}'"

private def withStoredHandle (handle : Handle) (linear : Bool)
    (k : StoredHandle → RequestM α) : RequestM α := do
  validateHandleForCurrentDoc handle
  let doc ← RequestM.readDoc
  let stored ← handleStoreRef.modifyGet fun store =>
    let stored? := store.handles.get? handle.value
    let handles :=
      if linear then
        store.handles.erase handle.value
      else
        store.handles
    (stored?, { store with handles })
  let some stored := stored
    | throw <| RequestError.invalidParams s!"unknown handle '{handle.value}'"
  if stored.uri != doc.meta.uri then
    eraseStoredHandle handle
    throw <| RequestError.invalidParams s!"handle '{handle.value}' does not belong to this document"
  if stored.version != doc.meta.version then
    eraseStoredHandle handle
    throw RequestError.fileChanged
  k stored

private def maybeAttachHandle
    (result : Result)
    (storeHandle : Bool)
    (state? : Option StoredHandleState) : RequestM Result := do
  if !storeHandle || !result.success then
    return result
  let some state := state?
    | return result
  return { result with handle? := some (← mintHandle state) }

private def lineUtf16Length (text : FileMap) (line : Nat) : Nat :=
  let start := text.lineStart (line + 1)
  let stop :=
    if line + 1 < text.getLastLine then
      text.lineStart (line + 2)
    else
      text.source.rawEndPos
  let lineText := String.Pos.Raw.extract text.source start stop
  let lineText :=
    if lineText.endsWith "\n" then
      (lineText.dropEnd 1).copy
    else
      lineText
  lineText.utf16Length

private def validatePosition (position : Lean.Lsp.Position) : RequestM Unit := do
  let doc ← RequestM.readDoc
  let text := doc.meta.text
  let eof := text.utf8PosToLspPos text.source.rawEndPos
  let lineTooLarge := position.line > eof.line
  let maxCharacter :=
    if position.line > eof.line then
      0
    else
      lineUtf16Length text position.line
  let charTooLarge :=
    if position.line > eof.line then
      false
    else
      position.character > maxCharacter
  if lineTooLarge then
    throw <| RequestError.invalidParams
      s!"position {position} is outside the document: line {position.line} is beyond the last line {eof.line}"
  if charTooLarge then
    throw <| RequestError.invalidParams
      s!"position {position} is outside the document: character {position.character} is beyond max character {maxCharacter} for line {position.line}"

private def noSnapshotFoundMessage (position : Lean.Lsp.Position) : String :=
  s!"position {position} is inside the document, but Lean has no command or tactic snapshot there; try a position inside a command or proof body, not a standalone comment, blank line, or declaration header"

private def withRunAtSnapAtPos
    (position : Lean.Lsp.Position)
    (f : Snapshots.Snapshot → RequestM α) : RequestM (RequestTask α) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.withWaitFindSnap doc (fun snap => snap.endPos >= pos)
    (notFoundX := throw <| RequestError.invalidParams (noSnapshotFoundMessage position))
    (x := f)

private def findProofBasisAt (position : Lean.Lsp.Position) : RequestM (RequestTask (Option GoalsAtResult)) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.mapTaskCostly (Lean.Server.FileWorker.findGoalsAt? doc pos) fun
    | some (result :: _) => return some result
    | _ => return none

private def findProofBasis (p : Params) : RequestM (RequestTask (Option GoalsAtResult)) :=
  findProofBasisAt p.position

private def noProofBasisFoundMessage (position : Lean.Lsp.Position) : String :=
  s!"position {position} is inside the document, but Lean has no proof goals there; try a position inside a tactic or proof body"

private def runCommandText (snap : Snapshots.Snapshot) (text : String) : RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let rc ← readThe RequestContext
    let stx ←
      match Parser.runParserCategory snap.env `command text "<runAt>" with
      | .ok stx => pure stx
      | .error err => return (errorResult err, none)
    let (output, response) ← IO.FS.withIsolatedStreams do
      EIO.toBaseIO do
        runCommandElabMWithCancel snap rc.doc.meta (some innerCancelTk) do
          let initialMsgCount := (← get).messages.toList.length
          let initialTraceCount := (← getTraces).size
          let error? ← try
            Elab.Command.elabCommandTopLevel stx
            pure none
          catch ex =>
            if ex.isInterrupt then
              throw ex
            pure (some (← ex.toMessageData.toString))
          let state ← get
          let messages := state.messages.toList.drop initialMsgCount
          let traces := (← getTraces).toList.drop initialTraceCount
          return (error?, messages, traces, state)
    let (error?, newMessages, newTraces, newState) ←
      match response with
      | .ok response => pure response
      | .error ex =>
          checkRequestCancelled
          throw <| RequestError.internalError (← ex.toMessageData.toString)
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let result := mkExecutionResult error? artifacts
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.command { snap with cmdState := newState }
      else
        none
    return (result, nextHandle?)

private def proofStateOfSnapshot (snapshot : ProofSnapshot) : RequestM ProofState := do
  let (proofState, _) ← snapshot.runMetaM <| proofStateOfGoalList snapshot.tacticState.goals
  return proofState

private def runTacticText (snapshot : ProofSnapshot) (initialProofState : ProofState) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let snapshot := snapshot.withCancelToken (some innerCancelTk)
    let stx ←
      match Parser.runParserCategory snapshot.coreState.env `tactic text "<runAt>" with
      | .ok stx => pure stx
      | .error err => return (errorResult err (some initialProofState), none)
    let (output, ((error?, newMessages, newTraces), proofSnapshot')) ←
      try
        IO.FS.withIsolatedStreams do
          let run := snapshot.runTacticM do
            let saved ← Elab.Tactic.saveState
            let initialMsgCount := (← Core.getMessageLog).toList.length
            let initialTraceCount := (← getTraces).size
            let error? ← try
              Elab.Tactic.evalTactic stx
              pure none
            catch ex =>
              if ex.isInterrupt then
                throw ex
              saved.restore (restoreInfo := true)
              pure (some (← ex.toMessageData.toString))
            let messages := (← Core.getMessageLog).toList.drop initialMsgCount
            let traces := (← getTraces).toList.drop initialTraceCount
            return ((error?, messages, traces))
          run
      catch ex =>
        checkRequestCancelled
        throw ex
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let proofState ←
      if error?.isSome then
        pure initialProofState
      else
        proofStateOfSnapshot proofSnapshot'
    let result := mkExecutionResult error? artifacts (proofState? := some proofState)
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.proof proofSnapshot'
      else
        none
    return (result, nextHandle?)

private def runTacticAtBasis (basis : GoalsAtResult) (text : String) : RequestM (Result × Option StoredHandleState) := do
  let ctxInfo := mkBasisCtxInfo basis
  let initialProofState ← basisProofState basis
  let proofSnapshot ← ProofSnapshot.create ctxInfo (basisGoals basis)
  runTacticText proofSnapshot initialProofState text

private def handleGoalsAt (p : GoalsParams) (useAfter : Bool) : RequestM (RequestTask ProofState) := do
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasisAt p.position
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis => do
        checkRequestCancelled
        return RequestTask.pure (← basisProofState basis useAfter)
    | none =>
        throw <| RequestError.invalidParams (noProofBasisFoundMessage p.position)

private def handleRunAt (p : Params) : RequestM (RequestTask Result) := do
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasis p
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis => do
        checkRequestCancelled
        let (result, state?) ← runTacticAtBasis basis p.text
        return RequestTask.pure (← maybeAttachHandle result (p.storeHandle?.getD false) state?)
    | none =>
        withRunAtSnapAtPos p.position fun snap => do
          checkRequestCancelled
          let (result, state?) ← runCommandText snap p.text
          maybeAttachHandle result (p.storeHandle?.getD false) state?

private def handleRunWith (p : RunWithParams) : RequestM (RequestTask Result) := do
  checkRequestCancelled
  withStoredHandle p.handle (p.linear?.getD false) fun stored => do
    RequestM.asTask do
      checkRequestCancelled
      let (result, state?) ←
        match stored.state with
        | .command snapshot =>
            runCommandText snapshot p.text
        | .proof snapshot =>
            let initialProofState ← proofStateOfSnapshot snapshot
            runTacticText snapshot initialProofState p.text
      maybeAttachHandle result (p.storeHandle?.getD false) state?

private def handleReleaseHandle (p : ReleaseHandleParams) : RequestM (RequestTask Json) := do
  releaseStoredHandle p.handle
  return RequestTask.pure Json.null

private def handleSaveArtifacts
    (p : RunAt.Internal.SaveArtifactsParams) : RequestM (RequestTask RunAt.Internal.SaveArtifactsResult) := do
  let doc ← RequestM.readDoc
  let t := doc.cmdSnaps.waitAll
  RequestM.mapTaskCostly t fun (snaps, _) => do
    saveCurrentArtifacts doc snaps p

private def handleSaveReadiness
    (_p : RunAt.Internal.SaveReadinessParams) : RequestM (RequestTask RunAt.Internal.SaveReadinessResult) := do
  let doc ← RequestM.readDoc
  let t := doc.cmdSnaps.waitAll
  RequestM.mapTaskCostly t fun _ => do
    let (readiness, _, _, _) ← collectSaveReadiness doc
    pure readiness

private def handleDirectImports
    (_p : RunAt.Internal.DirectImportsParams) : RequestM (RequestTask RunAt.Internal.DirectImportsResult) := do
  let doc ← RequestM.readDoc
  checkRequestCancelled
  let inputCtx := Lean.Parser.mkInputContext doc.meta.text.source doc.meta.uri
  let (header, _, _) ← Lean.Parser.parseHeader inputCtx
  let imports :=
    (Lean.Server.collectImports header).foldl (init := #[]) fun acc info =>
      if acc.contains info.module then
        acc
      else
        acc.push info.module
  return RequestTask.pure {
    version := doc.meta.version
    imports
  }

initialize
  registerLspRequestHandler method Params Result handleRunAt
  registerLspRequestHandler goalsAfterMethod GoalsParams ProofState (fun p => handleGoalsAt p true)
  registerLspRequestHandler goalsPrevMethod GoalsParams ProofState (fun p => handleGoalsAt p false)
  registerLspRequestHandler runWithMethod RunWithParams Result handleRunWith
  registerLspRequestHandler releaseHandleMethod ReleaseHandleParams Json handleReleaseHandle
  registerLspRequestHandler RunAt.Internal.saveArtifactsMethod
    RunAt.Internal.SaveArtifactsParams
    RunAt.Internal.SaveArtifactsResult
    handleSaveArtifacts
  registerLspRequestHandler RunAt.Internal.saveReadinessMethod
    RunAt.Internal.SaveReadinessParams
    RunAt.Internal.SaveReadinessResult
    handleSaveReadiness
  registerLspRequestHandler RunAt.Internal.directImportsMethod
    RunAt.Internal.DirectImportsParams
    RunAt.Internal.DirectImportsResult
    handleDirectImports

end RunAt
