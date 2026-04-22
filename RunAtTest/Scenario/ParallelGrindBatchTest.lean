/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAt.Internal.SaveSupport
import RunAtTest.Scenario

open Lean
open Lean.Lsp
open RunAtTest.Scenario

namespace RunAtTest.Scenario.ParallelGrindBatchTest

private def fixturePath : System.FilePath :=
  System.FilePath.mk "tests/scenario/docs/ParallelGrind10.lean"

private def sorryWarning : String :=
  "declaration uses `sorry`"

private def insertedText : String :=
  "slow_grind"

private def reportJson
    (runAtBatchWallTimeUs changeBatchILeansWallTimeUs : Nat)
    (scannedSorryCount declarationSorryDiagnosticCount finalDiagnosticCount remainingSorryCount : Nat)
    (saveReady : RunAt.Internal.SaveReadinessResult) : Json :=
  Json.mkObj [
    ("kind", toJson ("parallelGrindBatchReport" : String)),
    ("fixture", toJson fixturePath.toString),
    ("runAtBatchWallTimeUs", toJson runAtBatchWallTimeUs),
    ("changeBatchILeansWallTimeUs", toJson changeBatchILeansWallTimeUs),
    ("scannedSorryCount", toJson scannedSorryCount),
    ("declarationSorryDiagnosticCount", toJson declarationSorryDiagnosticCount),
    ("finalDiagnosticCount", toJson finalDiagnosticCount),
    ("remainingSorryDiagnosticCount", toJson remainingSorryCount),
    ("saveReady", toJson saveReady.saveReady),
    ("saveReadyReason", toJson saveReady.saveReadyReason),
    ("diagnosticErrorCount", toJson saveReady.diagnosticErrorCount),
    ("commandErrorCount", toJson saveReady.commandErrorCount)
  ]

private def sortChangesDescending (changes : Array ChangeSpec) : Array ChangeSpec :=
  changes.qsort fun a b =>
    if a.line == b.line then
      a.character > b.character
    else
      a.line > b.line

private def fixtureLines : IO (Array String) := do
  return (← IO.FS.readFile fixturePath).splitOn "\n" |>.toArray

private def leadingSpaces (line : String) : Nat :=
  line.toList.takeWhile (· == ' ') |>.length

private def findSorryColumns (line : String) : Array Nat := Id.run do
  let parts := (line.splitOn "sorry").toArray
  let mut cols := #[]
  let mut offset := 0
  for i in [:parts.size] do
    if i + 1 < parts.size then
      let some part := parts[i]?
        | panic! "splitOn index out of bounds"
      cols := cols.push (offset + part.length)
      offset := offset + part.length + "sorry".length
  cols

private def extractSorryChanges (lines : Array String) (diagnostics : PublishDiagnosticsParams) :
    ScenarioM (Array ChangeSpec) := do
  let sorryDiags := diagnostics.diagnostics.filter (fun diag => diag.message.contains sorryWarning)
  if sorryDiags.size != 10 then
    throw <| IO.userError s!"expected exactly 10 sorry diagnostics, got {sorryDiags.size}"
  let mut edits := #[]
  for lineNo in [:lines.size] do
    let some line := lines[lineNo]?
      | panic! "lines index out of bounds"
    let cols := findSorryColumns line
    for i in [:cols.size] do
      let some col := cols[i]?
        | panic! "sorry column index out of bounds"
      edits := edits.push {
        line := lineNo
        character := col
        delete := "sorry"
        insert := insertedText
      }
  if edits.size != 100 then
    throw <| IO.userError s!"expected exactly 100 scanned sorry tokens, got {edits.size}"
  pure <| sortChangesDescending edits

private def expectSolvedGrind (index : Nat) (result : RunAt.Result) : ScenarioM Unit := do
  if !result.success then
    throw <| IO.userError s!"parallel grind {index} did not succeed: {(toJson result).compress}"
  let some proofState := result.proofState?
    | throw <| IO.userError s!"parallel grind {index} did not return proofState"
  if proofState.goals.size != 0 then
    throw <| IO.userError
      s!"parallel grind {index} left {proofState.goals.size} goals: {(toJson result).compress}"
  if result.messages.size != 0 then
    throw <| IO.userError s!"parallel grind {index} emitted messages: {(toJson result).compress}"

def main : IO Unit := do
  let report ← RunAtTest.Scenario.run do
    let lines ← fixtureLines
    let doc ← openDoc fixturePath

    let initialDiagnostics ← waitForILeansDiagnostics doc
    let edits ← extractSorryChanges lines initialDiagnostics
    let scannedSorryCount := edits.size
    let diagnosticSorryCount :=
      initialDiagnostics.diagnostics.filter (fun diag => diag.message.contains sorryWarning) |>.size

    let runAtStartedAt ← IO.monoNanosNow
    let requests ← edits.mapM fun edit =>
      sendRunAt doc {
        line := edit.line
        character := edit.character
        text := insertedText
      }

    for h : i in [:requests.size] do
      let result : RunAt.Result ← awaitResponseAs requests[i]
      expectSolvedGrind i result
    let runAtFinishedAt ← IO.monoNanosNow

    let changeStartedAt ← IO.monoNanosNow
    changeDocBatch doc edits
    let finalDiagnostics ← waitForILeansDiagnostics doc
    let changeILeansFinishedAt ← IO.monoNanosNow

    let remainingSorryDiags :=
      finalDiagnostics.diagnostics.filter (fun diag => diag.message.contains sorryWarning)
    if remainingSorryDiags.size != 0 then
      throw <| IO.userError
        s!"expected no remaining sorry diagnostics after the atomic grind edit batch, got {(toJson finalDiagnostics).compress}"

    let readinessReq ← sendSaveReadiness doc
    let readiness : RunAt.Internal.SaveReadinessResult ← awaitResponseAs readinessReq
    if !readiness.saveReady then
      throw <| IO.userError s!"expected saveReadiness = true after the grind batch, got {(toJson readiness).compress}"
    if readiness.saveReadyReason != "ok" then
      throw <| IO.userError s!"expected saveReadiness reason = ok, got {(toJson readiness).compress}"
    if readiness.diagnosticErrorCount != 0 then
      throw <| IO.userError s!"expected diagnosticErrorCount = 0, got {(toJson readiness).compress}"
    if readiness.commandErrorCount != 0 then
      throw <| IO.userError s!"expected commandErrorCount = 0, got {(toJson readiness).compress}"

    closeDoc doc
    pure <| reportJson
      ((runAtFinishedAt - runAtStartedAt) / 1000)
      ((changeILeansFinishedAt - changeStartedAt) / 1000)
      scannedSorryCount
      diagnosticSorryCount
      finalDiagnostics.diagnostics.size
      remainingSorryDiags.size
      readiness
  IO.println report.pretty

end RunAtTest.Scenario.ParallelGrindBatchTest

def main := RunAtTest.Scenario.ParallelGrindBatchTest.main
