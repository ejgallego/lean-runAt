/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Pending
import BeamTest.Broker.JsonAssert

open Lean
open Lean.JsonRpc
open Lean.Lsp
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.PendingTest

private def requireFailureCode
    (label expectedCode : String)
    (failure : ResponseFailure) : IO Error := do
  if failure.error.code != expectedCode then
    throw <| IO.userError
      s!"{label}: expected code={expectedCode}, got {(toJson failure.toResponse).compress}"
  pure failure.error

private def mkPending
    (cancelRef? : Option (IO.Ref Bool) := none)
    (progress? : Option SyncFileProgress := none)
    (tracked? : Option (DocumentUri × Nat) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (PendingRequest × IO.Promise (Except ResponseFailure PendingResult)) := do
  let promise ← IO.Promise.new
  let progressRef ← IO.mkRef progress?
  let diagnosticsRef ← IO.mkRef #[]
  let diagnosticsSeenRef ← IO.mkRef false
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  pure ({
    cancelRef?
    promise
    tracked?
    progressRef
    diagnosticsRef
    diagnosticsSeenRef
    seenDiagnosticKeysRef
    diagnosticScope
    emitDiagnostic?
  }, promise)

private def expectRegistered
    (label : String)
    (result : Except BrokerFailure (Option ActiveRequest)) : IO (Option ActiveRequest) := do
  match result with
  | .ok active? => pure active?
  | .error failure =>
      throw <| IO.userError s!"{label}: {failure.message}"

private def checkActiveRegistry : IO Unit := do
  let registry ← ActiveRequestRegistry.create
  let noneResult ← ActiveRequestRegistry.register registry none
  let noneActive : Option ActiveRequest ←
    expectRegistered "register without clientRequestId" noneResult
  require "register without clientRequestId returns none" (Option.isNone noneActive)

  let firstResult ← ActiveRequestRegistry.register registry (some "req-1")
  let first? : Option ActiveRequest ←
    expectRegistered "register active request" firstResult
  let some first := first?
    | throw <| IO.userError "register active request returned none"
  match ← ActiveRequestRegistry.register registry (some "req-1") with
  | .ok _ =>
      throw <| IO.userError "duplicate clientRequestId registered successfully"
  | .error failure =>
      require "duplicate active request error is typed" (failure.code == .invalidParams)
      require "duplicate active request error names id" (failure.message.contains "req-1")

  require "mark active request cancelled"
    (Option.isSome (← ActiveRequestRegistry.markCancelled registry "req-1"))
  match ← ensureRequestNotCancelled (some (ActiveRequest.cancelRef first)) with
  | .ok _ =>
      throw <| IO.userError "ensureRequestNotCancelled reports broker cancellation: expected error"
  | .error failure =>
      discard <| requireFailureCode
        "ensureRequestNotCancelled reports broker cancellation"
        "requestCancelled"
        failure

  ActiveRequestRegistry.unregister registry first?
  require "unregistered active request is no longer cancellable"
    (Option.isNone (← ActiveRequestRegistry.markCancelled registry "req-1"))

  let replacementResult ← ActiveRequestRegistry.register registry (some "req-1")
  let replacement? : Option ActiveRequest ←
    expectRegistered "register replacement active request" replacementResult
  let some replacement := replacement?
    | throw <| IO.userError "register replacement active request returned none"
  ActiveRequestRegistry.unregister registry first?
  require "stale active handle cannot cancel replacement"
    (Option.isNone (← ActiveRequestRegistry.markCancelledActive registry first))
  match ← ensureRequestNotCancelled (some replacement.cancelRef) with
  | .ok _ => pure ()
  | .error failure =>
      throw <| IO.userError
        s!"stale active handle cancelled replacement: {(toJson failure.toResponse).compress}"
  require "stale unregister preserves replacement active request"
    (Option.isSome (← ActiveRequestRegistry.markCancelled registry "req-1"))
  match ← ensureRequestNotCancelled (some replacement.cancelRef) with
  | .ok _ =>
      throw <| IO.userError "replacement active request did not observe cancellation"
  | .error failure =>
      discard <| requireFailureCode
        "replacement active request reports broker cancellation"
        "requestCancelled"
        failure
  ActiveRequestRegistry.unregister registry replacement?

private def checkPendingCancellationIdentity : IO Unit := do
  let registry ← ActiveRequestRegistry.create
  let firstResult ← ActiveRequestRegistry.register registry (some "reused-id")
  let some first ← expectRegistered "register first cancellation identity" firstResult
    | throw <| IO.userError "register first cancellation identity returned none"
  ActiveRequestRegistry.unregister registry (some first)
  let replacementResult ← ActiveRequestRegistry.register registry (some "reused-id")
  let some replacement ← expectRegistered "register replacement cancellation identity" replacementResult
    | throw <| IO.userError "register replacement cancellation identity returned none"
  let (firstPending, _) ← mkPending (cancelRef? := some first.cancelRef)
  let (replacementPending, _) ← mkPending (cancelRef? := some replacement.cancelRef)
  require "first admission matches its pending request"
    (← PendingRequestStore.matchesCancellation firstPending first.cancelRef)
  require "first admission does not match replacement pending request"
    (!(← PendingRequestStore.matchesCancellation replacementPending first.cancelRef))
  require "replacement admission does not match first pending request"
    (!(← PendingRequestStore.matchesCancellation firstPending replacement.cancelRef))
  require "replacement admission matches its pending request"
    (← PendingRequestStore.matchesCancellation replacementPending replacement.cancelRef)
  ActiveRequestRegistry.unregister registry (some replacement)

private def checkPendingStoreResolve : IO Unit := do
  let store ← PendingRequestStore.create
  let (pending, promise) ← mkPending
    (progress? := some { updates := 3, done := false })
  let id : RequestID := 7
  PendingRequestStore.insert store id pending
  let entries ← PendingRequestStore.snapshotEntries store
  require "pending store has inserted request" (entries.size == 1)
  let some pending ← PendingRequestStore.remove store id
    | throw <| IO.userError "pending store remove missed inserted request"
  PendingRequest.resolveResponse pending (Json.mkObj [("value", toJson true)])
  let result ←
    match ← PendingRequest.awaitOutcome promise with
    | .ok result => pure result
    | .error failure =>
        throw <| IO.userError
          s!"pending response result: expected success, got {(toJson failure.toResponse).compress}"
  requireJsonBool "pending response result" "value" true result.result
  require "pending response preserves progress"
    (result.progress? == some { updates := 3, done := false })
  require "pending response records no diagnostics publication"
    (!result.diagnosticsSeen)
  require "pending store is empty after remove"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def checkPendingStoreFailAll : IO Unit := do
  let store ← PendingRequestStore.create
  let (pending, promise) ← mkPending
  PendingRequestStore.insert store 11 pending
  PendingRequestStore.failAll store (responseFailure "workerExited" "worker exited")
  match ← PendingRequest.awaitOutcome promise with
  | .ok _ =>
      throw <| IO.userError "failAll resolves pending request as an error: expected error"
  | .error failure =>
      discard <| requireFailureCode
        "failAll resolves pending request as an error" "workerExited" failure
  require "failAll clears pending store"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def mkRange (startLine startCharacter endLine endCharacter : Nat) : Range := {
  start := { line := startLine, character := startCharacter }
  «end» := { line := endLine, character := endCharacter }
}

private def mkFileProgress (ranges : Array Range) : LeanFileProgressParams := {
  textDocument := { uri := "file:///workspace/Foo.lean", version? := some 1 }
  processing := ranges.map fun range => { range }
}

private def mkDiagnostic (range : Range) (message : String) : Diagnostic := {
  range
  fullRange? := some range
  severity? := some .error
  message
}

private def mkDiagnosticWithSeverity
    (range : Range)
    (severity : DiagnosticSeverity)
    (message : String) : Diagnostic := {
  range
  fullRange? := some range
  severity? := some severity
  message
}

private def mkPublishDiagnostics (diagnostics : Array Diagnostic) : PublishDiagnosticsParams := {
  uri := "file:///workspace/Foo.lean"
  version? := some 1
  diagnostics
}

private def observeFileProgress
    (progress : SyncFileProgress)
    (ranges : Array Range) : IO SyncFileProgress := do
  let (pending, _) ← mkPending
    (progress? := some progress)
    (tracked? := some ("file:///workspace/Foo.lean", 1))
  PendingRequest.observeProgress pending (mkFileProgress ranges)
  let some next ← pending.progressRef.get
    | throw <| IO.userError "observeProgress cleared fileProgress"
  pure next

private def checkSyncFileProgressDisplay : IO Unit := do
  require "display includes range and done=false"
    (SyncFileProgress.displayDetails {
      updates := 4
      done := false
      rangeStartLine? := some 3
      rangeEndLine? := some 13
    } == "range=3..13 updates=4 done=false")
  require "display can omit done=true"
    (SyncFileProgress.displayDetails {
      updates := 5
      done := true
      rangeEndLine? := some 13
    } (includeDoneTrue := false) == "rangeEndLine=13 updates=5")

private def checkSyncFileProgressLines : IO Unit := do
  let trailingNewline ← observeFileProgress {} #[mkRange 0 0 1 0]
  require "progress trailing newline reports one-line range bound"
    (trailingNewline == {
      updates := 1
      done := false
      rangeStartLine? := some 1
      rangeEndLine? := some 1
    })

  let multipleRanges ← observeFileProgress {} #[
    mkRange 5 0 10 0,
    mkRange 2 0 12 3
  ]
  require "progress multiple ranges use earliest active line and max range end"
    (multipleRanges == {
      updates := 1
      done := false
      rangeStartLine? := some 3
      rangeEndLine? := some 13
    })

  let finished ← observeFileProgress multipleRanges #[]
  require "progress final empty processing preserves range end and clears active range start"
    (finished == {
      updates := 2
      done := true
      rangeEndLine? := some 13
    })
  let renderedProgress := toJson finished
  requireFieldAbsent "finished progress" "line" renderedProgress
  requireFieldAbsent "finished progress" "totalLines" renderedProgress
  requireJsonInt "finished progress" "rangeEndLine" 13 renderedProgress

private def checkDiagnosticLineCanExceedProgressRange : IO Unit := do
  let active ← observeFileProgress {} #[mkRange 0 0 1 0]
  let finished ← observeFileProgress active #[]
  require "progress fixture ends at one-line range bound"
    (finished == {
      updates := 2
      done := true
      rangeEndLine? := some 1
    })

  let farDiagnostic := mkDiagnostic (mkRange 20 2 20 8) "diagnostic beyond progress range"
  let (pending, _) ← mkPending
    (progress? := some finished)
    (tracked? := some ("file:///workspace/Foo.lean", 1))
  PendingRequest.observeDiagnostics
    (System.FilePath.mk ".")
    pending
    (mkPublishDiagnostics #[farDiagnostic])
  require "diagnostic publication does not rewrite fileProgress range"
    ((← pending.progressRef.get) == some finished)
  let diagnostics ← pending.diagnosticsRef.get
  let some diagnostic := diagnostics[0]?
    | throw <| IO.userError "expected diagnostic beyond progress range"
  require "diagnostic may start beyond progress rangeEndLine"
    (diagnostic.range.start.line + 1 > finished.rangeEndLine?.getD 0)

private def observeStreamedDiagnostics
    (diagnosticScope : DiagnosticScope)
    (diagnostics : Array Diagnostic) : IO (Array StreamDiagnostic) := do
  let streamedRef ← IO.mkRef #[]
  let (pending, _) ← mkPending
    (tracked? := some ("file:///workspace/Foo.lean", 1))
    (diagnosticScope := diagnosticScope)
    (emitDiagnostic? := some fun diagnostic =>
      streamedRef.modify (·.push diagnostic))
  PendingRequest.observeDiagnostics
    (System.FilePath.mk "/workspace")
    pending
    (mkPublishDiagnostics diagnostics)
  streamedRef.get

private def checkSetupFileProgressStreamsByScope : IO Unit := do
  let setupProgress :=
    mkDiagnosticWithSeverity
      (mkRange 0 0 1 0)
      .information
      "✔ [1/2] Built Liris.Iris.HeapLang.PrimitiveLaws (12s)\n"
  let warning :=
    mkDiagnosticWithSeverity
      (mkRange 3 0 3 6)
      .warning
      "unused variable"
  let goalsAccomplished := {
    mkDiagnosticWithSeverity
      (mkRange 5 0 5 8)
      .information
      "Goals accomplished!" with
    isSilent? := some true
    leanTags? := some #[.goalsAccomplished]
  }
  let defaultStreamed ← observeStreamedDiagnostics .errors #[setupProgress, warning, goalsAccomplished]
  require "default sync streams setup-file status"
    (defaultStreamed.map (·.message) == #[setupProgress.message])
  require "default setup-file status stays informational"
    (defaultStreamed.all (fun diagnostic => diagnostic.severity? == some .information))

  let allStreamed ← observeStreamedDiagnostics .all #[setupProgress, warning, goalsAccomplished]
  require "all diagnostic scope streams user-facing setup-file status and warning"
    (allStreamed.map (·.message) == #[setupProgress.message, warning.message])

def main : IO Unit := do
  checkActiveRegistry
  checkPendingCancellationIdentity
  checkPendingStoreResolve
  checkPendingStoreFailAll
  checkSyncFileProgressDisplay
  checkSyncFileProgressLines
  checkDiagnosticLineCanExceedProgressRange
  checkSetupFileProgressStreamsByScope

end BeamTest.Broker.PendingTest

def main := BeamTest.Broker.PendingTest.main
