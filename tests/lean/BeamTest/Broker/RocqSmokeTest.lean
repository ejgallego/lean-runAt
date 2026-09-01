/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import BeamTest.Broker.TestUtil
import Lean

open Lean

namespace BeamTest.Broker.RocqSmokeTest

open BeamTest.Broker.TestUtil

private def repoRoot : IO System.FilePath := do
  IO.FS.realPath <| System.FilePath.mk "."

private def rocqRoot : IO System.FilePath := do
  IO.FS.realPath <| (← repoRoot) / "tests" / "rocq" / "Minimal"

private def expectTwoTrueGoals (payload : Json) : IO Unit := do
  let goalConfig ← IO.ofExcept <| payload.getObjVal? "goals"
  let goals ← IO.ofExcept <| goalConfig.getObjVal? "goals"
  let .arr goals := goals
    | throw <| IO.userError s!"expected goals array, got {goals.compress}"
  if goals.size != 2 then
    throw <| IO.userError s!"expected 2 goals, got {goals.size}: {payload.compress}"
  for goal in goals do
    let ty ← IO.ofExcept <| goal.getObjValAs? String "ty"
    if ty.trimAscii != "True" then
      throw <| IO.userError s!"expected goal type True, got {ty}"

private def expectNonemptyError (payload : Json) : IO Unit := do
  let err ← IO.ofExcept <| payload.getObjVal? "error"
  match err with
  | .str text =>
      if text.trimAscii.isEmpty then
        throw <| IO.userError s!"expected non-empty error field, got {payload.compress}"
  | .arr items =>
      if items.isEmpty then
        throw <| IO.userError s!"expected non-empty structured error field, got {payload.compress}"
  | .null =>
      throw <| IO.userError s!"expected non-empty error field, got {payload.compress}"
  | _ =>
      pure ()

private def expectSurfacedError (resp : Beam.Broker.Response) : IO Unit := do
  if resp.ok then
    throw <| IO.userError s!"expected broker error, got success {(toJson resp).compress}"
  let some err := resp.error?
    | throw <| IO.userError s!"expected broker error payload, got {(toJson resp).compress}"
  if err.code == "internalError" then
    throw <| IO.userError s!"expected surfaced Rocq error, got internalError: {err.message}"
  if err.message.trimAscii.isEmpty then
    throw <| IO.userError s!"expected non-empty surfaced Rocq error, got {(toJson resp).compress}"

private def updateVersion
    (endpoint : Beam.Broker.Endpoint)
    (path : String) : IO Nat := do
  let resp ← runClient endpoint {
    op := .updateFile
    backend := .rocq
    path? := some path
  }
  let result ← requireUpdateFileResult s!"rocq update version for {path}" (← expectOk resp)
  pure result.version

def main : IO Unit := do
  let endpoint ← freshTcpEndpoint
  let root ← rocqRoot
  let broker ← spawnRocqBroker endpoint root ((← IO.getEnv "BEAM_ROCQ_CMD").getD "coq-lsp")
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint { op := .ensure, backend := .rocq })
    let unsupportedSync ← runClient endpoint {
      op := .syncFile
      backend := .rocq
      path? := some "Demo.v"
    }
    expectErrCode unsupportedSync "invalidParams"
    let demoVersion ← updateVersion endpoint "Demo.v"
    let semiVersion ← updateVersion endpoint "Semi.v"
    let errorVersion ← updateVersion endpoint "Error.v"
    let doneVersion ← updateVersion endpoint "Done.v"
    let goals ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      path? := some "Demo.v"
      version? := some demoVersion
      line? := some 2
      character? := some 8
      mode? := some .after
      compact? := some false
    }
    expectTwoTrueGoals goals

    let semiGoals ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      path? := some "Semi.v"
      version? := some semiVersion
      line? := some 2
      character? := some 3
      mode? := some .before
      text? := some "split."
      compact? := some false
    }
    expectTwoTrueGoals semiGoals

    let errorGoals ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      path? := some "Error.v"
      version? := some errorVersion
      line? := some 2
      character? := some 8
      mode? := some .after
      compact? := some false
    }
    expectTwoTrueGoals errorGoals

    let errorPayload ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      path? := some "Error.v"
      version? := some errorVersion
      line? := some 4
      character? := some 2
      mode? := some .after
      compact? := some false
    }
    expectNonemptyError errorPayload

    let zeroGoalResp ← runClient endpoint {
      op := .goals
      backend := .rocq
      path? := some "Done.v"
      version? := some doneVersion
      line? := some 3
      character? := some 0
      mode? := some .before
      text? := some "exact I."
      compact? := some false
    }
    expectSurfacedError zeroGoalResp

    let stats ← expectOk <| ← runClient endpoint {
      op := .stats
      workspaceId? := some testWorkspaceId
    }
    expectOpCountAtLeast stats "rocq" "goals" 5
    discard <| expectOk <| ← runClient endpoint { op := .shutdown }
  finally
    try
      broker.kill
    catch _ =>
      pure ()

end BeamTest.Broker.RocqSmokeTest

def main := BeamTest.Broker.RocqSmokeTest.main
