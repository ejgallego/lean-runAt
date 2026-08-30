/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Broker.Transport

open Lean

namespace Beam.Broker

structure StreamCallbacks where
  onFileProgress : Option String → SyncFileProgress → IO Unit := fun _ _ => pure ()
  onDiagnostic : Option String → StreamDiagnostic → IO Unit := fun _ _ => pure ()

abbrev Endpoint := Transport.Endpoint

/-- The transport operation that produced a typed broker client failure. -/
inductive BrokerTransportOperation where
  | connect
  | send
  | receive
  deriving Repr, BEq

private def BrokerTransportOperation.label : BrokerTransportOperation → String
  | .connect => "connect"
  | .send => "send"
  | .receive => "receive"

/-- Keep broker client failures typed until a CLI or transport presentation boundary. -/
inductive BrokerClientFailure where
  | transport (operation : BrokerTransportOperation) (error : IO.Error)
  | invalidResponse (detail : String)
  | streamCallback (error : IO.Error)
  | responseTimeout (timeoutMs : Nat)

def BrokerClientFailure.detail : BrokerClientFailure → String
  | .transport operation error =>
      s!"Beam daemon {operation.label} failed: {error}"
  | .streamCallback error => error.toString
  | .invalidResponse detail => detail
  | .responseTimeout timeoutMs =>
      s!"Beam daemon response timed out after {timeoutMs} ms"

instance : Repr BrokerClientFailure where
  reprPrec failure _ := Std.Format.text <|
    match failure with
    | .transport operation error => s!"BrokerClientFailure.transport {repr operation} {error}"
    | .invalidResponse detail => s!"BrokerClientFailure.invalidResponse {detail}"
    | .streamCallback error => s!"BrokerClientFailure.streamCallback {error}"
    | .responseTimeout timeoutMs => s!"BrokerClientFailure.responseTimeout {timeoutMs}"

private def BrokerClientFailure.toIOError : BrokerClientFailure → IO.Error
  | failure@(.transport ..) => IO.userError failure.detail
  | .streamCallback error => error
  | .invalidResponse detail => IO.userError detail
  | .responseTimeout timeoutMs =>
      IO.userError s!"Beam daemon response timed out after {timeoutMs} ms"

private def decodeStreamMessage (msg : String) : Except String StreamMessage := do
  match Json.parse msg with
  | .error err => throw s!"invalid Beam daemon response json: {err}"
  | .ok json =>
      match fromJson? (α := StreamMessage) json with
      | .ok stream => pure stream
      | .error err => throw s!"invalid Beam daemon response payload: {err}"

private def captureClientFailure
    (failure : IO.Error → BrokerClientFailure)
    (action : IO α) : IO (Except BrokerClientFailure α) := do
  try
    pure <| .ok (← action)
  catch e =>
    pure <| .error (failure e)

private structure ResponseDeadline where
  timeoutMs : Nat
  deadlineNanos : Nat

/-- Send one request while preserving transport, response, callback, and timeout failures. -/
private partial def sendRequestWithStreamResultCore
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit)
    (responseTimeoutMs? : Option Nat) : IO (Except BrokerClientFailure Response) := do
  let client ←
    match ← captureClientFailure (.transport .connect) (Transport.connect endpoint) with
    | .ok client => pure client
    | .error failure => return .error failure
  try
    match ← captureClientFailure (.transport .send) <|
        Transport.sendMsg client (toJson req).compress with
    | .ok () => pure ()
    | .error failure => return .error failure
    let deadline? : Option ResponseDeadline ← responseTimeoutMs?.mapM fun timeoutMs => do
      pure {
        timeoutMs
        deadlineNanos := (← IO.monoNanosNow) + timeoutMs * 1000000
      }
    let rec loop : IO (Except BrokerClientFailure Response) := do
      let msg ←
        match deadline? with
        | none =>
            match ← captureClientFailure (.transport .receive) (Transport.recvMsg client) with
            | .ok msg => pure msg
            | .error failure => return .error failure
        | some deadline =>
            match ← captureClientFailure (.transport .receive) <|
                Transport.recvMsgUntil client deadline.deadlineNanos with
            | .ok (some msg) => pure msg
            | .ok none => return .error (.responseTimeout deadline.timeoutMs)
            | .error failure => return .error failure
      let stream ←
        match decodeStreamMessage msg with
        | .ok stream => pure stream
        | .error detail => return .error (.invalidResponse detail)
      unless stream.clientRequestId? == req.clientRequestId? do
        return .error <| .invalidResponse <|
          s!"Beam daemon stream request id {stream.clientRequestId?} does not match request id {req.clientRequestId?}"
      match ← captureClientFailure .streamCallback (onStream stream) with
      | .ok () => pure ()
      | .error failure => return .error failure
      match stream with
      | .response _ response =>
          pure <| .ok response
      | .fileProgress .. | .diagnostic .. =>
          loop
    loop
  finally
    Transport.closeConnection client

/-- Send one request while preserving transport, response, and callback failures as typed data. -/
partial def sendRequestWithStreamResult
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResultCore endpoint req onStream none

/-- Send one request with an absolute timeout for receiving its complete response stream. -/
partial def sendRequestWithStreamTimeoutResult
    (endpoint : Endpoint)
    (req : Request)
    (timeoutMs : Nat)
    (onStream : StreamMessage → IO Unit) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResultCore endpoint req onStream (some timeoutMs)

/-- Send one request with typed client failures and structured progress callbacks. -/
partial def sendRequestWithCallbacksResult
    (endpoint : Endpoint)
    (req : Request)
    (callbacks : StreamCallbacks := {}) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResult endpoint req fun stream => do
    match stream with
    | .response .. =>
        pure ()
    | .fileProgress clientRequestId? progress =>
        callbacks.onFileProgress clientRequestId? progress
    | .diagnostic clientRequestId? diagnostic =>
        callbacks.onDiagnostic clientRequestId? diagnostic

partial def sendRequestWithCallbacks
    (endpoint : Endpoint)
    (req : Request)
    (callbacks : StreamCallbacks := {}) : IO Response := do
  match ← sendRequestWithCallbacksResult endpoint req callbacks with
  | .ok response => pure response
  | .error failure => throw failure.toIOError
def sendRequest (endpoint : Endpoint) (req : Request) : IO Response :=
  sendRequestWithCallbacks endpoint req

end Beam.Broker
