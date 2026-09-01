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
  onFileProgress : SyncFileProgress → IO Unit := fun _ => pure ()
  onDiagnostic : StreamDiagnostic → IO Unit := fun _ => pure ()

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
  | interrupted

def BrokerClientFailure.detail : BrokerClientFailure → String
  | .transport operation error =>
      s!"Beam daemon {operation.label} failed: {error}"
  | .streamCallback error => error.toString
  | .invalidResponse detail => detail
  | .responseTimeout timeoutMs =>
      s!"Beam daemon response timed out after {timeoutMs} ms"
  | .interrupted => "Beam request interrupted"

instance : Repr BrokerClientFailure where
  reprPrec failure _ := Std.Format.text <|
    match failure with
    | .transport operation error => s!"BrokerClientFailure.transport {repr operation} {error}"
    | .invalidResponse detail => s!"BrokerClientFailure.invalidResponse {detail}"
    | .streamCallback error => s!"BrokerClientFailure.streamCallback {error}"
    | .responseTimeout timeoutMs => s!"BrokerClientFailure.responseTimeout {timeoutMs}"
    | .interrupted => "BrokerClientFailure.interrupted"

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

private inductive ResponseWait where
  | unbounded
  | deadline (deadline : ResponseDeadline)
  | interruptible (interrupted : IO Bool)

/-- Send one request while preserving transport, response, callback, and timeout failures. -/
private partial def sendRequestWithStreamResultCore
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit)
    (wait : ResponseWait) : IO (Except BrokerClientFailure Response) := do
  let client ←
    match ← captureClientFailure (.transport .connect) (Transport.connect endpoint) with
    | .ok client => pure client
    | .error failure => return .error failure
  try
    match ← captureClientFailure (.transport .send) <|
        Transport.sendMsg client (toJson req).compress with
    | .ok () => pure ()
    | .error failure => return .error failure
    let rec receiveResponse : IO (Except BrokerClientFailure Response) := do
      let msg ←
        match wait with
        | .unbounded =>
            match ← captureClientFailure (.transport .receive) (Transport.recvMsg client) with
            | .ok msg => pure msg
            | .error failure => return .error failure
        | .interruptible interrupted =>
            match ← captureClientFailure (.transport .receive) <|
                Transport.recvMsgInterruptibly client interrupted with
            | .ok (.message msg) => pure msg
            | .ok .interrupted => return .error .interrupted
            | .error failure => return .error failure
        | .deadline deadline =>
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
          receiveResponse
    receiveResponse
  finally
    Transport.closeConnection client

/-- Send one request while preserving transport, response, and callback failures as typed data. -/
partial def sendRequestWithStreamResult
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResultCore endpoint req onStream .unbounded

/-- Send one request with an absolute timeout for receiving its complete response stream. -/
partial def sendRequestWithStreamTimeoutResult
    (endpoint : Endpoint)
    (req : Request)
    (timeoutMs : Nat)
    (onStream : StreamMessage → IO Unit) : IO (Except BrokerClientFailure Response) := do
  let deadline : ResponseDeadline := {
    timeoutMs
    deadlineNanos := (← IO.monoNanosNow) + timeoutMs * 1000000
  }
  sendRequestWithStreamResultCore endpoint req onStream (.deadline deadline)

/-- Send one request with typed client failures and structured progress callbacks. -/
partial def sendRequestWithCallbacksResult
    (endpoint : Endpoint)
    (req : Request)
    (callbacks : StreamCallbacks := {}) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResult endpoint req fun stream => do
    match stream with
    | .response .. =>
        pure ()
    | .fileProgress _ progress =>
        callbacks.onFileProgress progress
    | .diagnostic _ diagnostic =>
        callbacks.onDiagnostic diagnostic

/-- Send one request whose owning client may interrupt the exact in-flight connection. -/
partial def sendRequestWithCallbacksInterruptiblyResult
    (endpoint : Endpoint)
    (req : Request)
    (interrupted : IO Bool)
    (callbacks : StreamCallbacks := {}) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResultCore endpoint req (fun stream => do
    match stream with
    | .response .. =>
        pure ()
    | .fileProgress _ progress =>
        callbacks.onFileProgress progress
    | .diagnostic _ diagnostic =>
        callbacks.onDiagnostic diagnostic) (.interruptible interrupted)

end Beam.Broker
