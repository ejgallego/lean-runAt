/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
-- `Std.Internal.Async.TCP` moved to `Std.Async.TCP` in Lean v4.31. Use the lower-level UV
-- socket API because it is available across the supported toolchain range.
import Std.Internal.UV.TCP
import Std.Net.Addr

open Lean

namespace Beam.Broker.Transport

open Std.Net
open Std.Internal.UV

inductive Endpoint where
  | tcp (port : UInt16)
  deriving Repr, BEq

inductive Connection where
  | tcp (client : TCP.Socket)

inductive Listener where
  | tcp (server : TCP.Socket)

def localhost (port : UInt16) : SocketAddress :=
  SocketAddressV4.mk (.ofParts 127 0 0 1) port

def endpointDescription : Endpoint → String
  | .tcp port => s!"tcp://127.0.0.1:{port.toNat}"

private def waitTcpPromise (promise : IO.Promise (Except IO.Error α)) (failureMessage : String) :
    IO α := do
  let some result := promise.result?.get
    | throw <| IO.userError failureMessage
  match result with
  | .ok value => pure value
  | .error err => throw err

private inductive ReceiveWaitResult (α : Type) where
  | completed (value : α)
  | timedOut

private partial def waitTcpReceivePromiseUntil
    (client : TCP.Socket)
    (promise : IO.Promise (Except IO.Error α))
    (deadlineNanos : Nat)
    (failureMessage : String)
    (pollMs : Nat := 10) : IO (ReceiveWaitResult α) := do
  let resultTask := promise.result?
  let rec loop : IO (ReceiveWaitResult α) := do
    if ← IO.hasFinished resultTask then
      let some result ← IO.wait resultTask
        | throw <| IO.userError failureMessage
      match result with
      | .ok value => pure <| .completed value
      | .error err => throw err
    else if (← IO.monoNanosNow) >= deadlineNanos then
      -- The caller abandons and closes this connection after timeout. Cancel the exact pending UV
      -- receive first so no read remains attached to the socket.
      TCP.Socket.cancelRecv client
      pure .timedOut
    else
      IO.sleep pollMs.toUInt32
      loop
  loop

def connect (endpoint : Endpoint) : IO Connection := do
  match endpoint with
  | .tcp port =>
      let addr := localhost port
      let client ← TCP.Socket.new
      let promise ← TCP.Socket.connect client addr
      waitTcpPromise promise "Beam daemon connection failed before TCP connect completed"
      pure <| .tcp client

def bindAndListen (endpoint : Endpoint) (backlog : UInt32 := 16) : IO Listener := do
  match endpoint with
  | .tcp port =>
      let server ← TCP.Socket.new
      TCP.Socket.bind server (localhost port)
      TCP.Socket.listen server backlog
      pure <| .tcp server

def accept (listener : Listener) : IO Connection := do
  match listener with
  | .tcp server =>
      let promise ← TCP.Socket.accept server
      pure <| .tcp (← waitTcpPromise promise "Beam daemon listener closed before TCP accept completed")

def closeConnection (conn : Connection) : IO Unit := do
  match conn with
  | .tcp client =>
      try
        let promise ← TCP.Socket.shutdown client
        waitTcpPromise promise "Beam daemon connection closed before TCP shutdown completed"
      catch _ =>
        pure ()

def closeListener (listener : Listener) : IO Unit := do
  match listener with
  | .tcp server =>
      try
        TCP.Socket.cancelAccept server
      catch _ =>
        pure ()

private def sendMsgTcp (client : TCP.Socket) (msg : String) : IO Unit := do
  let bytes := msg.toUTF8
  let header := s!"{bytes.size}\n".toUTF8
  let promise ← TCP.Socket.send client #[header, bytes]
  waitTcpPromise promise "Beam daemon connection closed before TCP send completed"

private def receiveTcp (client : TCP.Socket) (size : UInt64) : IO (ReceiveWaitResult (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  .completed <$> waitTcpPromise promise "Beam daemon connection closed during TCP receive"

private def receiveTcpUntil
    (client : TCP.Socket)
    (size : UInt64)
    (deadlineNanos : Nat) : IO (ReceiveWaitResult (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  waitTcpReceivePromiseUntil client promise deadlineNanos
    "Beam daemon connection closed during TCP receive"

private def recvMsgTcpUsing
    (receive : UInt64 → IO (ReceiveWaitResult (Option ByteArray))) : IO (Option String) := do
  let mut header := ByteArray.empty
  repeat
    match ← receive 1 with
    | .timedOut => return none
    | .completed none => throw <| IO.userError "Beam daemon connection closed"
    | .completed (some chunk) =>
        if chunk[0]! == '\n'.toUInt8 then
          break
        header := header ++ chunk
  let some lenStr := String.fromUTF8? header
    | throw <| IO.userError "invalid Beam daemon header"
  let some len := lenStr.toNat?
    | throw <| IO.userError "invalid Beam daemon length"
  let mut payload := ByteArray.empty
  while payload.size < len do
    match ← receive (len - payload.size).toUInt64 with
    | .timedOut => return none
    | .completed none => throw <| IO.userError "Beam daemon connection closed"
    | .completed (some chunk) => payload := payload ++ chunk
  let some msg := String.fromUTF8? payload
    | throw <| IO.userError "invalid Beam daemon UTF-8"
  pure (some msg)

private def recvMsgTcp (client : TCP.Socket) : IO String := do
  let some msg ← recvMsgTcpUsing (receiveTcp client)
    | throw <| IO.userError "unbounded Beam daemon receive timed out"
  pure msg

private def recvMsgTcpUntil (client : TCP.Socket) (deadlineNanos : Nat) : IO (Option String) := do
  recvMsgTcpUsing (receiveTcpUntil client · deadlineNanos)

def sendMsg (conn : Connection) (msg : String) : IO Unit := do
  match conn with
  | .tcp client => sendMsgTcp client msg

def recvMsg (conn : Connection) : IO String := do
  match conn with
  | .tcp client => recvMsgTcp client

/-- Receive one framed message by an absolute monotonic deadline, returning `none` on timeout. -/
def recvMsgUntil (conn : Connection) (deadlineNanos : Nat) : IO (Option String) := do
  match conn with
  | .tcp client => recvMsgTcpUntil client deadlineNanos

end Beam.Broker.Transport
