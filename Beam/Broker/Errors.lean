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

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited

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

end Beam.Broker
