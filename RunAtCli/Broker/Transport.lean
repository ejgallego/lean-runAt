/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Std.Internal.Async.TCP
import Std.Net.Addr
import RunAtCli.Broker.UnixNative

open Lean
open Std.Internal.IO.Async

namespace RunAtCli.Broker.Transport

open Std.Net

inductive Endpoint where
  | tcp (port : UInt16)
  | unix (path : System.FilePath)
  deriving Repr, BEq

inductive Connection where
  | tcp (client : TCP.Socket.Client)
  | unix (fd : UInt32)

inductive Listener where
  | tcp (server : TCP.Socket.Server)
  | unix (fd : UInt32) (path : System.FilePath)

def localhost (port : UInt16) : SocketAddress :=
  SocketAddressV4.mk (.ofParts 127 0 0 1) port

def endpointDescription : Endpoint → String
  | .tcp port => s!"tcp://127.0.0.1:{port.toNat}"
  | .unix path => s!"unix://{path}"

def connect (endpoint : Endpoint) : IO Connection := do
  match endpoint with
  | .tcp port =>
      let addr := localhost port
      let client ← TCP.Socket.Client.mk
      let task ← (client.connect addr).toIO
      task.block
      pure <| .tcp client
  | .unix path =>
      let fd ← UnixNative.connect path.toString
      pure <| .unix fd

def bindAndListen (endpoint : Endpoint) (backlog : UInt32 := 16) : IO Listener := do
  match endpoint with
  | .tcp port =>
      let server ← TCP.Socket.Server.mk
      server.bind (localhost port)
      server.listen backlog
      pure <| .tcp server
  | .unix path =>
      if let some parent := path.parent then
        IO.FS.createDirAll parent
      let fd ← UnixNative.listen path.toString
      pure <| .unix fd path

def accept (listener : Listener) : IO Connection := do
  match listener with
  | .tcp server =>
      let task ← (server.accept).toIO
      pure <| .tcp (← task.block)
  | .unix fd _ =>
      pure <| .unix (← UnixNative.accept fd)

def closeConnection (conn : Connection) : IO Unit := do
  match conn with
  | .tcp client =>
      try
        let task ← (client.shutdown).toIO
        task.block
      catch _ =>
        pure ()
  | .unix fd =>
      try
        UnixNative.close fd
      catch _ =>
        pure ()

def closeListener (listener : Listener) : IO Unit := do
  match listener with
  | .tcp _ =>
      pure ()
  | .unix fd path =>
      try
        UnixNative.close fd
      catch _ =>
        pure ()
      try
        if ← path.pathExists then
          IO.FS.removeFile path
      catch _ =>
        pure ()

private def sendMsgTcp (client : TCP.Socket.Client) (msg : String) : IO Unit := do
  let bytes := msg.toUTF8
  let header := s!"{bytes.size}\n".toUTF8
  let task ← (client.sendAll #[header, bytes]).toIO
  task.block

private def recvMsgTcp (client : TCP.Socket.Client) : IO String := do
  let mut header := ByteArray.empty
  repeat
    let task ← (client.recv? 1).toIO
    let some chunk ← task.block
      | throw <| IO.userError "CLI daemon connection closed"
    if chunk[0]! == '\n'.toUInt8 then
      break
    header := header ++ chunk
  let some lenStr := String.fromUTF8? header
    | throw <| IO.userError "invalid CLI daemon header"
  let some len := lenStr.toNat?
    | throw <| IO.userError "invalid CLI daemon length"
  let mut payload := ByteArray.empty
  while payload.size < len do
    let task ← (client.recv? (len - payload.size).toUInt64).toIO
    let some chunk ← task.block
      | throw <| IO.userError "CLI daemon connection closed"
    payload := payload ++ chunk
  let some msg := String.fromUTF8? payload
    | throw <| IO.userError "invalid CLI daemon UTF-8"
  pure msg

def sendMsg (conn : Connection) (msg : String) : IO Unit := do
  match conn with
  | .tcp client => sendMsgTcp client msg
  | .unix fd => UnixNative.sendMsg fd msg

def recvMsg (conn : Connection) : IO String := do
  match conn with
  | .tcp client => recvMsgTcp client
  | .unix fd => UnixNative.recvMsg fd

end RunAtCli.Broker.Transport
