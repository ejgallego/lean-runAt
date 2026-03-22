/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario
import RunAt.Internal.DirectImports
import RunAt.Internal.SaveSupport

open Lean
open RunAtTest.Scenario

namespace RunAtTest.RequestSurfaceTest

private def expectFileExists (label : String) (path : System.FilePath) : ScenarioM Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"{label}: expected file {path} to exist"

private def requireSingleGoalTarget (label expectedNeedle : String) (state : RunAt.ProofState) :
    ScenarioM Unit := do
  let some goal := state.goals[0]?
    | throw <| IO.userError s!"{label}: expected one goal"
  unless goal.target.contains expectedNeedle do
    throw <| IO.userError s!"{label}: expected target to contain '{expectedNeedle}', got '{goal.target}'"

private def mkTmpDir (stem : String) : ScenarioM System.FilePath := do
  let dir := System.FilePath.mk s!"/tmp/{stem}-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  pure dir

private def checkGoalsRequests : ScenarioM Unit := do
  let doc ← openDoc "tests/save_olean_project/GoalSmoke.lean"

  let goalsPrevReq ← sendGoals doc { line := 1, character := 2, useAfter := false }
  let goalsPrev : RunAt.ProofState ← awaitResponseAs goalsPrevReq
  if goalsPrev.goals.size != 1 then
    throw <| IO.userError s!"goals prev: expected one goal, got {goalsPrev.goals.size}"
  requireSingleGoalTarget "goals prev" "True" goalsPrev

  let goalsAfterReq ← sendGoals doc { line := 1, character := 2, useAfter := true }
  let goalsAfter : RunAt.ProofState ← awaitResponseAs goalsAfterReq
  if goalsAfter.goals.size != 0 then
    throw <| IO.userError s!"goals after: expected solved proof state, got {goalsAfter.goals.size} goals"

  closeDoc doc

private def checkDirectImportsAndSave : ScenarioM Unit := do
  let doc ← openDoc "RunAtTest/Deps/DepA.lean"

  let importsReq ← sendDirectImports doc
  let imports : RunAt.Internal.DirectImportsResult ← awaitResponseAs importsReq
  if imports.version != 1 then
    throw <| IO.userError s!"directImports: expected version 1, got {imports.version}"
  if imports.imports != #["RunAtTest.Deps.DepB"] then
    throw <| IO.userError s!"directImports: unexpected imports {(toJson imports.imports).compress}"

  let readinessReq ← sendSaveReadiness doc
  let readiness : RunAt.Internal.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError s!"saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  if readiness.saveReadyReason != "ok" then
    throw <| IO.userError s!"saveReadiness: expected reason = ok, got {readiness.saveReadyReason}"

  let outDir ← mkTmpDir "runat-request-surface"
  let saveReq ← sendSaveArtifacts doc {
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }
  let saved : RunAt.Internal.SaveArtifactsResult ← awaitResponseAs saveReq
  if !saved.written then
    throw <| IO.userError "saveArtifacts: expected written = true"
  if saved.version != 1 then
    throw <| IO.userError s!"saveArtifacts: expected version 1, got {saved.version}"
  expectFileExists "saveArtifacts olean" (outDir / "DepA.olean")
  expectFileExists "saveArtifacts ilean" (outDir / "DepA.ilean")
  expectFileExists "saveArtifacts c" (outDir / "DepA.c")

  changeDoc doc {
    line := 8
    character := 18
    delete := "depB"
    insert := "\"oops\""
  }
  syncDoc doc

  let brokenReq ← sendSaveReadiness doc
  let broken : RunAt.Internal.SaveReadinessResult ← awaitResponseAs brokenReq
  if broken.saveReady then
    throw <| IO.userError s!"broken saveReadiness: expected saveReady = false, got {(toJson broken).compress}"
  if broken.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"broken saveReadiness: expected reason = documentErrors, got {broken.saveReadyReason}"
  if broken.diagnosticErrorCount == 0 then
    throw <| IO.userError s!"broken saveReadiness: expected diagnosticErrorCount > 0, got {(toJson broken).compress}"

  closeDoc doc

def main : IO Unit := RunAtTest.Scenario.run do
  checkGoalsRequests
  checkDirectImportsAndSave

end RunAtTest.RequestSurfaceTest

def main := RunAtTest.RequestSurfaceTest.main
