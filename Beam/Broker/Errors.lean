/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Broker

inductive BrokerFailureCode where
  | invalidParams
  | requestCancelled
  | contentModified
  | workerExited
  | syncBarrierIncomplete
  | saveTraceStale
  | saveUnsupportedSetup
  | saveTargetNotModule
  | internalError
  deriving Inhabited, BEq, Repr

def BrokerFailureCode.name : BrokerFailureCode → String
  | .invalidParams => "invalidParams"
  | .requestCancelled => "requestCancelled"
  | .contentModified => "contentModified"
  | .workerExited => "workerExited"
  | .syncBarrierIncomplete => syncBarrierIncompleteCode
  | .saveTraceStale => saveTraceStaleCode
  | .saveUnsupportedSetup => saveUnsupportedSetupCode
  | .saveTargetNotModule => saveTargetNotModuleCode
  | .internalError => "internalError"

instance : ToJson BrokerFailureCode where
  toJson code := toJson code.name

instance : FromJson BrokerFailureCode where
  fromJson? j :=
    match j with
    | .str "invalidParams" => .ok .invalidParams
    | .str "requestCancelled" => .ok .requestCancelled
    | .str "contentModified" => .ok .contentModified
    | .str "workerExited" => .ok .workerExited
    | .str s =>
        if s == syncBarrierIncompleteCode then
          .ok .syncBarrierIncomplete
        else if s == saveTraceStaleCode then
          .ok .saveTraceStale
        else if s == saveUnsupportedSetupCode then
          .ok .saveUnsupportedSetup
        else if s == saveTargetNotModuleCode then
          .ok .saveTargetNotModule
        else if s == "internalError" then
          .ok .internalError
        else
          .error s!"expected broker failure code, got {j.compress}"
    | _ => .error s!"expected broker failure code, got {j.compress}"

def BrokerFailureCode.ofName? (name : String) : Option BrokerFailureCode :=
  fromJson? (toJson name) |>.toOption

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

def BrokerFailure.toResponse (failure : BrokerFailure) : Response :=
  Response.error failure.code.name failure.message failure.data?

def reqError (code : String) (message : String := "") (data? : Option Json := none) : Response :=
  Response.error code message data?

def documentVersionMismatchErrorData
    (expectedVersion acceptedVersion : Nat)
    (currentVersion? : Option Nat := none)
    (uri? : Option String := none) : Json :=
  Json.mkObj <|
    [
      ("reason", toJson "documentVersionMismatch"),
      ("expectedVersion", toJson expectedVersion),
      ("acceptedVersion", toJson acceptedVersion)
    ] ++
    (match currentVersion? with
    | some currentVersion => [("currentVersion", toJson currentVersion)]
    | none => []) ++
    (match uri? with
    | some uri => [("uri", toJson uri)]
    | none => [])

def errorCodeName : JsonRpc.ErrorCode → String
  | .parseError => "parseError"
  | .invalidRequest => "invalidRequest"
  | .methodNotFound => "methodNotFound"
  | .invalidParams => "invalidParams"
  | .internalError => "internalError"
  | .serverNotInitialized => "serverNotInitialized"
  | .unknownErrorCode => "unknownErrorCode"
  | .contentModified => "contentModified"
  | .requestCancelled => "requestCancelled"
  | .rpcNeedsReconnect => "rpcNeedsReconnect"
  | .workerExited => "workerExited"
  | .workerCrashed => "workerCrashed"

private def responseFromJsonRpcErrorObject? (json : Json) : Option Response :=
  match json.getObjVal? "code", json.getObjVal? "message" with
  | .ok code, .ok (.str message) =>
      let data? := (json.getObjVal? "data").toOption
      match code with
      | .str codeName => some <| reqError codeName message data?
      | _ =>
          match fromJson? code with
          | .ok (errCode : JsonRpc.ErrorCode) => some <| reqError (errorCodeName errCode) message data?
          | .error _ => some <| reqError code.compress message data?
  | _, _ => none

def responseForJsonRpcErrorObject (errJson : Json) : Response :=
  match responseFromJsonRpcErrorObject? errJson with
  | some resp => resp
  | none => reqError "internalError" s!"invalid JSON-RPC error object: {errJson.compress}"

end Beam.Broker
