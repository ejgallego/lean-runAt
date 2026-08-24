/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Cli.Args
import Beam.Cli.Broker
import Beam.Cli.Info
import Beam.Cli.LeanOperation
import Beam.Cli.Lock
import Beam.Cli.RuntimeBundle
import Beam.Daemon.Debug
import Beam.Path
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert (requireJsonNull requireJsonString)

namespace BeamTest.Broker.CliDaemonTest

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def checkDaemonDebugWarnings : IO Unit := do
  let debug := Json.mkObj [
    ("registry", Json.mkObj [
      ("daemonId", toJson "fixture-daemon"),
      ("pid", toJson (424242 : Nat))
    ]),
    ("registryPidStatus", toJson "not alive"),
    ("registryEndpoint", toJson "tcp://127.0.0.1:42424")
  ]
  let warnings := Beam.Daemon.daemonDebugWarnings debug
  require "dead registry pid should produce a feedback warning"
    (warnings.any (fun warning => warning.contains "registry pid is not alive"))
  require "dead registry pid warning should include recovery hint"
    (warnings.any (fun warning =>
      warning.contains "lean-beam shutdown" && warning.contains "lean-beam ensure"))

private def expectIoErrorMessage (label : String) (act : IO α) : IO String := do
  let result ←
    try
      pure <| Except.ok (← act)
    catch err =>
      pure <| Except.error err
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected IO error"
  | .error err =>
      pure err.toString

private def expectIoErrorContains (label needle : String) (act : IO α) : IO Unit := do
  let msg ← expectIoErrorMessage label act
  unless msg.contains needle do
    throw <| IO.userError s!"{label}: expected error containing {needle}, got {msg}"

private def requireSubstring (label needle haystack : String) : IO Unit := do
  require s!"{label}: expected '{needle}' in '{haystack}'" (Beam.Cli.hasSubstring haystack needle)

private def requireJsonNat (label field : String) (expected : Nat) (json : Json) : IO Unit := do
  let actual ← IO.ofExcept <| json.getObjValAs? Nat field
  require s!"{label}: expected {field}={expected}, got {actual}" (actual == expected)

private def requireJsonStringContains (label field needle : String) (json : Json) : IO Unit := do
  let actual ← IO.ofExcept <| json.getObjValAs? String field
  require s!"{label}: expected {field} to contain {needle}, got {actual}" (actual.contains needle)

private def daemonFailureIncidentDir (root : System.FilePath) : IO System.FilePath := do
  pure ((← Beam.Cli.controlDir root) / "daemon-failures")

private def sortedIncidentEntries (root : System.FilePath) : IO (Array IO.FS.DirEntry) := do
  let dir ← daemonFailureIncidentDir root
  unless ← dir.pathExists do
    return #[]
  let entries ← dir.readDir
  pure <| (entries.filter (fun entry => entry.fileName.endsWith ".json")).qsort
    (fun a b => a.fileName < b.fileName)

private def readSingleDaemonFailureIncidentJson (root : System.FilePath) : IO Json := do
  let incidentDir ← daemonFailureIncidentDir root
  require "daemon failure should write incident directory" (← incidentDir.pathExists)
  let incidentEntries ← sortedIncidentEntries root
  require s!"expected one daemon failure incident, got {incidentEntries.size}" (incidentEntries.size == 1)
  let some incidentEntry := incidentEntries[0]?
    | throw <| IO.userError "expected one daemon failure incident entry"
  let incidentText ← IO.FS.readFile incidentEntry.path
  IO.ofExcept <| Json.parse incidentText

private def closeAcceptedConnection (listener : Beam.Broker.Transport.Listener) : IO Unit := do
  let conn ← Beam.Broker.Transport.accept listener
  Beam.Broker.Transport.closeConnection conn

private partial def withClosingBrokerEndpoint
    (act : Beam.Broker.Transport.Endpoint → IO α)
    (tries : Nat := 20) : IO α := do
  let stamp ← IO.monoNanosNow
  let portNat := 30000 + ((stamp + tries) % 20000)
  let endpoint := Beam.Broker.Transport.Endpoint.tcp portNat.toUInt16
  let listenerResult ←
    try
      pure <| Except.ok (← Beam.Broker.Transport.bindAndListen endpoint 1)
    catch err =>
      pure <| Except.error err
  match listenerResult with
  | .error err =>
      if tries == 0 then
        throw err
      else
        withClosingBrokerEndpoint act (tries - 1)
  | .ok listener =>
    let acceptTask ← IO.asTask (prio := Task.Priority.dedicated) <| closeAcceptedConnection listener
    let result ←
      try
        pure <| Except.ok (← act endpoint)
      catch err =>
        pure <| Except.error err
    discard <| IO.wait acceptTask
    match result with
    | .ok value => pure value
    | .error err => throw err

private def requireRequestJson
    (label : String)
    (actual expected : Beam.Broker.Request) : IO Unit := do
  let actualJson := toJson actual
  let expectedJson := toJson expected
  if actualJson != expectedJson then
    throw <| IO.userError s!"{label}: expected {expectedJson.compress}, got {actualJson.compress}"

private def sampleBrokerHandle : Beam.Broker.Handle := {
  workspaceId := Beam.Cli.projectDaemonWorkspaceId
  backend := .lean
  epoch := 3
  session := "session"
  raw := Json.mkObj [("value", toJson "raw-handle")]
}

private def checkProjectDaemonWorkspaceRouting : IO Unit := do
  let ensureReq := Beam.Cli.inProjectDaemonWorkspace ({ op := .ensure } : Beam.Broker.Request)
  require "CLI workspace-bound requests should select the project daemon workspace"
    (ensureReq.workspaceId? == some Beam.Cli.projectDaemonWorkspaceId)
  let statsReq := Beam.Cli.inProjectDaemonWorkspace ({ op := .stats } : Beam.Broker.Request)
  require "CLI stats should be scoped to the project daemon workspace"
    (statsReq.workspaceId? == some Beam.Cli.projectDaemonWorkspaceId)
  let shutdownReq := Beam.Cli.inProjectDaemonWorkspace ({ op := .shutdown } : Beam.Broker.Request)
  require "process-wide CLI shutdown should remain unscoped" shutdownReq.workspaceId?.isNone
  let explicitReq := Beam.Cli.inProjectDaemonWorkspace ({
    op := .ensure
    workspaceId? := some "maintenance-fixture"
  } : Beam.Broker.Request)
  require "CLI routing should preserve an explicitly selected workspace"
    (explicitReq.workspaceId? == some "maintenance-fixture")

private def checkClientResponsePresentation : IO Unit := do
  let semantic := Beam.Broker.Response.success Json.null
  let presented :=
    Beam.Broker.responseOutputJson semantic (some "visible-request")
  requireJsonString "presented response" "clientRequestId" "visible-request" presented
  match fromJson? (α := Beam.Broker.Response) presented with
  | .ok response =>
      throw <| IO.userError
        s!"presentation-decorated response decoded as semantic response: {(toJson response).compress}"
  | .error _ => pure ()

private def checkCliRecoveryHints : IO Unit := do
  let staleData := Json.mkObj [
    ("targetPath", toJson "SaveSmoke/A.lean"),
    ("recoveryPlan", toJson #[
      "lean-beam save \"SaveSmoke/B.lean\"",
      "lean-beam refresh \"SaveSmoke/A.lean\"",
      "lake build"
    ])
  ]
  let syncBarrierResp := Beam.Broker.errorResponseFor
    .syncBarrierIncomplete
    "Lean diagnostics barrier did not complete"
    (some staleData)
  let some hint := Beam.Cli.responseRecoveryHint? syncBarrierResp
    | throw <| IO.userError "syncBarrierIncomplete should produce a CLI recovery hint"
  requireSubstring "syncBarrier recovery hint" "lean-beam save \"SaveSmoke/B.lean\"" hint
  requireSubstring "syncBarrier recovery hint" "lean-beam refresh \"SaveSmoke/A.lean\"" hint
  requireSubstring "syncBarrier recovery hint" "lake build" hint

  let fallbackResp := Beam.Broker.errorResponseFor
    .syncBarrierIncomplete
    "Lean diagnostics barrier did not complete"
    (some <| Json.mkObj [("targetPath", toJson "SaveSmoke/A.lean")])
  let some fallbackHint := Beam.Cli.responseRecoveryHint? fallbackResp
    | throw <| IO.userError "syncBarrierIncomplete fallback should produce a CLI recovery hint"
  requireSubstring "syncBarrier fallback hint" "lean-beam refresh \"SaveSmoke/A.lean\"" fallbackHint
  requireSubstring "syncBarrier fallback hint" "lake build" fallbackHint

  let invalidResp := Beam.Broker.errorResponseFor .invalidParams "bad input"
  require "invalidParams should not produce a sync recovery hint"
    (Beam.Cli.responseRecoveryHint? invalidResp).isNone

private def checkSyncWaitSpecs : IO Unit := do
  let okResp :=
    (Beam.Broker.Response.success <| toJson ({
      path := "Demo.lean"
      version := 5
      : Beam.Broker.SyncFileResult
    })).withFileProgress { updates := 2, done := true }
  require "sync complete message should include version and progress"
    ((Beam.Cli.syncWaitSpec "Demo.lean").completeMsg okResp ==
      "beam: sync complete for Demo.lean (version 5, fp updates=2)")
  require "refresh complete message should share sync-like formatting"
    ((Beam.Cli.refreshWaitSpec "Demo.lean").completeMsg okResp ==
      "beam: refresh complete for Demo.lean (version 5, fp updates=2)")
  let publicTodoSpec := Beam.Cli.leanTodoWaitSpec "Demo.lean" 1 0 2 3 "todo"
  require "todo wait action should accept public wrapper label"
    (publicTodoSpec.action == "todo")
  requireSubstring "todo start message should use public wrapper label"
    "beam: querying todo for Demo.lean:1:0-2:3"
    publicTodoSpec.startMsg
  requireSubstring "todo complete message should use public wrapper label"
    "beam: todo complete for Demo.lean:1:0-2:3"
    (publicTodoSpec.completeMsg okResp)
  let publicDefinitionSpec := Beam.Cli.leanDefinitionWaitSpec "Demo.lean" 1 2 "definition"
  require "definition wait action should accept public wrapper label"
    (publicDefinitionSpec.action == "definition")
  requireSubstring "definition start message should use public wrapper label"
    "beam: running definition on Demo.lean:1:2"
    publicDefinitionSpec.startMsg
  let publicSignatureHelpSpec := Beam.Cli.leanSignatureHelpWaitSpec "Demo.lean" 1 2 "signature-help"
  require "signature-help wait action should accept public wrapper label"
    (publicSignatureHelpSpec.action == "signature-help")
  requireSubstring "signature-help start message should use public wrapper label"
    "beam: running signature-help on Demo.lean:1:2"
    publicSignatureHelpSpec.startMsg
  let publicDocumentSymbolsSpec := Beam.Cli.leanDocumentSymbolsWaitSpec "Demo.lean" "document-symbols"
  require "document-symbols wait action should accept public wrapper label"
    (publicDocumentSymbolsSpec.action == "document-symbols")
  requireSubstring "document-symbols complete message should use public wrapper label"
    "beam: document-symbols complete for Demo.lean"
    (publicDocumentSymbolsSpec.completeMsg okResp)
  let publicGoalsSpec := Beam.Cli.leanGoalsWaitSpec "Demo.lean" 1 2 .before (some "goals")
  require "goals wait action should accept public wrapper label"
    (publicGoalsSpec.action == "goals")
  requireSubstring "goals start message should use public wrapper label"
    "beam: running goals on Demo.lean:1:2"
    publicGoalsSpec.startMsg

  let notReadyResp := Beam.Broker.Response.success <| toJson ({
      path := "Demo.lean"
      version := 6
      readiness := {
        blockingErrorCount := 1
        saveReady := false
        reason := "documentErrors"
      }
      : Beam.Broker.SyncFileResult
    })
  requireSubstring "sync not-ready message"
    "saveReady=false (documentErrors, blockingErrorCount=1)"
    ((Beam.Cli.syncWaitSpec "Demo.lean").completeMsg notReadyResp)

private def checkCancelAcknowledgementDecoding : IO Unit := do
  let acknowledged := Beam.Broker.Response.success <|
    Json.mkObj [("cancelled", toJson true)]
  require "cancel acknowledgement should decode true"
    (Beam.Cli.decodeCancelAcknowledged? acknowledged == some true)

  let notAcknowledged := Beam.Broker.Response.success <|
    Json.mkObj [("cancelled", toJson false)]
  require "cancel acknowledgement should decode false"
    (Beam.Cli.decodeCancelAcknowledged? notAcknowledged == some false)

  let missing := Beam.Broker.Response.success <|
    Json.mkObj [("other", toJson true)]
  require "missing cancel acknowledgement should decode none"
    (Beam.Cli.decodeCancelAcknowledged? missing).isNone

  let failed := Beam.Broker.errorResponseFor .invalidParams "bad cancel"
  require "failed cancel response should decode none"
    (Beam.Cli.decodeCancelAcknowledged? failed).isNone

private def checkCliRootParsing : IO Unit := do
  let missingRoot := System.FilePath.mk s!"/tmp/beam-cli-missing-root-{← IO.monoNanosNow}"
  expectIoErrorContains
    "missing explicit CLI root should use the workspace error boundary"
    "workspace root does not resolve"
    (Beam.Cli.parseCliOptions {} ["--root", missingRoot.toString, "ensure", "lean"])

private def checkLeanOperationRequests : IO Unit := do
  let root := System.FilePath.mk "/repo"
  let rootText := root.toString
  let path := "Demo.lean"

  let runAtInput : Beam.Lean.RunAtInput := {
    path
    version := 12
    line := 4
    character := 2
    text := "exact h"
  }
  requireRequestJson "runAt request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest root path 12 4 2 (some "exact h"))
    (runAtInput.toBrokerRequest rootText)
  requireRequestJson "runAt handle request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest root path 12 4 2 (some "exact h") (storeHandle := true))
    (runAtInput.toBrokerRequest rootText (storeHandle := true))
  let missingRunAtText := Beam.Cli.leanRunAtRequest root path 12 4 2 none
  require "runAt missing text should remain a broker validation error" missingRunAtText.text?.isNone
  require "runAt missing text should still target run_at" (missingRunAtText.op == .runAt)
  require "runAt missing text should carry version" (missingRunAtText.version? == some 12)

  let positionInput : Beam.Lean.PositionInput := {
    path
    version := 13
    line := 7
    character := 3
  }
  requireRequestJson "hover request should share the Lean operation adapter"
    (Beam.Cli.leanHoverRequest root path 13 7 3)
    (positionInput.toHoverBrokerRequest rootText)
  requireRequestJson "signature-help request should share the Lean operation adapter"
    (Beam.Cli.leanSignatureHelpRequest root path 13 7 3)
    (positionInput.toSignatureHelpBrokerRequest rootText)
  requireRequestJson "definition request should share the Lean operation adapter"
    (Beam.Cli.leanDefinitionRequest root path 13 7 3)
    (positionInput.toDefinitionBrokerRequest rootText)
  let referencesInput : Beam.Lean.ReferencesInput := {
    path
    version := 13
    line := 7
    character := 3
    includeDeclaration? := some false
  }
  requireRequestJson "references request should share the Lean operation adapter"
    (Beam.Cli.leanReferencesRequest root path 13 7 3 false)
    (referencesInput.toBrokerRequest rootText)
  let documentSymbolsInput : Beam.Lean.DocumentSymbolsInput := {
    path
    version := 13
  }
  requireRequestJson "document-symbols request should share the Lean operation adapter"
    (Beam.Cli.leanDocumentSymbolsRequest root path 13)
    (documentSymbolsInput.toBrokerRequest rootText)
  let workspaceSymbolsInput : Beam.Lean.WorkspaceSymbolsInput := {
    query := "Demo"
  }
  requireRequestJson "workspace-symbols request should share the Lean operation adapter"
    (Beam.Cli.leanWorkspaceSymbolsRequest root "Demo")
    (workspaceSymbolsInput.toBrokerRequest rootText)
  requireRequestJson "goals request should share the Lean operation adapter"
    (Beam.Cli.leanGoalsRequest root path 13 7 3 .before)
    (positionInput.toGoalsBrokerRequest rootText .before)

  let runWithInput : Beam.Lean.RunWithInput := {
    path
    handle := sampleBrokerHandle
    text := "simp"
  }
  requireRequestJson "runWith request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest root path sampleBrokerHandle (some "simp"))
    (runWithInput.toBrokerRequest rootText)
  requireRequestJson "runWith linear request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest root path sampleBrokerHandle (some "simp") (linear := true))
    (runWithInput.toBrokerRequest rootText (linear := true))
  let missingRunWithText := Beam.Cli.leanRunWithRequest root path sampleBrokerHandle none
  require "runWith missing text should remain a broker validation error" missingRunWithText.text?.isNone
  require "runWith missing text should keep successor-handle semantics"
    (missingRunWithText.storeHandle? == some true)
  require "runWith missing text should keep linear flag explicit"
    (missingRunWithText.linear? == some false)
  require "runWith missing text should keep the supplied handle"
    missingRunWithText.handle?.isSome

  requireRequestJson "release request should share the Lean operation adapter"
    (Beam.Cli.leanReleaseRequest root path sampleBrokerHandle)
    (({ path, handle := sampleBrokerHandle } : Beam.Lean.ReleaseInput).toBrokerRequest rootText)

  let pathInput : Beam.Lean.PathInput := { path }
  requireRequestJson "update request should share the Lean operation adapter"
    (Beam.Cli.leanUpdateRequest root path)
    (pathInput.toUpdateBrokerRequest rootText)
  requireRequestJson "close request should share the Lean operation adapter"
    (Beam.Cli.leanCloseRequest root path)
    (pathInput.toCloseBrokerRequest rootText)

  let syncInput : Beam.Lean.SyncInput := { path, diagnosticScope? := some .all }
  let saveInput : Beam.Lean.SaveInput := { path, diagnosticScope? := some .all }
  requireRequestJson "sync request should share the Lean operation adapter"
    (Beam.Cli.leanSyncRequest root path .all)
    (syncInput.toSyncBrokerRequest rootText)
  requireRequestJson "refresh request should share the Lean operation adapter"
    (Beam.Cli.leanRefreshRequest root path .all)
    (syncInput.toRefreshBrokerRequest rootText)
  requireRequestJson "save request should share the Lean operation adapter"
    (Beam.Cli.leanSaveRequest root path .all)
    (saveInput.toSaveBrokerRequest rootText)
  requireRequestJson "close-save request should share the Lean operation adapter"
    (Beam.Cli.leanCloseSaveRequest root path .all)
    (saveInput.toCloseSaveBrokerRequest rootText)

  let closeSave := Beam.Cli.leanCloseSaveRequest root path .all
  require "close-save should use close broker op" (closeSave.op == .close)
  require "close-save should request artifact save" (closeSave.saveArtifacts? == some true)
  require "close-save should preserve diagnostic scope" (closeSave.diagnosticScope? == some .all)

private def checkDiagnosticScopeArgs : IO Unit := do
  let parsers : Array (String × (List String → IO Beam.Broker.DiagnosticScope)) := #[
    ("sync", Beam.Cli.parseLeanSyncArgs),
    ("refresh", Beam.Cli.parseLeanRefreshArgs),
    ("save", Beam.Cli.parseLeanSaveArgs),
    ("close-save", Beam.Cli.parseLeanCloseSaveArgs)
  ]
  for (label, parse) in parsers do
    require s!"{label} diagnostic scope should default to errors"
      ((← parse []) == .errors)
    require s!"{label} diagnostic scope should accept +all-diagnostics"
      ((← parse ["+all-diagnostics"]) == .all)
    let obsoleteRejected ←
      try
        discard <| parse ["+full"]
        pure false
      catch err =>
        pure <| err.toString.contains "+all-diagnostics"
    require s!"{label} diagnostic scope should reject obsolete +full" obsoleteRejected

private def checkStartupRetryPolicy : IO Unit := do
  require "automatic occupied endpoint should retry"
    (Beam.Daemon.shouldRetryAutomaticStartup true 1 true false)
  require "automatic startup bind collision should retry"
    (Beam.Daemon.shouldRetryAutomaticStartup true 1 false true)
  require "automatic endpoint should not retry after attempts are exhausted"
    (!Beam.Daemon.shouldRetryAutomaticStartup true 0 true true)
  require "automatic endpoint should not retry when endpoint is not occupied after failure"
    (!Beam.Daemon.shouldRetryAutomaticStartup true 1 false false)
  require "explicit endpoint should not retry"
    (!Beam.Daemon.shouldRetryAutomaticStartup false 1 true true)
  require "Linux bind failure wording should be recognized"
    (Beam.Daemon.startupFailureSuggestsEndpointInUse "resource busy (error code: 4294967198, address already in use)")
  require "macOS bind failure wording should be recognized"
    (Beam.Daemon.startupFailureSuggestsEndpointInUse "Address already in use")

private def checkDaemonFailureContext : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-failure-context-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let registryPath ← Beam.Cli.registryPath root
    if let some parent := registryPath.parent then
      IO.FS.createDirAll parent
    let entry : Beam.Daemon.RegistryEntry := {
      daemonId := "daemon-test"
      pid := 999999999
      port? := some 42424
      root := root.toString
      configHash := "config-test"
      toolchain? := some "leanprover/lean4:test"
      bundleId? := some "bundle-test"
      startedAt := "2026-07-02T00:00:00Z"
    }
    IO.FS.writeFile registryPath ((toJson entry).pretty ++ "\n")
    let startupLog := (← Beam.Cli.controlDir root) / "beam-daemon-startup.log"
    IO.FS.writeFile startupLog "line 1\nline 2\n"
    let msg ← Beam.Cli.daemonFailureMessage root "Beam daemon connection closed"
    requireSubstring "daemon failure context should include registry path" "Beam daemon registry" msg
    requireSubstring "daemon failure context should include daemon id" "daemonId: daemon-test" msg
    requireSubstring "daemon failure context should include dead pid status" "pid: 999999999 (not alive)" msg
    requireSubstring "daemon failure context should include endpoint" "endpoint: tcp://127.0.0.1:42424" msg
    requireSubstring "daemon failure context should include toolchain" "toolchain: leanprover/lean4:test" msg
    requireSubstring "daemon failure context should include bundle id" "bundleId: bundle-test" msg
    requireSubstring "daemon failure context should include daemon log tail" "Beam daemon log tail" msg
    requireSubstring "daemon failure context should include log contents" "line 2" msg
    requireSubstring "daemon failure context should include incident path" "Beam daemon incident:" msg

    let incidentJson ← readSingleDaemonFailureIncidentJson root
    requireJsonNat "daemon failure incident should use schema version" "schemaVersion" 1 incidentJson
    requireJsonString "daemon failure incident should classify connection close"
      "kind" "connectionClosed" incidentJson
    requireJsonString "daemon failure incident should keep original detail"
      "detail" "Beam daemon connection closed" incidentJson
    requireJsonString "daemon failure incident should include root"
      "root" root.toString incidentJson
    requireJsonString "daemon failure incident should include registry path"
      "registryPath" registryPath.toString incidentJson
    let incidentRegistryJson ← IO.ofExcept <| incidentJson.getObjVal? "registry"
    let incidentRegistry ← IO.ofExcept <| fromJson? (α := Beam.Daemon.RegistryEntry) incidentRegistryJson
    require "daemon failure incident should include daemon id"
      (incidentRegistry.daemonId == "daemon-test")
    requireJsonString "daemon failure incident should include registry pid status"
      "registryPidStatus" "not alive" incidentJson
    requireJsonString "daemon failure incident should include endpoint summary"
      "registryEndpoint" "tcp://127.0.0.1:42424" incidentJson
    requireJsonString "daemon failure incident should include startup log path"
      "startupLogPath" startupLog.toString incidentJson
    requireJsonString "daemon failure incident should include startup log tail"
      "startupLogTail" "line 1\nline 2" incidentJson
  finally
    try
      let control ← Beam.Cli.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkNoLiveDaemonFailureIncident : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-no-live-daemon-incident-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let detail := s!"no live Beam daemon registered for {root}"
    let msg ← Beam.Cli.daemonFailureMessage root detail
    requireSubstring "no-live daemon failure should include incident path" "Beam daemon incident:" msg

    let incidentJson ← readSingleDaemonFailureIncidentJson root
    requireJsonNat "no-live daemon incident should use schema version" "schemaVersion" 1 incidentJson
    requireJsonString "no-live daemon incident should classify stale lookup"
      "kind" "noLiveDaemon" incidentJson
    requireJsonString "no-live daemon incident should keep original detail"
      "detail" detail incidentJson
    requireJsonString "no-live daemon incident should include root"
      "root" root.toString incidentJson
  finally
    try
      let control ← Beam.Cli.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDaemonFailureUnreadableStartupLog : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-unreadable-startup-log-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let startupLog := (← Beam.Cli.controlDir root) / "beam-daemon-startup.log"
    IO.FS.createDirAll startupLog
    let msg ← Beam.Cli.daemonFailureMessage root "Beam daemon connection closed"
    requireSubstring "unreadable startup log should preserve original daemon failure"
      "Beam daemon connection closed" msg
    requireSubstring "unreadable startup log should still write incident path"
      "Beam daemon incident:" msg
    require "unreadable startup log should not print daemon log tail"
      (!Beam.Cli.hasSubstring msg "Beam daemon log tail")

    let incidentJson ← readSingleDaemonFailureIncidentJson root
    requireJsonString "unreadable startup log incident should classify connection close"
      "kind" "connectionClosed" incidentJson
    requireJsonNull "unreadable startup log incident should omit startup log path"
      "startupLogPath" incidentJson
    requireJsonNull "unreadable startup log incident should omit startup log tail"
      "startupLogTail" incidentJson
  finally
    try
      let control ← Beam.Cli.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def writeTestRegistryEntry
    (root : System.FilePath)
    (port? : Option Nat := none) : IO Unit := do
  let registryPath ← Beam.Cli.registryPath root
  if let some parent := registryPath.parent then
    IO.FS.createDirAll parent
  let entry : Beam.Daemon.RegistryEntry := {
    daemonId := "daemon-test"
    pid := 999999999
    port?
    root := root.toString
    configHash := "config-test"
    toolchain? := some "leanprover/lean4:test"
    bundleId? := some "bundle-test"
    startedAt := "2026-07-05T00:00:00Z"
  }
  IO.FS.writeFile registryPath ((toJson entry).pretty ++ "\n")

private def checkBrokerConnectionClosedIncident : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-broker-connection-closed-incident-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    withClosingBrokerEndpoint fun endpoint => do
      let port? :=
        match endpoint with
        | .tcp port => some port.toNat
      writeTestRegistryEntry root port?
      let msg ← expectIoErrorMessage "broker connection close should surface daemon failure" <|
        Beam.Cli.callBrokerQuiet root endpoint { op := .stats }
      requireSubstring "broker connection close should preserve transport failure"
        "Beam daemon connection closed" msg
      requireSubstring "broker connection close should include incident path"
        "Beam daemon incident:" msg

      let incidentJson ← readSingleDaemonFailureIncidentJson root
      requireJsonString "broker close incident should classify connection close"
        "kind" "connectionClosed" incidentJson
      requireJsonStringContains "broker close incident should keep transport detail"
        "detail" "Beam daemon connection closed" incidentJson
      requireJsonString "broker close incident should include endpoint summary"
        "registryEndpoint" (Beam.Daemon.endpointSummary endpoint) incidentJson
  finally
    try
      let control ← Beam.Cli.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDaemonFailureIncidentRetention : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-incident-retention-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let incidentDir ← daemonFailureIncidentDir root
    IO.FS.createDirAll incidentDir
    for i in [0:55] do
      IO.FS.writeFile (incidentDir / s!"000000000000000000{i}.json") "{}\n"
    let msg ← Beam.Cli.daemonFailureMessage root "Beam daemon connection closed"
    requireSubstring "retention failure should include incident path" "Beam daemon incident:" msg
    let entries ← sortedIncidentEntries root
    require s!"daemon incident retention should keep 50 files, got {entries.size}" (entries.size == 50)
    let newIncidents := entries.filter (fun entry => entry.fileName.contains "connectionClosed")
    require "daemon incident retention should keep newly written incident"
      (newIncidents.size == 1)
    let some newIncident := newIncidents[0]?
      | throw <| IO.userError "expected retained daemon failure incident entry"
    require "daemon incident filename should use sortable timestamp prefix"
      (newIncident.fileName.startsWith "incident-")
  finally
    try
      let control ← Beam.Cli.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDoctorDaemonFailureIncidentLines : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-doctor-daemon-incidents-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let absentLines ← Beam.Cli.daemonFailureIncidentDoctorLines root
    require "doctor should report no daemon incidents when directory is absent"
      (absentLines == ["daemon incidents: none"])

    discard <| Beam.Cli.daemonFailureMessage root "Beam daemon connection closed"
    let lines ← Beam.Cli.daemonFailureIncidentDoctorLines root
    require s!"doctor should report one recent daemon incident, got {lines}"
      (lines.head? == some "daemon incidents: 1 recent")
    let some incidentLine := lines.tail?.bind (·.head?)
      | throw <| IO.userError s!"doctor should include daemon incident path line, got {lines}"
    requireSubstring "doctor daemon incident line should include prefix"
      "daemon incident: " incidentLine
    requireSubstring "doctor daemon incident line should include incident directory"
      "daemon-failures" incidentLine
  finally
    try
      let control ← Beam.Cli.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private structure RelativePathCase where
  label : String
  root : System.FilePath
  path : System.FilePath
  expected? : Option String
  display : String

private def checkPathRelativeToRoot : IO Unit := do
  let p := System.FilePath.mk
  let cases : Array RelativePathCase := #[
    {
      label := "root path"
      root := p "/tmp/beam-root"
      path := p "/tmp/beam-root"
      expected? := some "."
      display := "."
    },
    {
      label := "child path"
      root := p "/tmp/beam-root"
      path := p "/tmp/beam-root/src/Main.lean"
      expected? := some "src/Main.lean"
      display := "src/Main.lean"
    },
    {
      label := "sibling prefix trap"
      root := p "/tmp/beam-root"
      path := p "/tmp/beam-root-other/Main.lean"
      expected? := none
      display := "/tmp/beam-root-other/Main.lean"
    },
    {
      label := "outside root"
      root := p "/tmp/beam-root"
      path := p "/tmp/other-root/Main.lean"
      expected? := none
      display := "/tmp/other-root/Main.lean"
    }
  ]
  for c in cases do
    let actual? := Beam.pathRelativeToRoot? c.root c.path
    require s!"{c.label}: expected relative path {repr c.expected?}, got {repr actual?}"
      (actual? == c.expected?)
    let display := Beam.pathRelativeToRootOrSelf c.root c.path
    require s!"{c.label}: expected display path {c.display}, got {display}"
      (display == c.display)

private def checkLeanModuleNamePathHelpers : IO Unit := do
  let p := System.FilePath.mk
  let root := p "/tmp/beam-root"
  require "relative top-level Lean path should become module name"
    (Beam.leanModuleNameFromRelPath? "Main.lean" == some "Main")
  require "relative nested Lean path should become dotted module name"
    (Beam.leanModuleNameFromRelPath? "Foo/Bar/Baz.lean" == some "Foo.Bar.Baz")
  require "relative non-Lean path should not become module name"
    (Beam.leanModuleNameFromRelPath? "Foo/Bar.v" == none)
  require "rooted Lean path under workspace should become module name"
    (Beam.leanModuleNameForPath? root (root / "Foo" / "Bar.lean") == some "Foo.Bar")
  require "rooted non-Lean path should not become module name"
    (Beam.leanModuleNameForPath? root (root / "Foo" / "Bar.v") == none)
  require "outside rooted Lean path should not become module name"
    (Beam.leanModuleNameForPath? root (p "/tmp/other-root/Foo.lean") == none)

private def createSymlink
    (label : String) (target link : System.FilePath) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "ln"
    args := #["-s", target.toString, link.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to create {label} symlink\n{out.stderr}"

private def checkPathCanonicalization : IO Unit := do
  let stamp ← IO.monoNanosNow
  let root := System.FilePath.mk s!"/tmp/beam-path-canonical-root-{stamp}"
  let alias := System.FilePath.mk s!"/tmp/beam-path-canonical-alias-{stamp}"
  try
    IO.FS.createDirAll root
    createSymlink "path canonicalization fixture" root alias
    require "canonical path equality should treat symlinked workspace roots as the same path"
      (← Beam.sameFilePath root alias)
    require "missing paths should fall back to exact text equality"
      (!(← Beam.sameFilePath (root / "missing") (alias / "missing")))
  finally
    try
      if ← alias.pathExists then
        IO.FS.removeFile alias
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkLockLifecycle : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-cli-lock-test-{← IO.monoNanosNow}"
  let lockDir := root / "lock"
  try
    Beam.Cli.withLock lockDir do
      require "lock directory should exist while lock is held" (← lockDir.pathExists)
      require "lock pid file should exist while lock is held" (← (lockDir / "pid").pathExists)
    require "lock directory should be removed after release" (!(← lockDir.pathExists))

    IO.FS.createDirAll lockDir
    IO.FS.writeFile (lockDir / "pid") "999999999\n"
    Beam.Cli.withLock lockDir do
      let pidText := (← IO.FS.readFile (lockDir / "pid")).trimAscii.toString
      require "stale lock should be replaced with this process lock" (pidText != "999999999")

    IO.FS.createDirAll lockDir
    let selfPid ← IO.Process.getPID
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
    expectIoErrorContains "live lock timeout" s!"lock owner: pid {selfPid}" <|
      Beam.Cli.withLockTimeout lockDir 100 do
        pure ()
    IO.FS.removeDirAll lockDir

    let deadPidTarget := root / "dead-pid"
    IO.FS.writeFile deadPidTarget "999999999\n"
    IO.FS.createDirAll lockDir
    createSymlink "lock PID fixture" deadPidTarget (lockDir / "pid")
    expectIoErrorContains "symlinked lock PID timeout" "lock owner: unknown owner" <|
      Beam.Cli.withLockTimeout lockDir 100 do
        pure ()
    require "a lock with a non-regular PID file should not be removed as stale"
      (← lockDir.pathExists)
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def writeFakeBundleArtifacts (workspace : System.FilePath) : IO Unit := do
  let paths := Beam.Cli.bundlePathsFor workspace
  for path in #[paths.daemon, paths.client, paths.plugin] do
    if let some parent := path.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile path "fake artifact\n"

private def sampleFingerprint : Beam.Cli.ToolchainFingerprint := {
  leanVersion := "Lean (version 4.30.0, test, Release)"
  leanPrefix := "/toolchains/a"
  leanLibDir := "/toolchains/a/lib/lean"
  lakeVersion := "Lake version 5.0.0-src (Lean version 4.30.0)"
}

private def sampleFingerprintB : Beam.Cli.ToolchainFingerprint := {
  sampleFingerprint with
  leanVersion := "Lean (version 4.30.0, rebuilt, Release)"
}

private def requireCanonicalToolchain
    (label toolchain releaseLine : String)
    (patch : Nat)
    (rc? : Option Nat) : IO Unit := do
  let some parsed := Beam.Cli.parseCanonicalLeanToolchain? toolchain
    | throw <| IO.userError s!"{label}: expected canonical toolchain parse for {toolchain}"
  require s!"{label}: unexpected release line" (parsed.releaseLine.versionText == releaseLine)
  require s!"{label}: unexpected patch" (parsed.patch == patch)
  require s!"{label}: unexpected RC" (parsed.rc? == rc?)
  require s!"{label}: canonical rendering should round-trip" (parsed.name == toolchain)

private def checkLeanToolchainPolicyParsing : IO Unit := do
  requireCanonicalToolchain "stable toolchain" "leanprover/lean4:v4.31.0" "4.31" 0 none
  requireCanonicalToolchain "RC toolchain" "leanprover/lean4:v4.31.0-rc2" "4.31" 0 (some 2)
  requireCanonicalToolchain "patch toolchain" "leanprover/lean4:v4.31.2" "4.31" 2 none
  for invalid in [
      "leanprover/lean4:v4.31",
      "leanprover/lean4:v4.31.0-rc0",
      "leanprover/lean4:v4.31.0-rc01",
      "leanprover/lean4:v04.31.0",
      "leanprover/lean4:v4.31.0-beta1",
      "leanprover/lean4-nightly:nightly-2026-08-01",
      "lean4-stage0"] do
    require s!"expected noncanonical toolchain rejection for {invalid}"
      (Beam.Cli.parseCanonicalLeanToolchain? invalid |>.isNone)

  let some line := Beam.Cli.parseLeanReleaseLine? "leanprover/lean4:v4.31"
    | throw <| IO.userError "expected canonical release-line parse"
  require "release-line rendering should round-trip"
    (line.registryEntry == "leanprover/lean4:v4.31")
  require "release line should reject patch versions"
    (Beam.Cli.parseLeanReleaseLine? "leanprover/lean4:v4.31.0" |>.isNone)
  require "canonical Lean version prefix should use the exact RC"
    (Beam.Cli.expectedCanonicalLeanVersionPrefix? "leanprover/lean4:v4.31.0-rc2" ==
      some "Lean (version 4.31.0-rc2,")
  require "custom toolchains should not claim a canonical Lean version"
    (Beam.Cli.expectedCanonicalLeanVersionPrefix? "lean4-stage0" |>.isNone)

private def checkLeanToolchainAdmission : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-toolchain-admission-test-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    IO.FS.writeFile (Beam.Cli.validatedLeanToolchainsPath root)
      "leanprover/lean4:v4.31.0\n"
    IO.FS.writeFile (Beam.Cli.compatibleLeanReleaseLinesPath root)
      "leanprover/lean4:v4.31\n"
    IO.FS.writeFile (Beam.Cli.customLeanToolchainsPath root)
      "lean4-stage0\n"

    let validated ← Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.0"
    require "exact toolchain should be validated" (validated.acceptance == .validated)

    let rc ← Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.0-rc2"
    require "canonical RC should be admitted by release line"
      (rc.acceptance == .releaseLine { major := 4, minor := 31 })

    let patch ← Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.2"
    require "canonical patch should be admitted by release line"
      (patch.acceptance == .releaseLine { major := 4, minor := 31 })

    let custom ← Beam.Cli.leanToolchainSupport root "lean4-stage0"
    require "explicit linked toolchain should remain custom" (custom.acceptance == .custom)

    for unsupported in [
        "leanprover/lean4:v4.32.0",
        "leanprover/lean4:v4.31.0-rc01",
        "leanprover/lean4-nightly:nightly-2026-08-01"] do
      let support ← Beam.Cli.leanToolchainSupport root unsupported
      require s!"expected unsupported admission for {unsupported}"
        (support.acceptance == .unsupported)

    IO.FS.writeFile (Beam.Cli.validatedLeanToolchainsPath root)
      "leanprover/lean4:v4.31.0-rc01\n"
    expectIoErrorContains
      "invalid validated registry"
      "invalid validated Lean toolchain"
      (Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.0")

    IO.FS.writeFile (Beam.Cli.validatedLeanToolchainsPath root)
      "leanprover/lean4:v4.31.0\nleanprover/lean4:v4.31.0\n"
    expectIoErrorContains
      "duplicate validated registry"
      "duplicate validated Lean toolchain"
      (Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.0")

    IO.FS.writeFile (Beam.Cli.validatedLeanToolchainsPath root)
      "leanprover/lean4:v4.31.0\n"

    IO.FS.writeFile (Beam.Cli.compatibleLeanReleaseLinesPath root)
      "leanprover/lean4:v4.31.0\n"
    expectIoErrorContains
      "invalid release-line registry"
      "invalid compatible Lean release line"
      (Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.0-rc2")

    IO.FS.writeFile (Beam.Cli.compatibleLeanReleaseLinesPath root)
      "leanprover/lean4:v4.31\nleanprover/lean4:v4.31\n"
    expectIoErrorContains
      "duplicate release-line registry"
      "duplicate compatible Lean release line"
      (Beam.Cli.leanToolchainSupport root "leanprover/lean4:v4.31.0-rc2")
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def writeBundleMetadataFile
    (bundleDir : System.FilePath)
    (toolchain sourceHash : String)
    (fingerprint : Beam.Cli.ToolchainFingerprint)
    (workspace : System.FilePath) : IO Unit := do
  IO.FS.writeFile
    (Beam.Cli.bundleMetadataPath bundleDir)
    ((Beam.Cli.bundleMetadataJson toolchain sourceHash fingerprint workspace "2026-06-05T00:00:00Z").pretty ++ "\n")

private def checkRuntimeBundleHelpers : IO Unit := do
  let id := Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" sampleFingerprint "source-a" "linux-x86_64"
  require "bundle id should be deterministic"
    (id == Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" sampleFingerprint "source-a" "linux-x86_64")
  require "bundle id should include platform"
    (id != Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" sampleFingerprint "source-a" "darwin-arm64")
  require "bundle id should include source hash"
    (id != Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" sampleFingerprint "source-b" "linux-x86_64")
  require "bundle id should include the resolved toolchain fingerprint"
    (id != Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" sampleFingerprintB "source-a" "linux-x86_64")
  require "bundle fingerprint hash should be deterministic"
    (Beam.Cli.toolchainFingerprintHash sampleFingerprint ==
      Beam.Cli.toolchainFingerprintHash sampleFingerprint)
  require "bundle fingerprint hash should change when Lean identity changes"
    (Beam.Cli.toolchainFingerprintHash sampleFingerprint !=
      Beam.Cli.toolchainFingerprintHash sampleFingerprintB)

  let workspace := System.FilePath.mk "/tmp/beam-runtime-bundle-workspace"
  let paths := Beam.Cli.bundlePathsFor workspace
  require "bundle daemon path should point at workspace build output"
    (paths.daemon == workspace / ".lake" / "build" / "bin" / "beam-daemon")
  require "bundle client path should point at workspace build output"
    (paths.client == workspace / ".lake" / "build" / "bin" / "beam-client")
  require "bundle plugin path should live under workspace build lib"
    (paths.plugin.toString.startsWith (workspace / ".lake" / "build" / "lib").toString)
  require "state directory should remain the public .beam path"
    (Beam.Cli.beamStateDir (System.FilePath.mk "/tmp/project") == System.FilePath.mk "/tmp/project" / ".beam")

  let metadata := Beam.Cli.bundleMetadataJson
    "leanprover/lean4:v4.30.0"
    "source-a"
    sampleFingerprint
    workspace
    "2026-06-05T00:00:00Z"
  let schemaVersion ← IO.ofExcept <| metadata.getObjValAs? Nat "schemaVersion"
  let toolchain ← IO.ofExcept <| metadata.getObjValAs? String "toolchain"
  let toolchainFingerprint ← IO.ofExcept <| metadata.getObjValAs? Beam.Cli.ToolchainFingerprint "toolchainFingerprint"
  let sourceHash ← IO.ofExcept <| metadata.getObjValAs? String "sourceHash"
  let metadataWorkspace ← IO.ofExcept <| metadata.getObjValAs? String "workspace"
  require "bundle metadata schema version should remain explicit"
    (schemaVersion == Beam.Cli.bundleMetadataSchemaVersion)
  require "bundle metadata should include toolchain" (toolchain == "leanprover/lean4:v4.30.0")
  require "bundle metadata should include toolchain fingerprint"
    (toolchainFingerprint == sampleFingerprint)
  require "bundle metadata should include source hash" (sourceHash == "source-a")
  require "bundle metadata should include workspace" (metadataWorkspace == workspace.toString)

private def checkRuntimeBundleMetadataAcceptance : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-runtime-bundle-ready-test-{← IO.monoNanosNow}"
  let bundleDir := root / "bundle"
  let workspace := Beam.Cli.bundleWorkspaceFor bundleDir
  let toolchain := "leanprover/lean4:v4.30.0"
  let sourceHash := "source-a"
  try
    writeFakeBundleArtifacts workspace

    require "bundle should reject artifacts without metadata"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))

    let invalidSchema := Json.mkObj [
      ("schemaVersion", toJson 0),
      ("toolchain", toJson toolchain),
      ("toolchainFingerprint", toJson sampleFingerprint),
      ("sourceHash", toJson sourceHash),
      ("workspace", toJson workspace.toString),
      ("builtAt", toJson "2026-06-05T00:00:00Z")
    ]
    IO.FS.writeFile (Beam.Cli.bundleMetadataPath bundleDir) (invalidSchema.pretty ++ "\n")
    require "bundle should reject unsupported metadata schema"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))

    writeBundleMetadataFile bundleDir toolchain "source-b" sampleFingerprint workspace
    require "bundle should reject stale source metadata"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))

    writeBundleMetadataFile bundleDir toolchain sourceHash sampleFingerprintB workspace
    require "bundle should reject stale toolchain fingerprint metadata"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))

    writeBundleMetadataFile bundleDir toolchain sourceHash sampleFingerprint (root / "elsewhere")
    require "bundle should reject metadata for a different workspace"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))
    require "bundle with mismatched workspace should not expose a source hash"
      ((← Beam.Cli.completeBundleSourceHash? bundleDir).isNone)

    writeBundleMetadataFile bundleDir toolchain sourceHash sampleFingerprint workspace
    require "bundle should accept matching artifacts and metadata"
      (← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint)

    writeBundleMetadataFile bundleDir toolchain sourceHash sampleFingerprint (workspace / ".")
    require "bundle should accept metadata with equivalent diagnostic workspace spelling"
      (← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint)

    require "complete bundle source hash should use typed ready metadata"
      ((← Beam.Cli.completeBundleSourceHash? bundleDir) == some sourceHash)

    let metadataPath := Beam.Cli.bundleMetadataPath bundleDir
    let metadataTarget := root / "metadata-symlink-target.json"
    IO.FS.writeFile metadataTarget (← IO.FS.readFile metadataPath)
    IO.FS.removeFile metadataPath
    createSymlink "bundle metadata fixture" metadataTarget metadataPath
    require "bundle should reject symlinked metadata"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))
    require "bundle with symlinked metadata should not expose a source hash"
      ((← Beam.Cli.completeBundleSourceHash? bundleDir).isNone)
    IO.FS.removeFile metadataPath
    writeBundleMetadataFile bundleDir toolchain sourceHash sampleFingerprint workspace

    let client := (Beam.Cli.bundlePathsFor workspace).client
    IO.FS.removeFile client
    IO.FS.createDir client
    require "bundle should reject a required artifact path that is a directory"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))
    require "bundle with a directory artifact should not expose a source hash"
      ((← Beam.Cli.completeBundleSourceHash? bundleDir).isNone)
    IO.FS.removeDir client

    let symlinkTarget := root / "client-symlink-target"
    IO.FS.writeFile symlinkTarget "fake artifact\n"
    createSymlink "bundle artifact fixture" symlinkTarget client
    require "bundle should reject a symlinked required artifact"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))
    require "bundle with a symlinked artifact should not expose a source hash"
      ((← Beam.Cli.completeBundleSourceHash? bundleDir).isNone)
    IO.FS.removeFile client

    require "bundle should reject matching metadata without required artifacts"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash sampleFingerprint))
    require "incomplete bundle should not expose a source hash"
      ((← Beam.Cli.completeBundleSourceHash? bundleDir).isNone)
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

def main : IO Unit := do
  checkProjectDaemonWorkspaceRouting
  checkClientResponsePresentation
  checkCliRecoveryHints
  checkSyncWaitSpecs
  checkCancelAcknowledgementDecoding
  checkCliRootParsing
  checkLeanOperationRequests
  checkDiagnosticScopeArgs
  checkStartupRetryPolicy
  checkDaemonDebugWarnings
  checkDaemonFailureContext
  checkNoLiveDaemonFailureIncident
  checkDaemonFailureUnreadableStartupLog
  checkBrokerConnectionClosedIncident
  checkDaemonFailureIncidentRetention
  checkDoctorDaemonFailureIncidentLines
  checkPathRelativeToRoot
  checkLeanModuleNamePathHelpers
  checkPathCanonicalization
  checkLockLifecycle
  checkLeanToolchainPolicyParsing
  checkLeanToolchainAdmission
  checkRuntimeBundleHelpers
  checkRuntimeBundleMetadataAcceptance

end BeamTest.Broker.CliDaemonTest

def main := BeamTest.Broker.CliDaemonTest.main
