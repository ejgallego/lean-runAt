/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Errors

open Lean

namespace Beam.Broker

structure LakeHelperEnvRequest where
  root : String
  leanCmd : String
  deriving FromJson, ToJson

structure LakeHelperSaveRequest where
  root : String
  path : String
  leanCmd : String
  sourceHash : String
  sourceMTimeSec : Int
  sourceMTimeNsec : Nat
  deriving FromJson, ToJson

structure LakeHelperWriteTraceRequest where
  oleanPath : String
  oleanServerPath? : Option String := none
  oleanPrivatePath? : Option String := none
  ileanPath : String
  irPath? : Option String := none
  cPath : String
  bcPath? : Option String := none
  tracePath : String
  traceMetadata : Json
  deriving FromJson, ToJson

structure LakeHelperSaveSpec extends LakeHelperWriteTraceRequest where
  relPath : String
  moduleName : String
  unsupportedSetupReason? : Option String := none
  deriving FromJson, ToJson

def BrokerFailureCode.ofName? (name : String) : Option BrokerFailureCode :=
  if name == "invalidParams" then some .invalidParams
  else if name == "requestCancelled" then some .requestCancelled
  else if name == "contentModified" then some .contentModified
  else if name == "workerExited" then some .workerExited
  else if name == syncBarrierIncompleteCode then some .syncBarrierIncomplete
  else if name == saveTraceStaleCode then some .saveTraceStale
  else if name == saveUnsupportedSetupCode then some .saveUnsupportedSetup
  else if name == saveTargetNotModuleCode then some .saveTargetNotModule
  else if name == "internalError" then some .internalError
  else none

private def helperOutputSummary (stdout stderr : String) : String :=
  let stderr := stderr.trimAscii.toString
  let stdout := stdout.trimAscii.toString
  if !stderr.isEmpty then stderr else if !stdout.isEmpty then stdout else "(no output)"

/-- Invoke a target-built helper without a shell and keep its structured failures typed. -/
def runLakeHelper
    (helper : System.FilePath)
    (operation : String)
    (request : Json) : IO (Except BrokerFailure Json) := do
  let out ← IO.Process.output {
    cmd := helper.toString
    args := #["lake-helper", operation]
  } (some request.compress)
  if out.exitCode != 0 then
    return .error {
      code := .internalError
      message :=
        s!"target Lake helper '{operation}' exited with code {out.exitCode}: " ++
          helperOutputSummary out.stdout out.stderr
    }
  let response ←
    match Json.parse out.stdout >>= fromJson? (α := Response) with
    | .ok response => pure response
    | .error err =>
        return .error {
          code := .internalError
          message :=
            s!"target Lake helper '{operation}' returned invalid JSON: {err}: " ++
              helperOutputSummary out.stdout out.stderr
        }
  match response with
  | .successResult result _ => pure <| .ok result
  | .errorResult failure =>
      let error := failure.error
      let some code := BrokerFailureCode.ofName? error.code
        | return .error {
            code := .internalError
            message := s!"target Lake helper '{operation}' returned unknown error code '{error.code}'"
          }
      pure <| .error { code, message := error.message, data? := error.data? }

end Beam.Broker
