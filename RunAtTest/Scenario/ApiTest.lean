/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Scenario.ApiTest

private def successJson : Json :=
  Json.mkObj [("success", toJson true)]

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

def main : IO Unit := RunAtTest.Scenario.run do
  let proofA ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let proofB ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  let cmdA ← openDoc "tests/scenario/docs/CommandA.lean"

  let staleReqs ← (List.range 5).mapM fun _ =>
    sendRunAt proofA { line := 1, character := 2, text := "exact trivial" }
  let proofReqs ← (List.range 3).mapM fun _ =>
    sendRunAt proofB { line := 1, character := 2, text := "exact trivial" }
  let commandReqs ← (List.range 2).mapM fun _ =>
    sendRunAt cmdA { line := 0, character := 2, text := "#check Nat" }

  changeDoc proofA { line := 0, character := 0, delete := "", insert := " " }
  syncDoc proofA

  for req in staleReqs do
    expectErrorContains req contentModifiedJson

  for req in proofReqs do
    expectResponseContains req successJson

  for req in commandReqs do
    expectResponseContains req successJson

  closeDoc proofA
  closeDoc proofB
  closeDoc cmdA

end RunAtTest.Scenario.ApiTest

def main := RunAtTest.Scenario.ApiTest.main
