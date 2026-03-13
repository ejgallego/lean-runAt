/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Handle.RestartTest

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def mintHandle : IO RunAt.Handle := RunAtTest.Scenario.run do
  let branch ← openDoc "tests/scenario/docs/BranchProof.lean"
  let mintReq ← sendRunAt branch { line := 0, character := 27, text := "constructor", storeHandle := true }
  let mint : RunAt.Result ← awaitResponseAs (α := RunAt.Result) mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected restart handle"
  closeDoc branch
  pure handle

private def assertRestartInvalidated (handle : RunAt.Handle) : IO Unit := RunAtTest.Scenario.run do
  let branch ← openDoc "tests/scenario/docs/BranchProof.lean"
  let req ← runWithHandle branch handle { text := "exact trivial" }
  expectErrorContains req contentModifiedJson
  closeDoc branch

def main : IO Unit := do
  let handle ← mintHandle
  assertRestartInvalidated handle

end RunAtTest.Handle.RestartTest

def main := RunAtTest.Handle.RestartTest.main
