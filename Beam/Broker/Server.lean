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
import Lean.Parser.Module
import RunAt.Protocol
import RunAt.Internal.DirectImports
import RunAt.Internal.SaveSupport
import Beam.Broker.Config
import Beam.Broker.Protocol
import Beam.Broker.Transport
import Beam.Broker.Lean
import Beam.Broker.Deps
import Beam.Broker.LakeSave
import Beam.Broker.StaleDirectDeps
import Beam.Broker.SyncSaveSupport
import Std.Sync.Mutex

open Lean
open Lean.JsonRpc
open Lean.Lsp
open IO.FS.Stream
open Std.Internal.IO.Async

namespace Beam.Broker

abbrev brokerStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .inherit

structure DocState where
  version : Nat
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  moduleName? : Option String := none
  savedOleanVersion? : Option Nat := none
  fileProgress? : Option SyncFileProgress := none
  lastSyncSeq : Nat := 0
  lastSaveSeq : Nat := 0

structure ModuleHistory where
  path : String
  lastSyncSeq : Nat := 0
  lastSaveSeq : Nat := 0

structure PendingResult where
  result : Json
  progress? : Option SyncFileProgress := none
  diagnostics : Array Diagnostic := #[]

structure PendingRequest where
  clientRequestId? : Option String := none
  promise : IO.Promise (Except String PendingResult)
  tracked? : Option (DocumentUri × Nat) := none
  progressRef : IO.Ref (Option SyncFileProgress)
  diagnosticsRef : IO.Ref (Array Diagnostic)
  emitProgress? : Option (SyncFileProgress → IO Unit) := none
  fullDiagnostics : Bool := false
  seenDiagnosticKeysRef : IO.Ref (Std.TreeSet String compare)
  emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none

structure Session where
  backend : Backend
  root : System.FilePath
  epoch : Nat
  sessionToken : String
  proc : IO.Process.Child brokerStdio
  stdin : IO.FS.Stream
  stdout : IO.FS.Stream
  pending : Std.Mutex (Std.TreeMap RequestID PendingRequest)
  nextId : Nat := 1
  nextEventSeq : Nat := 1
  moduleHistory : Std.TreeMap String ModuleHistory := {}
  docs : Std.TreeMap String DocState := {}

structure BackendState where
  nextEpoch : Nat := 1
  session? : Option Session := none

structure OpStats where
  count : Nat := 0
  successCount : Nat := 0
  errorCount : Nat := 0
  cancelledCount : Nat := 0
  workerExitedCount : Nat := 0
  invalidParamsCount : Nat := 0
  totalLatencyMs : Nat := 0
  maxLatencyMs : Nat := 0
  lastLatencyMs : Nat := 0

structure BackendMetrics where
  sessionStarts : Nat := 0
  sessionRestarts : Nat := 0
  requestCount : Nat := 0
  successCount : Nat := 0
  errorCount : Nat := 0
  cancelledCount : Nat := 0
  workerExitedCount : Nat := 0
  invalidParamsCount : Nat := 0
  ops : Std.TreeMap String OpStats := {}

structure State where
  config : BrokerConfig
  startMonoNanos : Nat := 0
  lean : BackendState := {}
  rocq : BackendState := {}
  leanMetrics : BackendMetrics := {}
  rocqMetrics : BackendMetrics := {}
  streamSink? : Option (StreamMessage → IO Unit) := none
  currentClientRequestId? : Option String := none

abbrev M := StateRefT State IO

inductive BrokerFailureCode where
  | invalidParams
  | requestCancelled
  | contentModified
  | workerExited
  | syncBarrierIncomplete
  | saveTargetNotModule
  | internalError
  deriving Inhabited, BEq, Repr

def BrokerFailureCode.name : BrokerFailureCode → String
  | .invalidParams => "invalidParams"
  | .requestCancelled => "requestCancelled"
  | .contentModified => "contentModified"
  | .workerExited => "workerExited"
  | .syncBarrierIncomplete => syncBarrierIncompleteCode
  | .saveTargetNotModule => saveTargetNotModuleCode
  | .internalError => "internalError"

instance : ToJson BrokerFailureCode where
  toJson code := toJson code.name

instance : FromJson BrokerFailureCode where
  fromJson? j :=
    match j with
    | .str "invalidParams" => .ok .invalidParams
    | .str "requestCancelled" => .ok .requestCancelled
    | .str "contentModified" => .ok .contentModified
    | .str "workerExited" => .ok .workerExited
    | .str s =>
        if s == syncBarrierIncompleteCode then
          .ok .syncBarrierIncomplete
        else if s == saveTargetNotModuleCode then
          .ok .saveTargetNotModule
        else if s == "internalError" then
          .ok .internalError
        else
          .error s!"expected broker failure code, got {j.compress}"
    | _ => .error s!"expected broker failure code, got {j.compress}"

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

private def brokerFailurePrefix : String :=
  "brokerfail:"

def BrokerFailure.toResponse (failure : BrokerFailure) : Response :=
  {
    ok := false
    error? := some {
      code := failure.code.name
      message := failure.message
      data? := failure.data?
    }
  }

def brokerFailureMessage (failure : BrokerFailure) : String :=
  s!"{brokerFailurePrefix}{(toJson failure).compress}"

def throwBrokerFailure (failure : BrokerFailure) : IO α := do
  throw <| IO.userError (brokerFailureMessage failure)

def decodeBrokerFailure? (msg : String) : Option BrokerFailure := do
  guard <| msg.startsWith brokerFailurePrefix
  let raw := msg.drop brokerFailurePrefix.length |>.toString
  let json ← Json.parse raw |>.toOption
  fromJson? json |>.toOption

def mkSessionToken : IO String := do
  let pid ← IO.Process.getPID
  let now ← IO.monoNanosNow
  pure s!"{pid}-{now}"

def resolveRoot (root : System.FilePath) : IO System.FilePath :=
  IO.FS.realPath root

def resolvePath (root : System.FilePath) (path : System.FilePath) : IO System.FilePath := do
  let path := if path.isAbsolute then path else root / path
  IO.FS.realPath path

def sessionUri (path : System.FilePath) : String :=
  (System.Uri.pathToUri path : String)

private partial def waitForTaskWithTimeout
    (task : Task α)
    (timeoutMs : Nat)
    (pollMs : Nat := 50) : IO (Option α) := do
  let rec loop (remainingMs : Nat) : IO (Option α) := do
    if ← IO.hasFinished task then
      return some (← IO.wait task)
    if remainingMs == 0 then
      return none
    IO.sleep pollMs.toUInt32
    loop (remainingMs - min pollMs remainingMs)
  loop timeoutMs

private def sessionShutdownReplyTimeoutMs : Nat :=
  1000

def shutdownSession (session : Session) : IO Unit := do
  try
    writeLspRequest session.stdin ({ id := 0, method := "shutdown", param := Json.null : Lean.JsonRpc.Request Json })
    let task ← IO.asTask session.stdout.readLspMessage
    let _ ← waitForTaskWithTimeout task sessionShutdownReplyTimeoutMs
    pure ()
  catch _ =>
    pure ()
  try
    writeLspNotification session.stdin ({ method := "exit", param := Json.null : Lean.JsonRpc.Notification Json })
  catch _ =>
    pure ()
  try
    session.proc.kill
  catch _ =>
    pure ()
  try
    discard <| session.proc.tryWait
  catch _ =>
    pure ()

def sessionExited (session : Session) : IO Bool := do
  try
    pure (← session.proc.tryWait).isSome
  catch _ =>
    pure true

def getBackendState (state : State) (backend : Backend) : BackendState :=
  match backend with
  | .lean => state.lean
  | .rocq => state.rocq

def setBackendState (state : State) (backend : Backend) (backendState : BackendState) : State :=
  match backend with
  | .lean => { state with lean := backendState }
  | .rocq => { state with rocq := backendState }

def getBackendMetrics (state : State) (backend : Backend) : BackendMetrics :=
  match backend with
  | .lean => state.leanMetrics
  | .rocq => state.rocqMetrics

def setBackendMetrics (state : State) (backend : Backend) (metrics : BackendMetrics) : State :=
  match backend with
  | .lean => { state with leanMetrics := metrics }
  | .rocq => { state with rocqMetrics := metrics }

def recordSessionSpawn (backend : Backend) (restart : Bool) : M Unit := do
  modify fun state =>
    let metrics := getBackendMetrics state backend
    let metrics := {
      metrics with
      sessionStarts := metrics.sessionStarts + 1
      sessionRestarts := metrics.sessionRestarts + (if restart then 1 else 0)
    }
    setBackendMetrics state backend metrics

private def isCancelledCode (errorCode? : Option String) : Bool :=
  errorCode? == some "requestCancelled"

private def isWorkerExitedCode (errorCode? : Option String) : Bool :=
  errorCode? == some "workerExited"

private def isInvalidParamsCode (errorCode? : Option String) : Bool :=
  errorCode? == some "invalidParams" || errorCode? == some "-32602"

def OpStats.record (stats : OpStats) (ok : Bool) (errorCode? : Option String) (latencyMs : Nat) : OpStats :=
  {
    count := stats.count + 1
    successCount := stats.successCount + (if ok then 1 else 0)
    errorCount := stats.errorCount + (if ok then 0 else 1)
    cancelledCount := stats.cancelledCount + (if isCancelledCode errorCode? then 1 else 0)
    workerExitedCount := stats.workerExitedCount + (if isWorkerExitedCode errorCode? then 1 else 0)
    invalidParamsCount := stats.invalidParamsCount + (if isInvalidParamsCode errorCode? then 1 else 0)
    totalLatencyMs := stats.totalLatencyMs + latencyMs
    maxLatencyMs := max stats.maxLatencyMs latencyMs
    lastLatencyMs := latencyMs
  }

def recordRequestMetrics
    (backend : Backend)
    (op : String)
    (ok : Bool)
    (errorCode? : Option String)
    (latencyMs : Nat) : M Unit := do
  modify fun state =>
    let metrics := getBackendMetrics state backend
    let opStats := (metrics.ops.get? op).getD {}
    let opStats := opStats.record ok errorCode? latencyMs
    let metrics := {
      metrics with
      requestCount := metrics.requestCount + 1
      successCount := metrics.successCount + (if ok then 1 else 0)
      errorCount := metrics.errorCount + (if ok then 0 else 1)
      cancelledCount := metrics.cancelledCount + (if isCancelledCode errorCode? then 1 else 0)
      workerExitedCount := metrics.workerExitedCount + (if isWorkerExitedCode errorCode? then 1 else 0)
      invalidParamsCount := metrics.invalidParamsCount + (if isInvalidParamsCode errorCode? then 1 else 0)
      ops := metrics.ops.insert op opStats
    }
    setBackendMetrics state backend metrics

def avgLatencyMs (count total : Nat) : Nat :=
  if count == 0 then 0 else total / count

def opStatsJson (stats : OpStats) : Json :=
  Json.mkObj [
    ("count", toJson stats.count),
    ("successCount", toJson stats.successCount),
    ("errorCount", toJson stats.errorCount),
    ("cancelledCount", toJson stats.cancelledCount),
    ("workerExitedCount", toJson stats.workerExitedCount),
    ("invalidParamsCount", toJson stats.invalidParamsCount),
    ("avgLatencyMs", toJson (avgLatencyMs stats.count stats.totalLatencyMs)),
    ("maxLatencyMs", toJson stats.maxLatencyMs),
    ("lastLatencyMs", toJson stats.lastLatencyMs)
  ]

def backendMetricsJson (metrics : BackendMetrics) : Json :=
  Json.mkObj <|
    [
      ("sessionStarts", toJson metrics.sessionStarts),
      ("sessionRestarts", toJson metrics.sessionRestarts),
      ("requestCount", toJson metrics.requestCount),
      ("successCount", toJson metrics.successCount),
      ("errorCount", toJson metrics.errorCount),
      ("cancelledCount", toJson metrics.cancelledCount),
      ("workerExitedCount", toJson metrics.workerExitedCount),
      ("invalidParamsCount", toJson metrics.invalidParamsCount)
    ] ++
    [("ops", Json.mkObj <| metrics.ops.toList.map fun (op, stats) => (op, opStatsJson stats))]

def sessionSnapshotJson (session? : Option Session) : Json :=
  match session? with
  | none => Json.mkObj [("active", toJson false)]
  | some session =>
      Json.mkObj [
        ("active", toJson true),
        ("root", toJson session.root.toString),
        ("epoch", toJson session.epoch),
        ("openDocCount", toJson session.docs.toList.length)
      ]

def statsPayload : M Json := do
  let state ← get
  let now ← IO.monoNanosNow
  let uptimeMs := (now - state.startMonoNanos) / 1000000
  pure <| Json.mkObj [
    ("root", toJson state.config.root.toString),
    ("uptimeMs", toJson uptimeMs),
    ("sessions", Json.mkObj [
      ("lean", sessionSnapshotJson state.lean.session?),
      ("rocq", sessionSnapshotJson state.rocq.session?)
    ]),
    ("byBackend", Json.mkObj [
      ("lean", backendMetricsJson state.leanMetrics),
      ("rocq", backendMetricsJson state.rocqMetrics)
    ])
  ]

def resetMetrics (startMonoNanos : Nat) : M Unit := do
  modify fun state => {
    state with
    leanMetrics := {}
    rocqMetrics := {}
    startMonoNanos := startMonoNanos
  }

def nextRequestId (session : Session) : Session × RequestID :=
  let id : RequestID := session.nextId
  ({ session with nextId := session.nextId + 1 }, id)

private def normalizePublishDiagnostics (params : PublishDiagnosticsParams) :
    PublishDiagnosticsParams := {
  params with
  diagnostics :=
    let sorted := params.diagnostics.toList.mergeSort fun d1 d2 =>
      compare d1.fullRange d2.fullRange |>.then (compare d1.message d2.message) |>.isLE
    sorted.toArray
}

private def updateSyncFileProgress (progress : SyncFileProgress) (params : LeanFileProgressParams) :
    SyncFileProgress :=
  let processing := params.processing.size
  {
    updates := progress.updates + 1
    done := processing == 0
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

private def trackedPublishDiagnostics?
    [ToJson α]
    (trackedUri? : Option DocumentUri)
    (param : α) : Option PublishDiagnosticsParams :=
  match trackedUri?, fromJson? (toJson param) with
  | some uri, .ok (diagnosticParam : PublishDiagnosticsParams) =>
      let diagnosticParam := normalizePublishDiagnostics diagnosticParam
      if diagnosticParam.uri == uri then
        some diagnosticParam
      else
        none
  | _, _ =>
      none

private def diagnosticDisplayPath (root : System.FilePath) (uri : DocumentUri) : String :=
  match System.Uri.fileUriToPath? uri with
  | some path =>
      let rootStr := root.toString
      let pathStr := path.toString
      let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
      if pathStr.startsWith rootPrefix then
        (pathStr.drop rootPrefix.length).toString
      else if pathStr == rootStr then
        "."
      else
        pathStr
  | none =>
      uri

private def diagnosticStreamKey (diagnostic : Diagnostic) : String :=
  (toJson diagnostic).compress

private def emitNewTrackedDiagnostics
    (root : System.FilePath)
    (seen : Std.TreeSet String compare)
    (diagnosticParam : PublishDiagnosticsParams)
    (fullDiagnostics : Bool)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Std.TreeSet String compare) := do
  let mut seen := seen
  let path := diagnosticDisplayPath root diagnosticParam.uri
  let diagnostics := filterSyncDiagnostics fullDiagnostics diagnosticParam.diagnostics
  for diagnostic in diagnostics do
    let key := diagnosticStreamKey diagnostic
    if !seen.contains key then
      seen := seen.insert key
      match emitDiagnostic? with
      | some emitDiagnostic =>
          emitDiagnostic {
            path
            uri := diagnosticParam.uri
            version? := diagnosticParam.version?
            severity? := effectiveSyncDiagnosticSeverity diagnostic
            range := diagnostic.fullRange
            message := diagnostic.message
          }
      | none =>
          pure ()
  pure seen

private def removePendingRequest (session : Session) (id : RequestID) : IO (Option PendingRequest) := do
  session.pending.atomically do
    let pending? := (← get).get? id
    modify (·.erase id)
    pure pending?

private def snapshotPendingRequests (session : Session) : IO (Array PendingRequest) := do
  session.pending.atomically do
    pure <| (← get).toList.map Prod.snd |>.toArray

private def snapshotPendingEntries (session : Session) : IO (Array (RequestID × PendingRequest)) := do
  session.pending.atomically do
    pure <| (← get).toList.toArray

private def resolvePendingResponse (pending : PendingRequest) (result : Json) : IO Unit := do
  let progress? ← pending.progressRef.get
  let diagnostics ← pending.diagnosticsRef.get
  try
    pending.promise.resolve (.ok { result, progress?, diagnostics })
  catch _ =>
    pure ()

private def resolvePendingError
    (pending : PendingRequest)
    (code : ErrorCode)
    (message : String)
    (data? : Option Json := none) : IO Unit := do
  let errJson := Json.mkObj <|
    [("code", toJson code), ("message", toJson message)] ++
    match data? with
    | some data => [("data", data)]
    | none => []
  try
    pending.promise.resolve (.error s!"jsonrpcerr:{errJson.compress}")
  catch _ =>
    pure ()

private def failAllPendingRequests (session : Session) (message : String) : IO Unit := do
  let pending ← session.pending.atomically do
    let pending := (← get).toList.map Prod.snd |>.toArray
    set ({} : Std.TreeMap RequestID PendingRequest)
    pure pending
  for req in pending do
    try
      req.promise.resolve (.error message)
    catch _ =>
      pure ()

private def observePendingProgress
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

private def observePendingDiagnostics
    [ToJson α]
    (root : System.FilePath)
    (pending : PendingRequest)
    (param : α) : IO Unit := do
  match trackedPublishDiagnostics? (pending.tracked?.map Prod.fst) param with
  | none =>
      pure ()
  | some diagnosticParam =>
      pending.diagnosticsRef.set diagnosticParam.diagnostics
      let seen ← pending.seenDiagnosticKeysRef.get
      let seen ←
        emitNewTrackedDiagnostics root seen diagnosticParam pending.fullDiagnostics pending.emitDiagnostic?
      pending.seenDiagnosticKeysRef.set seen

partial def sessionReaderLoop (session : Session) : IO Unit := do
  try
    let msg ← session.stdout.readLspMessage
    match msg with
    | .response id result =>
        if let some pending ← removePendingRequest session id then
          resolvePendingResponse pending result
    | .responseError id code message data? =>
        if let some pending ← removePendingRequest session id then
          resolvePendingError pending code message data?
    | .notification "$/lean/fileProgress" (some param) =>
        let pending ← snapshotPendingRequests session
        for req in pending do
          observePendingProgress req param
    | .notification "textDocument/publishDiagnostics" (some param) =>
        let pending ← snapshotPendingRequests session
        for req in pending do
          observePendingDiagnostics session.root req param
    | _ =>
        pure ()
    sessionReaderLoop session
  catch e =>
    failAllPendingRequests session <| brokerFailureMessage {
      code := .workerExited
      message := e.toString
    }
    try
      session.proc.kill
    catch _ =>
      pure ()
    try
      discard <| session.proc.tryWait
    catch _ =>
      pure ()

private def awaitPendingResult
    (promise : IO.Promise (Except String PendingResult)) : IO PendingResult := do
  let some result ← IO.wait promise.result?
    | throw <| IO.userError "pending broker request promise dropped"
  match result with
  | .ok result => pure result
  | .error err => throw <| IO.userError err

private def sendCancelNotification (session : Session) (id : RequestID) : IO Unit := do
  writeLspNotification session.stdin ({
    method := "$/cancelRequest"
    param := toJson ({ id } : CancelParams)
    : Lean.JsonRpc.Notification Json
  })

private def startRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Session × IO.Promise (Except String PendingResult)) := do
  let (session, id) := nextRequestId session
  let progressRef ← IO.mkRef (initialProgress? <|> tracked.map (fun _ => {}))
  let diagnosticsRef ← IO.mkRef #[]
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  let promise ← IO.Promise.new
  session.pending.atomically do
    modify (·.insert id {
      clientRequestId? := clientRequestId?
      promise := promise
      tracked? := tracked
      progressRef := progressRef
      diagnosticsRef := diagnosticsRef
      emitProgress? := emitProgress?
      fullDiagnostics := fullDiagnostics
      seenDiagnosticKeysRef := seenDiagnosticKeysRef
      emitDiagnostic? := emitDiagnostic?
      : PendingRequest
    })
  try
    writeLspRequest session.stdin ({ id, method, param : Lean.JsonRpc.Request Json })
    pure (session, promise)
  catch e =>
    discard <| removePendingRequest session id
    try
      promise.resolve (.error e.toString)
    catch _ =>
      pure ()
    throw e

def sendRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Session × Json × Option SyncFileProgress × Array Diagnostic) := do
  let (session, promise) ←
    startRequestJsonTrackedDetailed session method param clientRequestId? tracked initialProgress?
      emitProgress? fullDiagnostics emitDiagnostic?
  let pending ← awaitPendingResult promise
  pure (session, pending.result, pending.progress?, pending.diagnostics)

def sendRequestJsonTracked
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Session × Json × Option SyncFileProgress) := do
  let (session, result, progress?, _) ←
    sendRequestJsonTrackedDetailed session method param clientRequestId? tracked initialProgress? emitProgress?
  pure (session, result, progress?)

def sendRequestJson (session : Session) (method : String) (param : Json) : IO (Session × Json) := do
  let (session, result, _) ← sendRequestJsonTracked session method param
  pure (session, result)

private partial def awaitInitializeResponse (stdout : IO.FS.Stream) : IO Unit := do
  let msg ← stdout.readLspMessage
  match msg with
  | .response id _ =>
      if id == 0 then
        pure ()
      else
        throwBrokerFailure {
          code := .internalError
          message := s!"unexpected response id {id} before initialize completed"
        }
  | .responseError id _code message _ =>
      if id == 0 then
        throwBrokerFailure { code := .internalError, message := s!"initialize failed: {message}" }
      else
        throwBrokerFailure {
          code := .internalError
          message := s!"unexpected response error id {id} before initialize completed: {message}"
        }
  | .notification .. =>
      awaitInitializeResponse stdout
  | .request .. =>
      throwBrokerFailure {
        code := .internalError
        message := "unexpected server request before initialize completed"
      }

def ensureSession (backend : Backend) : M Session := do
  let state ← get
  let config := state.config
  let root := config.root
  let backendState := getBackendState state backend
  let (backendState, restart) ← match backendState.session? with
    | some session =>
        if ← sessionExited session then
          shutdownSession session
          pure ({ backendState with session? := none, nextEpoch := backendState.nextEpoch + 1 }, true)
        else
          pure (backendState, false)
    | none =>
        pure (backendState, false)
  match backendState.session? with
  | some session =>
      modify fun st => setBackendState st backend backendState
      pure session
  | none =>
      let (cmd, args) ← backendCommand config backend
      let proc ← IO.Process.spawn {
        toStdioConfig := brokerStdio
        cmd := cmd
        args := args
        cwd := root.toString
      }
      let stdin := IO.FS.Stream.ofHandle proc.stdin
      let stdout := IO.FS.Stream.ofHandle proc.stdout
      let pending ← Std.Mutex.new ({} : Std.TreeMap RequestID PendingRequest)
      let sessionToken ← mkSessionToken
      let mut session : Session := {
        backend
        root
        epoch := backendState.nextEpoch
        sessionToken
        proc
        stdin
        stdout
        pending
      }
      writeLspRequest stdin ({ id := 0, method := "initialize", param := initializeParams backend root : Lean.JsonRpc.Request Json })
      awaitInitializeResponse stdout
      writeLspNotification stdin ({ method := "initialized", param := Json.mkObj [] : Lean.JsonRpc.Notification Json })
      let _ ← IO.asTask do
        try
          sessionReaderLoop session
        catch e =>
          IO.eprintln s!"broker session reader task failed: {e.toString}"
      recordSessionSpawn backend restart
      let backendState := { backendState with session? := some session }
      modify fun st => setBackendState st backend backendState
      pure session

def sendNotificationJson (session : Session) (method : String) (param : Json) : IO Session := do
  writeLspNotification session.stdin ({ method, param : Lean.JsonRpc.Notification Json })
  pure session

private def trackedModuleName? (root path : System.FilePath) (backend : Backend) : Option String := do
  guard (backend == .lean)
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  let relPath? :=
    if pathStr.startsWith rootPrefix then
      some <| (pathStr.drop rootPrefix.length).toString
    else if pathStr == rootStr then
      some "."
    else
      none
  let relPath ← relPath?
  guard (relPath.endsWith ".lean")
  let relFile := System.FilePath.mk relPath
  let stem ← relFile.fileStem
  let parts := relFile.components.dropLast
  some <| String.intercalate "." (parts ++ [stem])

def syncFile (session : Session) (path : System.FilePath) : IO Session := do
  let path ← resolvePath session.root path
  let text ← IO.FS.readFile path
  let uri := sessionUri path
  let textHash := hash text
  let textTraceHash := Lake.Hash.ofText text
  let textMTime ← Lake.getFileMTime path
  let moduleName? := trackedModuleName? session.root path session.backend
  match session.docs.get? uri with
  | none =>
      let param := toJson ({
        textDocument := {
          uri := uri
          languageId := match session.backend with | .lean => "lean" | .rocq => "rocq"
          version := 1
          text := text
        } : DidOpenTextDocumentParams
      })
      let session ← sendNotificationJson session "textDocument/didOpen" param
      pure {
        session with
        docs := session.docs.insert uri {
          version := 1
          textHash
          textTraceHash
          textMTime
          moduleName?
        }
      }
  | some docState =>
      if docState.textHash == textHash then
        pure {
          session with
          docs := session.docs.insert uri {
            docState with
            textTraceHash
            textMTime
            moduleName?
          }
        }
      else
        let newVersion := docState.version + 1
        let param := toJson ({
          textDocument := { uri := uri, version? := some newVersion }
          contentChanges := #[TextDocumentContentChangeEvent.fullChange text]
          : DidChangeTextDocumentParams
        })
        let session ← sendNotificationJson session "textDocument/didChange" param
        pure {
          session with
          docs := session.docs.insert uri {
            docState with
            version := newVersion
            textHash
            textTraceHash
            textMTime
            moduleName?
            savedOleanVersion? := none
            fileProgress? := none
          }
        }

def requireDocState (session : Session) (uri : String) : IO DocState := do
  match session.docs.get? uri with
  | some docState => pure docState
  | none => throw <| IO.userError s!"missing synced document state for {uri}"

def closeFile (session : Session) (path : System.FilePath) : IO Session := do
  let path ← resolvePath session.root path
  let uri := sessionUri path
  if session.docs.get? uri |>.isNone then
    pure session
  else
    let param := toJson ({ textDocument := { uri := uri } : DidCloseTextDocumentParams })
    let session ← sendNotificationJson session "textDocument/didClose" param
    pure { session with docs := session.docs.erase uri }

def recordFileProgress (session : Session) (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : Session :=
  match session.docs.get? uri with
  | some docState =>
      { session with docs := session.docs.insert uri { docState with fileProgress? := fileProgress? } }
  | none =>
      session

def decodeResponseAs [FromJson α] (json : Json) : IO α := do
  match fromJson? json with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"invalid backend response payload: {err}\n{json.compress}"

private def fetchSyncSaveReadiness
    (session : Session)
    (uri : DocumentUri) : IO (Session × SyncSaveReadiness) := do
  if session.backend != .lean then
    pure (session, {})
  else
    let method ← IO.ofExcept <| saveReadinessMethod session.backend
    let params := toJson ({
      textDocument := ({ uri := uri : TextDocumentIdentifier })
      : RunAt.Internal.SaveReadinessParams
    })
    let (session, result) ← sendRequestJson session method params
    let readiness : RunAt.Internal.SaveReadinessResult ← decodeResponseAs result
    pure (session, syncSaveReadinessOfResult readiness)

private def ensureSyncBarrierComplete
    (uri : DocumentUri)
    (version : Nat)
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic := #[]) : IO Unit := do
  if syncBarrierIncomplete? progress? diagnostics then
    throwBrokerFailure {
      code := .syncBarrierIncomplete
      message := syncBarrierIncompleteMessage uri version progress?
    }

def waitForDiagnostics (session : Session) (uri : DocumentUri) (version : Nat) : IO Session := do
  let params := toJson (WaitForDiagnosticsParams.mk uri version)
  let (session, result) ← sendRequestJson session "textDocument/waitForDiagnostics" params
  let (_ : WaitForDiagnostics) ← decodeResponseAs result
  pure session

partial def waitForSyncBarrierWithDiagnostics
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Session × Option SyncFileProgress × Array Diagnostic) := do
  if session.backend != .lean then
    pure (session, none, #[])
  else
    let params := toJson (WaitForDiagnosticsParams.mk uri version)
    let (session, result, progress?, diagnostics) ←
      sendRequestJsonTrackedDetailed session "textDocument/waitForDiagnostics" params
        (tracked := some (uri, version))
        (emitProgress? := emitProgress?)
        (fullDiagnostics := fullDiagnostics)
        (emitDiagnostic? := emitDiagnostic?)
    let (_ : WaitForDiagnostics) ← decodeResponseAs result
    ensureSyncBarrierComplete uri version progress?
    pure (session, progress?, diagnostics)

partial def waitForSyncBarrierWith
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Session × Option SyncFileProgress) := do
  let (session, progress?, _) ← waitForSyncBarrierWithDiagnostics session uri version emitProgress?
  pure (session, progress?)

partial def waitForSyncBarrier (session : Session) (uri : DocumentUri) (version : Nat) :
    IO (Session × Option SyncFileProgress) := do
  waitForSyncBarrierWith session uri version

private def trackedPathLabel (root : System.FilePath) (uri : DocumentUri) : String :=
  match workspacePath? root uri with
  | some path => path
  | none => uri

private def nextEventSeq (session : Session) : Session × Nat :=
  ({ session with nextEventSeq := session.nextEventSeq + 1 }, session.nextEventSeq)

private def updateModuleHistorySync (session : Session) (moduleName path : String) (seq : Nat) : Session :=
  let history := (session.moduleHistory.get? moduleName).getD { path }
  { session with
    moduleHistory := session.moduleHistory.insert moduleName {
      history with
      path
      lastSyncSeq := seq
    }
  }

private def updateModuleHistorySave (session : Session) (moduleName path : String) (seq : Nat) : Session :=
  let history := (session.moduleHistory.get? moduleName).getD { path }
  { session with
    moduleHistory := session.moduleHistory.insert moduleName {
      history with
      path
      lastSyncSeq := seq
      lastSaveSeq := seq
    }
  }

private def markDocSyncedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  match session.docs.get? uri with
  | some docState =>
      if docState.version == version then
        let (session, seq) := nextEventSeq session
        let path := trackedPathLabel session.root uri
        let session :=
          match docState.moduleName? with
          | some moduleName => updateModuleHistorySync session moduleName path seq
          | none => session
        { session with
          docs := session.docs.insert uri {
            docState with
            lastSyncSeq := seq
          }
        }
      else
        session
  | none =>
      session

private def markDocSavedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  match session.docs.get? uri with
  | some docState =>
      if docState.version == version then
        let (session, seq) := nextEventSeq session
        let path := trackedPathLabel session.root uri
        let session :=
          match docState.moduleName? with
          | some moduleName => updateModuleHistorySave session moduleName path seq
          | none => session
        { session with
          docs := session.docs.insert uri {
            docState with
            savedOleanVersion? := some version
            lastSyncSeq := seq
            lastSaveSeq := seq
          }
        }
      else
        session
  | none =>
      session

def saveOlean
    (leanCmd? : Option String)
    (session : Session)
    (path : System.FilePath)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Session × Json × Option SyncFileProgress) := do
  if session.backend != .lean then
    throw <| IO.userError "save_olean is only supported for the lean backend"
  let path ← resolvePath session.root path
  let session ← syncFile session path
  let uri := sessionUri path
  let docState ← requireDocState session uri
  let (session, fileProgress?, _) ←
    waitForSyncBarrierWithDiagnostics session uri docState.version emitProgress? fullDiagnostics emitDiagnostic?
  let spec ← mkLeanSaveSpec session.root path
    {
      hash := docState.textTraceHash
      mtime := docState.textMTime
    }
    leanCmd?
  let method ← IO.ofExcept <| saveArtifactsMethod session.backend
  let params := toJson ({
    textDocument := ({ uri := uri : TextDocumentIdentifier })
    oleanFile := spec.oleanPath.toString
    ileanFile := spec.ileanPath.toString
    cFile := spec.cPath.toString
    bcFile? := spec.bcPath?.map (·.toString)
    : RunAt.Internal.SaveArtifactsParams
  })
  let (session, result) ← sendRequestJson session method params
  let saveResult : RunAt.Internal.SaveArtifactsResult ← decodeResponseAs result
  if saveResult.version != docState.version then
    throw <| IO.userError
      s!"save_olean saved version {saveResult.version}, expected synced version {docState.version}"
  if saveResult.textHash != docState.textHash then
    throw <| IO.userError
      s!"save_olean saved text hash {saveResult.textHash}, expected synced hash {docState.textHash}"
  writeLeanSaveTrace spec
  let session ←
    if session.docs.contains uri then
      sendNotificationJson session "textDocument/didSave" (toJson ({
        textDocument := ({ uri := uri : TextDocumentIdentifier })
        text? := none
        : DidSaveTextDocumentParams
      }))
    else
      pure session
  let session ← sendNotificationJson session "workspace/didChangeWatchedFiles" (toJson ({
    changes := #[
      { uri := (System.Uri.pathToUri spec.ileanPath : String), type := FileChangeType.Changed }
    ]
    : DidChangeWatchedFilesParams
  }))
  pure (markDocSavedVersion session uri docState.version, leanSavePayload spec docState.version docState.textTraceHash, fileProgress?)

private def docSyncStatus (path : System.FilePath) (docState : DocState) : IO String := do
  if !(← path.pathExists) then
    pure "missing"
  else
    let text ← IO.FS.readFile path
    pure <| if hash text == docState.textHash then "saved" else "notSaved"

private def docDepsJson? (root : System.FilePath) (path : System.FilePath) (uri : DocumentUri) :
    IO (Option Json) := do
  let some module := normalizeModuleForPath root path uri none
    | pure none
  try
    let state ← mkDepsQueryState root
    let imports ← requireDirectImports state module.name
    pure <| some <| Json.arr <| imports.map (importJson root)
  catch _ =>
    pure none

private def docSaveFields
    (root : System.FilePath)
    (backend : Backend)
    (path? : Option System.FilePath)
    (leanCmd? : Option String) : IO (List (String × Json)) := do
  match backend, path? with
  | .lean, some path =>
      match ← checkLeanSaveTarget root path leanCmd? with
      | .eligible moduleName =>
          pure [
            ("saveEligible", toJson true),
            ("saveReason", toJson "ok"),
            ("saveModule", toJson moduleName.toString)
          ]
      | .notModule =>
          pure [
            ("saveEligible", toJson false),
            ("saveReason", toJson saveTargetNotModuleCode)
          ]
      | .workspaceLoadFailed msg =>
          pure [
            ("saveEligible", toJson false),
            ("saveReason", toJson "workspaceLoadFailed"),
            ("saveDetail", toJson msg)
          ]
  | _, _ =>
      pure []

private def docStateJson
    (root : System.FilePath)
    (backend : Backend)
    (leanCmd? : Option String)
    (uri : DocumentUri)
    (docState : DocState) : IO Json := do
  let path? := System.Uri.fileUriToPath? uri
  let relPath? := workspacePath? root uri
  let status ←
    match path? with
    | some path => docSyncStatus path docState
    | none => pure "unknown"
  let saved := status == "saved"
  let savedOlean := saved && docState.savedOleanVersion? == some docState.version
  let depsFields ←
    match backend, path? with
    | .lean, some path =>
        match ← docDepsJson? root path uri with
        | some deps => pure [("deps", deps)]
        | none => pure []
    | _, _ => pure []
  let fileProgressFields :=
    match docState.fileProgress? with
    | some fileProgress => [("fileProgress", toJson fileProgress)]
    | none => []
  let saveFields ← docSaveFields root backend path? leanCmd?
  pure <| Json.mkObj <|
    [
      ("uri", toJson uri),
      ("version", toJson docState.version),
      ("status", toJson status),
      ("saved", toJson saved),
      ("savedOlean", toJson savedOlean)
    ] ++
    (match relPath?, path? with
    | some relPath, _ => [("path", toJson relPath)]
    | none, some path => [("path", toJson path.toString)]
    | none, none => []) ++
    depsFields ++
    saveFields ++
    fileProgressFields

private def sessionOpenDocsJson (leanCmd? : Option String) (session? : Option Session) : IO Json := do
  match session? with
  | none =>
      pure <| Json.mkObj [
        ("active", toJson false),
        ("files", Json.arr #[])
      ]
  | some session =>
      let files ← session.docs.toList.mapM fun (uri, docState) =>
        docStateJson session.root session.backend leanCmd? uri docState
      pure <| Json.mkObj [
        ("active", toJson true),
        ("files", Json.arr files.toArray)
      ]

def openDocsPayload : M Json := do
  let state ← get
  pure <| Json.mkObj [
    ("root", toJson state.config.root.toString),
    ("sessions", Json.mkObj [
      ("lean", ← sessionOpenDocsJson state.config.leanCmd? state.lean.session?),
      ("rocq", ← sessionOpenDocsJson state.config.leanCmd? state.rocq.session?)
    ])
  ]

def wrapHandle (session : Session) (raw : Json) : Json :=
  toJson ({ backend := session.backend, epoch := session.epoch, session := session.sessionToken, raw : Handle })

def unwrapHandle (session : Session) (handle : Handle) : Except String Json := do
  if handle.backend != session.backend then
    throw "handle belongs to a different backend"
  if handle.epoch != session.epoch || handle.session != session.sessionToken then
    throw "handle belongs to a stale backend session"
  pure handle.raw

def wrapResultHandle (session : Session) (result : Json) : Json :=
  match result.getObjVal? "handle" with
  | .ok raw =>
      result.setObjVal! "handle" (wrapHandle session raw)
  | .error _ =>
      result

def reqError (code : String) (message : String := "") (data? : Option Json := none) : Response :=
  Response.error code message data?

def errorCodeName : JsonRpc.ErrorCode → String
  | .parseError => "parseError"
  | .invalidRequest => "invalidRequest"
  | .methodNotFound => "methodNotFound"
  | .invalidParams => "invalidParams"
  | .internalError => "internalError"
  | .serverNotInitialized => "serverNotInitialized"
  | .unknownErrorCode => "unknownErrorCode"
  | .contentModified => "contentModified"
  | .requestCancelled => "requestCancelled"
  | .rpcNeedsReconnect => "rpcNeedsReconnect"
  | .workerExited => "workerExited"
  | .workerCrashed => "workerCrashed"

def sessionResult (_session : Session) (payload : Json := Json.null) : Response :=
  Response.success payload

def withFileProgress (resp : Response) (fileProgress? : Option SyncFileProgress) : Response :=
  match fileProgress? with
  | some progress => { resp with fileProgress? := some progress }
  | none => resp

def updateSession (session : Session) : M Unit := do
  modify fun state =>
    let backendState := getBackendState state session.backend
    setBackendState state session.backend { backendState with session? := some session }

private def decodeJsonRpcErrorObject (json : Json) : Option Response :=
  match json.getObjVal? "code", json.getObjVal? "message" with
  | .ok code, .ok (.str message) =>
      match fromJson? code with
      | .ok (errCode : JsonRpc.ErrorCode) => some <| reqError (errorCodeName errCode) message
      | .error _ => some <| reqError code.compress message
  | _, _ => none

private def decodeJsonRpcErrorPayload (json : Json) : Option Response :=
  decodeJsonRpcErrorObject json <|>
    match json.getObjVal? "error" with
    | .ok errJson => decodeJsonRpcErrorObject errJson
    | .error _ => none

/-
Rocq-side goal probes can surface valid LSP/server error codes that Lean's JSON-RPC reader does not
recognize on the normal `.responseError` path. In particular, `rocq-goals-prev` with injected text
can trip a `coq-lsp` error such as `-32803` ("Expected a single focused goal but 0 goals are
focused."). When that happens, we may only see the embedded JSON error payload inside the thrown
`Cannot read LSP message: JSON '…'` text, so keep this fallback decoder tolerant of both direct
`jsonrpcerr:` payloads and embedded `{"error": ...}` objects instead of collapsing them to a plain
`internalError`.
-/
def decodeJsonRpcError (msg : String) : Option Response :=
  let decodeParsed (raw : String) : Option Response :=
    match Json.parse raw with
    | .error _ => some <| reqError "internalError" msg
    | .ok json =>
        match decodeJsonRpcErrorPayload json with
        | some resp => some resp
        | none => some <| reqError "internalError" msg
  if msg.startsWith "jsonrpcerr:" then
    decodeParsed (msg.drop 11 |>.toString)
  else if msg.startsWith "Cannot read LSP message: JSON '" then
    let raw := (msg.drop 31).toString
    match (raw.splitOn "' did not have the format of a JSON-RPC message.").head? with
    | some embedded => decodeParsed embedded
    | none => none
  else
    none

private def isSyncBarrierIncompleteMessage (msg : String) : Bool :=
  msg.startsWith "Lean diagnostics barrier did not complete for "

private def isSaveTargetNotModuleMessage (msg : String) : Bool :=
  msg.startsWith "could not resolve a Lake module for "

private def isRequestCancelledMessage (msg : String) : Bool :=
  msg.startsWith "requestCancelled:"

private def isContentModifiedMessage (msg : String) : Bool :=
  msg.startsWith "contentModified:"

private def isWorkerExitedMessage (msg : String) : Bool :=
  msg.startsWith "workerExited:"

private def responseForExceptionMessage (msg : String) : Response :=
  if let some failure := decodeBrokerFailure? msg then
    failure.toResponse
  else if isRequestCancelledMessage msg then
    reqError "requestCancelled" msg
  else if isContentModifiedMessage msg then
    reqError "contentModified" msg
  else if isWorkerExitedMessage msg then
    reqError "workerExited" msg
  else if isSyncBarrierIncompleteMessage msg then
    reqError syncBarrierIncompleteCode msg
  else if isSaveTargetNotModuleMessage msg then
    reqError saveTargetNotModuleCode msg
  else if let some resp := decodeJsonRpcError msg then
    resp
  else
    reqError "internalError" msg

def handleDepsOp (req : Request) : M (Response × Bool) := do
  let path ←
    match req.requirePath with
    | .ok path => pure path
    | .error err => return (reqError "invalidParams" err, false)
  let root := (← get).config.root
  let resolvedPath ← resolvePath root path
  let uri := sessionUri resolvedPath
  try
    let some module := normalizeModuleForPath root resolvedPath uri none
      | return (reqError "invalidParams" s!"no Lean module available for {uri}", false)
    let state ← mkDepsQueryState root
    let imports ← requireDirectImports state module.name
    let importedBy ← directImportedBy state module.name
    let importClosure ← collectImportClosure state module.name
    let importedByClosure ← collectImportedByClosure state module.name
    pure (Response.success (depsPayload root module imports importedBy importClosure importedByClosure), false)
  catch e =>
    let msg := e.toString
    if let some resp := decodeJsonRpcError msg then
      pure (resp, false)
    else
      pure (reqError "internalError" msg, false)

def currentSession? (backend : Backend) : M (Option Session) := do
  let state ← get
  match (getBackendState state backend).session? with
  | none =>
      pure none
  | some session =>
      if ← sessionExited session then
        shutdownSession session
        modify fun st =>
          let backendState := getBackendState st backend
          setBackendState st backend { backendState with session? := none, nextEpoch := backendState.nextEpoch + 1 }
        pure none
      else
        pure (some session)

private def sameSessionIdentity (left right : Session) : Bool :=
  left.backend == right.backend &&
    left.root == right.root &&
    left.epoch == right.epoch &&
    left.sessionToken == right.sessionToken

private def modifyCurrentSessionIfMatching
    (session : Session)
    (f : Session → Session) : M Unit := do
  match ← currentSession? session.backend with
  | some current =>
      if sameSessionIdentity current session then
        updateSession (f current)
      else
        pure ()
  | none =>
      pure ()

structure ServerRuntime where
  state : Std.Mutex State
  endpoint : Transport.Endpoint
  stop : IO.Ref Bool
  activeRequests : Std.Mutex (Std.TreeMap String (IO.Ref Bool))

def ServerRuntime.withState (server : ServerRuntime) (act : M α) : IO α := do
  server.state.atomically do
    let state ← get
    let (a, state) ← act.run state
    set state
    pure a

private def registerActiveRequest
    (server : ServerRuntime)
    (clientRequestId? : Option String) : IO (Except Response (Option (String × IO.Ref Bool))) := do
  match clientRequestId? with
  | none =>
      pure (.ok none)
  | some clientRequestId =>
      let cancelRef ← IO.mkRef false
      server.activeRequests.atomically do
        if (← get).contains clientRequestId then
          pure <| .error <| reqError "invalidParams" s!"clientRequestId '{clientRequestId}' is already active"
        else
          modify (·.insert clientRequestId cancelRef)
          pure <| .ok <| some (clientRequestId, cancelRef)

private def unregisterActiveRequest
    (server : ServerRuntime)
    (active? : Option (String × IO.Ref Bool)) : IO Unit := do
  match active? with
  | none => pure ()
  | some (clientRequestId, _) =>
      server.activeRequests.atomically do
        modify (·.erase clientRequestId)

private def ensureRequestNotCancelled
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  match cancelRef? with
  | none => pure ()
  | some cancelRef =>
      if ← cancelRef.get then
        throwBrokerFailure {
          code := .requestCancelled
          message := "client requested cancellation"
        }

private def cancelMatchingPendingRequests
    (session : Session)
    (clientRequestId : String) : IO Nat := do
  let entries ← snapshotPendingEntries session
  let mut cancelled := 0
  for (requestId, pending) in entries do
    if pending.clientRequestId? == some clientRequestId then
      sendCancelNotification session requestId
      cancelled := cancelled + 1
  pure cancelled

private def cancelActiveRequest
    (server : ServerRuntime)
    (clientRequestId : String) : IO Bool := do
  let cancelRef? ← server.activeRequests.atomically do
    pure <| (← get).get? clientRequestId
  match cancelRef? with
  | none =>
      pure false
  | some cancelRef =>
      cancelRef.set true
      let sessions ← server.withState do
        let state ← get
        pure [state.lean.session?, state.rocq.session?]
      for session? in sessions do
        if let some session := session? then
          discard <| cancelMatchingPendingRequests session clientRequestId
      pure true

private def propagatePendingCancellation
    (session : Session)
    (clientRequestId? : Option String)
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  match clientRequestId?, cancelRef? with
  | some clientRequestId, some cancelRef =>
      if ← cancelRef.get then
        discard <| cancelMatchingPendingRequests session clientRequestId
  | _, _ =>
      pure ()

private def requestStop (server : ServerRuntime) : IO Unit := do
  server.stop.set true
  try
    let conn ← Transport.connect server.endpoint
    Transport.closeConnection conn
  catch _ =>
    pure ()

private def validateRequestRoot (server : ServerRuntime) (req : Request) : IO (Except Response Unit) := do
  let requestedRoot ←
    match req.requireRoot with
    | .ok root => pure root
    | .error err => return .error (reqError "invalidParams" err)
  let requestedRoot ←
    try
      resolveRoot requestedRoot
    catch e =>
      return .error (reqError "invalidParams" e.toString)
  let daemonRoot ← server.withState do
    pure (← get).config.root
  if requestedRoot != daemonRoot then
    return .error (reqError "invalidParams" s!"Beam daemon serves {daemonRoot}, not {requestedRoot}")
  pure (.ok ())

private def mergeFileProgressIfCurrent
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : IO Unit := do
  server.withState do
    modifyCurrentSessionIfMatching session (fun current => recordFileProgress current uri fileProgress?)

private def withCurrentMatchingSession
    (server : ServerRuntime)
    (session : Session)
    (k : Session → M α) : IO α := do
  server.withState do
    match ← currentSession? session.backend with
    | some current =>
        if sameSessionIdentity current session then
          k current
        else
          throwBrokerFailure {
            code := .workerExited
            message := "broker backend session changed while request was in flight"
          }
    | none =>
        throwBrokerFailure {
          code := .workerExited
          message := "broker backend session exited while request was in flight"
        }

private def sendCurrentSessionRequestDecode [FromJson α]
    (server : ServerRuntime)
    (session : Session)
    (method : String)
    (params : Json) : IO α := do
  withCurrentMatchingSession server session fun current => do
    let (current, payload) ← sendRequestJson current method params
    updateSession current
    decodeResponseAs payload

private structure StartedTrackedBarrier where
  session : Session
  uri : DocumentUri
  version : Nat
  priorProgress? : Option SyncFileProgress := none
  promise : IO.Promise (Except String PendingResult)

private def startTrackedDiagnosticsBarrierIO
    (server : ServerRuntime)
    (req : Request)
    (path : System.FilePath)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO StartedTrackedBarrier := do
  server.withState do
    let session ← ensureSession req.backend
    let session ← syncFile session path
    let uri := sessionUri (← resolvePath session.root path)
    let docState ← requireDocState session uri
    let params := toJson (WaitForDiagnosticsParams.mk uri docState.version)
    let (session, promise) ←
      startRequestJsonTrackedDetailed session "textDocument/waitForDiagnostics" params
        (clientRequestId? := req.clientRequestId?)
        (tracked := some (uri, docState.version))
        (initialProgress? := docState.fileProgress?)
        (emitProgress? := emitProgress?)
        (fullDiagnostics := req.fullDiagnostics?.getD false)
        (emitDiagnostic? := emitDiagnostic?)
    updateSession session
    pure {
      session
      uri
      version := docState.version
      priorProgress? := docState.fileProgress?
      promise
    }

private def handleCloseWithoutSessionIO (req : Request) : IO (Response × Bool) := do
  let path ←
    match req.requirePath with
    | .ok path => pure path
    | .error err => return (reqError "invalidParams" err, false)
  if req.saveArtifacts?.getD false then
    let backendName := match req.backend with | .lean => "lean" | .rocq => "rocq"
    return (reqError "internalError" s!"cannot save artifacts without a live {backendName} session for {path}", false)
  pure (Response.success (Json.mkObj [("closed", toJson true)]), false)

private def finalizeSavedDoc
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (spec : LeanSaveSpec)
    (closeAfter : Bool) : IO Unit := do
  withCurrentMatchingSession server session fun current => do
    let shouldSendDidSave :=
      match current.docs.get? uri with
      | some docState => docState.version == version
      | none => false
    let current ←
      if shouldSendDidSave then
        sendNotificationJson current "textDocument/didSave" (toJson ({
          textDocument := ({ uri := uri : TextDocumentIdentifier })
          text? := none
          : DidSaveTextDocumentParams
        }))
      else
        pure current
    let current ← sendNotificationJson current "workspace/didChangeWatchedFiles" (toJson ({
      changes := #[
        { uri := (System.Uri.pathToUri spec.ileanPath : String), type := FileChangeType.Changed }
      ]
      : DidChangeWatchedFilesParams
    }))
    let current := markDocSavedVersion current uri version
    let current ←
      if closeAfter && current.docs.contains uri then
        sendNotificationJson current "textDocument/didClose" (toJson ({
          textDocument := ({ uri := uri : TextDocumentIdentifier })
          : DidCloseTextDocumentParams
        }))
      else
        pure current
    let current :=
      if closeAfter then
        { current with docs := current.docs.erase uri }
      else
        current
    updateSession current

private structure SaveOleanCompleted where
  session : Session
  uri : DocumentUri
  version : Nat
  spec : LeanSaveSpec
  payload : Json
  fileProgress? : Option SyncFileProgress := none

private def saveCompletedResponse
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) : Response :=
  let payload :=
    if closeAfter then
      Json.mkObj [("closed", toJson true), ("saved", saved.payload)]
    else
      saved.payload
  withFileProgress (sessionResult saved.session payload) saved.fileProgress?

private def fetchSyncSaveReadinessIO
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri) : IO SyncSaveReadiness := do
  if session.backend != .lean then
    pure {}
  else
    let method ← IO.ofExcept <| saveReadinessMethod session.backend
    let params := toJson ({
      textDocument := ({ uri := uri : TextDocumentIdentifier })
      : RunAt.Internal.SaveReadinessParams
    })
    let readiness : RunAt.Internal.SaveReadinessResult ←
      sendCurrentSessionRequestDecode server session method params
    pure (syncSaveReadinessOfResult readiness)

private def fetchDirectImportsIO
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri) : IO DirectImportsQueryResult := do
  let method ← IO.ofExcept <| directImportsMethod session.backend
  let params := toJson ({
    textDocument := ({ uri := uri : TextDocumentIdentifier })
    : RunAt.Internal.DirectImportsParams
  })
  let result : RunAt.Internal.DirectImportsResult ←
    sendCurrentSessionRequestDecode server session method params
  pure {
    version := result.version
    imports := result.imports
  }

private def staleSyncErrorResponse
    (message : String)
    (targetPath : String)
    (hints : Array StaleDirectDepHint) : Response :=
  reqError syncBarrierIncompleteCode message (some <| staleSyncErrorData targetPath hints)

private def collectStaleDirectDepHintsIO
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat) : IO (Array StaleDirectDepHint) := do
  if session.backend != .lean then
    pure #[]
  else
    let importsResult ← fetchDirectImportsIO server session uri
    withCurrentMatchingSession server session fun current => do
      let targetLastSyncSeq :=
        match current.docs.get? uri with
        | some docState => docState.lastSyncSeq
        | none => 0
      let history :=
        current.moduleHistory.foldl (init := {}) fun acc moduleName moduleHistory =>
          acc.insert moduleName {
            path := moduleHistory.path
            lastSyncSeq := moduleHistory.lastSyncSeq
            lastSaveSeq := moduleHistory.lastSaveSeq
            : ModuleHistorySnapshot
          }
      pure <| collectStaleDirectDepHints importsResult version targetLastSyncSeq history

private def saveOleanIO
    (server : ServerRuntime)
    (req : Request)
    (path : System.FilePath)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO SaveOleanCompleted := do
  ensureRequestNotCancelled cancelRef?
  let path ← resolvePath ((← server.withState do pure (← get).config.root)) path
  let started ← startTrackedDiagnosticsBarrierIO server req path emitProgress? emitDiagnostic?
  let (textHash, textTraceHash, textMTime, leanCmd?) ← server.withState do
    let docState ← requireDocState started.session started.uri
    pure (docState.textHash, docState.textTraceHash, docState.textMTime, (← get).config.leanCmd?)
  propagatePendingCancellation started.session req.clientRequestId? cancelRef?
  let barrier ← awaitPendingResult started.promise
  let barrierProgress? := effectiveSyncBarrierProgress started.priorProgress? barrier.progress? barrier.diagnostics
  let (_ : WaitForDiagnostics) ← decodeResponseAs barrier.result
  mergeFileProgressIfCurrent server started.session started.uri barrierProgress?
  ensureSyncBarrierComplete started.uri started.version barrierProgress? barrier.diagnostics
  ensureRequestNotCancelled cancelRef?
  let spec ← mkLeanSaveSpec started.session.root path { hash := textTraceHash, mtime := textMTime } leanCmd?
  let method ← IO.ofExcept <| saveArtifactsMethod started.session.backend
  let params := toJson ({
    textDocument := ({ uri := started.uri : TextDocumentIdentifier })
    oleanFile := spec.oleanPath.toString
    ileanFile := spec.ileanPath.toString
    cFile := spec.cPath.toString
    bcFile? := spec.bcPath?.map (fun bcPath => System.FilePath.toString bcPath)
    : RunAt.Internal.SaveArtifactsParams
  })
  let (session, savePromise) ← withCurrentMatchingSession server started.session fun current => do
    let (current, savePromise) ← startRequestJsonTrackedDetailed current method params
      (clientRequestId? := req.clientRequestId?)
    updateSession current
    pure (current, savePromise)
  propagatePendingCancellation session req.clientRequestId? cancelRef?
  let savePending ← awaitPendingResult savePromise
  let saveResult : RunAt.Internal.SaveArtifactsResult ← decodeResponseAs savePending.result
  if saveResult.version != started.version then
    throw <| IO.userError
      s!"save_olean saved version {saveResult.version}, expected synced version {started.version}"
  if saveResult.textHash != textHash then
    throw <| IO.userError
      s!"save_olean saved text hash {saveResult.textHash}, expected synced hash {textHash}"
  writeLeanSaveTrace spec
  pure {
    session
    uri := started.uri
    version := started.version
    spec
    payload := leanSavePayload spec started.version textTraceHash
    fileProgress? := barrierProgress?
  }

private def handleSyncFileOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.requirePath with
      | .ok path => pure path
      | .error err => return (reqError "invalidParams" err, false)
    ensureRequestNotCancelled cancelRef?
    let path ← resolvePath ((← server.withState do pure (← get).config.root)) path
    let started ← startTrackedDiagnosticsBarrierIO server req path emitProgress? emitDiagnostic?
    propagatePendingCancellation started.session req.clientRequestId? cancelRef?
    let pending ← awaitPendingResult started.promise
    let fileProgress? := effectiveSyncBarrierProgress started.priorProgress? pending.progress? pending.diagnostics
    mergeFileProgressIfCurrent server started.session started.uri fileProgress?
    if syncBarrierIncomplete? fileProgress? pending.diagnostics then
      let hints ← collectStaleDirectDepHintsIO server started.session started.uri started.version
      let message := syncBarrierIncompleteMessage started.uri started.version fileProgress?
      let targetPath := trackedPathLabel started.session.root started.uri
      return (staleSyncErrorResponse message targetPath hints, false)
    server.withState do
      modifyCurrentSessionIfMatching started.session
        (fun current => markDocSyncedVersion current started.uri started.version)
    let saveReadiness ← fetchSyncSaveReadinessIO server started.session started.uri
    let payload := toJson ({
      version := started.version
      errorCount := syncErrorCount pending.diagnostics
      warningCount := syncWarningCount pending.diagnostics
      stateErrorCount := saveReadiness.stateErrorCount
      stateCommandErrorCount := saveReadiness.stateCommandErrorCount
      saveReady := saveReadiness.saveReady
      saveReadyReason := saveReadiness.saveReadyReason
      : SyncFileResult
    })
    pure (withFileProgress (sessionResult started.session payload) fileProgress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleCloseOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Response × Bool) := do
  let path ←
    match req.requirePath with
    | .ok path => pure path
    | .error err => return (reqError "invalidParams" err, false)
  if req.saveArtifacts?.getD false then
    try
      let saved ← saveOleanIO server req path cancelRef? emitProgress? emitDiagnostic?
      finalizeSavedDoc server saved.session saved.uri saved.version saved.spec true
      pure (saveCompletedResponse saved true, false)
    catch e =>
      pure (responseForExceptionMessage e.toString, false)
  else
    server.withState do
      match ← currentSession? req.backend with
      | some session =>
          let session ← closeFile session path
          updateSession session
          pure (Response.success (Json.mkObj [("closed", toJson true)]), false)
      | none =>
          pure (Response.success (Json.mkObj [("closed", toJson true)]), false)

private def handleRunAtOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.requirePath with
      | .ok path => pure path
      | .error err => return (reqError "invalidParams" err, false)
    let line ←
      match req.requireLine with
      | .ok line => pure line
      | .error err => return (reqError "invalidParams" err, false)
    let character ←
      match req.requireCharacter with
      | .ok character => pure character
      | .error err => return (reqError "invalidParams" err, false)
    let text ←
      match req.requireText with
      | .ok text => pure text
      | .error err => return (reqError "invalidParams" err, false)
    let method ←
      match runAtMethod req.backend with
      | .ok method => pure method
      | .error err => return (reqError "invalidParams" err, false)
    ensureRequestNotCancelled cancelRef?
    let (session, uri, promise) ← server.withState do
      let session ← ensureSession req.backend
      let session ← syncFile session path
      let uri := sessionUri (← resolvePath session.root path)
      let docState ← requireDocState session uri
      let params := Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
        , ("position", toJson ({ line := line, character := character : Lsp.Position }))
        , ("text", toJson text)
        ] ++
        match req.storeHandle? with
        | some b => [("storeHandle", toJson b)]
        | none => []
      let (session, promise) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := some (uri, docState.version))
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
      updateSession session
      pure (session, uri, promise)
    propagatePendingCancellation session req.clientRequestId? cancelRef?
    let pending ← awaitPendingResult promise
    mergeFileProgressIfCurrent server session uri pending.progress?
    pure (withFileProgress (sessionResult session (wrapResultHandle session pending.result)) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRequestAtOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.requirePath with
      | .ok path => pure path
      | .error err => return (reqError "invalidParams" err, false)
    let line ←
      match req.requireLine with
      | .ok line => pure line
      | .error err => return (reqError "invalidParams" err, false)
    let character ←
      match req.requireCharacter with
      | .ok character => pure character
      | .error err => return (reqError "invalidParams" err, false)
    let requestedMethod ←
      match req.requireMethod with
      | .ok method => pure method
      | .error err => return (reqError "invalidParams" err, false)
    let method ←
      match requestAtMethod req.backend requestedMethod with
      | .ok method => pure method
      | .error err => return (reqError "invalidParams" err, false)
    let extraParams ←
      match req.requireParamsObject with
      | .ok params => pure params
      | .error err => return (reqError "invalidParams" err, false)
    ensureRequestNotCancelled cancelRef?
    let (session, uri, tracked, promise) ← server.withState do
      let session ← ensureSession req.backend
      let session ← syncFile session path
      let uri := sessionUri (← resolvePath session.root path)
      let docState ← requireDocState session uri
      let tracked :=
        if session.backend == .lean then
          some (uri, docState.version)
        else
          none
      let params := Json.mergeObj extraParams <| Json.mkObj [
        ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
        ("position", toJson ({ line := line, character := character : Lsp.Position }))
      ]
      let (session, promise) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := tracked)
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
      updateSession session
      pure (session, uri, tracked, promise)
    propagatePendingCancellation session req.clientRequestId? cancelRef?
    let pending ← awaitPendingResult promise
    if tracked.isSome then
      mergeFileProgressIfCurrent server session uri pending.progress?
    pure (withFileProgress (sessionResult session pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleSaveOleanOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Response × Bool) := do
  let path ←
    match req.requirePath with
    | .ok path => pure path
    | .error err => return (reqError "invalidParams" err, false)
  try
    let saved ← saveOleanIO server req path cancelRef? emitProgress? emitDiagnostic?
    finalizeSavedDoc server saved.session saved.uri saved.version saved.spec false
    pure (saveCompletedResponse saved false, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleGoalsOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.requirePath with
      | .ok path => pure path
      | .error err => return (reqError "invalidParams" err, false)
    let line ←
      match req.requireLine with
      | .ok line => pure line
      | .error err => return (reqError "invalidParams" err, false)
    let character ←
      match req.requireCharacter with
      | .ok character => pure character
      | .error err => return (reqError "invalidParams" err, false)
    let method ←
      match goalsMethod req.backend req.mode? with
      | .ok method => pure method
      | .error err => return (reqError "invalidParams" err, false)
    if req.backend == .lean && req.text?.isSome then
      return (reqError "invalidParams" "lean goals does not accept speculative text; use lean-run-at for execution", false)
    ensureRequestNotCancelled cancelRef?
    let (session, uri, tracked, promise) ← server.withState do
      let session ← ensureSession req.backend
      let session ← syncFile session path
      let uri := sessionUri (← resolvePath session.root path)
      let docState ← requireDocState session uri
      let position : Lsp.Position := { line := line, character := character }
      let params :=
        match req.backend with
        | .lean =>
            Json.mkObj [
              ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
              ("position", toJson position)
            ]
        | .rocq =>
            let fields :=
              [
                ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier })),
                ("position", toJson position),
                ("mode", toJson (goalModeValue req.mode?)),
                ("compact", toJson (req.compact?.getD false)),
                ("pp_format", toJson (goalPpFormatValue req.ppFormat?))
              ] ++
              match req.text? with
              | some text => [("command", toJson text)]
              | none => []
            Json.mkObj fields
      let tracked :=
        if session.backend == .lean then
          some (uri, docState.version)
        else
          none
      let (session, promise) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := tracked)
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
      updateSession session
      pure (session, uri, tracked, promise)
    propagatePendingCancellation session req.clientRequestId? cancelRef?
    let pending ← awaitPendingResult promise
    if tracked.isSome then
      mergeFileProgressIfCurrent server session uri pending.progress?
    pure (withFileProgress (sessionResult session pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRunWithOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.requirePath with
      | .ok path => pure path
      | .error err => return (reqError "invalidParams" err, false)
    let handle ←
      match req.requireHandle with
      | .ok handle => pure handle
      | .error err => return (reqError "invalidParams" err, false)
    let text ←
      match req.requireText with
      | .ok text => pure text
      | .error err => return (reqError "invalidParams" err, false)
    let method ←
      match runWithMethod req.backend with
      | .ok method => pure method
      | .error err => return (reqError "invalidParams" err, false)
    ensureRequestNotCancelled cancelRef?
    let (session, uri, promise) ← server.withState do
      let session ← ensureSession req.backend
      let rawHandle ←
        match unwrapHandle session handle with
        | .ok raw => pure raw
        | .error err => throwBrokerFailure { code := .contentModified, message := err }
      let session ← syncFile session path
      let uri := sessionUri (← resolvePath session.root path)
      let docState ← requireDocState session uri
      let params := Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
        , ("handle", rawHandle)
        , ("text", toJson text)
        ] ++ (match req.storeHandle? with
        | some b => [("storeHandle", toJson b)]
        | none => []) ++
        (match req.linear? with
        | some b => [("linear", toJson b)]
        | none => [])
      let (session, promise) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := some (uri, docState.version))
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
      updateSession session
      pure (session, uri, promise)
    propagatePendingCancellation session req.clientRequestId? cancelRef?
    let pending ← awaitPendingResult promise
    mergeFileProgressIfCurrent server session uri pending.progress?
    pure (withFileProgress (sessionResult session (wrapResultHandle session pending.result)) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleReleaseOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.requirePath with
      | .ok path => pure path
      | .error err => return (reqError "invalidParams" err, false)
    let handle ←
      match req.requireHandle with
      | .ok handle => pure handle
      | .error err => return (reqError "invalidParams" err, false)
    let method ←
      match releaseMethod req.backend with
      | .ok method => pure method
      | .error err => return (reqError "invalidParams" err, false)
    ensureRequestNotCancelled cancelRef?
    let (session, uri, promise) ← server.withState do
      let session ← ensureSession req.backend
      let rawHandle ←
        match unwrapHandle session handle with
        | .ok raw => pure raw
        | .error err => throwBrokerFailure { code := .contentModified, message := err }
      let session ← syncFile session path
      let uri := sessionUri (← resolvePath session.root path)
      let docState ← requireDocState session uri
      let params := Json.mkObj [
        ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
        ("handle", rawHandle)
      ]
      let (session, promise) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := some (uri, docState.version))
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
      updateSession session
      pure (session, uri, promise)
    propagatePendingCancellation session req.clientRequestId? cancelRef?
    let pending ← awaitPendingResult promise
    mergeFileProgressIfCurrent server session uri pending.progress?
    pure (withFileProgress (sessionResult session pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRequestIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO (Response × Bool) := do
  match req.op with
  | .shutdown =>
      let resp ← server.withState do
        let state ← get
        for backend in [Backend.lean, Backend.rocq] do
          match (getBackendState state backend).session? with
          | some session => shutdownSession session
          | none => pure ()
        pure <| Response.success (Json.mkObj [("shutdown", toJson true)])
      pure (resp, true)
  | .stats =>
      pure (Response.success (← server.withState statsPayload), false)
  | .resetStats =>
      let now ← IO.monoNanosNow
      let resp ← server.withState do
        resetMetrics now
        pure <| Response.success (Json.mkObj [("reset", toJson true)])
      pure (resp, false)
  | .openDocs =>
      pure (Response.success (← server.withState openDocsPayload), false)
  | op =>
      match ← validateRequestRoot server req with
      | .error resp => pure (resp, false)
      | .ok _ =>
          match op with
          | .ensure =>
              let resp ←
                try
                  server.withState do
                    let session ← ensureSession req.backend
                    let payload := Json.mkObj [
                      ("backend", toJson req.backend),
                      ("root", toJson session.root.toString),
                      ("epoch", toJson session.epoch)
                    ]
                    pure <| sessionResult session payload
                catch e =>
                  pure <| reqError "internalError" e.toString
              pure (resp, false)
          | .cancel =>
              let targetClientRequestId ←
                match req.requireCancelRequestId with
                | .ok targetClientRequestId => pure targetClientRequestId
                | .error err => return (reqError "invalidParams" err, false)
              let cancelled ← cancelActiveRequest server targetClientRequestId
              pure (Response.success (Json.mkObj [("cancelled", toJson cancelled)]), false)
          | .syncFile => handleSyncFileOpIO server req cancelRef? emitProgress? emitDiagnostic?
          | .close => handleCloseOpIO server req cancelRef? emitProgress? emitDiagnostic?
          | .runAt => handleRunAtOpIO server req cancelRef? emitProgress?
          | .requestAt => handleRequestAtOpIO server req cancelRef? emitProgress?
          | .deps => server.withState <| handleDepsOp req
          | .saveOlean => handleSaveOleanOpIO server req cancelRef? emitProgress? emitDiagnostic?
          | .goals => handleGoalsOpIO server req cancelRef? emitProgress?
          | .runWith => handleRunWithOpIO server req cancelRef? emitProgress?
          | .release => handleReleaseOpIO server req cancelRef? emitProgress?
          | .openDocs | .stats | .resetStats | .shutdown =>
              unreachable!

def handleClient (server : ServerRuntime) (client : Transport.Connection) : IO Unit := do
  let clientRequestIdRef ← IO.mkRef (none : Option String)
  try
    let msg ← Transport.recvMsg client
    let req : Request ←
      match Json.parse msg with
      | .error err => throw <| IO.userError s!"invalid request json: {err}"
      | .ok json =>
          match fromJson? json with
          | .ok req => pure req
          | .error err => throw <| IO.userError s!"invalid request payload: {err}"
    clientRequestIdRef.set req.clientRequestId?
    let emitProgress : SyncFileProgress → IO Unit := fun progress =>
      Transport.sendMsg client (toJson (StreamMessage.mkFileProgress req.clientRequestId? progress)).compress
    let emitDiagnostic : StreamDiagnostic → IO Unit := fun diagnostic =>
      Transport.sendMsg client (toJson (StreamMessage.mkDiagnostic req.clientRequestId? diagnostic)).compress
    let startedAt ← IO.monoNanosNow
    let active? ←
      match req.op with
      | .cancel | .stats | .resetStats | .shutdown | .openDocs =>
          pure none
      | _ =>
          match ← registerActiveRequest server req.clientRequestId? with
          | .ok active? => pure active?
          | .error resp =>
              let finishedAt ← IO.monoNanosNow
              let latencyMs := (finishedAt - startedAt) / 1000000
              server.withState do
                recordRequestMetrics req.backend req.op.key resp.ok (resp.error?.map (·.code)) latencyMs
              Transport.sendMsg client (toJson (StreamMessage.mkResponse (resp.withClientRequestId req.clientRequestId?))).compress
              return
    try
      let (resp, shouldStop) ←
        handleRequestIO server req (active?.map Prod.snd) (some emitProgress) (some emitDiagnostic)
      let finishedAt ← IO.monoNanosNow
      if req.op != .stats && req.op != .resetStats && req.op != .shutdown &&
          req.op != .openDocs && req.op != .cancel then
        let latencyMs := (finishedAt - startedAt) / 1000000
        server.withState do
          recordRequestMetrics req.backend req.op.key resp.ok (resp.error?.map (·.code)) latencyMs
      let resp := resp.withClientRequestId req.clientRequestId?
      Transport.sendMsg client (toJson (StreamMessage.mkResponse resp)).compress
      if shouldStop then
        requestStop server
    finally
      unregisterActiveRequest server active?
  catch e =>
    let resp := (Response.error "internalError" e.toString).withClientRequestId (← clientRequestIdRef.get)
    try
      Transport.sendMsg client (toJson (StreamMessage.mkResponse resp)).compress
    catch _ =>
      pure ()
  finally
    Transport.closeConnection client

partial def acceptLoop (server : ServerRuntime) (listener : Transport.Listener) : IO Unit := do
  if ← server.stop.get then
    pure ()
  else
    let client ← Transport.accept listener
    if ← server.stop.get then
      Transport.closeConnection client
    else
      let _ ← IO.asTask do
        try
          handleClient server client
        catch e =>
          IO.eprintln s!"broker client task failed: {e.toString}"
      acceptLoop server listener

private structure CliOptions where
  endpoint : Transport.Endpoint := .tcp 8765
  root? : Option String := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  rocqCmd? : Option String := none

private def parseNatArg (name value : String) : Except String Nat := do
  let some n := value.toNat?
    | throw s!"invalid {name} '{value}'"
  pure n

private def parsePortArg (value : String) : Except String UInt16 := do
  let port ← parseNatArg "port" value
  if port < UInt16.size then
    pure port.toUInt16
  else
    throw s!"port '{value}' is outside the supported range 0-65535"

private partial def parseCliOptions (opts : CliOptions) : List String → Except String CliOptions
  | [] => pure opts
  | "--socket" :: socketPath :: rest =>
      parseCliOptions { opts with endpoint := .unix (System.FilePath.mk socketPath) } rest
  | "--port" :: port :: rest => do
      let port ← parsePortArg port
      parseCliOptions { opts with endpoint := .tcp port } rest
  | "--root" :: root :: rest =>
      parseCliOptions { opts with root? := some root } rest
  | "--lean-cmd" :: leanCmd :: rest =>
      parseCliOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseCliOptions { opts with leanPlugin? := some leanPlugin } rest
  | "--rocq-cmd" :: rocqCmd :: rest =>
      parseCliOptions { opts with rocqCmd? := some rocqCmd } rest
  | arg :: _ =>
      throw s!"unexpected Beam daemon argument '{arg}'"

def main (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| parseCliOptions {} args
  let some root := opts.root?
    | throw <| IO.userError "missing Beam daemon --root PATH"
  let root ← IO.FS.realPath <| System.FilePath.mk root
  let leanPlugin? ← opts.leanPlugin?.mapM (fun path => IO.FS.realPath <| System.FilePath.mk path)
  let config : BrokerConfig := {
    root := root
    leanCmd? := opts.leanCmd?
    leanPlugin? := leanPlugin?
    rocqCmd? := opts.rocqCmd?
  }
  let listener ← Transport.bindAndListen opts.endpoint 16
  let startMonoNanos ← IO.monoNanosNow
  let runtime : ServerRuntime := {
    state := ← Std.Mutex.new { config := config, startMonoNanos := startMonoNanos }
    endpoint := opts.endpoint
    stop := ← IO.mkRef false
    activeRequests := ← Std.Mutex.new ({} : Std.TreeMap String (IO.Ref Bool))
  }
  try
    acceptLoop runtime listener
  finally
    Transport.closeListener listener

end Beam.Broker

def main := Beam.Broker.main
