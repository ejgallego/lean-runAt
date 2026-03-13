/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import RunAtCli.Broker.Protocol
import RunAtCli.Broker.Transport

open Lean

namespace RunAtCli.Broker

structure StreamCallbacks where
  onFileProgress : Option String → SyncFileProgress → IO Unit := fun _ _ => pure ()
  onDiagnostic : Option String → StreamDiagnostic → IO Unit := fun _ _ => pure ()

abbrev Endpoint := Transport.Endpoint

def parsePortText (name value : String) : Except String UInt16 := do
  let some n := value.toNat?
    | throw s!"invalid {name} '{value}'"
  if n < UInt16.size then
    pure n.toUInt16
  else
    throw s!"{name} '{value}' is outside the supported range 0-65535"

def parseEndpointOption (args : List String) : Except String (Endpoint × List String) := do
  match args with
  | "--socket" :: path :: rest =>
      pure (.unix (System.FilePath.mk path), rest)
  | "--port" :: port :: rest =>
      pure (.tcp (← parsePortText "port" port), rest)
  | _ =>
      pure (.tcp 8765, args)

def parsePortOption (args : List String) : Except String (UInt16 × List String) := do
  match args with
  | "--port" :: port :: rest =>
      pure (← parsePortText "port" port, rest)
  | _ =>
      pure (8765, args)

private def decodeStreamMessage (msg : String) : IO StreamMessage := do
  match Json.parse msg with
  | .error err => throw <| IO.userError s!"invalid CLI daemon response json: {err}"
  | .ok json =>
      match fromJson? json with
      | .ok (stream : StreamMessage) => pure stream
      | .error _ =>
          match fromJson? json with
          | .ok (resp : Response) => pure <| StreamMessage.mkResponse resp
          | .error err => throw <| IO.userError s!"invalid CLI daemon response payload: {err}"

private def diagnosticSeverityLabel : Option Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "info"
  | some .hint => "hint"
  | none => "diagnostic"

private def condenseDiagnosticMessage (message : String) : String :=
  String.intercalate " / " <|
    ((message.split (· == '\n')).toList.map (fun line => line.trimAscii.toString)).filter
      (fun line => !line.isEmpty)

def formatStreamDiagnostic (diagnostic : StreamDiagnostic) : String :=
  let pos := diagnostic.range.start
  let line := pos.line + 1
  let character := pos.character + 1
  let severity := diagnosticSeverityLabel diagnostic.severity?
  let message := condenseDiagnosticMessage diagnostic.message
  s!"runat: diagnostic {severity} {diagnostic.path}:{line}:{character}: {message}"

partial def sendRequestWithStream
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit) : IO Response := do
  let client ← Transport.connect endpoint
  try
    Transport.sendMsg client (toJson req).compress
    let rec loop : IO Response := do
      let msg ← Transport.recvMsg client
      let stream ← decodeStreamMessage msg
      onStream stream
      match stream.kind with
      | .response =>
          let some resp := stream.response?
            | throw <| IO.userError "invalid CLI daemon response stream: missing response payload"
          pure resp
      | .fileProgress | .diagnostic =>
          loop
    loop
  finally
    Transport.closeConnection client

partial def sendRequestWithCallbacks
    (endpoint : Endpoint)
    (req : Request)
    (callbacks : StreamCallbacks := {}) : IO Response := do
  sendRequestWithStream endpoint req fun stream => do
    match stream.kind with
    | .response =>
        pure ()
    | .fileProgress =>
        let some progress := stream.fileProgress?
          | throw <| IO.userError "invalid CLI daemon response stream: missing fileProgress payload"
        callbacks.onFileProgress stream.clientRequestId? progress
    | .diagnostic =>
        let some diagnostic := stream.diagnostic?
          | throw <| IO.userError "invalid CLI daemon response stream: missing diagnostic payload"
        callbacks.onDiagnostic stream.clientRequestId? diagnostic
def sendRequestWithProgress
    (endpoint : Endpoint)
    (req : Request)
    (onFileProgress : Option String → SyncFileProgress → IO Unit) : IO Response :=
  sendRequestWithCallbacks endpoint req { onFileProgress := onFileProgress }

def sendRequest (endpoint : Endpoint) (req : Request) : IO Response :=
  sendRequestWithCallbacks endpoint req

def readRequestFromStdin : IO Request := do
  let input ← (← IO.getStdin).readToEnd
  match Json.parse input with
  | .error err => throw <| IO.userError s!"invalid request json: {err}"
  | .ok json =>
      match fromJson? json with
      | .ok req => pure req
      | .error err => throw <| IO.userError s!"invalid request payload: {err}"

def printResponse (resp : Response) : IO Unit := do
  IO.println (toJson resp).pretty

def failOnError (resp : Response) : IO Unit := do
  if resp.ok then
    pure ()
  else
    throw <| IO.userError ((resp.error?.map (·.message)).getD "CLI daemon error")

end RunAtCli.Broker
