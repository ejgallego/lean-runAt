/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Scenario.StressTest

private inductive ExpectedOutcome where
  | success
  | semanticError
  | contentModified
  | requestCancelled
  deriving Inhabited

private def successJson : Json :=
  Json.mkObj [("success", toJson true)]

private def semanticErrorJson : Json :=
  Json.mkObj [("success", toJson false)]

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def requestCancelledJson : Json :=
  Json.mkObj [("code", toJson "requestCancelled")]

private def swap! [Inhabited α] (xs : Array α) (i j : Nat) : Array α :=
  let xi := xs[i]!
  let xj := xs[j]!
  let xs := xs.set! i xj
  xs.set! j xi

private def shuffle [Inhabited α] (xs : Array α) (seed : Nat) : Array α :=
  go xs (mkStdGen seed) 0 xs.size
where
  go (xs : Array α) (gen : StdGen) (i fuel : Nat) : Array α :=
    match fuel with
    | 0 => xs
    | fuel + 1 =>
        let (j, gen) := randNat gen i (xs.size - 1)
        go (swap! xs i j) gen (i + 1) fuel

def main : IO Unit := RunAtTest.Scenario.run do
  let proofOk ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let proofStale ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  let cmdOk ← openDoc "tests/scenario/docs/CommandA.lean"
  let cmdErr ← openDoc "tests/scenario/docs/CommandB.lean"
  let slowCancel ← openDoc "tests/scenario/docs/SlowClose.lean"
  let slowClose ← openDoc "tests/scenario/docs/SlowCloseB.lean"

  let proofOkReqs ← (List.range 35).mapM fun _ =>
    sendRunAt proofOk { line := 1, character := 2, text := "exact trivial" }
  let cmdOkReqs ← (List.range 35).mapM fun _ =>
    sendRunAt cmdOk { line := 0, character := 2, text := "#check Nat" }
  let cmdErrReqs ← (List.range 20).mapM fun _ =>
    sendRunAt cmdErr { line := 0, character := 2, text := "#check MissingName" }
  let staleReqs ← (List.range 5).mapM fun _ =>
    sendRunAt proofStale { line := 1, character := 2, text := "exact trivial" }
  let cancelReqs ← (List.range 3).mapM fun _ =>
    sendRunAt slowCancel { line := 8, character := 2, text := "exact trivial" }
  let closeReqs ← (List.range 2).mapM fun _ =>
    sendRunAt slowClose { line := 8, character := 2, text := "exact trivial" }

  changeDoc proofStale { line := 0, character := 0, delete := "", insert := " " }
  syncDoc proofStale

  for req in cancelReqs do
    cancelReq req

  closeDoc slowClose

  let expectations : Array (ReqHandle × ExpectedOutcome) :=
    (proofOkReqs.map (·, ExpectedOutcome.success) ++
      cmdOkReqs.map (·, ExpectedOutcome.success) ++
      cmdErrReqs.map (·, ExpectedOutcome.semanticError) ++
      staleReqs.map (·, ExpectedOutcome.contentModified) ++
      cancelReqs.map (·, ExpectedOutcome.requestCancelled) ++
      closeReqs.map (·, ExpectedOutcome.contentModified)).toArray

  for (req, expected) in shuffle expectations 20260310 do
    match expected with
    | .success =>
        expectResponseContains req successJson
    | .semanticError =>
        expectResponseContains req semanticErrorJson
    | .contentModified =>
        expectErrorContains req contentModifiedJson
    | .requestCancelled =>
        expectErrorContains req requestCancelledJson

  closeDoc proofOk
  closeDoc proofStale
  closeDoc cmdOk
  closeDoc cmdErr
  closeDoc slowCancel

end RunAtTest.Scenario.StressTest

def main := RunAtTest.Scenario.StressTest.main
