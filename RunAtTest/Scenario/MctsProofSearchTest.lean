/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Scenario.MctsProofSearchTest

private structure SearchHandle where
  handle : RunAt.Handle
  goalCount : Nat

private inductive StepOutcome where
  | ongoing (next : SearchHandle)
  | solved (extraHandle? : Option RunAt.Handle)

private def searchPath : System.FilePath :=
  System.FilePath.mk "tests/scenario/docs/MctsProof.lean"

private def successTactic : String :=
  "first | constructor | exact trivial"

private def badTactic : String :=
  "exact MissingMctsWitness"

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def startPos : IO Lean.Lsp.Position := do
  let text ← IO.FS.readFile searchPath
  let some line := text.splitOn "\n" |>.head?
    | throw <| IO.userError s!"could not read first line of {searchPath}"
  pure { line := 0, character := line.length }

private def goalCountOf (label : String) (result : RunAt.Result) : ScenarioM Nat := do
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState payload"
  pure proofState.goals.size

private def awaitResult (label : String) (req : ReqHandle) : ScenarioM RunAt.Result := do
  let outcome ← awaitReq req
  let some actual := outcome.result?
    | throw <| IO.userError
        s!"{label}: unexpected transport error {outcome.errorCode?.getD "unknown"}"
  match fromJson? actual with
  | .ok result => pure result
  | .error err =>
      throw <| IO.userError s!"{label}: failed to decode RunAt result: {err}"

private def expectHandleError (doc : DocHandle) (current : SearchHandle) (expected : Json) :
    ScenarioM Unit := do
  let req ← runWithHandle doc current.handle { text := successTactic }
  expectErrorContains req expected

private def releaseAndAssertInvalid (doc : DocHandle) (current : SearchHandle) : ScenarioM Unit := do
  releaseHandle doc current.handle
  expectHandleError doc current invalidParamsJson

private def awaitBranchSuccess (doc : DocHandle) (current : SearchHandle) : ScenarioM StepOutcome := do
  let req ← runWithHandle doc current.handle {
    text := successTactic
    storeHandle := true
    linear := false
  }
  let result ← awaitResult s!"branch success from {current.goalCount} goals" req
  if !result.success then
    throw <| IO.userError "expected successful non-linear search step"
  let goalCount ← goalCountOf "branch success" result
  match result.handle? with
  | some handle =>
      if goalCount == 0 then
        pure (.solved (some handle))
      else
        pure (.ongoing { handle, goalCount })
  | none =>
      if goalCount == 0 then
        pure (.solved none)
      else
        throw <| IO.userError "unfinished branch success did not return a successor handle"

private def awaitLinearSuccess (doc : DocHandle) (current : SearchHandle) : ScenarioM StepOutcome := do
  let req ← runWithHandle doc current.handle {
    text := successTactic
    storeHandle := true
    linear := true
  }
  let result ← awaitResult s!"linear success from {current.goalCount} goals" req
  if !result.success then
    throw <| IO.userError "expected successful linear MCTS playout step"
  let goalCount ← goalCountOf "linear success" result
  match result.handle? with
  | some handle =>
      if goalCount == 0 then
        pure (.solved (some handle))
      else
        pure (.ongoing { handle, goalCount })
  | none =>
      if goalCount == 0 then
        pure (.solved none)
      else
        throw <| IO.userError "unfinished linear step did not return a successor handle"

private def awaitFailureStep (doc : DocHandle) (current : SearchHandle) (linear : Bool) :
    ScenarioM Unit := do
  let req ← runWithHandle doc current.handle {
    text := badTactic
    storeHandle := true
    linear
  }
  let result ← awaitResult s!"failure probe linear={linear} from {current.goalCount} goals" req
  if result.success then
    throw <| IO.userError "expected semantic failure from bad MCTS probe"
  if result.proofState?.isNone then
    throw <| IO.userError "failed MCTS probe unexpectedly omitted proofState"
  if result.handle?.isSome then
    throw <| IO.userError "failed MCTS probe unexpectedly returned a successor handle"

private def disposeSolvedHandle? (doc : DocHandle) : Option RunAt.Handle → ScenarioM Unit
  | some handle =>
      releaseAndAssertInvalid doc { handle, goalCount := 0 }
  | none =>
      pure ()

private def mintRootHandle (doc : DocHandle) : ScenarioM SearchHandle := do
  let pos ← startPos
  let req ← sendRunAt doc {
    line := pos.line
    character := pos.character
    text := "constructor"
    storeHandle := true
  }
  let result ← awaitResult "root mint" req
  if !result.success then
    throw <| IO.userError "expected successful root search handle mint"
  let goalCount ← goalCountOf "root mint" result
  if goalCount == 0 then
    throw <| IO.userError "root mint unexpectedly solved the search proof"
  let some handle := result.handle?
    | throw <| IO.userError "expected root search handle"
  pure { handle, goalCount }

private def runPlayout (doc : DocHandle) (root : SearchHandle) (seed : Nat) : ScenarioM Unit := do
  let mut gen := mkStdGen seed
  let branch ← awaitBranchSuccess doc root
  let current ←
    match branch with
    | .ongoing next => pure next
    | .solved handle? =>
        disposeSolvedHandle? doc handle?
        throw <| IO.userError "playout branch unexpectedly solved on its first move"
  let mut current := current
  for _ in List.range 16 do
    let (probeRoll, gen') := randNat gen 0 3
    gen := gen'
    if probeRoll == 0 then
      awaitFailureStep doc current (linear := false)
    let (sideRoll, gen') := randNat gen 0 4
    gen := gen'
    if sideRoll == 0 then
      match ← awaitBranchSuccess doc current with
      | .ongoing side =>
          awaitFailureStep doc side (linear := false)
          releaseAndAssertInvalid doc side
      | .solved handle? =>
          disposeSolvedHandle? doc handle?
    match ← awaitLinearSuccess doc current with
    | .ongoing next =>
        current := next
    | .solved handle? =>
        disposeSolvedHandle? doc handle?
        return
  throw <| IO.userError "MCTS playout exceeded the step budget without solving the proof"

private def assertLinearFailureConsumesBranch (doc : DocHandle) (root : SearchHandle) : ScenarioM Unit := do
  match ← awaitBranchSuccess doc root with
  | .ongoing branch =>
      awaitFailureStep doc branch (linear := true)
      expectHandleError doc branch invalidParamsJson
  | .solved handle? =>
      disposeSolvedHandle? doc handle?
      throw <| IO.userError "linear-failure test unexpectedly solved the branch immediately"

def main : IO Unit := RunAtTest.Scenario.run do
  let doc ← openDoc searchPath
  let root ← mintRootHandle doc

  for seed in [20260311, 20260312, 20260313, 20260314, 20260315, 20260316] do
    runPlayout doc root seed

  match ← awaitBranchSuccess doc root with
  | .ongoing liveBranch =>
      releaseAndAssertInvalid doc liveBranch
  | .solved handle? =>
      disposeSolvedHandle? doc handle?

  assertLinearFailureConsumesBranch doc root

  let staleBranch ←
    match ← awaitBranchSuccess doc root with
    | .ongoing branch => pure branch
    | .solved handle? =>
        disposeSolvedHandle? doc handle?
        throw <| IO.userError "stale-invalidation branch unexpectedly solved immediately"
  changeDoc doc { line := 0, character := 0, insert := " " }
  syncDoc doc
  expectHandleError doc root contentModifiedJson
  expectHandleError doc staleBranch contentModifiedJson
  closeDoc doc

end RunAtTest.Scenario.MctsProofSearchTest

def main := RunAtTest.Scenario.MctsProofSearchTest.main
