/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Protocol
import BeamTest.Broker.ClientUtil

open Lean

namespace BeamTest.Broker.TestUtil

structure StreamRun where
  response : Beam.Broker.Response
  messages : Array Beam.Broker.StreamMessage

def runBrokerStream
    (port : UInt16)
    (req : Beam.Broker.Request) : IO StreamRun := do
  let req := inFixtureWorkspace req
  let messagesRef ← IO.mkRef #[]
  let response ← Beam.Broker.sendRequestWithStream (.tcp port) req fun message =>
    messagesRef.modify (·.push message)
  pure {
    response
    messages := ← messagesRef.get
  }

def requireSuccessStream (label : String) (run : StreamRun) :
    IO (Array Beam.Broker.StreamMessage) := do
  unless run.response.ok do
    throw <| IO.userError s!"expected {label} stream success, got {(toJson run.response).compress}"
  pure run.messages

def requireFailedStream (label : String) (run : StreamRun) :
    IO (Array Beam.Broker.StreamMessage) := do
  if run.response.ok then
    throw <| IO.userError s!"expected {label} stream failure"
  pure run.messages

end BeamTest.Broker.TestUtil
