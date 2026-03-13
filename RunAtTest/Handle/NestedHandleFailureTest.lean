/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Handle.NestedHandleFailureTest

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def badTactic : String :=
  "exact MissingNestedFailureWitness"

private def goalCount (label : String) (result : RunAt.Result) : ScenarioM Nat := do
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState payload"
  pure proofState.goals.size

private def expectStoredHandle (label : String) (result : RunAt.Result) : ScenarioM RunAt.Handle := do
  let some handle := result.handle?
    | throw <| IO.userError s!"{label}: expected successor handle"
  pure handle

private def expectFailureShape (label : String) (result : RunAt.Result) : ScenarioM Unit := do
  if result.success then
    throw <| IO.userError s!"{label}: expected semantic failure"
  let goals ← goalCount label result
  if goals == 0 then
    throw <| IO.userError s!"{label}: expected unsolved proofState after failure"
  if result.handle?.isSome then
    throw <| IO.userError s!"{label}: did not expect successor handle on failure"

def main : IO Unit := RunAtTest.Scenario.run do
  let branch ← openDoc "tests/scenario/docs/NestedRightBranchProof.lean"

  let mintReq ← sendRunAt branch {
    line := 0
    character := 50
    text := "constructor"
    storeHandle := true
  }
  let mint : RunAt.Result ← awaitResponseAs (α := RunAt.Result) mintReq
  let some h0 := mint.handle?
    | throw <| IO.userError "expected root handle"

  let splitReq ← runWithHandle branch h0 {
    text := "constructor"
    storeHandle := true
  }
  let split : RunAt.Result ← awaitResponseAs (α := RunAt.Result) splitReq
  let splitGoals ← goalCount "split" split
  let h1 ← expectStoredHandle "split" split

  let failReq ← runWithHandle branch h1 {
    text := badTactic
    storeHandle := true
  }
  let fail : RunAt.Result ← awaitResponseAs (α := RunAt.Result) failReq
  expectFailureShape "non-linear nested failure" fail

  let advanceReq ← runWithHandle branch h1 {
    text := "exact trivial"
    storeHandle := true
  }
  let advance : RunAt.Result ← awaitResponseAs (α := RunAt.Result) advanceReq
  let _ ← goalCount "advance" advance
  let h2 ← expectStoredHandle "advance" advance

  let linearFailReq ← runWithHandle branch h2 {
    text := badTactic
    storeHandle := true
    linear := true
  }
  let linearFail : RunAt.Result ← awaitResponseAs (α := RunAt.Result) linearFailReq
  expectFailureShape "linear nested failure" linearFail

  let consumedReq ← runWithHandle branch h2 { text := "exact trivial" }
  expectErrorContains consumedReq invalidParamsJson

  let branchAgainReq ← runWithHandle branch h0 {
    text := "constructor"
    storeHandle := true
  }
  let branchAgain : RunAt.Result ← awaitResponseAs (α := RunAt.Result) branchAgainReq
  let branchAgainGoals ← goalCount "branchAgain" branchAgain
  if branchAgainGoals != splitGoals then
    throw <| IO.userError
      s!"expected preserved root handle to recreate {splitGoals} goals, got {branchAgainGoals}"
  let _ ← expectStoredHandle "branchAgain" branchAgain

  closeDoc branch

end RunAtTest.Handle.NestedHandleFailureTest

def main := RunAtTest.Handle.NestedHandleFailureTest.main
