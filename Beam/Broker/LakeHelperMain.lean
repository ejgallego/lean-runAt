/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.LakeEnv
import Beam.Broker.LakeSave

open Lean

namespace Beam.Broker.LakeHelperMain

private def readRequest [FromJson α] : IO α := do
  let input ← (← IO.getStdin).readToEnd
  let json ← IO.ofExcept <| Json.parse input
  IO.ofExcept <| fromJson? json

private def writeResponse (response : Response) : IO Unit := do
  IO.println (toJson response).compress

private def runServerEnv : IO Unit := do
  let request : LakeHelperEnvRequest ← readRequest
  let serverEnv ← leanServerLakeEnv
    (System.FilePath.mk request.root) (some request.leanCmd)
  writeResponse <| Response.success (toJson serverEnv)

private def runPrepareSave : IO Unit := do
  let request : LakeHelperSaveRequest ← readRequest
  match ← lakeHelperSaveSpec request with
  | .ok spec => writeResponse <| Response.success (toJson spec)
  | .error failure => writeResponse failure.toResponse

private def runWriteSaveTrace : IO Unit := do
  let request : LakeHelperWriteTraceRequest ← readRequest
  lakeHelperWriteLeanSaveTrace request
  writeResponse <| Response.success (toJson ({} : LakeHelperAck))

def main (args : List String) : IO Unit := do
  try
    match args with
    | [operation] =>
        match LakeHelperOperation.ofString? operation with
        | some .serverEnv => runServerEnv
        | some .prepareSave => runPrepareSave
        | some .writeSaveTrace => runWriteSaveTrace
        | none => throw <| IO.userError "invalid target Lake helper operation"
    | _ => throw <| IO.userError "invalid target Lake helper operation"
  catch error =>
    writeResponse <| BrokerFailure.toResponse {
      code := .internalError
      message := error.toString
    }

end Beam.Broker.LakeHelperMain
