/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Handle.ApiTest

def main : IO Unit := RunAtTest.Scenario.run do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"

  -- The scenario DSL cannot currently assert that a failed request did *not* return a handle.
  let mintReq ← sendRunAt cmd { line := 0, character := 2, text := "def tempNoHandle : Nat := 9", storeHandle := true }
  let mint : RunAt.Result ← awaitResponseAs (α := RunAt.Result) mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected command handle"

  let failureReq ← runWithHandle cmd handle {
    text := "#check MissingNameAgain"
    storeHandle := true
    linear := true
  }
  let failure : RunAt.Result ← awaitResponseAs (α := RunAt.Result) failureReq
  if failure.success then
    throw <| IO.userError "expected semantic failure for failed successor handle test"
  if failure.handle?.isSome then
    throw <| IO.userError "did not expect successor handle on semantic failure"

  closeDoc cmd

end RunAtTest.Handle.ApiTest

def main := RunAtTest.Handle.ApiTest.main
