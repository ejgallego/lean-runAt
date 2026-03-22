/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import RunAt.Internal.SaveSupport
import Beam.Broker.LakeSave
import Beam.Broker.Protocol

open Lean
open Lean.Lsp

namespace Beam.Broker

def isIncompleteBarrierDiagnostic (diagnostic : Diagnostic) : Bool :=
  diagnostic.message.contains "Failed to build module dependencies." ||
    diagnostic.message.contains "error: target is out-of-date and needs to be rebuilt"

def effectiveSyncDiagnosticSeverity (diagnostic : Diagnostic) :
    Option DiagnosticSeverity :=
  if isIncompleteBarrierDiagnostic diagnostic then
    some .error
  else
    diagnostic.severity?

def filterSyncDiagnostics (fullDiagnostics : Bool) (diagnostics : Array Diagnostic) :
    Array Diagnostic :=
  if fullDiagnostics then
    diagnostics
  else
    diagnostics.filter (fun diagnostic => effectiveSyncDiagnosticSeverity diagnostic == some .error)

def syncErrorCount (diagnostics : Array Diagnostic) : Nat :=
  diagnostics.foldl (init := 0) fun count diagnostic =>
    if effectiveSyncDiagnosticSeverity diagnostic == some .error then
      count + 1
    else
      count

def syncWarningCount (diagnostics : Array Diagnostic) : Nat :=
  diagnostics.foldl (init := 0) fun count diagnostic =>
    if effectiveSyncDiagnosticSeverity diagnostic == some .warning then
      count + 1
    else
      count

structure SyncSaveReadiness where
  stateErrorCount : Nat := 0
  stateCommandErrorCount : Nat := 0
  saveReady : Bool := true
  saveReadyReason : String := "ok"
  deriving Inhabited

def syncSaveReadinessOfResult
    (result : RunAt.Internal.SaveReadinessResult) : SyncSaveReadiness :=
  {
    stateErrorCount := result.diagnosticErrorCount
    stateCommandErrorCount := result.commandErrorCount
    saveReady := result.saveReady
    saveReadyReason := result.saveReadyReason
  }

def diagnosticsIndicateIncompleteBarrier (diagnostics : Array Diagnostic) : Bool :=
  diagnostics.any isIncompleteBarrierDiagnostic

def incompleteBarrierProgress (progress? : Option SyncFileProgress := none) : SyncFileProgress :=
  match progress? with
  | some progress => { progress with done := false }
  | none => { done := false }

def syncBarrierIncompleteMessage
    (uri : DocumentUri)
    (version : Nat)
    (progress? : Option SyncFileProgress) : String :=
  let progress := incompleteBarrierProgress progress?
  s!"Lean diagnostics barrier did not complete for {uri} at version {version}; " ++
    s!"fileProgress={toJson progress |>.compress}. An imported target may be stale or broken, " ++
    s!"or the Lean worker may have exited. Run `lake build` or fix the upstream module first."

def syncBarrierIncomplete?
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic := #[]) : Bool :=
  if diagnosticsIndicateIncompleteBarrier diagnostics then
    true
  else
    match progress? with
    | some progress => !progress.done
    | none => false

def effectiveSyncBarrierProgress
    (priorProgress? : Option SyncFileProgress)
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic) : Option SyncFileProgress :=
  if diagnosticsIndicateIncompleteBarrier diagnostics then
    some <| incompleteBarrierProgress (progress?.or priorProgress?)
  else
    match progress? with
    | some progress =>
        some progress
    | none =>
        some <| priorProgress?.getD {}

def leanSavePayload (spec : LeanSaveSpec) (version : Nat) (sourceHash : Lake.Hash) : Json :=
  Json.mkObj <|
    [
      ("path", toJson spec.relPath),
      ("module", toJson spec.moduleName.toString),
      ("version", toJson version),
      ("sourceHash", toJson sourceHash),
      ("olean", toJson spec.oleanPath.toString),
      ("ilean", toJson spec.ileanPath.toString),
      ("c", toJson spec.cPath.toString),
      ("trace", toJson spec.tracePath.toString)
    ] ++
    (match spec.oleanServerPath? with
    | some path => [("oleanServer", toJson path.toString)]
    | none => []) ++
    (match spec.oleanPrivatePath? with
    | some path => [("oleanPrivate", toJson path.toString)]
    | none => []) ++
    (match spec.irPath? with
    | some path => [("ir", toJson path.toString)]
    | none => []) ++
    (match spec.bcPath? with
    | some path => [("bc", toJson path.toString)]
    | none => [])

end Beam.Broker
