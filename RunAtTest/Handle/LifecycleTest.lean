/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Handle.LifecycleTest

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def expectHandleResultErrorTwice
    (doc : DocHandle)
    (handle : RunAt.Handle)
    (text : String) : ScenarioM Unit := do
  let reqA ← runWithHandle doc handle { text }
  expectErrorContains reqA contentModifiedJson
  let reqB ← runWithHandle doc handle { text }
  expectErrorContains reqB contentModifiedJson

private def checkEditPruning : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"
  let mintReq ← sendRunAt cmd {
    line := 0
    character := 2
    text := "def tempLifecycle : Nat := 1"
    storeHandle := true
  }
  let mint : RunAt.Result ← awaitResponseAs mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected lifecycle edit handle"

  changeDoc cmd { line := 0, character := 23, insert := " " }
  syncDoc cmd

  let freshReq ← sendRunAt cmd {
    line := 0
    character := 2
    text := "#check Nat"
    storeHandle := true
  }
  let _fresh : RunAt.Result ← awaitResponseAs freshReq

  expectHandleResultErrorTwice cmd handle "#check tempLifecycle"
  closeDoc cmd

private def checkClosePruning : ScenarioM Unit := do
  let branch ← openDoc "tests/scenario/docs/BranchProof.lean"
  let mintReq ← sendRunAt branch {
    line := 0
    character := 27
    text := "constructor"
    storeHandle := true
  }
  let mint : RunAt.Result ← awaitResponseAs mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected lifecycle close handle"
  closeDoc branch

  let branch2 ← openDoc "tests/scenario/docs/BranchProof.lean"
  let freshReq ← sendRunAt branch2 {
    line := 0
    character := 27
    text := "constructor"
    storeHandle := true
  }
  let _fresh : RunAt.Result ← awaitResponseAs freshReq

  expectHandleResultErrorTwice branch2 handle "exact trivial"
  closeDoc branch2

def main : IO Unit := RunAtTest.Scenario.run do
  checkEditPruning
  checkClosePruning

end RunAtTest.Handle.LifecycleTest

def main := RunAtTest.Handle.LifecycleTest.main
