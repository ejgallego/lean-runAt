/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonManager
import Beam.Cli.Output
import Beam.Broker.Client
import Beam.Broker.Transport
import Std.Internal.UV.Signal

namespace Beam.Cli

open Beam.Broker

/--
Address a request to the private workspace of the CLI's one-project daemon.

Process-wide control operations deliberately remain unscoped. An explicitly supplied workspace is
preserved so this adapter does not rewrite lower-level test or maintenance requests.
-/
def inProjectDaemonWorkspace (req : Request) : Request :=
  match req.op.workspaceScope with
  | .none => req
  | .optional | .required =>
      if req.workspaceId?.isSome then req
      else { req with workspaceId? := some projectDaemonWorkspaceId }

def withBrokerErrorContext {α} (root : System.FilePath) (action : IO α) : IO α := do
  try
    action
  catch e =>
    throw <| IO.userError (← daemonFailureMessage root e.toString)

def callBroker (root : System.FilePath) (endpoint : Transport.Endpoint) (req : Request) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId (inProjectDaemonWorkspace req)
    let resp ← sendRequest endpoint req
    printResponse resp
    failOnError resp

def callBrokerQuiet (root : System.FilePath) (endpoint : Transport.Endpoint) (req : Request) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId (inProjectDaemonWorkspace req)
    let resp ← sendRequest endpoint req
    failOnError resp

structure BrokerWaitSpec where
  action : String
  startMsg : String
  progressMsg : SyncFileProgress → String
  stillWaitingMsg : Nat → String
  completeMsg : Response → String
  failureBoundary : String := "before the request completed"
  responseNote? : Response → Option String := fun _ => none

private structure InterruptWatcher where
  signal : Std.Internal.UV.Signal
  task : Task (Except IO.Error Unit)

private def InterruptWatcher.stop (watcher : InterruptWatcher) : IO Unit :=
  Std.Internal.UV.Signal.stop watcher.signal

private def InterruptWatcher.interrupted (watcher : InterruptWatcher) : IO Bool :=
  IO.hasFinished watcher.task

def progressEnabled : IO Bool := do
  match ← envFlag? "BEAM_PROGRESS" with
  | some enabled =>
      pure enabled
  | none =>
      (← IO.getStderr).isTty

private structure WrapperBrokerRequest where
  request : Request
  visibleClientRequestId? : Option String

private def mkWrapperClientRequestId (req : Request) : IO String := do
  let pid ← IO.Process.getPID
  let stamp ← IO.monoNanosNow
  pure s!"beam-wrapper-{req.op.key}-{pid}-{stamp}"

private def withWrapperClientRequestId (req : Request) : IO WrapperBrokerRequest := do
  let req ← withEnvClientRequestId req
  match req.clientRequestId? with
  | some clientRequestId =>
      pure {
        request := req
        visibleClientRequestId? := some clientRequestId
      }
  | none =>
      let clientRequestId ← mkWrapperClientRequestId req
      pure {
        request := { req with clientRequestId? := some clientRequestId }
        visibleClientRequestId? := none
      }

private def WrapperBrokerRequest.visibleResponse
    (wrapperReq : WrapperBrokerRequest)
    (resp : Response) : Response :=
  resp.setClientRequestId wrapperReq.visibleClientRequestId?

private def mkInterruptWatcher? (clientRequestId? : Option String) : IO (Option InterruptWatcher) := do
  match clientRequestId? with
  | none => pure none
  | some _ =>
      let signal ← Std.Internal.UV.Signal.mk 2 false
      let promise ← Std.Internal.UV.Signal.next signal
      let task ← IO.asTask (prio := Task.Priority.dedicated) do
        let some _ ← IO.wait promise.result?
          | throw <| IO.userError "SIGINT watcher promise dropped"
        pure ()
      pure <| some { signal, task }

def decodeCancelAcknowledged? (resp : Response) : Option Bool := do
  let result ← resp.result?
  result.getObjValAs? Bool "cancelled" |>.toOption

private def sendBrokerCancellation
    (endpoint : Transport.Endpoint)
    (req : Request) : IO (Option Bool) := do
  let cancelReq : Request := {
    op := .cancel
    cancelRequestId? := req.clientRequestId?
  }
  try
    let resp ← sendRequest endpoint (← withEnvClientRequestId cancelReq)
    pure <| decodeCancelAcknowledged? resp
  catch _ =>
    pure none

private def awaitBrokerResponse
    (task : Task (Except IO.Error Response))
    (endpoint : Transport.Endpoint)
    (req : Request)
    (visibleClientRequestId? : Option String)
    (spec : BrokerWaitSpec)
    (interruptWatcher? : Option InterruptWatcher)
    (showProgress : Bool) : IO Response := do
  let mut interruptObserved := false
  let mut cancelAcknowledged := false
  let emit := fun msg => IO.eprintln <| annotateRunatMessage visibleClientRequestId? msg
  if showProgress then
    emit spec.startMsg
  let mut waitedMs := 0
  try
    while !(← IO.hasFinished task) do
      match interruptWatcher? with
      | some watcher =>
          if (← watcher.interrupted) then
            if !interruptObserved then
              interruptObserved := true
              emit "beam: requesting broker cancellation"
            if !cancelAcknowledged then
              -- SIGINT can arrive after the wrapper starts the request task but before the broker
              -- has registered the client request id as active. Retry until the broker acknowledges
              -- cancellation or the original request finishes.
              match ← sendBrokerCancellation endpoint req with
              | some true => cancelAcknowledged := true
              | some false | none => pure ()
          else
            pure ()
      | none =>
          pure ()
      IO.sleep 500
      if !(← IO.hasFinished task) then
        waitedMs := waitedMs + 500
        if showProgress && waitedMs % 1000 == 0 then
          emit <| spec.stillWaitingMsg (waitedMs / 1000)
    let resp ←
      match (← IO.wait task) with
      | .ok resp => pure resp
      | .error err => throw err
    if showProgress then
      emit <| spec.completeMsg resp
    pure resp
  finally
    match interruptWatcher? with
    | some watcher => watcher.stop
    | none => pure ()

private def awaitBrokerResponseWithInterrupts
    (endpoint : Transport.Endpoint)
    (req : Request)
    (visibleClientRequestId? : Option String)
    (spec : BrokerWaitSpec)
    (showProgress : Bool)
    (action : IO Response) : IO Response := do
  -- Wrapper calls synthesize a broker clientRequestId when the user did not provide one. That id
  -- gives SIGINT cancellation a stable broker key but is kept out of the CLI's public output.
  let interruptWatcher? ← mkInterruptWatcher? req.clientRequestId?
  let task ←
    try
      IO.asTask (prio := Task.Priority.dedicated) action
    catch e =>
      match interruptWatcher? with
      | some watcher => watcher.stop
      | none => pure ()
      throw e
  awaitBrokerResponse task endpoint req visibleClientRequestId? spec interruptWatcher? showProgress

private def syncReadinessSuffix (result : SyncFileResult) : String :=
  let readiness := result.readiness
  if readiness.saveReady then
    ""
  else
    let errorCount := readiness.blockingErrorCount
    let reason := readiness.reason
    s!", saveReady=false ({reason}, " ++
      s!"blockingErrorCount={errorCount})"

private def syncLikeCompleteMsg (completeLabel path : String) (resp : Response) : String :=
  match decodeSyncFileResult? resp with
  | some result =>
      let suffix := syncFileProgressSuffix (responseFileProgress? resp)
      s!"beam: {completeLabel} complete for {path} (version {result.version}{suffix}{syncReadinessSuffix result})"
  | none =>
      s!"beam: {completeLabel} complete for {path}"

private def syncLikeWaitSpec
    (action path startMsg progressLabel stillWaitingLabel completeLabel : String) : BrokerWaitSpec :=
  {
    action
    startMsg
    progressMsg := fun progress => s!"beam: {progressLabel} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still {stillWaitingLabel} {path} ({seconds}s)"
    completeMsg := syncLikeCompleteMsg completeLabel path
    failureBoundary := "before a complete diagnostics barrier was available"
  }

def syncWaitSpec (path : String) (action : String := "lean-sync") : BrokerWaitSpec :=
  syncLikeWaitSpec
    (action := action)
    (path := path)
    (startMsg := s!"beam: syncing {path} and waiting for Lean diagnostics")
    (progressLabel := "sync")
    (stillWaitingLabel := "syncing")
    (completeLabel := "sync")

def refreshWaitSpec (path : String) (action : String := "lean-refresh") : BrokerWaitSpec :=
  syncLikeWaitSpec
    (action := action)
    (path := path)
    (startMsg := s!"beam: refreshing {path} by closing and resyncing")
    (progressLabel := "refresh")
    (stillWaitingLabel := "refreshing")
    (completeLabel := "refresh")

def leanRunAtWaitSpec (action path : String) (line character : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: snapshot progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for a ready Lean snapshot for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before probe execution"
    responseNote? := runAtPayloadSummary? action "probe"
  }

private def leanPositionNavigationWaitSpec
    (path : String)
    (line character : Nat)
    (action progressLabel noun : String) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: {progressLabel} progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := s!"before {noun} data was available"
  }

def leanHoverWaitSpec (path : String) (line character : Nat) (action : String := "lean-hover") :
    BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "hover" "hover"

def leanDefinitionWaitSpec
    (path : String)
    (line character : Nat)
    (action : String := "lean-definition") : BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "definition" "definition"

def leanSignatureHelpWaitSpec
    (path : String)
    (line character : Nat)
    (action : String := "lean-signature-help") : BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "signature-help" "signature help"

def leanReferencesWaitSpec
    (path : String)
    (line character : Nat)
    (action : String := "lean-references") : BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "references" "reference"

def leanDocumentSymbolsWaitSpec
    (path : String)
    (action : String := "lean-document-symbols") : BrokerWaitSpec :=
  {
    action := action
    startMsg := s!"beam: querying {action} for {path} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: document-symbol progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before document symbols were available"
  }

def leanWorkspaceSymbolsWaitSpec
    (query : String)
    (action : String := "lean-workspace-symbols") : BrokerWaitSpec :=
  {
    action := action
    startMsg := s!"beam: querying {action} for {query}"
    progressMsg := fun _ => s!"beam: workspace-symbol progress for query {query}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} query {query} ({seconds}s)"
    completeMsg := fun _ => s!"beam: {action} complete for query {query}"
    failureBoundary := "before workspace symbols were available"
  }

def leanGoalsWaitSpec
    (path : String)
    (line character : Nat)
    (mode : GoalMode)
    (action? : Option String := none) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  let action :=
    action?.getD <|
      match mode with
      | .before | .after => "lean-goals"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: goals progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before goal inspection completed"
  }

def leanTodoWaitSpec
    (path : String)
    (startLine startCharacter endLine endCharacter : Nat)
    (action : String := "lean-todo") : BrokerWaitSpec :=
  let pos := s!"{path}:{startLine}:{startCharacter}-{endLine}:{endCharacter}"
  {
    action := action
    startMsg := s!"beam: querying {action} for {pos} and waiting for Lean diagnostics"
    progressMsg := fun progress => s!"beam: todo progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before todo inspection completed"
  }

def leanRunWithWaitSpec
    (path : String)
    (linear : Bool := false)
    (action? : Option String := none) : BrokerWaitSpec :=
  let action := action?.getD <| if linear then "lean-run-with-linear" else "lean-run-with"
  {
    action := action
    startMsg := s!"beam: running {action} on {path} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before speculative continuation completed"
    responseNote? := runAtPayloadSummary? action "continuation"
  }

def leanSaveWaitSpec
    (path : String)
    (closeAfter : Bool := false)
    (action? : Option String := none) : BrokerWaitSpec :=
  let action := action?.getD <| if closeAfter then "lean-close-save" else "lean-save"
  let verb := if closeAfter then "closing and saving" else "saving"
  {
    action := action
    startMsg := s!"beam: {verb} {path} and waiting for Lean diagnostics/artifacts"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp => s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before save artifacts were finalized"
  }

def callBrokerWithProgress
    (root : System.FilePath)
    (endpoint : Transport.Endpoint)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Unit :=
  withBrokerErrorContext root do
    let wrapperReq ← withWrapperClientRequestId (inProjectDaemonWorkspace req)
    let req := wrapperReq.request
    let visibleClientRequestId? := wrapperReq.visibleClientRequestId?
    let showProgress ← progressEnabled
    let callbacks : StreamCallbacks := {
      onFileProgress := fun _ progress => do
        if showProgress then
          IO.eprintln <| annotateRunatMessage visibleClientRequestId? (spec.progressMsg progress)
      onDiagnostic := fun _ diagnostic =>
        IO.eprintln <| annotateRunatMessage visibleClientRequestId? (formatStreamDiagnostic diagnostic)
    }
    let resp ← awaitBrokerResponseWithInterrupts endpoint req visibleClientRequestId? spec showProgress <|
      sendRequestWithCallbacks endpoint req callbacks
    let resp := wrapperReq.visibleResponse resp
    match responseErrorSummary? spec.action spec.failureBoundary resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage visibleClientRequestId? note
    | none =>
        pure ()
    match responseRecoveryHint? resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage visibleClientRequestId? note
    | none =>
        pure ()
    match spec.responseNote? resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage visibleClientRequestId? note
    | none =>
        pure ()
    maybeEmitLiteralBackslashNewlineHint visibleClientRequestId? req resp
    printResponse resp
    failOnError resp

end Beam.Cli
