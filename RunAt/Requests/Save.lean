/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Compiler.IR
import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import RunAt.Internal.SaveSupport
import RunAt.Lib.Handles
import RunAt.Lib.Support

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open RunAt.Lib

namespace RunAt.Requests

def mkFilePath (path : String) : System.FilePath :=
  System.FilePath.mk path

def ensureParentDir (path : System.FilePath) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent

def writeIlean
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

def singleLineText (text : String) : String :=
  let parts := text.splitOn "\n"
  let parts := parts.filterMap fun part =>
    let trimmed := part.trimAscii.toString
    if trimmed.isEmpty then none else some trimmed
  String.intercalate " " parts

def formatErrorDiagnostic (diagnostic : Lean.Widget.InteractiveDiagnostic) : String :=
  let line := diagnostic.range.start.line + 1
  let character := diagnostic.range.start.character + 1
  s!"{line}:{character}: {singleLineText diagnostic.message.stripTags}"

def summarizeErrorItems (items : Array String) (maxItems : Nat := 3) : String :=
  let limit := Nat.min maxItems items.size
  let shown := items.extract 0 limit
  let extra := items.size - shown.size
  let suffix := if extra > 0 then s!" (and {extra} more)" else ""
  s!"{String.intercalate " | " shown.toList}{suffix}"

def saveArtifactsErrorMessage
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

def saveReadinessDocumentErrorsReason : String :=
  "documentErrors"

def saveReadinessNotElaboratedReason : String :=
  "documentDidNotElaborateSuccessfully"

def collectSaveReadiness
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

def saveCurrentArtifacts
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

def handleSaveArtifacts
    (p : RunAt.Internal.SaveArtifactsParams) :
    RequestM (RequestTask RunAt.Internal.SaveArtifactsResult) := do
  syncHandleStoreForCurrentDoc
  let doc ← RequestM.readDoc
  let t := doc.cmdSnaps.waitAll
  RequestM.mapTaskCostly t fun (snaps, _) => do
    saveCurrentArtifacts doc snaps p

def handleSaveReadiness
    (_p : RunAt.Internal.SaveReadinessParams) :
    RequestM (RequestTask RunAt.Internal.SaveReadinessResult) := do
  syncHandleStoreForCurrentDoc
  let doc ← RequestM.readDoc
  let t := doc.cmdSnaps.waitAll
  RequestM.mapTaskCostly t fun _ => do
    let (readiness, _, _, _) ← collectSaveReadiness doc
    pure readiness

end RunAt.Requests
