/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import BeamTest.Broker.RequestStreamUtil
import BeamTest.Broker.TestUtil
import BeamTest.Fixtures.TodoFixture
import Lean

open Lean

namespace BeamTest.Broker.RequestStreamContractTest

open BeamTest.Broker.TestUtil

private def buildLakeTarget (root : System.FilePath) (target : String) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "env"
    args := #["LAKE_ARTIFACT_CACHE=false", "lake", "--no-cache", "build", target]
    cwd := root.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to build {target} in {root}\n{out.stderr}"

private def expectErrorCode (label code : String) (resp : Beam.Broker.Response) : IO Unit := do
  match resp with
  | .successResult .. =>
      throw <| IO.userError s!"expected {label} error {code}, got success {(toJson resp).compress}"
  | .errorResult failure =>
      if failure.error.code != code then
        throw <| IO.userError s!"expected {label} error {code}, got {(toJson resp).compress}"

private def expectTodoKindOnly
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (result : Beam.LSP.Todo.TodoResult) : IO Beam.LSP.Todo.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind)
    | throw <| IO.userError s!"expected {label} to contain todo kind {kind.key}, got {(toJson result).compress}"
  if result.items.any (fun item => item.kind != kind) then
    throw <| IO.userError s!"expected {label} to contain only todo kind {kind.key}, got {(toJson result).compress}"
  pure item

private def syncVersion
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (path : String) : IO Nat := do
  let resp ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some path
  }
  let result ← requireSyncFileResult s!"sync version for {path}" (← expectOk resp)
  pure result.version

def main : IO Unit := do
  let port ← freshTcpPort
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-daemon-request-stream"
  copySaveProjectFixture root
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint { op := .ensure, root? := some root.toString })

    let todoVersion ← syncVersion endpoint root BeamTest.Fixtures.TodoFixture.brokerPath
    let todoMessages ← requireSuccessStream "todo" <| ← runRequestStream port {
      op := .todo
      root? := some root.toString
      path? := some BeamTest.Fixtures.TodoFixture.brokerPath
      version? := some todoVersion
      line? := some BeamTest.Fixtures.TodoFixture.startLine
      character? := some BeamTest.Fixtures.TodoFixture.startCharacter
      endLine? := some BeamTest.Fixtures.TodoFixture.endLine
      endCharacter? := some BeamTest.Fixtures.TodoFixture.endCharacter
      kinds? := some #[.sorry]
      suggest? := some .none
    }
    let todoResp ← requireFinalStreamResponse "todo" todoMessages
    let todoPayload ← expectOk todoResp
    let todoResult : Beam.LSP.Todo.TodoResult ← IO.ofExcept <| fromJson? todoPayload
    let todoSorry ← expectTodoKindOnly "todo" .sorry todoResult
    if todoSorry.runAtPosition != BeamTest.Fixtures.TodoFixture.sorryPosition then
      throw <| IO.userError
        s!"expected todo runAtPosition at {BeamTest.Fixtures.TodoFixture.sorryPosition}, got {(toJson todoSorry).compress}"

    writeSaveWarningFile root "-- request-stream sync"
    let syncRequestId := some "request-stream-sync"
    let syncMessages ← requireSuccessStream "sync_file" <| ← runRequestStream port {
      op := .syncFile
      clientRequestId? := syncRequestId
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      diagnosticScope? := some .all
    }
    expectStreamClientRequestId "sync_file" syncMessages syncRequestId
    let syncResp ← requireFinalStreamResponse "sync_file" syncMessages
    discard <| requireFileProgress "sync_file terminal response" syncResp
    let syncPayload ← expectOk syncResp
    expectNoReplayDiagnosticsField "sync_file" syncPayload
    let syncResult ← requireSyncFileResult "sync_file" syncPayload
    if syncResult.version != 1 then
      throw <| IO.userError s!"expected sync_file version 1, got {syncResult.version}"
    if !syncResult.readiness.saveReady then
      throw <| IO.userError s!"expected sync_file saveReady = true, got {(toJson syncResult).compress}"
    if syncResult.readiness.blockingErrorCount != 0 then
      throw <| IO.userError
        s!"expected sync_file blocking error count = 0, got {(toJson syncResult).compress}"
    let syncProgress := ← requireAnyStreamFileProgress "sync_file" syncMessages
    let some syncLast := syncProgress.back?
      | throw <| IO.userError "expected sync_file fileProgress tail"
    if !syncLast.done then
      throw <| IO.userError s!"expected sync_file final fileProgress to be done, got {(toJson syncLast).compress}"
    let syncDiagnostics ← requireAnyStreamDiagnostics "sync_file" syncMessages
    expectDiagnosticsForPath "sync_file" "SaveSmoke/B.lean" syncDiagnostics

    let syncReplyMessages ← requireSuccessStream "sync_file include diagnostics" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      diagnosticScope? := some .all
      diagnosticsInResult? := some true
    }
    let syncReplyResp ← requireFinalStreamResponse "sync_file include diagnostics" syncReplyMessages
    let syncReplyPayload ← expectOk syncReplyResp
    let syncReplyResult ← requireSyncFileResult "sync_file include diagnostics" syncReplyPayload
    let some replyDiagnostics := syncReplyResult.diagnostics.items?
      | throw <| IO.userError "expected sync_file final diagnostic items"
    if replyDiagnostics.isEmpty then
      throw <| IO.userError
        s!"expected sync_file include diagnostics to replay diagnostics, got {syncReplyPayload.compress}"
    expectDiagnosticsForPath "sync_file include diagnostics" "SaveSmoke/B.lean" replyDiagnostics
    expectWarningDiagnosticPresent "sync_file include diagnostics" replyDiagnostics

    writeSaveWarningFile root "-- request-stream save"
    let saveMessages ← requireSuccessStream "save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      diagnosticScope? := some .all
    }
    let saveResp ← requireFinalStreamResponse "save_olean" saveMessages
    let savePayload ← expectOk saveResp
    expectNoReplayDiagnosticsField "save_olean" savePayload
    let saveVersion ← IO.ofExcept <| savePayload.getObjValAs? Nat "version"
    if saveVersion != 2 then
      throw <| IO.userError s!"expected save_olean version 2, got {saveVersion}"
    let saveDiagnostics ← requireAnyStreamDiagnostics "save_olean" saveMessages
    expectNonErrorDiagnosticsForPath "save_olean" "SaveSmoke/B.lean" saveDiagnostics

    writeSaveWarningFile root "-- request-stream close-save"
    let closeMessages ← requireSuccessStream "close-save" <| ← runRequestStream port {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      saveArtifacts? := some true
      diagnosticScope? := some .all
    }
    let closeResp ← requireFinalStreamResponse "close-save" closeMessages
    let closePayload ← expectOk closeResp
    expectNoReplayDiagnosticsField "close-save" closePayload
    let closed ← IO.ofExcept <| closePayload.getObjValAs? Bool "closed"
    if !closed then
      throw <| IO.userError s!"expected close-save payload to report closed = true, got {closePayload.compress}"
    let savedPayload ← IO.ofExcept <| closePayload.getObjVal? "saved"
    let closeVersion ← IO.ofExcept <| savedPayload.getObjValAs? Nat "version"
    if closeVersion != 3 then
      throw <| IO.userError s!"expected close-save saved version 3, got {closeVersion}"
    let closeDiagnostics ← requireAnyStreamDiagnostics "close-save" closeMessages
    expectNonErrorDiagnosticsForPath "close-save" "SaveSmoke/B.lean" closeDiagnostics

    let standalonePath := root / "StandaloneSaveSmoke.lean"
    IO.FS.writeFile standalonePath "import SaveSmoke.B\n\n#check bVal\n"
    let standaloneSyncMessages ← requireSuccessStream "standalone sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "StandaloneSaveSmoke.lean"
    }
    let standaloneSyncResp ← requireFinalStreamResponse "standalone sync_file" standaloneSyncMessages
    discard <| expectOk standaloneSyncResp

    let standaloneSaveMessages ← requireFailedStream "standalone save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "StandaloneSaveSmoke.lean"
    }
    let standaloneSaveResp ← requireFinalStreamResponse "standalone save_olean" standaloneSaveMessages
    expectErrorCode "standalone save_olean" Beam.Broker.saveTargetNotModuleCode standaloneSaveResp

    buildLakeTarget root "SaveSmoke/A.lean"
    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"

    let staleSyncMessages ← requireFailedStream "stale sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    let staleSyncResp ← requireFinalStreamResponse "stale sync_file" staleSyncMessages
    expectErrorCode "stale sync_file" Beam.Broker.syncBarrierIncompleteCode staleSyncResp
    discard <| requireFileProgress "stale sync_file terminal response" staleSyncResp

    let staleSaveMessages ← requireFailedStream "stale save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    let staleSaveResp ← requireFinalStreamResponse "stale save_olean" staleSaveMessages
    expectErrorCode "stale save_olean" Beam.Broker.syncBarrierIncompleteCode staleSaveResp
    discard <| requireFileProgress "stale save_olean terminal response" staleSaveResp

    let staleCloseMessages ← requireFailedStream "stale close-save" <| ← runRequestStream port {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
      saveArtifacts? := some true
    }
    let staleCloseResp ← requireFinalStreamResponse "stale close-save" staleCloseMessages
    expectErrorCode "stale close-save" Beam.Broker.syncBarrierIncompleteCode staleCloseResp
    discard <| requireFileProgress "stale close-save terminal response" staleCloseResp

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := 1\n"
    buildLakeTarget root "SaveSmoke/A.lean"
    discard <| expectOk <| ← runClient endpoint {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    let staleTraceSyncResp ← runClient endpoint {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    discard <| expectOk staleTraceSyncResp
    writeSaveWarningFile root "-- request-stream stale trace"

    let staleTraceSaveMessages ← requireFailedStream "stale trace save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    let staleTraceSaveResp ← requireFinalStreamResponse "stale trace save_olean" staleTraceSaveMessages
    expectErrorCode "stale trace save_olean" Beam.Broker.saveTraceStaleCode staleTraceSaveResp
    discard <| expectOk (← runClient endpoint { op := .stats })

    discard <| expectOk (← runClient endpoint { op := .shutdown })
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    discard <| broker.tryWait
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

end BeamTest.Broker.RequestStreamContractTest
