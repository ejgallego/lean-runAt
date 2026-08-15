/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Broker

/--
The failure branch of a broker response while it is still inside request handling.

Keeping this separate from `Response` prevents successful responses from inhabiting `Except` error
channels. The conversion to the wire-level response sum happens only when a request is completed.
-/
structure ResponseFailure where
  error : Error
  fileProgress? : Option SyncFileProgress := none
  clientRequestId? : Option String := none
  deriving Inhabited

def ResponseFailure.toResponse (failure : ResponseFailure) : Response :=
  .errorResult failure.error failure.fileProgress? failure.clientRequestId?

def responseFailure
    (code : String)
    (message : String := "")
    (data? : Option Json := none) : ResponseFailure :=
  { error := { code, message, data? } }

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

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

def BrokerFailure.toResponseFailure (failure : BrokerFailure) : ResponseFailure :=
  responseFailure failure.code.name failure.message failure.data?

def BrokerFailure.toResponse (failure : BrokerFailure) : Response :=
  failure.toResponseFailure.toResponse

def reqError (code : String) (message : String := "") (data? : Option Json := none) : Response :=
  (responseFailure code message data?).toResponse

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

private def responseFailureFromJsonRpcErrorObject? (json : Json) : Option ResponseFailure :=
  match json.getObjVal? "code", json.getObjVal? "message" with
  | .ok code, .ok (.str message) =>
      let data? := (json.getObjVal? "data").toOption
      match code with
      | .str codeName => some <| responseFailure codeName message data?
      | _ =>
          match fromJson? code with
          | .ok (errCode : JsonRpc.ErrorCode) =>
              some <| responseFailure (errorCodeName errCode) message data?
          | .error _ => some <| responseFailure code.compress message data?
  | _, _ => none

def responseFailureForJsonRpcErrorObject (errJson : Json) : ResponseFailure :=
  match responseFailureFromJsonRpcErrorObject? errJson with
  | some failure => failure
  | none => responseFailure "internalError" s!"invalid JSON-RPC error object: {errJson.compress}"

end Beam.Broker
