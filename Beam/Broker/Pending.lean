/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Communication
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Lean.Data.Lsp.Internal
import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.SyncSaveSupport
import Std.Sync.Mutex

open Lean
open Lean.JsonRpc
open Lean.Lsp
open IO.FS.Stream

namespace Beam.Broker

structure PendingResult where
  result : Json
  progress? : Option SyncFileProgress := none
  diagnostics : Array Diagnostic := #[]
  diagnosticsSeen : Bool := false

structure PendingRequest where
  cancelRef? : Option (IO.Ref Bool) := none
  promise : IO.Promise (Except ResponseFailure PendingResult)
  tracked? : Option (DocumentUri × Nat) := none
  progressRef : IO.Ref (Option SyncFileProgress)
  diagnosticsRef : IO.Ref (Array Diagnostic)
  diagnosticsSeenRef : IO.Ref Bool
  emitProgress? : Option (SyncFileProgress → IO Unit) := none
  diagnosticScope : DiagnosticScope := .errors
  seenDiagnosticKeysRef : IO.Ref (Std.TreeSet String compare)
  emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none

abbrev PendingRequestStore := Std.Mutex (Std.TreeMap RequestID PendingRequest)

namespace PendingRequestStore

def create : BaseIO PendingRequestStore :=
  Std.Mutex.new ({} : Std.TreeMap RequestID PendingRequest)

def insert (store : PendingRequestStore) (id : RequestID) (pending : PendingRequest) : IO Unit := do
  store.atomically do
    modify (·.insert id pending)

def remove (store : PendingRequestStore) (id : RequestID) : IO (Option PendingRequest) := do
  store.atomically do
    let pending? := (← get).get? id
    modify (·.erase id)
    pure pending?

def snapshot (store : PendingRequestStore) : IO (Array PendingRequest) := do
  store.atomically do
    pure <| (← get).toList.map Prod.snd |>.toArray

def snapshotEntries (store : PendingRequestStore) : IO (Array (RequestID × PendingRequest)) := do
  store.atomically do
    pure <| (← get).toList.toArray

def clear (store : PendingRequestStore) : IO (Array PendingRequest) := do
  store.atomically do
    let pending := (← get).toList.map Prod.snd |>.toArray
    set ({} : Std.TreeMap RequestID PendingRequest)
    pure pending

end PendingRequestStore

namespace PendingRequest

def resolveResponse (pending : PendingRequest) (result : Json) : IO Unit := do
  let progress? ← pending.progressRef.get
  let diagnostics ← pending.diagnosticsRef.get
  let diagnosticsSeen ← pending.diagnosticsSeenRef.get
  try
    pending.promise.resolve (.ok { result, progress?, diagnostics, diagnosticsSeen })
  catch _ =>
    pure ()

def resolveError
    (pending : PendingRequest)
    (code : ErrorCode)
    (message : String)
    (data? : Option Json := none) : IO Unit := do
  let progress? ← pending.progressRef.get
  let failure :=
    (backendResponseFailure code message data?).withOptionalFileProgress progress?
  try
    pending.promise.resolve (.error failure)
  catch _ =>
    pure ()

def awaitOutcome (promise : IO.Promise (Except ResponseFailure PendingResult)) :
    IO (Except ResponseFailure PendingResult) := do
  let some result ← IO.wait promise.result?
    | throw <| IO.userError "pending broker request promise dropped"
  pure result

private def normalizePublishDiagnostics (params : PublishDiagnosticsParams) :
    PublishDiagnosticsParams := {
  params with
  diagnostics :=
    let diagnostics := Beam.LSP.Lib.userVisibleDiagnostics params.diagnostics
    let sorted := diagnostics.toList.mergeSort fun d1 d2 =>
      compare d1.fullRange d2.fullRange |>.then (compare d1.message d2.message) |>.isLE
    sorted.toArray
}

private structure FileProgressRangeInfo where
  rangeStartLine : Nat
  rangeEndLine : Nat

private def fileProgressRangeEndLine (range : Range) : Nat :=
  let endPos := range.«end»
  if endPos.line > 0 && endPos.character == 0 then
    endPos.line
  else
    endPos.line + 1

private def mergeFileProgressRangeInfo
    (info? : Option FileProgressRangeInfo)
    (range : Range) : Option FileProgressRangeInfo :=
  let rangeStartLine := range.start.line + 1
  let rangeEndLine := fileProgressRangeEndLine range
  match info? with
  | none => some { rangeStartLine, rangeEndLine }
  | some info =>
      some {
        rangeStartLine := Nat.min info.rangeStartLine rangeStartLine
        rangeEndLine := Nat.max info.rangeEndLine rangeEndLine
      }

private def fileProgressRangeInfo? (params : LeanFileProgressParams) :
    Option FileProgressRangeInfo :=
  params.processing.foldl
    (init := none)
    (fun info? processing => mergeFileProgressRangeInfo info? processing.range)

private def updateSyncFileProgress (progress : SyncFileProgress) (params : LeanFileProgressParams) :
    SyncFileProgress :=
  let processing := params.processing.size
  let rangeInfo? := fileProgressRangeInfo? params
  let done := processing == 0
  let rangeEndLine? := rangeInfo?.map (·.rangeEndLine) |>.or progress.rangeEndLine?
  let rangeStartLine? :=
    match rangeInfo? with
    | some info => some info.rangeStartLine
    | none => if done then none else progress.rangeStartLine?
  {
    updates := progress.updates + 1
    done
    rangeStartLine?
    rangeEndLine?
  }

private def matchesSyncFileProgress
    (uri : DocumentUri)
    (version : Nat)
    (params : LeanFileProgressParams) : Bool :=
  let matchesUri := params.textDocument.uri == uri
  let matchesVersion := params.textDocument.version?.map (fun progressVersion =>
    decide (version <= progressVersion)) |>.getD true
  matchesUri && matchesVersion

private def observeSyncFileProgress
    [ToJson α]
    (tracked : Option (DocumentUri × Nat))
    (progress? : Option SyncFileProgress)
    (param : α) : Option SyncFileProgress :=
  match tracked, progress?, fromJson? (toJson param) with
  | some (uri, version), some progress, .ok (progressParam : LeanFileProgressParams) =>
      if matchesSyncFileProgress uri version progressParam then
        some <| updateSyncFileProgress progress progressParam
      else
        some progress
  | _, _, _ =>
      progress?

private def trackedPublishDiagnosticsParam?
    (trackedUri? : Option DocumentUri)
    (diagnosticParam : PublishDiagnosticsParams) : Option PublishDiagnosticsParams :=
  match trackedUri? with
  | some uri =>
      let diagnosticParam := normalizePublishDiagnostics diagnosticParam
      if diagnosticParam.uri == uri then
        some diagnosticParam
      else
        none
  | none =>
      none

private def diagnosticStreamKey (diagnostic : Diagnostic) : String :=
  (toJson diagnostic).compress

private def emitNewTrackedDiagnostics
    (root : System.FilePath)
    (seen : Std.TreeSet String compare)
    (diagnosticParam : PublishDiagnosticsParams)
    (diagnosticScope : DiagnosticScope)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Std.TreeSet String compare) := do
  let mut seen := seen
  let diagnostics := filterSyncDiagnostics diagnosticScope diagnosticParam.diagnostics
  for diagnostic in diagnostics do
    let key := diagnosticStreamKey diagnostic
    if !seen.contains key then
      seen := seen.insert key
      match emitDiagnostic? with
      | some emitDiagnostic =>
          try
            emitDiagnostic <|
              streamDiagnosticOfDiagnostic root diagnosticParam.uri diagnosticParam.version? diagnostic
          catch _ =>
            pure ()
      | none =>
          pure ()
  pure seen

def observeProgress
    [ToJson α]
    (pending : PendingRequest)
    (param : α) : IO Unit := do
  let progress? ← pending.progressRef.get
  let nextProgress? := observeSyncFileProgress pending.tracked? progress? param
  if nextProgress? != progress? then
    pending.progressRef.set nextProgress?
    match pending.emitProgress?, nextProgress? with
    | some emitProgress, some progress =>
        try
          emitProgress progress
        catch _ =>
          pure ()
    | _, _ =>
        pure ()

def observePublishDiagnostics
    (root : System.FilePath)
    (pending : PendingRequest)
    (diagnosticParam : PublishDiagnosticsParams) : IO Unit := do
  match trackedPublishDiagnosticsParam? (pending.tracked?.map Prod.fst) diagnosticParam with
  | none =>
      pure ()
  | some diagnosticParam =>
      pending.diagnosticsSeenRef.set true
      pending.diagnosticsRef.set diagnosticParam.diagnostics
      let seen ← pending.seenDiagnosticKeysRef.get
      let seen ←
        emitNewTrackedDiagnostics root seen diagnosticParam pending.diagnosticScope pending.emitDiagnostic?
      pending.seenDiagnosticKeysRef.set seen

def observeDiagnostics
    [ToJson α]
    (root : System.FilePath)
    (pending : PendingRequest)
    (param : α) : IO Unit := do
  match fromJson? (toJson param) with
  | .ok (diagnosticParam : PublishDiagnosticsParams) =>
      observePublishDiagnostics root pending diagnosticParam
  | .error _ =>
      pure ()

end PendingRequest

namespace PendingRequestStore

/-- Fail every pending request, giving an already-marked cancellation token precedence. -/
def failAllRespectingCancellation
    (store : PendingRequestStore)
    (fallback : ResponseFailure) : IO Unit := do
  let pending ← clear store
  for req in pending do
    let progress? ← req.progressRef.get
    let cancelled ←
      match req.cancelRef? with
      | some cancelRef => cancelRef.get
      | none => pure false
    let failure :=
      if cancelled then
        responseFailureFor .requestCancelled "request was cancelled while its backend session closed"
      else
        fallback
    let failure := failure.withOptionalFileProgress progress?
    try
      req.promise.resolve (.error failure)
    catch _ =>
      pure ()

def sendCancelNotification (stdin : IO.FS.Stream) (id : RequestID) : IO Unit := do
  writeLspNotification stdin ({
    method := "$/cancelRequest"
    param := toJson ({ id } : CancelParams)
    : Lean.JsonRpc.Notification Json
  })

def matchesCancellation
    (pending : PendingRequest)
    (cancelRef : IO.Ref Bool) : IO Bool := do
  match pending.cancelRef? with
  | none => pure false
  | some pendingCancelRef => pendingCancelRef.ptrEq cancelRef

def cancelMatching
    (store : PendingRequestStore)
    (stdin : IO.FS.Stream)
    (cancelRef : IO.Ref Bool) : IO Nat := do
  let entries ← snapshotEntries store
  let mut cancelled := 0
  for (requestId, pending) in entries do
    if ← matchesCancellation pending cancelRef then
      sendCancelNotification stdin requestId
      cancelled := cancelled + 1
  pure cancelled

def propagateCancellation
    (store : PendingRequestStore)
    (stdin : IO.FS.Stream)
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  match cancelRef? with
  | some cancelRef =>
      if ← cancelRef.get then
        discard <| cancelMatching store stdin cancelRef
  | none =>
      pure ()

end PendingRequestStore

structure ActiveRequest where
  clientRequestId? : Option String
  token : Nat
  cancelRef : IO.Ref Bool

private structure ActiveRequestRegistryState where
  nextToken : Nat := 1
  accepting : Bool := true
  requests : Std.TreeMap String ActiveRequest := {}
  anonymousRequests : Std.TreeMap Nat ActiveRequest := {}

structure ActiveRequestRegistry where
  private mutex : Std.Mutex ActiveRequestRegistryState

namespace ActiveRequestRegistry

def create : BaseIO ActiveRequestRegistry := do
  pure { mutex := ← Std.Mutex.new {} }

def register
    (registry : ActiveRequestRegistry)
    (clientRequestId? : Option String) : IO (Except BrokerFailure ActiveRequest) := do
  let cancelRef ← IO.mkRef false
  registry.mutex.atomically do
    let state ← get
    unless state.accepting do
      return .error {
        code := .requestCancelled
        message := "Beam session owner is closing"
      }
    match clientRequestId? with
    | none =>
        let active : ActiveRequest := { clientRequestId?, token := state.nextToken, cancelRef }
        set { state with
          nextToken := state.nextToken + 1
          anonymousRequests := state.anonymousRequests.insert active.token active
        }
        pure <| .ok active
    | some clientRequestId =>
        if state.requests.contains clientRequestId then
          pure <| .error {
            code := .invalidParams
            message := s!"clientRequestId '{clientRequestId}' is already active"
          }
        else
          let active : ActiveRequest := { clientRequestId?, token := state.nextToken, cancelRef }
          set { state with
            nextToken := state.nextToken + 1
            requests := state.requests.insert clientRequestId active
          }
          pure <| .ok active

def unregister
    (registry : ActiveRequestRegistry)
    (active? : Option ActiveRequest) : IO Unit := do
  match active? with
  | none => pure ()
  | some active =>
      registry.mutex.atomically do
        let state ← get
        match active.clientRequestId? with
        | some clientRequestId =>
            match state.requests.get? clientRequestId with
            | some current =>
                if current.token == active.token then
                  set { state with requests := state.requests.erase clientRequestId }
            | none => pure ()
        | none =>
            match state.anonymousRequests.get? active.token with
            | some current =>
                if current.token == active.token then
                  set { state with anonymousRequests := state.anonymousRequests.erase active.token }
            | none => pure ()

def count (registry : ActiveRequestRegistry) : IO Nat := do
  registry.mutex.atomically do
    let state ← get
    pure (state.requests.size + state.anonymousRequests.size)

/--
Atomically close request admission and mark every admitted request for cancellation. Return `true`
only to the caller that changed the registry from accepting to closed.
-/
def closeAdmission (registry : ActiveRequestRegistry) : IO Bool := do
  let (firstClose, active) ← registry.mutex.atomically do
    let state : ActiveRequestRegistryState ← get
    if !state.accepting then
      pure (false, #[])
    else
      set { state with accepting := false }
      let named := state.requests.toList.map Prod.snd |>.toArray
      let anonymous := state.anonymousRequests.toList.map Prod.snd |>.toArray
      pure (true, named ++ anonymous)
  for request in active do
    request.cancelRef.set true
  pure firstClose

def markCancelled
    (registry : ActiveRequestRegistry)
    (clientRequestId : String) : IO (Option ActiveRequest) := do
  registry.mutex.atomically do
    let active? := (← get).requests.get? clientRequestId
    match active? with
    | none =>
        pure none
    | some active =>
        active.cancelRef.set true
        pure (some active)

def markCancelledActive
    (registry : ActiveRequestRegistry)
    (active : ActiveRequest) : IO (Option ActiveRequest) := do
  registry.mutex.atomically do
    let state ← get
    let current? :=
      match active.clientRequestId? with
      | some clientRequestId => state.requests.get? clientRequestId
      | none => state.anonymousRequests.get? active.token
    match current? with
    | none => pure none
    | some current =>
        if current.token == active.token then
          current.cancelRef.set true
          pure (some current)
        else
          pure none

end ActiveRequestRegistry

def ensureRequestNotCancelled
    (cancelRef? : Option (IO.Ref Bool)) : IO (Except ResponseFailure Unit) := do
  match cancelRef? with
  | none => pure (.ok ())
  | some cancelRef =>
      if ← cancelRef.get then
        pure <| .error <| BrokerFailure.toResponseFailure {
          code := .requestCancelled
          message := "client requested cancellation"
        }
      else
        pure (.ok ())

end Beam.Broker
