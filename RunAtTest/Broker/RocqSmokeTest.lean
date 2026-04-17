/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import RunAtTest.Broker.TestUtil
import Lean

open Lean

namespace RunAtTest.Broker.RocqSmokeTest

open RunAtTest.Broker.TestUtil

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

def main : IO Unit := do
  let port : UInt16 := ((← IO.monoNanosNow) % 20000 + 30000).toUInt16
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← rocqRoot
  let broker ← IO.Process.spawn {
    cmd := (← daemonExe).toString
    args := #[
      "--port", toString port.toNat,
      "--root", root.toString,
      "--rocq-cmd", (← IO.getEnv "BEAM_ROCQ_CMD").getD "coq-lsp"
    ]
    stdin := .null
    stdout := .null
    stderr := .null
    setsid := true
  }
  try
    IO.sleep 400
    discard <| expectOk (← runClient endpoint { op := .ensure, backend := .rocq, root? := some root.toString })
    discard <| expectOk (← runClient endpoint { op := .resetStats })
    let goals ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      root? := some root.toString
      path? := some "Demo.v"
      line? := some 2
      character? := some 8
      mode? := some .after
      compact? := some false
    }
    expectTwoTrueGoals goals

    let semiGoals ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      root? := some root.toString
      path? := some "Semi.v"
      line? := some 2
      character? := some 3
      mode? := some .prev
      text? := some "split."
      compact? := some false
    }
    expectTwoTrueGoals semiGoals

    let errorGoals ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      root? := some root.toString
      path? := some "Error.v"
      line? := some 2
      character? := some 8
      mode? := some .after
      compact? := some false
    }
    expectTwoTrueGoals errorGoals

    let errorPayload ← expectOk <| ← runClient endpoint {
      op := .goals
      backend := .rocq
      root? := some root.toString
      path? := some "Error.v"
      line? := some 4
      character? := some 2
      mode? := some .after
      compact? := some false
    }
    expectNonemptyError errorPayload

    let zeroGoalResp ← runClient endpoint {
      op := .goals
      backend := .rocq
      root? := some root.toString
      path? := some "Done.v"
      line? := some 3
      character? := some 0
      mode? := some .prev
      text? := some "exact I."
      compact? := some false
    }
    expectSurfacedError zeroGoalResp

    let stats ← expectOk <| ← runClient endpoint { op := .stats }
    expectOpCountAtLeast stats "rocq" "goals" 5
    discard <| expectOk <| ← runClient endpoint { op := .shutdown }
  finally
    try
      broker.kill
    catch _ =>
      pure ()

end RunAtTest.Broker.RocqSmokeTest

def main := RunAtTest.Broker.RocqSmokeTest.main
