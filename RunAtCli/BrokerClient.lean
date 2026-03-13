/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import RunAtCli.Broker.Client
import RunAtCli.Broker.Protocol

open Lean

namespace RunAtCli.BrokerClient

open RunAtCli.Broker

private inductive ClientMode where
  | request
  | requestStream

private def usage : String :=
  String.intercalate "\n" [
    "usage: runAt-cli-client [--socket PATH | --port N] request <json|-> | request-stream <json|->",
    "",
    "request prints the final response on stdout and formats streamed diagnostics for humans on stderr.",
    "request-stream is the preferred machine interface: it prints one compact StreamMessage JSON line",
    "per event on stdout, with kinds diagnostic | fileProgress | response, and the final response last."
  ]

private def parseRequest (args : List String) : IO (ClientMode × Request) := do
  match args with
  | "request" :: json :: _ =>
      let req ←
        if json == "-" then
          readRequestFromStdin
        else
          match Json.parse json with
          | .error err => throw <| IO.userError s!"invalid request json: {err}"
          | .ok j =>
              match fromJson? j with
              | .ok req => pure req
              | .error err => throw <| IO.userError s!"invalid request payload: {err}"
      pure (.request, req)
  | "request-stream" :: json :: _ =>
      let req ←
        if json == "-" then
          readRequestFromStdin
        else
          match Json.parse json with
          | .error err => throw <| IO.userError s!"invalid request json: {err}"
          | .ok j =>
              match fromJson? j with
              | .ok req => pure req
              | .error err => throw <| IO.userError s!"invalid request payload: {err}"
      pure (.requestStream, req)
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
                if msg.startsWith "runat:" then
                  s!"runat[{clientRequestId}]:" ++ (msg.drop 6).toString
                else
                  s!"runat[{clientRequestId}]: {msg}"
            | none => msg
          IO.eprintln msg
      }
      printResponse resp
      failOnError resp
  | .requestStream =>
      let resp ← sendRequestWithStream endpoint req fun stream =>
        IO.println (toJson stream).compress
      if resp.ok then
        pure ()
      else
        IO.Process.exit 1

end RunAtCli.BrokerClient

def main := RunAtCli.BrokerClient.main
