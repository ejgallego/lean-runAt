/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Protocol

open Lean

namespace Beam.BrokerClient

open Beam.Broker

private inductive ClientMode where
  | request
  | requestStream

private def usage : String :=
  String.intercalate "\n" [
    "usage: beam-client [--port N] request <json|-> | request-stream <json|->",
    "",
    "beam-client is raw port-oriented maintainer/debug tooling.",
    "For wrapper sessions, use: lean-beam --root PATH [--session-dir DIR] request-stream <json|->",
    "That supported machine interface selects the session descriptor and injects routing/authentication.",
    "",
    "request prints the final response on stdout and formats streamed diagnostics for humans on stderr.",
    "raw request-stream prints one compact StreamMessage JSON line",
    "per event on stdout using kind + payload + optional clientRequestId; kinds are",
    "diagnostic | fileProgress | response, and the final response is last."
  ]

private def parseRequestArg (json : String) : IO Request := do
  if json == "-" then
    readRequestFromStdin
  else
    match Json.parse json with
    | .error err => throw <| IO.userError s!"invalid request json: {err}"
    | .ok j =>
        match fromJson? j with
        | .ok req => pure req
        | .error err => throw <| IO.userError s!"invalid request payload: {err}"

private def parseRequest (args : List String) : IO (ClientMode × Request) := do
  match args with
  | ["request", json] =>
      pure (.request, ← parseRequestArg json)
  | ["request-stream", json] =>
      pure (.requestStream, ← parseRequestArg json)
  | _ =>
      throw <| IO.userError usage

def main (args : List String) : IO Unit := do
  let (endpoint, args) ← IO.ofExcept <| parseEndpointOption args
  let (mode, req) ← parseRequest args
  match mode with
  | .request =>
      let resp ← sendRequestWithCallbacks endpoint req {
        onDiagnostic := fun clientRequestId? diagnostic => do
          let msg := formatStreamDiagnostic diagnostic
          let msg :=
            match clientRequestId? with
            | some clientRequestId =>
                if msg.startsWith "beam:" then
                  s!"beam[{clientRequestId}]:" ++ (msg.drop 6).toString
                else
                  s!"beam[{clientRequestId}]: {msg}"
            | none => msg
          IO.eprintln msg
      }
      printResponse resp req.clientRequestId?
      failOnError resp
  | .requestStream =>
      let resp ← sendRequestWithStream endpoint req fun stream =>
        IO.println (toJson stream).compress
      if resp.ok then
        pure ()
      else
        IO.Process.exit 1

end Beam.BrokerClient

def main := Beam.BrokerClient.main
