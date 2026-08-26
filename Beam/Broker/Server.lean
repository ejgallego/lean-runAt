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
import Lean.Server.CodeActions
import Beam.Broker.Config
import Beam.Broker.DocumentState
import Beam.Broker.Errors
import Beam.Broker.Metrics
import Beam.Broker.OpenDocs
import Beam.Broker.Pending
import Beam.Broker.Protocol
import Beam.Broker.RequestArgs
import Beam.Broker.Transport
import Beam.Broker.Lean
import Beam.Broker.LakeSave
import Beam.Broker.Readiness
import Beam.Broker.SyncResult
import Beam.LSP.Save
import Beam.Path
import Std.Sync.Mutex

open Lean
open Lean.JsonRpc
open Lean.Lsp
open IO.FS.Stream

namespace Beam.Broker

abbrev brokerStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  -- Keep backend stderr away from MCP stdio. Inheriting it can corrupt
  -- client framing; piping and draining it caused macOS save_olean hangs.
  stderr := .null

structure Session where
  workspaceId : WorkspaceId
  backend : Backend
  root : System.FilePath
  epoch : Nat
  sessionToken : String
  proc : IO.Process.Child brokerStdio
  stdin : IO.FS.Stream
  stdout : IO.FS.Stream
  pending : PendingRequestStore
  nextId : Nat := 1
  nextEventSeq : Nat := 1
  moduleHistory : Std.TreeMap String ModuleHistory := {}
  docs : Std.TreeMap String DocState := {}

structure BackendState where
  nextEpoch : Nat := 1
  session? : Option Session := none

structure WorkspaceState where
  config : BrokerConfig
  nextFileSnapshotSeq : Nat := 1
  lean : BackendState := {}
  rocq : BackendState := {}
  leanMetrics : BackendMetrics := {}
  rocqMetrics : BackendMetrics := {}

structure State where
  bootstrapConfig : BrokerConfig
  startMonoNanos : Nat := 0
  workspaces : Std.TreeMap WorkspaceId WorkspaceState := {}
  streamSink? : Option (StreamMessage → IO Unit) := none
  currentClientRequestId? : Option String := none

abbrev M := StateRefT State IO

private abbrev HandlerM := ExceptT ResponseFailure IO

private def liftHandlerIO (act : IO α) : HandlerM α :=
  ExceptT.mk do
    let value ← act
    pure (.ok value)

private def liftFailureIO (act : IO (Except ResponseFailure α)) : HandlerM α :=
  ExceptT.mk act

private def throwBrokerFailure (failure : BrokerFailure) : HandlerM α :=
  throw failure.toResponseFailure

private def liftBrokerFailureIO (act : IO (Except BrokerFailure α)) : HandlerM α :=
  liftFailureIO do
    match ← act with
    | .ok value => pure <| .ok value
    | .error failure => pure <| .error failure.toResponseFailure

private def withFailureProgress
    (fileProgress? : Option SyncFileProgress)
    (act : HandlerM α) : HandlerM α :=
  ExceptT.mk do
    try
      match ← act.run with
      | .ok value => pure (.ok value)
      | .error failure =>
          pure (.error <| failure.withOptionalFileProgress fileProgress?)
    catch e =>
      pure (.error <|
        (responseFailureFor .internalError e.toString).withOptionalFileProgress fileProgress?)

private def requestArg (arg : Except ResponseFailure α) : HandlerM α :=
  match arg with
  | .ok value => pure value
  | .error failure => throw failure

private def requestMethod (method : Except String String) : HandlerM String :=
  match method with
  | .ok method => pure method
  | .error msg => throw <| responseFailureFor .invalidParams msg

private def runHandler (act : HandlerM (Response × Bool)) : IO (Response × Bool) := do
  try
    match ← act.run with
    | .ok result => pure result
    | .error failure => pure (failure.toResponse, false)
  catch e =>
    pure (errorResponseFor .internalError e.toString, false)

private def mkSessionToken : IO String := do
  let pid ← IO.Process.getPID
  let now ← IO.monoNanosNow
  pure s!"{pid}-{now}"

private def resolveRoot (root : System.FilePath) : IO System.FilePath :=
  Beam.resolveExistingPath root

private def resolvePath (root : System.FilePath) (path : System.FilePath) : IO System.FilePath :=
  Beam.resolvePathAgainstRoot root path

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

private def killCommand? : IO (Option System.FilePath) := do
  for candidate in [System.FilePath.mk "/bin/kill", System.FilePath.mk "/usr/bin/kill"] do
    if ← candidate.pathExists then
      return some candidate
  pure none

private partial def waitForProcessExitWithTimeout
    (proc : IO.Process.Child brokerStdio)
    (timeoutMs : Nat)
    (pollMs : Nat := 50) : IO Bool := do
  let rec loop (remainingMs : Nat) : IO Bool := do
    match ← (try
      proc.tryWait
    catch _ =>
      pure none) with
    | some _ => pure true
    | none =>
        if remainingMs == 0 then
          pure false
        else
          IO.sleep pollMs.toUInt32
          loop (remainingMs - min pollMs remainingMs)
  loop timeoutMs

private def shutdownSession (session : Session) : IO Unit := do
  try
    writeLspRequest session.stdin ({ id := 0, method := "shutdown", param := Json.null : Lean.JsonRpc.Request Json })
    let task ← IO.asTask (prio := Task.Priority.dedicated) session.stdout.readLspMessage
    let _ ← waitForTaskWithTimeout task sessionShutdownReplyTimeoutMs
    pure ()
  catch _ =>
    pure ()
  try
    writeLspNotification session.stdin ({ method := "exit", param := Json.null : Lean.JsonRpc.Notification Json })
  catch _ =>
    pure ()
  unless ← waitForProcessExitWithTimeout session.proc sessionShutdownReplyTimeoutMs do
    try
      session.proc.kill
    catch _ =>
      pure ()
    try
      if let some kill := ← killCommand? then
        let _ ← IO.Process.output {
          cmd := kill.toString
          args := #["-9", toString session.proc.pid.toNat]
        }
        pure ()
    catch _ =>
      pure ()
    discard <| waitForProcessExitWithTimeout session.proc sessionShutdownReplyTimeoutMs
  try
    discard <| session.proc.tryWait
  catch _ =>
    pure ()

private def sessionExited (session : Session) : IO Bool := do
  try
    pure (← session.proc.tryWait).isSome
  catch _ =>
    pure true

private def mkWorkspaceState (config : BrokerConfig) : WorkspaceState := { config }

private def mkInitialState
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (startMonoNanos : Nat) : State := {
  bootstrapConfig := config
  startMonoNanos
  workspaces := Std.TreeMap.empty.insert workspaceId (mkWorkspaceState config)
}

private def validWorkspaceId (workspaceId : WorkspaceId) : Bool :=
  Beam.Workspace.validWorkspaceId workspaceId

private def getWorkspace? (state : State) (workspaceId : WorkspaceId) : Option WorkspaceState :=
  state.workspaces.get? workspaceId

private def setWorkspace
    (state : State)
    (workspaceId : WorkspaceId)
    (workspace : WorkspaceState) : State :=
  { state with workspaces := state.workspaces.insert workspaceId workspace }

private def getBackendState (workspace : WorkspaceState) (backend : Backend) : BackendState :=
  match backend with
  | .lean => workspace.lean
  | .rocq => workspace.rocq

private def setBackendState
    (workspace : WorkspaceState)
    (backend : Backend)
    (backendState : BackendState) : WorkspaceState :=
  match backend with
  | .lean => { workspace with lean := backendState }
  | .rocq => { workspace with rocq := backendState }

private def getBackendMetrics (workspace : WorkspaceState) (backend : Backend) : BackendMetrics :=
  match backend with
  | .lean => workspace.leanMetrics
  | .rocq => workspace.rocqMetrics

private def setBackendMetrics
    (workspace : WorkspaceState)
    (backend : Backend)
    (metrics : BackendMetrics) : WorkspaceState :=
  match backend with
  | .lean => { workspace with leanMetrics := metrics }
  | .rocq => { workspace with rocqMetrics := metrics }

private def recordSessionSpawn (workspaceId : WorkspaceId) (backend : Backend) (restart : Bool) : M Unit := do
  modify fun state =>
    match getWorkspace? state workspaceId with
    | none => state
    | some workspace =>
        let metrics := getBackendMetrics workspace backend
        let metrics := {
          metrics with
          sessionStarts := metrics.sessionStarts + 1
          sessionRestarts := metrics.sessionRestarts + (if restart then 1 else 0)
        }
        setWorkspace state workspaceId (setBackendMetrics workspace backend metrics)

private def recordRequestMetrics
    (workspaceId : WorkspaceId)
    (backend : Backend)
    (op : String)
    (ok : Bool)
    (errorCode? : Option String)
    (latencyMs : Nat) : M Unit := do
  modify fun state =>
    match getWorkspace? state workspaceId with
    | none => state
    | some workspace =>
        let metrics := getBackendMetrics workspace backend
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
        setWorkspace state workspaceId (setBackendMetrics workspace backend metrics)

private def sessionSnapshotJson (session? : Option Session) : Json :=
  match session? with
  | none => Json.mkObj [("active", toJson false)]
  | some session =>
      Json.mkObj [
        ("active", toJson true),
        ("workspaceId", toJson session.workspaceId),
        ("root", toJson session.root.toString),
        ("epoch", toJson session.epoch),
        ("openDocCount", toJson session.docs.toList.length)
      ]

private def workspaceStatsJson (workspaceId : WorkspaceId) (workspace : WorkspaceState) : Json :=
  Json.mkObj [
    ("id", toJson workspaceId),
    ("root", toJson workspace.config.root.toString),
    ("sessions", Json.mkObj [
      ("lean", sessionSnapshotJson workspace.lean.session?),
      ("rocq", sessionSnapshotJson workspace.rocq.session?)
    ]),
    ("byBackend", Json.mkObj [
      ("lean", backendMetricsJson workspace.leanMetrics),
      ("rocq", backendMetricsJson workspace.rocqMetrics)
    ])
  ]

private def statsPayload (workspaceId? : Option WorkspaceId := none) : M Json := do
  let state ← get
  let now ← IO.monoNanosNow
  let uptimeMs := (now - state.startMonoNanos) / 1000000
  match workspaceId? with
  | some workspaceId =>
      match getWorkspace? state workspaceId with
      | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
      | some workspace =>
          pure <| (workspaceStatsJson workspaceId workspace).setObjVal! "uptimeMs" (toJson uptimeMs)
  | none =>
      let workspaceFields := state.workspaces.toList.map fun (workspaceId, workspace) =>
        (workspaceId, workspaceStatsJson workspaceId workspace)
      pure <| Json.mkObj [
        ("uptimeMs", toJson uptimeMs),
        ("workspaces", Json.mkObj workspaceFields)
      ]

private def resetMetrics (startMonoNanos : Nat) : M Unit := do
  modify fun state =>
    let workspaces := state.workspaces.map fun _ workspace => {
      workspace with
      leanMetrics := {}
      rocqMetrics := {}
    }
    { state with workspaces, startMonoNanos := startMonoNanos }

private def traceEnabled (envName : String) : IO Bool := do
  match ← IO.getEnv envName with
  | some value => pure (!value.isEmpty && value != "0")
  | none => pure false

private def emitBrokerTrace (message : String) : IO Unit := do
  let now ← IO.monoNanosNow
  IO.eprintln s!"beam-broker trace {now}: {message}"

private def traceBroker (message : String) : IO Unit := do
  if ← traceEnabled "LEAN_BEAM_BROKER_TRACE" then
    emitBrokerTrace message

private def optionLabel (value? : Option String) : String :=
  value?.getD "<none>"

private def waitDiagnosticsWatchdogMs? : IO (Option Nat) := do
  match ← IO.getEnv "LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS" with
  | none => pure none
  | some value =>
      if value.isEmpty || value == "0" then
        pure none
      else
        match value.toNat? with
        | some ms => pure (some ms)
        | none =>
            emitBrokerTrace
              s!"invalid LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS={value}; watchdog disabled"
            pure none

private def startWaitDiagnosticsWatchdog
    (label : String)
    (doneRef : IO.Ref Bool) : IO Unit := do
  match ← waitDiagnosticsWatchdogMs? with
  | none => pure ()
  | some timeoutMs =>
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        IO.sleep timeoutMs.toUInt32
        unless (← doneRef.get) do
          emitBrokerTrace
            s!"waitForDiagnostics watchdog after {timeoutMs}ms: {label}"
      pure ()

private def awaitPending (promise : IO.Promise (Except ResponseFailure PendingResult)) :
    HandlerM PendingResult := do
  requestArg (← liftHandlerIO <| PendingRequest.awaitOutcome promise)

private def awaitWaitForDiagnosticsBarrier
    (label : String)
    (promise : IO.Promise (Except ResponseFailure PendingResult)) : HandlerM PendingResult := do
  let doneRef ← liftHandlerIO <| IO.mkRef false
  liftHandlerIO <| startWaitDiagnosticsWatchdog label doneRef
  let outcome ← liftHandlerIO <| do
    try
      let outcome ← PendingRequest.awaitOutcome promise
      doneRef.set true
      pure outcome
    catch e =>
      doneRef.set true
      throw e
  requestArg outcome

private def nextRequestId (session : Session) : Session × RequestID :=
  let id : RequestID := session.nextId
  ({ session with nextId := session.nextId + 1 }, id)

partial def sessionReaderLoop (session : Session) : IO Unit := do
  try
    let msg ← session.stdout.readLspMessage
    match msg with
    | .response id result =>
        let pending? ← PendingRequestStore.remove session.pending id
        traceBroker s!"lsp response id={id} matched={pending?.isSome}"
        if let some pending := pending? then
          PendingRequest.resolveResponse pending result
    | .responseError id code message data? =>
        let pending? ← PendingRequestStore.remove session.pending id
        traceBroker s!"lsp responseError id={id} matched={pending?.isSome} code={(toJson code).compress} message={message}"
        if let some pending := pending? then
          PendingRequest.resolveError pending code message data?
    | .notification "$/lean/fileProgress" (some param) =>
        let pending ← PendingRequestStore.snapshot session.pending
        traceBroker s!"lsp fileProgress pending={pending.size} params={(toJson param).compress}"
        for req in pending do
          PendingRequest.observeProgress req param
    | .notification "textDocument/publishDiagnostics" (some param) =>
        match (fromJson? (toJson param) : Except String PublishDiagnosticsParams) with
        | .ok diagnosticParam =>
            let pending ← PendingRequestStore.snapshot session.pending
            traceBroker s!"lsp publishDiagnostics pending={pending.size} params={(toJson param).compress}"
            for req in pending do
              PendingRequest.observePublishDiagnostics session.root req diagnosticParam
        | .error _ =>
            pure ()
    | _ =>
        pure ()
    sessionReaderLoop session
  catch e =>
    PendingRequestStore.failAllRespectingCancellation session.pending <| BrokerFailure.toResponseFailure {
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

private def startRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    IO (Session × IO.Promise (Except ResponseFailure PendingResult)) := do
  let (session, id) := nextRequestId session
  let progressRef ← IO.mkRef (initialProgress? <|> tracked.map (fun _ => {}))
  let diagnosticsRef ← IO.mkRef #[]
  let diagnosticsSeenRef ← IO.mkRef false
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  let promise ← IO.Promise.new
  PendingRequestStore.insert session.pending id {
      cancelRef? := cancelRef?
      promise := promise
      tracked? := tracked
      progressRef := progressRef
      diagnosticsRef := diagnosticsRef
      diagnosticsSeenRef := diagnosticsSeenRef
      emitProgress? := emitProgress?
      diagnosticScope := diagnosticScope
      seenDiagnosticKeysRef := seenDiagnosticKeysRef
      emitDiagnostic? := emitDiagnostic?
      : PendingRequest
    }
  traceBroker
    s!"lsp request inserted id={id} method={method} clientRequestId={optionLabel clientRequestId?} tracked={tracked.isSome}"
  try
    writeLspRequest session.stdin ({ id, method, param : Lean.JsonRpc.Request Json })
    traceBroker s!"lsp request sent id={id} method={method}"
    pure (session, promise)
  catch e =>
    discard <| PendingRequestStore.remove session.pending id
    traceBroker s!"lsp request send failed id={id} method={method} error={e.toString}"
    try
      promise.resolve (.error (responseFailureFor .internalError e.toString))
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
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Except ResponseFailure (Session × Json × Option SyncFileProgress × Array Diagnostic)) := do
  let (session, promise) ←
    startRequestJsonTrackedDetailed session method param clientRequestId? tracked initialProgress?
      emitProgress? diagnosticScope emitDiagnostic?
  match ← PendingRequest.awaitOutcome promise with
  | .ok pending => pure <| .ok (session, pending.result, pending.progress?, pending.diagnostics)
  | .error failure => pure <| .error failure

private partial def awaitInitializeResponse (stdout : IO.FS.Stream) : IO Unit := do
  let msg ← stdout.readLspMessage
  match msg with
  | .response id _ =>
      if id == 0 then
        pure ()
      else
        throw <| IO.userError s!"unexpected response id {id} before initialize completed"
  | .responseError id _code message _ =>
      if id == 0 then
        throw <| IO.userError s!"initialize failed: {message}"
      else
        throw <| IO.userError
          s!"unexpected response error id {id} before initialize completed: {message}"
  | .notification .. =>
      awaitInitializeResponse stdout
  | .request .. =>
      throw <| IO.userError "unexpected server request before initialize completed"

private def requireWorkspace (workspaceId : WorkspaceId) : M WorkspaceState := do
  let state ← get
  match getWorkspace? state workspaceId with
  | some workspace => pure workspace
  | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"

private def ensureSession (workspaceId : WorkspaceId) (backend : Backend) : M Session := do
  let state ← get
  let workspace ←
    match getWorkspace? state workspaceId with
    | some workspace => pure workspace
    | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
  let config := workspace.config
  let root := config.root
  let backendState := getBackendState workspace backend
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
      modify fun st =>
        match getWorkspace? st workspaceId with
        | some workspace => setWorkspace st workspaceId (setBackendState workspace backend backendState)
        | none => st
      pure session
  | none =>
      let (cmd, args, env) ← backendCommand config backend
      let proc ← IO.Process.spawn {
        toStdioConfig := brokerStdio
        cmd := cmd
        args := args
        env := env
        cwd := root.toString
      }
      let stdin := IO.FS.Stream.ofHandle proc.stdin
      let stdout := IO.FS.Stream.ofHandle proc.stdout
      let pending ← PendingRequestStore.create
      let sessionToken ← mkSessionToken
      let mut session : Session := {
        workspaceId
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
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        try
          sessionReaderLoop session
        catch e =>
          IO.eprintln s!"broker session reader task failed: {e.toString}"
      recordSessionSpawn workspaceId backend restart
      let backendState := { backendState with session? := some session }
      modify fun st =>
        match getWorkspace? st workspaceId with
        | some workspace => setWorkspace st workspaceId (setBackendState workspace backend backendState)
        | none => st
      pure session

private def sendNotificationJson (session : Session) (method : String) (param : Json) : IO Session := do
  writeLspNotification session.stdin ({ method, param : Lean.JsonRpc.Notification Json })
  pure session

private def sendTextDocumentDidSave (session : Session) (uri : DocumentUri) : IO Session := do
  if session.backend != .lean then
    pure session
  else
    sendNotificationJson session "textDocument/didSave" (toJson ({
      textDocument := ({ uri := uri : TextDocumentIdentifier })
      text? := none
      : DidSaveTextDocumentParams
    }))

/--
An immutable view of a source file used to synchronize the LSP session.

The file contents and metadata are computed before the broker state mutex is
held. This keeps potentially slow filesystem work out of the critical section.
For request handlers that can race with each other, `readSeq` is reserved while
holding the mutex and is later used by `DocumentState.syncFileDecision` to
ignore stale snapshots that completed after a newer read was already applied.
-/
private structure FileSyncSnapshot where
  path : System.FilePath
  uri : DocumentUri
  text : String
  file : DocumentState.FileSnapshot

private structure SyncedFileSnapshot where
  session : Session
  uri : DocumentUri
  version : Nat
  changed : Bool

private def readFileSyncSnapshot
    (root path : System.FilePath)
    (backend : Backend)
    (readSeq : Nat := 0) : IO FileSyncSnapshot := do
  let path ← resolvePath root path
  let text ← IO.FS.readFile path
  let textMTime ← Lake.getFileMTime path
  let uri := sessionUri path
  let moduleName? := DocumentState.trackedModuleName? root path backend
  pure {
    path
    uri
    text
    file := {
      textHash := hash text
      textTraceHash := Lake.Hash.ofText text
      textMTime
      readSeq
      moduleName?
    }
  }

private def syncFileSnapshotDetailed
    (session : Session)
    (snapshot : FileSyncSnapshot) : IO SyncedFileSnapshot := do
  let decision := DocumentState.syncFileDecision session.docs snapshot.uri snapshot.file
  let session ←
    match decision.action with
    | .open =>
      let param := toJson ({
        textDocument := {
          uri := snapshot.uri
          languageId := match session.backend with | .lean => "lean" | .rocq => "rocq"
          version := decision.version
          text := snapshot.text
        } : DidOpenTextDocumentParams
      })
      let session ← sendNotificationJson session "textDocument/didOpen" param
      pure session
    | .change =>
        let param := toJson ({
          textDocument := { uri := snapshot.uri, version? := some decision.version }
          contentChanges := #[TextDocumentContentChangeEvent.fullChange snapshot.text]
          : DidChangeTextDocumentParams
        })
        let session ← sendNotificationJson session "textDocument/didChange" param
        sendTextDocumentDidSave session snapshot.uri
    | .unchanged =>
        pure session
  pure {
    session := { session with docs := decision.docs }
    uri := snapshot.uri
    version := decision.version
    changed := decision.action != .unchanged
  }

private def syncFileSnapshot (session : Session) (snapshot : FileSyncSnapshot) : IO Session := do
  let synced ← syncFileSnapshotDetailed session snapshot
  pure synced.session

private def requireDocState (session : Session) (uri : String) : IO DocState := do
  DocumentState.requireDocState session.docs uri

private def closeFile (session : Session) (path : System.FilePath) : IO Session := do
  let path ← resolvePath session.root path
  let uri := sessionUri path
  if session.docs.get? uri |>.isNone then
    pure session
  else
    let param := toJson ({ textDocument := { uri := uri } : DidCloseTextDocumentParams })
    let session ← sendNotificationJson session "textDocument/didClose" param
    pure { session with docs := session.docs.erase uri }

private def recordFileProgress (session : Session) (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : Session :=
  { session with docs := DocumentState.recordFileProgress session.docs uri fileProgress? }

private def decodeResponseAs [FromJson α] (json : Json) : IO α := do
  match fromJson? json with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"invalid backend response payload: {err}\n{json.compress}"

private def trackedPathLabel (root : System.FilePath) (uri : DocumentUri) : String :=
  Beam.pathRelativeToRootOrUri root uri

private def applyVersionMarkResult
    (session : Session)
    (result : DocumentState.VersionMarkResult) : Session :=
  if result.applied then
    { session with
      nextEventSeq := session.nextEventSeq + 1
      docs := result.docs
      moduleHistory := result.moduleHistory
    }
  else
    session

private def markDocSyncedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSyncedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def markDocSavedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSavedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def openDocsSessionView (session : Session) : OpenDocs.SessionView := {
  root := session.root
  docs := session.docs
}

private def openDocsWorkspacePayload (workspace : WorkspaceState) : IO Json :=
  OpenDocs.payload workspace.config.root
    (workspace.lean.session?.map openDocsSessionView)
    (workspace.rocq.session?.map openDocsSessionView)

private def openDocsPayload (workspaceId? : Option WorkspaceId := none) : M Json := do
  let state ← get
  match workspaceId? with
  | some workspaceId =>
      match getWorkspace? state workspaceId with
      | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
      | some workspace =>
          pure <| (← openDocsWorkspacePayload workspace).setObjVal!
            "workspace_id" (toJson workspaceId)
  | none =>
      let workspaceFields ← state.workspaces.toList.mapM fun (workspaceId, workspace) => do
        pure (workspaceId, ← openDocsWorkspacePayload workspace)
      pure <| Json.mkObj [("workspaces", Json.mkObj workspaceFields)]

private def wrapHandle (session : Session) (raw : Json) : Json :=
  toJson ({
    workspaceId := session.workspaceId
    backend := session.backend
    epoch := session.epoch
    session := session.sessionToken
    raw
    : Handle
  })

private def unwrapHandle (session : Session) (handle : Handle) : Except String Json := do
  if handle.workspaceId != session.workspaceId then
    throw "handle belongs to a different workspace"
  if handle.backend != session.backend then
    throw "handle belongs to a different backend"
  if handle.epoch != session.epoch || handle.session != session.sessionToken then
    throw "handle belongs to a stale backend session"
  pure handle.raw

private def wrapResultHandle (session : Session) (result : Json) : Json :=
  match result.getObjVal? "handle" with
  | .ok raw =>
      result.setObjVal! "handle" (wrapHandle session raw)
  | .error _ =>
      result

private def updateSession (session : Session) : M Unit := do
  modify fun state =>
    match getWorkspace? state session.workspaceId with
    | none => state
    | some workspace =>
        let backendState := getBackendState workspace session.backend
        setWorkspace state session.workspaceId
          (setBackendState workspace session.backend { backendState with session? := some session })

private def currentSession? (workspaceId : WorkspaceId) (backend : Backend) : M (Option Session) := do
  let state ← get
  let some workspace := getWorkspace? state workspaceId
    | pure none
  match (getBackendState workspace backend).session? with
  | none =>
      pure none
  | some session =>
      if ← sessionExited session then
        shutdownSession session
        modify fun st =>
          match getWorkspace? st workspaceId with
          | none => st
          | some workspace =>
              let backendState := getBackendState workspace backend
              setWorkspace st workspaceId <| setBackendState workspace backend {
                backendState with
                session? := none
                nextEpoch := backendState.nextEpoch + 1
              }
        pure none
      else
        pure (some session)

private def currentSessionForHandle
    (workspaceId : WorkspaceId)
    (backend : Backend) : M (Except ResponseFailure Session) := do
  match ← currentSession? workspaceId backend with
  | some session => pure (.ok session)
  | none =>
      pure <| .error <| BrokerFailure.toResponseFailure {
        code := .contentModified
        message := "handle belongs to a stale backend session"
      }

private def sameSessionIdentity (left right : Session) : Bool :=
  left.workspaceId == right.workspaceId &&
    left.backend == right.backend &&
    left.root == right.root &&
    left.epoch == right.epoch &&
    left.sessionToken == right.sessionToken

private def modifyCurrentSessionIfMatching
    (session : Session)
    (f : Session → Session) : M Unit := do
  match ← currentSession? session.workspaceId session.backend with
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
  activeRequests : ActiveRequestRegistry
  private closeMutex : Std.Mutex Bool
  private closeDone : IO.Promise (Except IO.Error Unit)

/--
A cancellation capability bound to one active broker request admission.

The handle does not expose dispatch. It becomes inert after its broker-owned
dispatch scope exits, even if a later request reuses the same client request ID.
-/
structure RequestHandle where
  private runtime : ServerRuntime
  private active? : Option ActiveRequest

def ServerRuntime.withState (server : ServerRuntime) (act : M α) : IO α := do
  server.state.atomically do
    let state ← get
    let (a, state) ← act.run state
    set state
    pure a

private def ServerRuntime.statsResponse
    (server : ServerRuntime)
    (workspaceId? : Option WorkspaceId := none) : IO Response := do
  let payload ← server.withState <| statsPayload workspaceId?
  pure <| Response.success payload

def ServerRuntime.create
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (endpoint : Transport.Endpoint := .tcp 0) : IO ServerRuntime := do
  unless validWorkspaceId workspaceId do
    throw <| IO.userError "workspace id must be non-empty"
  let startMonoNanos ← IO.monoNanosNow
  let state := mkInitialState config workspaceId startMonoNanos
  pure {
    state := ← Std.Mutex.new state
    endpoint := endpoint
    stop := ← IO.mkRef false
    activeRequests := ← ActiveRequestRegistry.create
    closeMutex := ← Std.Mutex.new false
    closeDone := ← IO.Promise.new
  }

private def brokerConfigSame (left right : BrokerConfig) : Bool :=
  left.root == right.root &&
    left.leanCmd? == right.leanCmd? &&
    left.leanPlugin? == right.leanPlugin? &&
    left.rocqCmd? == right.rocqCmd?

private def shutdownWorkspaceSessions (workspace : WorkspaceState) : IO Unit := do
  for session? in [workspace.lean.session?, workspace.rocq.session?] do
    if let some session := session? then
      shutdownSession session

private def detachBackendSession
    (backend : BackendState) : BackendState × Option Session :=
  match backend.session? with
  | none => (backend, none)
  | some session =>
      ({ backend with session? := none, nextEpoch := backend.nextEpoch + 1 }, some session)

private def detachRuntimeSessions (server : ServerRuntime) : IO (Array Session) := do
  server.withState do
    let state ← get
    let mut sessions := #[]
    for (workspaceId, workspace) in state.workspaces.toList do
      let (lean, leanSession?) := detachBackendSession workspace.lean
      let (rocq, rocqSession?) := detachBackendSession workspace.rocq
      if let some session := leanSession? then
        sessions := sessions.push session
      if let some session := rocqSession? then
        sessions := sessions.push session
      modify fun state => setWorkspace state workspaceId { workspace with lean, rocq }
    pure sessions

private def shutdownRuntimeSessions (server : ServerRuntime) : IO Unit := do
  for session in ← detachRuntimeSessions server do
    shutdownSession session

private def awaitRuntimeClose
    (promise : IO.Promise (Except IO.Error Unit)) : IO Unit := do
  let some outcome ← IO.wait promise.result?
    | throw <| IO.userError "broker runtime close promise dropped"
  match outcome with
  | .ok () => pure ()
  | .error err => throw err

/--
Close broker admission, cancel admitted requests, shut down every backend session, and wait for
all admitted dispatch scopes to unregister. Concurrent and repeated callers wait for the same
close result; only the caller that started closure receives `true`.
-/
def ServerRuntime.close (server : ServerRuntime) : IO Bool := do
  let leadsClose ← server.closeMutex.atomically do
    if ← get then
      pure false
    else
      set true
      pure true
  if leadsClose then
    let outcome ←
      try
        discard <| ActiveRequestRegistry.closeAdmission server.activeRequests
        -- The first sweep unblocks requests already waiting on a backend. An admitted request may
        -- have been between admission and session creation when closure began, so repeat the sweep
        -- after every dispatch scope has drained to guarantee that no late session survives.
        shutdownRuntimeSessions server
        ActiveRequestRegistry.awaitDrained server.activeRequests
        shutdownRuntimeSessions server
        pure (.ok () : Except IO.Error Unit)
      catch err =>
        pure (.error err)
    server.closeDone.resolve outcome
    match outcome with
    | .ok () => pure true
    | .error err => throw err
  else
    awaitRuntimeClose server.closeDone
    pure false

def workspaceInitResult
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (mode : Beam.Workspace.InitMode)
    (runtimeReused : Bool)
    (invalidatedHandles : Bool)
    (previousRoot? : Option System.FilePath := none) : Beam.Workspace.InitResult := {
  workspaceId
  root
  mode
  runtimeReused
  invalidatedHandles
  previousRoot?
}

private def duplicateRootWorkspace?
    (state : State)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig) : Option WorkspaceId :=
  state.workspaces.toList.findSome? fun (otherId, otherWorkspace) =>
    if otherId != workspaceId && otherWorkspace.config.root == config.root then
      some otherId
    else
      none

def ServerRuntime.initWorkspaceWithConfig
    (server : ServerRuntime)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig)
    (mode? : Option Beam.Workspace.InitMode := none) : IO Response := do
  if !validWorkspaceId workspaceId then
    return errorResponseFor .invalidParams "workspace id must be non-empty"
  let mode := mode?.getD .set
  server.withState do
    let state ← get
    match getWorkspace? state workspaceId with
    | some current =>
        if mode == .reset then
          if let some otherId := duplicateRootWorkspace? state workspaceId config then
            pure <| errorResponseFor .invalidParams <|
              s!"workspace root {config.root} is already owned by workspace '{otherId}'"
          else
            shutdownWorkspaceSessions current
            let replacement := mkWorkspaceState config
            modify fun state => setWorkspace state workspaceId replacement
            pure <| Response.success <| toJson <|
              workspaceInitResult workspaceId config.root mode false true (some current.config.root)
        else if brokerConfigSame current.config config then
          pure <| Response.success <| toJson <|
            workspaceInitResult workspaceId current.config.root mode true false
        else
          pure <| errorResponseFor .invalidParams <|
            s!"workspace '{workspaceId}' is already initialized for {current.config.root}; " ++
            s!"use workspaceMode=reset to switch it explicitly to {config.root}"
    | none =>
        if mode == .verify then
          pure <| errorResponseFor .invalidParams
            s!"workspace '{workspaceId}' is not initialized; use workspaceMode=set first"
        else if let some otherId := duplicateRootWorkspace? state workspaceId config then
          pure <| errorResponseFor .invalidParams <|
            s!"workspace root {config.root} is already owned by workspace '{otherId}'"
        else
          modify fun state => setWorkspace state workspaceId (mkWorkspaceState config)
          pure <| Response.success <| toJson <|
            workspaceInitResult workspaceId config.root mode false false

private def workspaceListPayload (state : State) : Json :=
  toJson ({
    workspaces := state.workspaces.toList.toArray.map fun (workspaceId, workspace) => ({
      workspaceId
      root := workspace.config.root
      leanActive := workspace.lean.session?.isSome
      rocqActive := workspace.rocq.session?.isSome
    } : Beam.Workspace.ListEntry)
  } : Beam.Workspace.ListResult)

def ServerRuntime.dropWorkspace
    (server : ServerRuntime)
    (workspaceId : WorkspaceId) : IO Response := do
  if !validWorkspaceId workspaceId then
    return errorResponseFor .invalidParams "workspace id must be non-empty"
  server.withState do
    let state ← get
    match getWorkspace? state workspaceId with
    | none =>
        pure <| Response.success <| toJson ({
          workspaceId
          dropped := false
          reason? := some "notFound"
        } : Beam.Workspace.DropResult)
    | some workspace =>
      shutdownWorkspaceSessions workspace
      modify fun state => { state with workspaces := state.workspaces.erase workspaceId }
      pure <| Response.success <| toJson ({
        workspaceId
        dropped := true
        invalidatedHandles := true
      } : Beam.Workspace.DropResult)

private def requestRecordsMetrics : Op → Bool
  | .cancel | .stats | .resetStats | .shutdown | .openDocs | .listWorkspaces => false
  | _ => true

private def recordDispatchMetrics
    (server : ServerRuntime)
    (req : Request)
    (resp : Response)
    (startedAt : Nat) : IO Unit := do
  if requestRecordsMetrics req.op then
    let finishedAt ← IO.monoNanosNow
    let latencyMs := (finishedAt - startedAt) / 1000000
    if let some workspaceId := req.resolvedWorkspaceId? then
      server.withState do
        recordRequestMetrics workspaceId req.backend req.op.key resp.ok (resp.error?.map (·.code)) latencyMs

private def cancelRegisteredRequest
    (server : ServerRuntime)
    (markCancelled : IO (Option ActiveRequest)) : IO Bool := do
  match ← markCancelled with
  | some active =>
    let sessions ← server.withState do
      let state ← get
      pure <| state.workspaces.toList.flatMap fun (_, workspace) =>
        [workspace.lean.session?, workspace.rocq.session?]
    for session? in sessions do
      if let some session := session? then
        discard <| PendingRequestStore.cancelMatching session.pending session.stdin active.cancelRef
    pure true
  | none => pure false

private def cancelActiveRequest
    (server : ServerRuntime)
    (clientRequestId : String) : IO Bool :=
  cancelRegisteredRequest server <|
    ActiveRequestRegistry.markCancelled server.activeRequests clientRequestId

/--
Cancel the exact active admission represented by `handle`.

Returns `false` when the request does not track cancellation or the handle is no
longer active.
-/
def RequestHandle.cancel (handle : RequestHandle) : IO Bool := do
  match handle.active? with
  | none => pure false
  | some active =>
      cancelRegisteredRequest handle.runtime <|
        ActiveRequestRegistry.markCancelledActive handle.runtime.activeRequests active

private def propagatePendingCancellation
    (session : Session)
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  PendingRequestStore.propagateCancellation session.pending session.stdin cancelRef?

private def requestStop (server : ServerRuntime) : IO Unit := do
  server.stop.set true
  try
    -- Wake the blocking accept. Both ends are intentionally left to scope cleanup: performing a
    -- graceful TCP shutdown on the wake-up pair can wait for its peer and deadlock daemon exit.
    discard <| Transport.connect server.endpoint
  catch _ =>
    pure ()

private structure WorkspaceRequest extends Request where
  workspaceId : WorkspaceId

private instance : Coe WorkspaceRequest Request := ⟨WorkspaceRequest.toRequest⟩

private def validateRequestWorkspace
    (server : ServerRuntime)
    (req : Request) : IO (Except ResponseFailure WorkspaceRequest) := do
  let workspaceId ←
    match req.requireWorkspaceId with
    | .ok workspaceId => pure workspaceId
    | .error err => return .error (responseFailureFor .invalidParams err)
  if let some explicitWorkspaceId := req.workspaceId? then
    if let some handle := req.handle? then
      if explicitWorkspaceId != handle.workspaceId then
        return .error <| responseFailureFor .invalidParams
          s!"request workspace '{explicitWorkspaceId}' does not match handle workspace '{handle.workspaceId}'"
  let workspace? ← server.withState do
    pure <| (← get).workspaces.get? workspaceId
  let some workspace := workspace?
    | return .error (responseFailureFor .invalidParams s!"unknown Beam workspace '{workspaceId}'")
  match req.root? with
  | none => pure (.ok { toRequest := req, workspaceId })
  | some rootText =>
      let requestedRoot ←
        try
          resolveRoot (System.FilePath.mk rootText)
        catch e =>
          return .error (responseFailureFor .invalidParams e.toString)
      if requestedRoot != workspace.config.root then
        return .error <| responseFailureFor .invalidParams
          s!"Beam workspace '{workspaceId}' serves {workspace.config.root}, not {requestedRoot}"
      pure (.ok { toRequest := req, workspaceId })

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
    (k : Session → M α) : HandlerM α := do
  liftFailureIO <| server.withState do
    match ← currentSession? session.workspaceId session.backend with
    | some current =>
      if sameSessionIdentity current session then
          .ok <$> k current
      else
          pure <| .error <| BrokerFailure.toResponseFailure {
            code := .workerExited
            message := "broker backend session changed while request was in flight"
          }
    | none =>
        pure <| .error <| BrokerFailure.toResponseFailure {
          code := .workerExited
          message := "broker backend session exited while request was in flight"
        }

private def recordCompletedSync
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat) : HandlerM Unit := do
  withCurrentMatchingSession server session fun current => do
    let current := markDocSyncedVersion current uri version
    updateSession current

private structure StartedSyncedRequest where
  session : Session
  uri : DocumentUri
  version : Nat
  priorProgress? : Option SyncFileProgress := none
  tracked : Option (DocumentUri × Nat) := none
  promise : IO.Promise (Except ResponseFailure PendingResult)

private def trackedDocumentVersion (uri : DocumentUri) (docState : DocState) :
    Option (DocumentUri × Nat) :=
  some (uri, docState.version)

private def trackedLeanDocumentVersion
    (backend : Backend)
    (uri : DocumentUri)
    (docState : DocState) : Option (DocumentUri × Nat) :=
  if backend == .lean then
    trackedDocumentVersion uri docState
  else
    none

private def documentVersionMismatchFailure
    (expectedVersion acceptedVersion : Nat)
    (uri : DocumentUri) : ResponseFailure :=
  responseFailureFor
    .contentModified
    (s!"document version mismatch for {uri}: expected document version {expectedVersion}, got {acceptedVersion}")
    (some <| documentVersionMismatchErrorData expectedVersion acceptedVersion
      (currentVersion? := some acceptedVersion)
      (uri? := some uri))

private def startSyncedDocumentRequest
    (session : Session)
    (snapshot : FileSyncSnapshot)
    (method : String)
    (mkParams : DocumentUri → DocState → Json)
    (trackedFor : DocumentUri → DocState → Option (DocumentUri × Nat))
    (expectedVersion? : Option Nat := none)
    (clientRequestId? : Option String := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    M (Except ResponseFailure StartedSyncedRequest) := do
  let session ← syncFileSnapshot session snapshot
  let uri := snapshot.uri
  let docState ← requireDocState session uri
  match expectedVersion? with
  | some expectedVersion =>
      if docState.version != expectedVersion then
        updateSession session
        return .error <| documentVersionMismatchFailure expectedVersion docState.version uri
  | none =>
      pure ()
  let tracked := trackedFor uri docState
  let params := mkParams uri docState
  let (session, promise) ←
    startRequestJsonTrackedDetailed session method params
      (clientRequestId? := clientRequestId?)
      (tracked := tracked)
      (initialProgress? := docState.fileProgress?)
      (emitProgress? := emitProgress?)
      (diagnosticScope := diagnosticScope)
      (emitDiagnostic? := emitDiagnostic?)
      (cancelRef? := cancelRef?)
  updateSession session
  pure <| .ok {
    session
    uri
    version := docState.version
    priorProgress? := docState.fileProgress?
    tracked
    promise
  }

private def awaitSyncedDocumentRequest
    (server : ServerRuntime)
    (started : StartedSyncedRequest)
    (cancelRef? : Option (IO.Ref Bool) := none) : HandlerM PendingResult := do
  liftHandlerIO <| propagatePendingCancellation started.session cancelRef?
  let pending ← awaitPending started.promise
  if started.tracked.isSome then
    withFailureProgress pending.progress? <|
      liftHandlerIO <| mergeFileProgressIfCurrent server started.session started.uri pending.progress?
  pure pending

private def readRequestSyncSnapshot
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath) : IO FileSyncSnapshot := do
  let (root, readSeq) ← server.withState do
    let workspace ← requireWorkspace req.workspaceId
    let readSeq := workspace.nextFileSnapshotSeq
    let workspace := { workspace with nextFileSnapshotSeq := readSeq + 1 }
    modify fun state => setWorkspace state req.workspaceId workspace
    pure (workspace.config.root, readSeq)
  -- Reserve the ordering token under the mutex, then do the slow file IO
  -- outside it.
  readFileSyncSnapshot root path req.backend (readSeq := readSeq)

private structure StartedTrackedBarrier where
  session : Session
  uri : DocumentUri
  version : Nat
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  changed : Bool := false
  priorProgress? : Option SyncFileProgress := none
  promise : IO.Promise (Except ResponseFailure PendingResult)

private def startTrackedDiagnosticsBarrierIO
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    IO StartedTrackedBarrier := do
  let snapshot ← readRequestSyncSnapshot server req path
  server.withState do
    let session ← ensureSession req.workspaceId req.backend
    let synced ← syncFileSnapshotDetailed session snapshot
    let session := synced.session
    let uri := synced.uri
    let docState ← requireDocState session uri
    let tracked := trackedDocumentVersion uri docState
    let params := toJson (WaitForDiagnosticsParams.mk uri docState.version)
    let method ← IO.ofExcept <| diagnosticsBarrierMethod session.backend
    let (session, promise) ←
      startRequestJsonTrackedDetailed session method params
        (clientRequestId? := req.clientRequestId?)
        (tracked := tracked)
        (initialProgress? := docState.fileProgress?)
        (emitProgress? := emitProgress?)
        (diagnosticScope := req.diagnosticScope?.getD .errors)
        (emitDiagnostic? := emitDiagnostic?)
        (cancelRef? := cancelRef?)
    updateSession session
    pure {
      session
      uri
      version := synced.version
      textHash := docState.textHash
      textTraceHash := docState.textTraceHash
      textMTime := docState.textMTime
      changed := synced.changed
      priorProgress? := docState.fileProgress?
      promise
    }

private def finalizeSavedDoc
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (closeAfter : Bool) : HandlerM Unit := do
  withCurrentMatchingSession server session fun current => do
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
  result : SaveOleanResult
  fileProgress? : Option SyncFileProgress := none

private def saveCompletedResponse
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) : Response :=
  let result :=
    if closeAfter then
      toJson ({ saved := saved.result } : CloseSaveResult)
    else
      toJson saved.result
  Response.withOptionalFileProgress (Response.success result) saved.fileProgress?

private def syncSaveReadinessOfBarrierResult
    (uri : DocumentUri)
    (expectedVersion : Nat)
    (expectedTextHash : UInt64)
    (barrierResult : DiagnosticsBarrierResult) : HandlerM SyncSaveReadiness := do
  let readiness := barrierResult.saveReadiness
  if readiness.version != expectedVersion then
    throwBrokerFailure {
      code := .contentModified
      message :=
        s!"diagnostics barrier save readiness reported version " ++
          s!"{readiness.version}, expected document version {expectedVersion}"
      data? := some <| documentVersionMismatchErrorData expectedVersion readiness.version
        (currentVersion? := some readiness.version)
        (uri? := some uri)
    }
  if readiness.textHash != expectedTextHash then
    throwBrokerFailure {
      code := .contentModified
      message :=
        s!"diagnostics barrier save readiness reported text hash " ++
          s!"{readiness.textHash}, expected synced hash {expectedTextHash}"
      data? := some <| Json.mkObj [
        ("expectedHash", toJson expectedTextHash),
        ("actualHash", toJson readiness.textHash),
        ("uri", toJson uri)
      ]
    }
  pure <| syncSaveReadinessOfResult readiness

private def collectStaleDirectDepHintsForSession
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (imports : Array String) : HandlerM (Array StaleDirectDepHint) := do
  if session.backend != .lean then
    pure #[]
  else
    withCurrentMatchingSession server session fun current => do
      match current.docs.get? uri with
      | some docState =>
          if docState.version == version then
            pure <| collectStaleDirectDepHints imports
              docState.lastSyncEventSeq current.moduleHistory
          else
            pure #[]
      | none =>
          pure #[]

private structure SyncBarrierOutcome where
  completionDiagnostics : Array Diagnostic := #[]
  hints : Array StaleDirectDepHint := #[]
  fileProgress? : Option SyncFileProgress := none
  incomplete : Bool := false

private def staleDirectDepsBlock
    (changed : Bool)
    (hints : Array StaleDirectDepHint) : Bool :=
  !hints.isEmpty && (!changed || hints.any (·.needsSave))

private def syncBarrierOutcome
    (server : ServerRuntime)
    (started : StartedTrackedBarrier)
    (progress? : Option SyncFileProgress)
    (diagnosticsSeen : Bool)
    (observedDiagnostics : Array Diagnostic)
    (directImports : Array String)
    (currentDiagnostics : Array Diagnostic) : HandlerM SyncBarrierOutcome := do
  let completionDiagnostics :=
    if diagnosticsSeen then observedDiagnostics else currentDiagnostics
  let decision :=
    decideSyncBarrier started.uri started.version started.priorProgress? progress? completionDiagnostics
  let hints ← collectStaleDirectDepHintsForSession server started.session started.uri started.version
    directImports
  let staleDepsBlock := staleDirectDepsBlock started.changed hints
  let fileProgress? :=
    if staleDepsBlock then
      some <| incompleteBarrierProgress decision.fileProgress?
    else
      decision.fileProgress?
  pure {
    completionDiagnostics
    hints
    fileProgress?
    incomplete := decision.incomplete || staleDepsBlock
  }

private initialize savePublicationMutex : Std.Mutex Unit ← Std.Mutex.new ()

private def saveOleanCore
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM SaveOleanCompleted := do
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let started ← liftHandlerIO <| startTrackedDiagnosticsBarrierIO server req path emitProgress?
    emitDiagnostic? (cancelRef? := cancelRef?)
  let leanCmd? ← liftHandlerIO <| server.withState do
    let workspace ← requireWorkspace req.workspaceId
    pure workspace.config.leanCmd?
  liftHandlerIO <| propagatePendingCancellation started.session cancelRef?
  let barrier ← awaitWaitForDiagnosticsBarrier
    s!"save_olean sync barrier clientRequestId={optionLabel req.clientRequestId?} uri={started.uri} version={started.version}"
    started.promise
  let barrierResult : DiagnosticsBarrierResult ←
    withFailureProgress barrier.progress? <| liftHandlerIO <| decodeResponseAs barrier.result
  if barrierResult.version != started.version then
    throw <| (documentVersionMismatchFailure started.version barrierResult.version started.uri)
      |>.withOptionalFileProgress barrier.progress?
  withFailureProgress barrier.progress? <| liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let saveReadiness ←
    withFailureProgress barrier.progress? <|
      syncSaveReadinessOfBarrierResult started.uri started.version started.textHash barrierResult
  let currentDiagnostics := saveReadiness.currentDiagnostics
  let barrierOutcome ← withFailureProgress barrier.progress? <|
    syncBarrierOutcome server started barrier.progress? barrier.diagnosticsSeen
      barrier.diagnostics barrierResult.directImports currentDiagnostics
  let barrierProgress? := barrierOutcome.fileProgress?
  withFailureProgress barrierProgress? <|
    liftHandlerIO <| mergeFileProgressIfCurrent server started.session started.uri barrierProgress?
  if barrierOutcome.incomplete then
    let targetPath := trackedPathLabel started.session.root started.uri
    throw <| syncBarrierIncompleteFailure
      started.uri started.version targetPath barrierOutcome.hints
      barrierOutcome.completionDiagnostics barrierProgress?
  let spec ← withFailureProgress barrierProgress? <| liftBrokerFailureIO <|
    mkLeanSaveSpec started.session.root path
      { hash := started.textTraceHash, mtime := started.textMTime } leanCmd?
  let syncResult :=
    mkSyncFileResult spec.relPath started.version currentDiagnostics saveReadiness
  withFailureProgress barrierProgress? <|
    recordCompletedSync server started.session started.uri started.version
  if let some reason := spec.unsupportedSetupReason? then
    withFailureProgress barrierProgress? <| throwBrokerFailure {
      code := .saveUnsupportedSetup
      message :=
        s!"lean-beam save cannot reuse the Lean server snapshot for {spec.relPath}: {reason}. " ++
        "Move shared -D settings from moreLeanArgs to leanOptions so Lake applies them to both " ++
        "the language server and batch compilation. If the arguments are intentionally batch-only, " ++
        "run lake build for this module instead."
      data? :=
        some <| (syncResultErrorData syncResult)
          |>.setObjVal! "reason" (toJson reason)
          |>.setObjVal! "path" (toJson spec.relPath)
    }
  let method ← withFailureProgress barrierProgress? <|
    requestMethod <| saveArtifactsMethod started.session.backend
  let params := toJson ({
    textDocument := ({ uri := started.uri : TextDocumentIdentifier })
    expectedVersion := started.version
    expectedTextHash := started.textHash
    oleanFile := spec.oleanPath.toString
    moduleArtifacts? :=
      match spec.oleanServerPath?, spec.oleanPrivatePath?, spec.irPath? with
      | some oleanServerFile, some oleanPrivateFile, some irFile =>
          some {
            oleanServerFile := oleanServerFile.toString
            oleanPrivateFile := oleanPrivateFile.toString
            irFile := irFile.toString
          }
      | _, _, _ => none
    ileanFile := spec.ileanPath.toString
    cFile := spec.cPath.toString
    bcFile? := spec.bcPath?.map (fun bcPath => System.FilePath.toString bcPath)
    : Beam.LSP.Save.SaveArtifactsParams
  })
  -- A cancellation after readiness/spec computation must not invalidate a valid trace.
  withFailureProgress barrierProgress? <| liftFailureIO <| ensureRequestNotCancelled cancelRef?
  -- Once artifact publication can begin, an older trace must not remain visible: it may have the
  -- same dependency hash while describing a different in-server artifact family.
  withFailureProgress barrierProgress? <| liftHandlerIO <| invalidateLeanSaveTrace spec
  let (session, savePromise) ← withFailureProgress barrierProgress? <|
    withCurrentMatchingSession server started.session fun current => do
      let (current, savePromise) ← startRequestJsonTrackedDetailed current method params
        (clientRequestId? := req.clientRequestId?)
        (cancelRef? := cancelRef?)
      updateSession current
      pure (current, savePromise)
  withFailureProgress barrierProgress? <|
    liftHandlerIO <| propagatePendingCancellation session cancelRef?
  let savePending ←
    match ← withFailureProgress barrierProgress? <|
        liftHandlerIO <| PendingRequest.awaitOutcome savePromise with
    | .ok pending => pure pending
    | .error failure =>
        throw <| ({
          failure with
          error := {
            failure.error with
            data? :=
              if failure.error.code == "invalidParams" then
                some (syncResultErrorData syncResult)
              else
                failure.error.data?
          }
        }).withOptionalFileProgress barrierProgress?
  let saveResult : Beam.LSP.Save.SaveArtifactsResult ←
    withFailureProgress barrierProgress? <| liftHandlerIO <| decodeResponseAs savePending.result
  if saveResult.version != started.version then
    throw <| (responseFailureFor .internalError
      s!"save_olean saved version {saveResult.version}, expected document version {started.version}")
      |>.withOptionalFileProgress barrierProgress?
  if saveResult.textHash != started.textHash then
    throw <| (responseFailureFor .internalError
      s!"save_olean saved text hash {saveResult.textHash}, expected synced hash {started.textHash}")
      |>.withOptionalFileProgress barrierProgress?
  withFailureProgress barrierProgress? <| liftHandlerIO <| writeLeanSaveTrace spec
  pure {
    session
    uri := started.uri
    version := started.version
    spec
    result := leanSaveResult spec started.textTraceHash syncResult
    fileProgress? := barrierProgress?
  }

private def saveOlean
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM SaveOleanCompleted :=
  savePublicationMutex.atomically do
    -- A cancelled save waiting behind another transaction must not start new sync or trace work.
    liftFailureIO <| ensureRequestNotCancelled cancelRef?
    saveOleanCore server req path cancelRef? emitProgress? emitDiagnostic?

private def handleSyncFileOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  if req.backend != .lean then
    throw <| responseFailureFor .invalidParams
      "sync_file diagnostics barrier is only supported for Lean"
  let path ← requestArg req.pathArg
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let started ← liftHandlerIO <| startTrackedDiagnosticsBarrierIO server req path emitProgress?
    emitDiagnostic? (cancelRef? := cancelRef?)
  liftHandlerIO <| traceBroker
    s!"sync_file await barrier clientRequestId={optionLabel req.clientRequestId?} uri={started.uri} version={started.version}"
  liftHandlerIO <| propagatePendingCancellation started.session cancelRef?
  let pending ← awaitWaitForDiagnosticsBarrier
    s!"sync_file clientRequestId={optionLabel req.clientRequestId?} uri={started.uri} version={started.version}"
    started.promise
  liftHandlerIO <| traceBroker
    s!"sync_file barrier completed clientRequestId={optionLabel req.clientRequestId?} progress={pending.progress?.isSome} diagnostics={pending.diagnostics.size} diagnosticsSeen={pending.diagnosticsSeen}"
  let barrierResult : DiagnosticsBarrierResult ←
    withFailureProgress pending.progress? <| liftHandlerIO <| decodeResponseAs pending.result
  if barrierResult.version != started.version then
    throw <| (documentVersionMismatchFailure started.version barrierResult.version started.uri)
      |>.withOptionalFileProgress pending.progress?
  let saveReadiness ←
    withFailureProgress pending.progress? <|
      syncSaveReadinessOfBarrierResult started.uri started.version started.textHash barrierResult
  let currentDiagnostics := saveReadiness.currentDiagnostics
  let barrierOutcome ← withFailureProgress pending.progress? <|
    syncBarrierOutcome server started pending.progress? pending.diagnosticsSeen
      pending.diagnostics barrierResult.directImports currentDiagnostics
  let fileProgress? := barrierOutcome.fileProgress?
  withFailureProgress fileProgress? <|
    liftHandlerIO <| mergeFileProgressIfCurrent server started.session started.uri fileProgress?
  if barrierOutcome.incomplete then
    let targetPath := trackedPathLabel started.session.root started.uri
    throw <| syncBarrierIncompleteFailure
      started.uri started.version targetPath barrierOutcome.hints
      barrierOutcome.completionDiagnostics fileProgress?
  let replyDiagnostics? :=
    if req.diagnosticsInResult?.getD false then
      some <| streamDiagnosticsForReply started.session.root started.uri started.version
        (req.diagnosticScope?.getD .errors) currentDiagnostics
    else
      none
  let resultPath := trackedPathLabel started.session.root started.uri
  let syncResult :=
    mkSyncFileResult resultPath started.version currentDiagnostics saveReadiness replyDiagnostics?
  withFailureProgress fileProgress? <|
    recordCompletedSync server started.session started.uri started.version
  liftHandlerIO <| traceBroker
    s!"sync_file response ready clientRequestId={optionLabel req.clientRequestId?} version={started.version} saveReady={saveReadiness.saveReady}"
  pure (syncFileSuccessResponse
    syncResult fileProgress?,
    false)

private def closeTrackedFileIfOpen
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath) : HandlerM Unit :=
  liftHandlerIO <| server.withState do
    match ← currentSession? req.workspaceId req.backend with
    | some session =>
        let session ← closeFile session path
        updateSession session
    | none =>
        pure ()

private def handleRefreshFileOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let path ← requestArg req.pathArg
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  closeTrackedFileIfOpen server req path
  handleSyncFileOp server req cancelRef? emitProgress? emitDiagnostic?

private def handleUpdateFileOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    HandlerM (Response × Bool) := do
  let path ← requestArg req.pathArg
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req path
  let updated ← liftHandlerIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    let synced ← syncFileSnapshotDetailed session snapshot
    updateSession synced.session
    pure synced
  pure (Response.success (toJson ({
    version := updated.version
    changed := updated.changed
    : UpdateFileResult
  })), false)

private def handleCloseOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let path ← requestArg req.pathArg
  if req.saveArtifacts?.getD false then
    let saved ← saveOlean server req path cancelRef? emitProgress? emitDiagnostic?
    finalizeSavedDoc server saved.session saved.uri saved.version true
    pure (saveCompletedResponse saved true, false)
  else
    liftHandlerIO <| server.withState do
      match ← currentSession? req.workspaceId req.backend with
      | some session =>
          let session ← closeFile session path
          updateSession session
          pure (Response.success (Json.mkObj [("closed", toJson true)]), false)
      | none =>
          pure (Response.success (Json.mkObj [("closed", toJson true)]), false)

private def runAtSetupProgressEmitter?
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit)) :
    Option (StreamDiagnostic → IO Unit) :=
  emitDiagnostic?.map fun emitDiagnostic => fun diagnostic => do
    if isLakeSetupFileProgressStreamDiagnostic diagnostic then
      emitDiagnostic diagnostic

private def handleRunAtOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.runAtArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    startSyncedDocumentRequest session snapshot args.method
      (fun uri _ => Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri, version? := some args.version : VersionedTextDocumentIdentifier }))
        , ("position", toJson ({ line := args.line, character := args.character : Lsp.Position }))
        , ("text", toJson args.text)
        ] ++
        match req.storeHandle? with
        | some b => [("storeHandle", toJson b)]
        | none => [])
      trackedDocumentVersion
      (expectedVersion? := some args.version)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (emitDiagnostic? := runAtSetupProgressEmitter? emitDiagnostic?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (
    Response.withOptionalFileProgress
      (Response.success (wrapResultHandle started.session pending.result))
      pending.progress?,
    false)

private def positionLspParams
    (args : PositionArgs)
    (uri : DocumentUri)
    (extraFields : List (String × Json) := []) : Json :=
  Json.mkObj <|
    [
      ("textDocument", toJson ({ uri := uri, version? := some args.version : VersionedTextDocumentIdentifier })),
      ("position", toJson ({ line := args.line, character := args.character : Lsp.Position }))
    ] ++ extraFields

private def handlePositionLspOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (args : PositionArgs)
    (method : String)
    (extraFields : List (String × Json) := [])
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    startSyncedDocumentRequest session snapshot method
      (fun uri _ => positionLspParams args uri extraFields)
      (trackedLeanDocumentVersion req.backend)
      (expectedVersion? := some args.version)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (Response.withOptionalFileProgress (Response.success pending.result) pending.progress?, false)

private def handleHoverOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.hoverArgs
  handlePositionLspOp server req args.toPositionArgs args.method
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleSignatureHelpOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.signatureHelpArgs
  handlePositionLspOp server req args.toPositionArgs args.method
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleDefinitionOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.definitionArgs
  handlePositionLspOp server req args.toPositionArgs args.method
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleReferencesOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.referencesArgs
  handlePositionLspOp server req args.toPositionArgs args.method
    [("context", Json.mkObj [("includeDeclaration", toJson args.includeDeclaration)])]
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleDocumentSymbolsOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.documentSymbolsArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    startSyncedDocumentRequest session snapshot args.method
      (fun uri _ => Json.mkObj [
        ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
      ])
      (trackedLeanDocumentVersion req.backend)
      (expectedVersion? := some args.version)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (Response.withOptionalFileProgress (Response.success pending.result) pending.progress?, false)

private def handleWorkspaceSymbolsOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.workspaceSymbolsArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let (session, promise) ← liftHandlerIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    let params := toJson ({ query := args.query : WorkspaceSymbolParams })
    let (session, promise) ← startRequestJsonTrackedDetailed session args.method params
      (clientRequestId? := req.clientRequestId?)
      (cancelRef? := cancelRef?)
    updateSession session
    pure (session, promise)
  liftHandlerIO <| propagatePendingCancellation session cancelRef?
  let pending ← awaitPending promise
  pure (Response.success pending.result, false)

private def codeActionResolveSourceUri
    (action : CodeAction) : Except ResponseFailure DocumentUri := do
  let some data := action.data?
    | throw <| responseFailureFor .invalidParams
        "code_action_resolve requires codeAction.data"
  let resolveData ←
    match (fromJson? data : Except String Lean.Server.CodeActionResolveData) with
    | .ok resolveData => pure resolveData
    | .error err =>
        throw <| responseFailureFor .invalidParams s!"invalid codeAction.data: {err}"
  pure resolveData.params.textDocument.uri

private def handleCodeActionResolveOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.codeActionResolveArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let sourceUri ← requestArg <| codeActionResolveSourceUri args.codeAction
  if sourceUri != snapshot.uri then
    throw <| responseFailureFor .invalidParams
      s!"codeAction.data targets {sourceUri}, not requested document {snapshot.uri}"
  let started ← liftFailureIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    startSyncedDocumentRequest session snapshot args.method
      (fun _uri _docState => toJson args.codeAction)
      (trackedLeanDocumentVersion req.backend)
      (expectedVersion? := some args.version)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  let resolved : CodeAction ← liftHandlerIO <| decodeResponseAs pending.result
  let payload : CodeActionResolveResult := {
    version := started.version
    codeAction := resolved
  }
  pure (Response.withOptionalFileProgress (Response.success (toJson payload)) pending.progress?, false)

private def handleSaveOleanOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let path ← requestArg req.pathArg
  let saved ← saveOlean server req path cancelRef? emitProgress? emitDiagnostic?
  finalizeSavedDoc server saved.session saved.uri saved.version false
  pure (saveCompletedResponse saved false, false)

private def handleGoalsOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.goalsArgs
  if req.backend == .lean && req.text?.isSome then
    throw <| responseFailureFor .invalidParams
      "lean goals does not accept speculative text; use lean-beam run-at for execution"
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    let position : Lsp.Position := { line := args.line, character := args.character }
    startSyncedDocumentRequest session snapshot args.method
      (fun uri docState =>
        match req.backend with
        | .lean =>
            Json.mkObj [
              ("textDocument", toJson ({ uri := uri, version? := some args.version : VersionedTextDocumentIdentifier })),
              ("position", toJson position)
            ]
        | .rocq =>
            let fields :=
              [
                ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier })),
                ("position", toJson position),
                ("mode", toJson (Backend.Rocq.goalModeValue req.mode?)),
                ("compact", toJson (req.compact?.getD false)),
                ("pp_format", toJson (goalPpFormatValue req.ppFormat?))
              ] ++
              match req.text? with
              | some text => [("command", toJson text)]
              | none => []
            Json.mkObj fields)
      (trackedLeanDocumentVersion req.backend)
      (expectedVersion? := some args.version)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (Response.withOptionalFileProgress (Response.success pending.result) pending.progress?, false)

private def handleTodoOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.todoArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let range : Lsp.Range := {
    start := { line := args.line, character := args.character }
    «end» := { line := args.endLine, character := args.endCharacter }
  }
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    let session ← ensureSession req.workspaceId req.backend
    startSyncedDocumentRequest session snapshot args.method
      (fun uri _docState => Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri, version? := some args.version : VersionedTextDocumentIdentifier }))
        , ("range", toJson range)
        ] ++
        (match req.kinds? with
        | some kinds => [("kinds", toJson kinds)]
        | none => []) ++
        (match req.suggest? with
        | some suggest => [("suggest", toJson suggest)]
        | none => []))
      (trackedLeanDocumentVersion req.backend)
      (expectedVersion? := some args.version)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (Response.withOptionalFileProgress (Response.success pending.result) pending.progress?, false)

private def handleRunWithOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.runWithArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    match ← currentSessionForHandle req.workspaceId req.backend with
    | .error resp => pure (.error resp)
    | .ok session =>
        let rawHandle ←
          match unwrapHandle session args.handle with
          | .ok raw => pure raw
          | .error err =>
              return .error <| BrokerFailure.toResponseFailure {
                code := .contentModified
                message := err
              }
        let startedResult ← startSyncedDocumentRequest session snapshot args.method
          (fun uri _ => Json.mkObj <|
            [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
            , ("handle", rawHandle)
            , ("text", toJson args.text)
            ] ++ (match req.storeHandle? with
            | some b => [("storeHandle", toJson b)]
            | none => []) ++
            (match req.linear? with
            | some b => [("linear", toJson b)]
            | none => []))
          trackedDocumentVersion
          (clientRequestId? := req.clientRequestId?)
          (emitProgress? := emitProgress?)
          (cancelRef? := cancelRef?)
        pure startedResult
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (
    Response.withOptionalFileProgress
      (Response.success (wrapResultHandle started.session pending.result))
      pending.progress?,
    false)

private def handleReleaseOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM (Response × Bool) := do
  let args ← requestArg req.releaseArgs
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftHandlerIO <| readRequestSyncSnapshot server req args.path
  let started ← liftFailureIO <| server.withState do
    match ← currentSessionForHandle req.workspaceId req.backend with
    | .error resp => pure (.error resp)
    | .ok session =>
        let rawHandle ←
          match unwrapHandle session args.handle with
          | .ok raw => pure raw
          | .error err =>
              return .error <| BrokerFailure.toResponseFailure {
                code := .contentModified
                message := err
              }
        let startedResult ← startSyncedDocumentRequest session snapshot args.method
          (fun uri _ => Json.mkObj [
            ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
            ("handle", rawHandle)
          ])
          trackedDocumentVersion
          (clientRequestId? := req.clientRequestId?)
          (emitProgress? := emitProgress?)
          (cancelRef? := cancelRef?)
        pure startedResult
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure (Response.withOptionalFileProgress (Response.success pending.result) pending.progress?, false)

private def initWorkspaceConfigFromRequest
    (server : ServerRuntime)
    (req : Request) : IO (Except ResponseFailure BrokerConfig) := do
  let root ←
    match req.rootArg with
    | .ok root => pure root
    | .error failure => return .error failure
  let root ←
    try
      resolveRoot root
    catch e =>
      return .error (responseFailureFor .invalidParams e.toString)
  let leanPlugin? ←
    try
      req.leanPlugin?.mapM (fun path => Beam.resolveExistingPath <| System.FilePath.mk path)
    catch e =>
      return .error (responseFailureFor .invalidParams e.toString)
  if req.leanCmd?.isNone && leanPlugin?.isNone && req.rocqCmd?.isNone then
    let bootstrapConfig ← server.withState do
      let state ← get
      pure state.bootstrapConfig
    if root == bootstrapConfig.root then
      return .ok bootstrapConfig
  pure <| .ok {
    root
    leanCmd? := req.leanCmd?
    leanPlugin? := leanPlugin?
    rocqCmd? := req.rocqCmd?
  }

private def handleRequestIO
    (server : ServerRuntime)
    (req : Request)
    (activeRequest? : Option ActiveRequest := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO (Response × Bool) := do
  let cancelRef? := activeRequest?.map (·.cancelRef)
  match req.op with
  | .shutdown =>
      let firstClose ← server.close
      pure (
        Response.success (Json.mkObj [("shutdown", toJson true)]),
        firstClose
      )
  | .stats =>
      match req.workspaceId? with
      | none => pure (← server.statsResponse, false)
      | some _ =>
          match ← validateRequestWorkspace server req with
          | .error failure => pure (failure.toResponse, false)
          | .ok workspaceReq =>
              pure (← server.statsResponse (some workspaceReq.workspaceId), false)
  | .listWorkspaces =>
      let payload ← server.withState do
        pure <| workspaceListPayload (← get)
      pure (Response.success payload, false)
  | .resetStats =>
      let now ← IO.monoNanosNow
      let resp ← server.withState do
        resetMetrics now
        pure <| Response.success (Json.mkObj [("reset", toJson true)])
      pure (resp, false)
  | .openDocs =>
      match req.workspaceId? with
      | none => pure (Response.success (← server.withState openDocsPayload), false)
      | some _ =>
          match ← validateRequestWorkspace server req with
          | .error failure => pure (failure.toResponse, false)
          | .ok workspaceReq =>
              pure (Response.success
                (← server.withState <| openDocsPayload (some workspaceReq.workspaceId)), false)
  | .initWorkspace =>
      match req.requireWorkspaceId with
      | .error err => pure (errorResponseFor .invalidParams err, false)
      | .ok workspaceId =>
          match ← initWorkspaceConfigFromRequest server req with
          | .error failure => pure (failure.toResponse, false)
          | .ok config =>
              let resp ← server.initWorkspaceWithConfig workspaceId config req.workspaceMode?
              pure (resp, false)
  | .dropWorkspace =>
      match req.requireWorkspaceId with
      | .error err => pure (errorResponseFor .invalidParams err, false)
      | .ok workspaceId =>
          let resp ← server.dropWorkspace workspaceId
          pure (resp, false)
  | .cancel =>
      let targetClientRequestId ←
        match req.cancelRequestIdArg with
        | .ok targetClientRequestId => pure targetClientRequestId
        | .error failure => return (failure.toResponse, false)
      let cancelled ← cancelActiveRequest server targetClientRequestId
      pure (Response.success (Json.mkObj [("cancelled", toJson cancelled)]), false)
  | op =>
      match ← validateRequestWorkspace server req with
      | .error failure => pure (failure.toResponse, false)
      | .ok workspaceReq =>
          match op with
          | .ensure =>
              let resp ←
                try
                  server.withState do
                    let session ← ensureSession workspaceReq.workspaceId workspaceReq.backend
                    let payload := Json.mkObj [
                      ("workspace_id", toJson workspaceReq.workspaceId),
                      ("backend", toJson workspaceReq.backend),
                      ("root", toJson session.root.toString),
                      ("epoch", toJson session.epoch)
                    ]
                    pure <| Response.success payload
                catch e =>
                  pure <| errorResponseFor .internalError e.toString
              pure (resp, false)
          | .updateFile => runHandler <| handleUpdateFileOp server workspaceReq cancelRef?
          | .syncFile =>
              runHandler <| handleSyncFileOp server workspaceReq cancelRef? emitProgress? emitDiagnostic?
          | .refreshFile =>
              runHandler <| handleRefreshFileOp server workspaceReq cancelRef? emitProgress? emitDiagnostic?
          | .close =>
              runHandler <| handleCloseOp server workspaceReq cancelRef? emitProgress? emitDiagnostic?
          | .runAt =>
              runHandler <| handleRunAtOp server workspaceReq cancelRef? emitProgress? emitDiagnostic?
          | .hover => runHandler <| handleHoverOp server workspaceReq cancelRef? emitProgress?
          | .signatureHelp =>
              runHandler <| handleSignatureHelpOp server workspaceReq cancelRef? emitProgress?
          | .definition =>
              runHandler <| handleDefinitionOp server workspaceReq cancelRef? emitProgress?
          | .references =>
              runHandler <| handleReferencesOp server workspaceReq cancelRef? emitProgress?
          | .documentSymbols =>
              runHandler <| handleDocumentSymbolsOp server workspaceReq cancelRef? emitProgress?
          | .workspaceSymbols =>
              runHandler <| handleWorkspaceSymbolsOp server workspaceReq cancelRef?
          | .codeActionResolve =>
              runHandler <| handleCodeActionResolveOp server workspaceReq cancelRef? emitProgress?
          | .saveOlean =>
              runHandler <| handleSaveOleanOp server workspaceReq cancelRef? emitProgress? emitDiagnostic?
          | .goals => runHandler <| handleGoalsOp server workspaceReq cancelRef? emitProgress?
          | .todo => runHandler <| handleTodoOp server workspaceReq cancelRef? emitProgress?
          | .runWith => runHandler <| handleRunWithOp server workspaceReq cancelRef? emitProgress?
          | .release => runHandler <| handleReleaseOp server workspaceReq cancelRef? emitProgress?
          | .openDocs | .stats | .resetStats | .shutdown
          | .cancel | .initWorkspace | .listWorkspaces | .dropWorkspace =>
              unreachable!

private def ServerRuntime.withRequestAdmission
    (server : ServerRuntime)
    (req : Request)
    (act : RequestHandle → IO (Response × Bool)) : IO (Response × Bool) := do
  let startedAt ← IO.monoNanosNow
  traceBroker
    s!"dispatch start op={req.op.key} clientRequestId={optionLabel req.clientRequestId?}"
  match req.validateFields with
  | .error err =>
      let resp := errorResponseFor .invalidParams err
      traceBroker
        s!"dispatch rejected op={req.op.key} clientRequestId={optionLabel req.clientRequestId?} error={err}"
      recordDispatchMetrics server req resp startedAt
      return (resp, false)
  | .ok () => pure ()
  try
    let active? ←
      if req.op.tracksActiveRequest then
        match ← ActiveRequestRegistry.register server.activeRequests req.clientRequestId? with
        | .ok active => pure (some active)
        | .error failure =>
            let resp := BrokerFailure.toResponse failure
            recordDispatchMetrics server req resp startedAt
            return (resp, false)
      else
        pure none
    try
      let handle : RequestHandle := { runtime := server, active? }
      let (resp, shouldStop) ← act handle
      traceBroker
        s!"dispatch complete op={req.op.key} clientRequestId={optionLabel req.clientRequestId?} ok={resp.ok}"
      recordDispatchMetrics server req resp startedAt
      pure (resp, shouldStop)
    finally
      ActiveRequestRegistry.unregister server.activeRequests active?
  catch e =>
    let resp := errorResponseFor .internalError e.toString
    traceBroker
      s!"dispatch exception op={req.op.key} clientRequestId={optionLabel req.clientRequestId?} error={e.toString}"
    recordDispatchMetrics server req resp startedAt
    pure (resp, false)

/--
Admit `req`, expose its exact cancellation handle to `beforeDispatch`, and
retain broker ownership of the one allowed dispatch.

When `beforeDispatch` returns `false`, the request is unregistered without
dispatch and receives a `requestCancelled` response. Registration cleanup also
runs if `beforeDispatch` or the request handler throws. Operation field-shape
errors are rejected before admission and do not invoke `beforeDispatch`.
-/
def ServerRuntime.dispatchRequestWithHandle
    (server : ServerRuntime)
    (req : Request)
    (beforeDispatch : RequestHandle → IO Bool)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO (Response × Bool) := do
  server.withRequestAdmission req fun handle => do
    unless ← beforeDispatch handle do
      return (
        BrokerFailure.toResponse {
          code := .requestCancelled
          message := "request was cancelled before broker dispatch"
        },
        false
      )
    handleRequestIO server req handle.active? emitProgress? emitDiagnostic?

def ServerRuntime.dispatchRequest
    (server : ServerRuntime)
    (req : Request)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO (Response × Bool) := do
  server.dispatchRequestWithHandle req (fun _ => pure true) emitProgress? emitDiagnostic?

private def rootWatchPollMs : UInt32 :=
  250

/--
A standalone daemon cannot rely on its registry after the project directory disappears: the
default registry lives below that directory and is removed with it. Stop the broker proactively so
removing a git worktree does not strand either the daemon or its backend processes.
-/
private partial def watchRoot (server : ServerRuntime) (root : System.FilePath) : IO Unit := do
  if ← server.stop.get then
    pure ()
  else
    let rootAvailable ←
      try
        root.isDir
      catch _ =>
        pure false
    if !rootAvailable then
      IO.eprintln s!"Beam daemon root is no longer available; shutting down: {root}"
      let shouldStop ← server.close
      if shouldStop then
        requestStop server
    else
      IO.sleep rootWatchPollMs
      watchRoot server root

private def watchSessionOwnerStdin (server : ServerRuntime) : IO Unit := do
  try
    discard <| (← IO.getStdin).readToEnd
  catch _ =>
    pure ()
  unless ← server.stop.get do
    let shouldStop ← server.close
    if shouldStop then
      requestStop server

private def watchClientDisconnect
    (client : Transport.Connection)
    (handle : RequestHandle) : IO Unit := do
  try
    -- The daemon transport accepts one request per connection. A second receive therefore blocks
    -- until the client closes or dies; either outcome should cancel an unfinished admission.
    discard <| Transport.recvMsg client
  catch _ =>
    pure ()
  discard <| handle.cancel

private def handleClient (server : ServerRuntime) (client : Transport.Connection) : IO Unit := do
  let clientRequestIdRef ← IO.mkRef (none : Option String)
  let terminalSentRef ← IO.mkRef false
  let sendResponse (clientRequestId? : Option String) (resp : Response) : IO Unit := do
    Transport.sendMsg client
      (toJson (StreamMessage.response clientRequestId? resp)).compress
    terminalSentRef.set true
  try
    let msg ← Transport.recvMsg client
    let request : Except ResponseFailure Request ←
      match Json.parse msg with
      | .error err =>
          pure <| Except.error <|
            responseFailureFor .invalidParams s!"invalid request json: {err}"
      | .ok json => do
          match json.getObjValAs? String "clientRequestId" with
          | .ok clientRequestId => clientRequestIdRef.set (some clientRequestId)
          | .error _ => pure ()
          match fromJson? json with
          | .ok req => pure <| Except.ok req
          | .error err =>
              pure <| Except.error <|
                responseFailureFor .invalidParams s!"invalid request payload: {err}"
    match request with
    | Except.error failure =>
        sendResponse (← clientRequestIdRef.get) failure.toResponse
    | Except.ok req =>
        let emitProgress : SyncFileProgress → IO Unit := fun progress =>
          Transport.sendMsg client
            (toJson (StreamMessage.fileProgress req.clientRequestId? progress)).compress
        let emitDiagnostic : StreamDiagnostic → IO Unit := fun diagnostic =>
          Transport.sendMsg client
            (toJson (StreamMessage.diagnostic req.clientRequestId? diagnostic)).compress
        let (resp, shouldStop) ← server.dispatchRequestWithHandle req (fun handle => do
          let _ ← IO.asTask (prio := Task.Priority.dedicated) <| watchClientDisconnect client handle
          pure true) (some emitProgress) (some emitDiagnostic)
        sendResponse req.clientRequestId? resp
        if shouldStop then
          requestStop server
  catch e =>
    unless ← terminalSentRef.get do
      let clientRequestId? ← clientRequestIdRef.get
      let resp := errorResponseFor .internalError e.toString
      try
        sendResponse clientRequestId? resp
      catch _ =>
        pure ()
  finally
    Transport.closeConnection client

private partial def acceptLoop (server : ServerRuntime) (listener : Transport.Listener) : IO Unit := do
  if ← server.stop.get then
    pure ()
  else
    let client ← Transport.accept listener
    if ← server.stop.get then
      pure ()
    else
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        try
          handleClient server client
        catch e =>
          IO.eprintln s!"broker client task failed: {e.toString}"
      acceptLoop server listener

private structure CliOptions where
  endpoint : Transport.Endpoint := .tcp 8765
  root? : Option String := none
  workspaceId? : Option WorkspaceId := none
  sessionOwnerStdin : Bool := false
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
  | "--port" :: port :: rest => do
      let port ← parsePortArg port
      parseCliOptions { opts with endpoint := .tcp port } rest
  | "--root" :: root :: rest =>
      parseCliOptions { opts with root? := some root } rest
  | "--workspace-id" :: workspaceId :: rest =>
      parseCliOptions { opts with workspaceId? := some workspaceId } rest
  | "--session-owner-stdin" :: rest =>
      parseCliOptions { opts with sessionOwnerStdin := true } rest
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
  let some workspaceId := opts.workspaceId?
    | throw <| IO.userError "missing Beam daemon --workspace-id ID"
  unless validWorkspaceId workspaceId do
    throw <| IO.userError "workspace id must be non-empty"
  let root ← Beam.resolveExistingPath <| System.FilePath.mk root
  let leanPlugin? ← opts.leanPlugin?.mapM (fun path => Beam.resolveExistingPath <| System.FilePath.mk path)
  let config : BrokerConfig := {
    root := root
    leanCmd? := opts.leanCmd?
    leanPlugin? := leanPlugin?
    rocqCmd? := opts.rocqCmd?
  }
  let listener ← Transport.bindAndListen opts.endpoint 16
  let runtime ← ServerRuntime.create config workspaceId opts.endpoint
  let rootWatcher ← IO.asTask (prio := Task.Priority.dedicated) <| watchRoot runtime root
  let ownerWatcher? ←
    if opts.sessionOwnerStdin then
      some <$> IO.asTask (prio := Task.Priority.dedicated) (watchSessionOwnerStdin runtime)
    else
      pure none
  try
    acceptLoop runtime listener
  finally
    runtime.stop.set true
    Transport.closeListener listener
    if let some ownerWatcher := ownerWatcher? then
      IO.cancel ownerWatcher
    discard <| IO.wait rootWatcher
    discard <| runtime.close

end Beam.Broker
