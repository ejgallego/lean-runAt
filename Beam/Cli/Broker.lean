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

private def withBrokerErrorContext
    {α}
    (root : System.FilePath)
    (action : IO (Except BrokerClientFailure α)) : IO α := do
  match ← action with
  | .ok value => pure value
  | .error failure =>
      throw <| IO.userError (← daemonFailureMessage root failure)

structure BrokerWaitSpec where
  action : String
  startMsg : String
  progressMsg : SyncFileProgress → String
  stillWaitingMsg : Nat → String
  completeMsg : Response → String
  failureBoundary : String := "before the request completed"
  responseNote? : Response → Option String := fun _ => none

structure InterruptWatcher where
  interrupted : IO Bool
  awaitInterrupt : IO Unit

private def closeInterruptSignal (signal : Std.Internal.UV.Signal) : IO Unit := do
  -- `Signal.stop` alone leaves an unresolved `next` promise and its waiter leaked. Cancel the
  -- pending wait first, then stop the underlying signal resource.
  try
    Std.Internal.UV.Signal.cancel signal
  finally
    Std.Internal.UV.Signal.stop signal

/-- Acquire one non-repeating SIGINT watcher and release its pending wait on every exit path. -/
def withInterruptWatcher (act : InterruptWatcher → IO α) : IO α := do
  let signal ← Std.Internal.UV.Signal.mk 2 false
  let promise ←
    try
      Std.Internal.UV.Signal.next signal
    catch err =>
      try
        Std.Internal.UV.Signal.stop signal
      catch _ =>
        pure ()
      throw err
  let event := promise.result?
  let watcher : InterruptWatcher := {
    interrupted := IO.hasFinished event
    awaitInterrupt := do
      let some _ ← IO.wait event
        | throw <| IO.userError "SIGINT watcher promise dropped"
      pure ()
  }
  try
    act watcher
  finally
    closeInterruptSignal signal

private def progressEnabled : IO Bool := do
  match ← envFlag? "BEAM_PROGRESS" with
  | some enabled =>
      pure enabled
  | none =>
      (← IO.getStderr).isTty

private structure WrapperBrokerRequest where
  request : Request
  clientRequestId : String
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
        clientRequestId
        visibleClientRequestId? := some clientRequestId
      }
  | none =>
      let clientRequestId ← mkWrapperClientRequestId req
      pure {
        request := { req with clientRequestId? := some clientRequestId }
        clientRequestId
        visibleClientRequestId? := none
      }

private def prepareWrapperBrokerRequest
    (req : Request) : IO WrapperBrokerRequest :=
  withWrapperClientRequestId <| inProjectDaemonWorkspace req

def decodeCancelAcknowledged? (resp : Response) : Option Bool := do
  let result ← resp.result?
  result.getObjValAs? Bool "cancelled" |>.toOption

private def sendBrokerCancellation
    (endpoint : Transport.Endpoint)
    (clientRequestId : String) : IO (Option Bool) := do
  let cancelReq : Request := {
    op := .cancel
    cancelRequestId? := some clientRequestId
  }
  try
    let resp ← sendRequest endpoint (← withEnvClientRequestId cancelReq)
    pure <| decodeCancelAcknowledged? resp
  catch _ =>
    pure none

private def awaitBrokerResponse
    (task : Task (Except IO.Error (Except BrokerClientFailure Response)))
    (endpoint : Transport.Endpoint)
    (clientRequestId : String)
    (visibleClientRequestId? : Option String)
    (progressSpec? : Option BrokerWaitSpec)
    (interruptWatcher : InterruptWatcher) : IO (Except BrokerClientFailure Response) := do
  let mut interruptObserved := false
  let mut cancelAcknowledged := false
  let emit := fun msg => IO.eprintln <| annotateRunatMessage visibleClientRequestId? msg
  if let some spec := progressSpec? then
    emit spec.startMsg
  let mut waitedMs := 0
  while !(← IO.hasFinished task) do
    let signalInterrupted ← interruptWatcher.interrupted
    if signalInterrupted || (← IO.checkCanceled) then
      if !interruptObserved then
        interruptObserved := true
        emit "beam: requesting broker cancellation"
      if !cancelAcknowledged then
        -- SIGINT can arrive after the wrapper starts the request task but before the broker
        -- has registered the client request id as active. Retry until the broker acknowledges
        -- cancellation or the original request finishes.
        match ← sendBrokerCancellation endpoint clientRequestId with
        | some true => cancelAcknowledged := true
        | some false | none => pure ()
    IO.sleep 500
    if !(← IO.hasFinished task) then
      waitedMs := waitedMs + 500
      if waitedMs % 1000 == 0 then
        if let some spec := progressSpec? then
          emit <| spec.stillWaitingMsg (waitedMs / 1000)
  let result ←
    match (← IO.wait task) with
    | .ok result => pure result
    | .error err => throw err
  match result with
  | .ok response =>
      if let some spec := progressSpec? then
        emit <| spec.completeMsg response
      pure <| .ok response
  | .error failure =>
      pure <| .error failure

private def awaitBrokerResponseWithInterrupts
    (endpoint : Transport.Endpoint)
    (clientRequestId : String)
    (visibleClientRequestId? : Option String)
    (progressSpec? : Option BrokerWaitSpec)
    (action : IO (Except BrokerClientFailure Response)) :
    IO (Except BrokerClientFailure Response) := do
  -- Wrapper calls synthesize a broker clientRequestId when the user did not provide one. That id
  -- gives SIGINT cancellation a stable broker key but is kept out of the CLI's public output.
  withInterruptWatcher fun interruptWatcher => do
    let task ← IO.asTask (prio := Task.Priority.dedicated) action
    awaitBrokerResponse task endpoint clientRequestId visibleClientRequestId? progressSpec?
      interruptWatcher

private structure WrapperBrokerResponse where
  response : Response
  visibleClientRequestId? : Option String

private def requestBrokerResponse
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO WrapperBrokerResponse := do
  let wrapperReq ← prepareWrapperBrokerRequest req
  let req := wrapperReq.request
  let response ← withBrokerErrorContext root do
    awaitBrokerResponseWithInterrupts client.endpoint wrapperReq.clientRequestId
      wrapperReq.visibleClientRequestId? none <|
      sendRequestWithCallbacksResult client.endpoint req
  pure { response, visibleClientRequestId? := wrapperReq.visibleClientRequestId? }

/-- Send one wrapper request without printing or interpreting its response. -/
def requestBroker
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO Response := do
  pure (← requestBrokerResponse root client req).response

def callBroker
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO Unit := do
  let result ← requestBrokerResponse root client req
  printResponse result.response result.visibleClientRequestId?
  failOnError result.response

def callBrokerQuiet
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO Unit := do
  let resp ← requestBroker root client req
  failOnError resp

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
    (client : ProjectDaemonClient)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Unit := do
  let wrapperReq ← prepareWrapperBrokerRequest req
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
  let progressSpec? := if showProgress then some spec else none
  let resp ← withBrokerErrorContext root do
    awaitBrokerResponseWithInterrupts client.endpoint wrapperReq.clientRequestId
      visibleClientRequestId? progressSpec? <|
      sendRequestWithCallbacksResult client.endpoint req callbacks
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
  printResponse resp visibleClientRequestId?
  failOnError resp

end Beam.Cli
