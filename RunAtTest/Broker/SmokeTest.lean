/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import RunAt.Lib.NativeLib
import RunAtTest.Broker.TestUtil
import Lean

set_option maxRecDepth 4096

open Lean

namespace RunAtTest.Broker.SmokeTest

open RunAtTest.Broker.TestUtil

private def repoRoot : IO System.FilePath := do
  IO.FS.realPath <| System.FilePath.mk "."

private def leanCmd : IO String := do
  pure "lean"

private def ensurePluginSharedBuilt (root : System.FilePath) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "lake"
    args := #["build", "RunAt:shared"]
    cwd := root.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to build RunAt:shared for smoke test\n{out.stderr}"

private def pluginPath : IO System.FilePath := do
  let root ← repoRoot
  ensurePluginSharedBuilt root
  IO.FS.realPath <| RunAt.Lib.pluginSharedLibPath (root / ".lake" / "build" / "lib")

private def expectModuleNames (payload : Json) (field : String) (expected : List String) : IO Unit := do
  let arr ← IO.ofExcept <| payload.getObjVal? field
  let .arr arr := arr
    | throw <| IO.userError s!"expected array for {field}, got {arr.compress}"
  let names ← arr.mapM fun item => do
    let moduleJson ← IO.ofExcept <| item.getObjVal? "module"
    IO.ofExcept <| moduleJson.getObjValAs? String "name"
  for want in expected do
    unless names.contains want do
      throw <| IO.userError s!"expected {field} to contain {want}, got {names}"

private def expectStringContains (label haystack needle : String) : IO Unit := do
  unless haystack.contains needle do
    throw <| IO.userError s!"expected {label} to contain '{needle}', got '{haystack}'"

private def requireErrorMessage (label : String) (resp : Beam.Broker.Response) : IO String := do
  match resp.error? with
  | some err => pure err.message
  | none => throw <| IO.userError s!"expected {label} to contain an error payload"

private def expectClientRequestId (label : String) (actual expected : Option String) : IO Unit := do
  unless actual == expected do
    throw <| IO.userError s!"expected {label} clientRequestId {expected}, got {actual}"

private def expectProgressIds
    (label : String)
    (events : Array ProgressEvent)
    (expected : Option String) : IO Unit := do
  for event in events do
    expectClientRequestId label event.clientRequestId? expected

private def awaitTask (label : String) (task : Task (Except IO.Error α)) : IO α := do
  match (← IO.wait task) with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label} failed: {err}"

private def relativePathString (root path : System.FilePath) : String :=
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  if pathStr.startsWith rootPrefix then
    (pathStr.drop rootPrefix.length).toString
  else
    pathStr

private def writeStandaloneErrorFile (root : System.FilePath) : IO System.FilePath := do
  let dir := root / ".tmp" / s!"beam-daemon-error-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "ErrorOnly.lean"
  IO.FS.writeFile path "def brokenVal : Nat := \"broken\"\n"
  pure path

private def writeSlowSyncFile (root : System.FilePath) : IO System.FilePath := do
  let dir := root / ".tmp" / s!"beam-daemon-slow-sync-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "SlowSync.lean"
  IO.FS.writeFile path <| String.intercalate "\n" [
    "import Lean",
    "",
    "open Lean Elab Command",
    "",
    "elab \"progress_sleep_cmd\" : command => do",
    "  IO.sleep 1500",
    "",
    "def partialProgressAnchor : Nat := 0",
    "",
    "progress_sleep_cmd",
    "",
    "def partialProgressDone : Nat := partialProgressAnchor + 1",
    ""
  ]
  pure path

private def runSyncSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let syncRequestId := some "smoke-sync"
  let (syncResp, syncEvents) ← runClientWithProgress endpoint {
    op := .syncFile
    clientRequestId? := syncRequestId
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
  }
  let syncRes : Beam.Broker.SyncFileResult ← IO.ofExcept <| fromJson? (← expectOk syncResp)
  if syncRes.version != 1 then
    throw <| IO.userError s!"expected sync_file version 1, got {syncRes.version}"
  if !syncRes.saveReady then
    throw <| IO.userError
      s!"expected sync_file saveReady = true for clean module, got {(toJson syncRes).compress}"
  if syncRes.stateErrorCount != 0 || syncRes.stateCommandErrorCount != 0 then
    throw <| IO.userError
      s!"expected sync_file state error counts to be zero for clean module, got {(toJson syncRes).compress}"
  let syncTop := ← requireFileProgress "sync_file" syncResp
  expectClientRequestId "sync_file response" syncResp.clientRequestId? syncRequestId
  if !syncTop.done then
    throw <| IO.userError s!"expected top-level sync_file fileProgress.done = true, got {(toJson syncTop).compress}"
  let some syncLast := syncEvents.back?
    | throw <| IO.userError "expected sync_file to stream fileProgress events"
  expectClientRequestId "sync_file progress" syncLast.clientRequestId? syncRequestId
  if !syncLast.progress.done then
    throw <| IO.userError s!"expected final streamed sync_file progress to be done, got {(toJson syncLast.progress).compress}"
  let syncRespAgain ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
  }
  let syncResAgain : Beam.Broker.SyncFileResult ← IO.ofExcept <| fromJson? (← expectOk syncRespAgain)
  if syncResAgain.version != 1 then
    throw <| IO.userError s!"expected unchanged sync_file version 1, got {syncResAgain.version}"
  let syncTopAgain := ← requireFileProgress "unchanged sync_file" syncRespAgain
  if !syncTopAgain.done then
    throw <| IO.userError s!"expected unchanged sync_file fileProgress.done = true, got {(toJson syncTopAgain).compress}"

private def runErrorOnlySyncSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let errorPath ← writeStandaloneErrorFile root
  let errorRel := relativePathString root errorPath
  let (errorResp, errorProgress, errorDiagnostics) ← runClientWithStream endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some errorPath.toString
  }
  let errorRes : Beam.Broker.SyncFileResult ← IO.ofExcept <| fromJson? (← expectOk errorResp)
  if errorRes.version != 1 then
    throw <| IO.userError s!"expected error-only sync_file version 1, got {errorRes.version}"
  if errorRes.saveReady then
    throw <| IO.userError
      s!"expected error-only sync_file saveReady = false, got {(toJson errorRes).compress}"
  if errorRes.stateErrorCount == 0 then
    throw <| IO.userError
      s!"expected error-only sync_file stateErrorCount > 0, got {(toJson errorRes).compress}"
  if errorRes.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"expected error-only sync_file saveReadyReason = documentErrors, got {(toJson errorRes).compress}"
  let some errorLast := errorProgress.back?
    | throw <| IO.userError "expected error-only sync_file to stream fileProgress events"
  if !errorLast.done then
    throw <| IO.userError s!"expected error-only sync_file progress to finish, got {(toJson errorLast).compress}"
  if errorDiagnostics.isEmpty then
    throw <| IO.userError "expected error-only sync_file to stream error diagnostics"
  unless errorDiagnostics.all (fun diagnostic => diagnostic.severity? == some .error) do
    throw <| IO.userError s!"expected error-only sync_file to stream only errors by default, got {(toJson errorDiagnostics).compress}"
  unless errorDiagnostics.all (fun diagnostic => diagnostic.path == errorRel) do
    throw <| IO.userError s!"expected error-only sync_file paths to match {errorRel}, got {(toJson errorDiagnostics).compress}"

private def runPartialProgressSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let partialRequestId := some "smoke-partial"
  let (partialResp, partialEvents) ← runClientWithProgress endpoint {
    op := .runAt
    clientRequestId? := partialRequestId
    root? := some root.toString
    path? := some "tests/scenario/docs/PartialProgress.lean"
    line? := some 7
    character? := some 2
    text? := some "#check partialProgressAnchor"
  }
  let partialRes ← expectOk partialResp
  let .ok true := partialRes.getObjValAs? Bool "success" | throw <| IO.userError "partial run_at did not succeed"
  let partialProgress := ← requireFileProgress "partial run_at" partialResp
  expectClientRequestId "partial run_at response" partialResp.clientRequestId? partialRequestId
  if partialProgress.done then
    throw <| IO.userError s!"expected partial run_at fileProgress.done = false, got {(toJson partialProgress).compress}"
  if partialProgress.updates == 0 then
    throw <| IO.userError s!"expected partial run_at to report at least one fileProgress update, got {(toJson partialProgress).compress}"
  let some partialLast := partialEvents.back?
    | throw <| IO.userError "expected partial run_at to stream fileProgress events"
  expectClientRequestId "partial run_at progress" partialLast.clientRequestId? partialRequestId
  if partialLast.progress.done then
    throw <| IO.userError s!"expected final streamed partial run_at progress to stay incomplete, got {(toJson partialLast.progress).compress}"

private def runConcurrentSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let concurrentSyncId := some "concurrent-sync"
  let concurrentHoverId := some "concurrent-hover"
  let slowSyncPath ← writeSlowSyncFile root
  let syncTask ← IO.asTask <| runClientWithProgress endpoint {
    op := .syncFile
    clientRequestId? := concurrentSyncId
    root? := some root.toString
    path? := some slowSyncPath.toString
  }
  IO.sleep 200
  let hoverStartedAt ← IO.monoNanosNow
  let (hoverResp, hoverEvents) ← runClientWithProgress endpoint {
    op := .requestAt
    clientRequestId? := concurrentHoverId
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/hover"
  }
  let _hoverLatencyMs := ((← IO.monoNanosNow) - hoverStartedAt) / 1000000
  let hoverPayload ← expectOk hoverResp
  expectClientRequestId "concurrent hover response" hoverResp.clientRequestId? concurrentHoverId
  expectProgressIds "concurrent hover progress" hoverEvents concurrentHoverId
  let hoverContents ← IO.ofExcept <| hoverPayload.getObjVal? "contents"
  let hoverValue ← IO.ofExcept <| hoverContents.getObjValAs? String "value"
  expectStringContains "concurrent hover markdown" hoverValue "answerA : Nat"
  let (concurrentSyncResp, concurrentSyncEvents) ← awaitTask "concurrent sync_file" syncTask
  let concurrentSyncTop := ← requireFileProgress "concurrent sync_file" concurrentSyncResp
  expectClientRequestId "concurrent sync_file response" concurrentSyncResp.clientRequestId? concurrentSyncId
  expectProgressIds "concurrent sync_file progress" concurrentSyncEvents concurrentSyncId
  if !concurrentSyncTop.done then
    throw <| IO.userError
      s!"expected concurrent sync_file fileProgress.done = true, got {(toJson concurrentSyncTop).compress}"

private def runRequestAndGoalsSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let cmdResp ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 2
    text? := some "#check answerA"
  }
  let cmdRes ← expectOk cmdResp
  let .ok true := cmdRes.getObjValAs? Bool "success" | throw <| IO.userError "run_at did not succeed"

  let requestAtHoverResp ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/hover"
  }
  let requestAtHover ← expectOk requestAtHoverResp
  discard <| requireFileProgress "request_at hover" requestAtHoverResp
  let hoverContents ← IO.ofExcept <| requestAtHover.getObjVal? "contents"
  let hoverValue ← IO.ofExcept <| hoverContents.getObjValAs? String "value"
  expectStringContains "request_at hover markdown" hoverValue "answerA : Nat"

  let goalsPrevResp ← runClient endpoint {
    op := .goals
    root? := some root.toString
    path? := some "tests/scenario/docs/SimpleProof.lean"
    line? := some 1
    character? := some 2
    mode? := some .prev
  }
  let goalsPrev ← expectOk goalsPrevResp
  discard <| requireFileProgress "goals prev" goalsPrevResp
  let prevGoals ← IO.ofExcept <| goalsPrev.getObjVal? "goals"
  let .arr prevGoals := prevGoals
    | throw <| IO.userError s!"expected goals prev result to be an array, got {prevGoals.compress}"
  if prevGoals.size != 1 then
    throw <| IO.userError s!"expected one previous goal, got {(Json.arr prevGoals).compress}"
  let prevTarget ← IO.ofExcept <| prevGoals[0]!.getObjValAs? String "target"
  expectStringContains "goals prev target" prevTarget "True"

  let goalsAfterResp ← runClient endpoint {
    op := .goals
    root? := some root.toString
    path? := some "tests/scenario/docs/SimpleProof.lean"
    line? := some 1
    character? := some 2
    mode? := some .after
  }
  let goalsAfter ← expectOk goalsAfterResp
  discard <| requireFileProgress "goals after" goalsAfterResp
  let afterGoals := ← IO.ofExcept <| goalsAfter.getObjVal? "goals"
  if afterGoals != Json.arr #[] then
    throw <| IO.userError s!"expected no goals after trivial, got {afterGoals.compress}"

  let requestAtRefsResp ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/references"
    params? := some <| Json.mkObj [
      ("context", Json.mkObj [("includeDeclaration", toJson true)])
    ]
  }
  discard <| expectOk requestAtRefsResp

  let requestAtUnsupported ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/completion"
    params? := some <| Json.mkObj []
  }
  expectErrCode requestAtUnsupported "invalidParams"
  let unsupportedMsg ← requireErrorMessage "request_at unsupported" requestAtUnsupported
  expectStringContains "request_at unsupported error" unsupportedMsg "does not support 'textDocument/completion'"

  let requestAtBadTextDocument ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/hover"
    params? := some <| Json.mkObj [
      ("textDocument", Json.mkObj [("uri", toJson ("file:///tmp/nope.lean" : String))])
    ]
  }
  expectErrCode requestAtBadTextDocument "invalidParams"
  let badTextDocumentMsg ← requireErrorMessage "request_at textDocument override" requestAtBadTextDocument
  expectStringContains "request_at textDocument override error" badTextDocumentMsg "'params' must not include 'textDocument'"

  let requestAtBadPosition ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/hover"
    params? := some <| Json.mkObj [
      ("position", Json.mkObj [("line", toJson (99 : Nat)), ("character", toJson (0 : Nat))])
    ]
  }
  expectErrCode requestAtBadPosition "invalidParams"
  let badPositionMsg ← requireErrorMessage "request_at position override" requestAtBadPosition
  expectStringContains "request_at position override error" badPositionMsg "'params' must not include 'position'"

private def runCancelSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let slowRequestId := some "cancel-slow"
  let slowTask ← IO.asTask <| runClientWithProgress endpoint {
    op := .runAt
    clientRequestId? := slowRequestId
    root? := some root.toString
    path? := some "tests/scenario/docs/SlowPoll.lean"
    line? := some 25
    character? := some 2
    text? := some "poll_sleep_cmd"
  }
  IO.sleep 200
  let cancelResp ← runClient endpoint {
    op := .cancel
    root? := some root.toString
    cancelRequestId? := slowRequestId
  }
  let cancelPayload ← expectOk cancelResp
  let .ok true := cancelPayload.getObjValAs? Bool "cancelled"
    | throw <| IO.userError s!"expected cancel response to report cancelled=true, got {cancelPayload.compress}"
  let (slowResp, slowEvents) ← awaitTask "cancel slow run_at" slowTask
  expectErrCode slowResp "requestCancelled"
  expectClientRequestId "cancelled run_at response" slowResp.clientRequestId? slowRequestId
  expectProgressIds "cancelled run_at progress" slowEvents slowRequestId

  let postCancelHoverResp ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/hover"
  }
  let postCancelHover ← expectOk postCancelHoverResp
  let postCancelHoverContents ← IO.ofExcept <| postCancelHover.getObjVal? "contents"
  let postCancelHoverValue ← IO.ofExcept <| postCancelHoverContents.getObjValAs? String "value"
  expectStringContains "post-cancel hover markdown" postCancelHoverValue "answerA : Nat"

private def runWorkerExitSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let handleSeed ← expectOk <| ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    line? := some 0
    character? := some 27
    text? := some "constructor"
    storeHandle? := some true
  }
  let handleJson ← IO.ofExcept <| handleSeed.getObjVal? "handle"
  let staleHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? handleJson

  let workerExitRequestId := some "worker-exit-slow"
  let slowTask ← IO.asTask <| runClientWithProgress endpoint {
    op := .runAt
    clientRequestId? := workerExitRequestId
    root? := some root.toString
    path? := some "tests/scenario/docs/SlowPoll.lean"
    line? := some 25
    character? := some 2
    text? := some "poll_sleep_cmd"
  }
  IO.sleep 200
  killLeanServerForEndpoint endpoint root
  let (slowResp, slowEvents) ← awaitTask "worker-exit slow run_at" slowTask
  expectErrCode slowResp "workerExited"
  expectClientRequestId "worker-exit run_at response" slowResp.clientRequestId? workerExitRequestId
  expectProgressIds "worker-exit run_at progress" slowEvents workerExitRequestId

  let restartHoverResp ← runClient endpoint {
    op := .requestAt
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
    line? := some 0
    character? := some 4
    method? := some "textDocument/hover"
  }
  let restartHover ← expectOk restartHoverResp
  let restartHoverContents ← IO.ofExcept <| restartHover.getObjVal? "contents"
  let restartHoverValue ← IO.ofExcept <| restartHoverContents.getObjValAs? String "value"
  expectStringContains "post-restart hover markdown" restartHoverValue "answerA : Nat"

  let staleAfterRestart ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some staleHandle
    text? := some "exact trivial"
  }
  expectErrCode staleAfterRestart "contentModified"

private def runHandleAndDepsSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let proofRes ← expectOk <| ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    line? := some 0
    character? := some 27
    text? := some "constructor"
    storeHandle? := some true
  }
  let handleJson ← IO.ofExcept <| proofRes.getObjVal? "handle"
  let handle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? handleJson
  let proofNext ← expectOk <| ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some handle
    text? := some "exact trivial"
    storeHandle? := some true
  }
  let nextHandleJson ← IO.ofExcept <| proofNext.getObjVal? "handle"
  let nextHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? nextHandleJson
  let proofDone ← expectOk <| ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some nextHandle
    text? := some "exact trivial"
  }
  let goals ← IO.ofExcept <| proofDone.getObjVal? "proofState"
  let goals := (← IO.ofExcept <| goals.getObjVal? "goals")
  if goals != Json.arr #[] then
    throw <| IO.userError s!"expected no goals, got {goals.compress}"

  discard <| expectOk <| ← runClient endpoint {
    op := .release
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some handle
  }
  let stale ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some handle
    text? := some "exact trivial"
  }
  expectErrCode stale "invalidParams"
  let deps ← expectOk <| ← runClient endpoint {
    op := .deps
    root? := some root.toString
    path? := some "RunAtTest/Deps/DepB.lean"
  }
  expectModuleNames deps "imports" ["RunAtTest.Deps.DepC"]
  expectModuleNames deps "importedBy" ["RunAtTest.Deps.DepA"]
  expectModuleNames deps "importClosure" ["RunAtTest.Deps.DepC"]
  expectModuleNames deps "importedByClosure" ["RunAtTest.Deps.DepA"]

private def runSaveAndStatsSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let saveResp ← runClient endpoint {
    op := .saveOlean
    root? := some root.toString
    path? := some "RunAtTest/Deps/DepA.lean"
  }
  let savePayload ← expectOk saveResp
  let saveVersion ← IO.ofExcept <| savePayload.getObjValAs? Nat "version"
  if saveVersion != 1 then
    throw <| IO.userError s!"expected save_olean version = 1, got {saveVersion}"
  let saveHash ← IO.ofExcept <| savePayload.getObjValAs? String "sourceHash"
  if saveHash.isEmpty then
    throw <| IO.userError "expected save_olean sourceHash to be present"
  let saveProgress := ← requireFileProgress "save_olean" saveResp
  if !saveProgress.done then
    throw <| IO.userError s!"expected save_olean fileProgress.done = true, got {(toJson saveProgress).compress}"

  let stats ← expectOk <| ← runClient endpoint { op := .stats }
  expectOpCountAtLeast stats "lean" "sync_file" 1
  expectOpCountAtLeast stats "lean" "run_at" 3
  expectOpCountAtLeast stats "lean" "request_at" 5
  expectOpCountAtLeast stats "lean" "goals" 2
  expectOpCountAtLeast stats "lean" "run_with" 3
  expectOpCountAtLeast stats "lean" "release" 1
  expectOpCountAtLeast stats "lean" "deps" 1
  expectOpCountAtLeast stats "lean" "save_olean" 1
  expectBackendMetricAtLeast stats "lean" "cancelledCount" 1
  expectBackendMetricAtLeast stats "lean" "workerExitedCount" 1
  expectBackendMetricAtLeast stats "lean" "sessionRestarts" 1
  expectOpMetricAtLeast stats "lean" "run_at" "cancelledCount" 1
  expectOpMetricAtLeast stats "lean" "run_at" "workerExitedCount" 1

def smokeMain : IO Unit := do
  let port : UInt16 := ((← IO.monoNanosNow) % 20000 + 30000).toUInt16
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← repoRoot
  let otherRoot ← IO.FS.realPath <| root / "tests" / "save_olean_project"
  let broker ← spawnLeanBrokerWithPlugin endpoint root (← pluginPath) (← leanCmd)
  try
    waitForBrokerReady endpoint
    discard <| expectOk (← runClient endpoint { op := .ensure, root? := some root.toString })
    let rootMismatch ← runClient endpoint { op := .ensure, root? := some otherRoot.toString }
    expectErrCode rootMismatch "invalidParams"
    discard <| expectOk (← runClient endpoint { op := .resetStats })
    runSyncSmoke endpoint root
    runErrorOnlySyncSmoke endpoint root
    runPartialProgressSmoke endpoint root
    runConcurrentSmoke endpoint root
    runRequestAndGoalsSmoke endpoint root
    runCancelSmoke endpoint root
    runWorkerExitSmoke endpoint root
    runHandleAndDepsSmoke endpoint root
    runSaveAndStatsSmoke endpoint root

    let shutdownResp ← runClient endpoint { op := .shutdown }
    discard <| expectOk shutdownResp
  finally
    try
      broker.kill
    catch _ =>
      pure ()

end RunAtTest.Broker.SmokeTest
