/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.JsonPretty
import Beam.Broker.Protocol
import Beam.Broker.Transport

open Lean

namespace Beam.Broker

structure StreamCallbacks where
  onFileProgress : Option String → SyncFileProgress → IO Unit := fun _ _ => pure ()
  onDiagnostic : Option String → StreamDiagnostic → IO Unit := fun _ _ => pure ()

abbrev Endpoint := Transport.Endpoint

/-- Classify failures produced while a broker client exchanges one streamed request. -/
inductive BrokerClientFailureKind where
  | transport
  | invalidResponse
  | streamCallback
  deriving BEq, Repr

/-- Keep broker client failures typed until a CLI or transport presentation boundary. -/
structure BrokerClientFailure where
  kind : BrokerClientFailureKind
  detail : String
  deriving BEq, Repr

def parsePortText (name value : String) : Except String UInt16 := do
  let some n := value.toNat?
    | throw s!"invalid {name} '{value}'"
  if n < UInt16.size then
    pure n.toUInt16
  else
    throw s!"{name} '{value}' is outside the supported range 0-65535"

def parseEndpointOption (args : List String) : Except String (Endpoint × List String) := do
  match args with
  | "--port" :: port :: rest =>
      pure (.tcp (← parsePortText "port" port), rest)
  | _ =>
      pure (.tcp 8765, args)

private def decodeStreamMessage (msg : String) : IO StreamMessage := do
  match Json.parse msg with
  | .error err => throw <| IO.userError s!"invalid Beam daemon response json: {err}"
  | .ok json =>
      match fromJson? (α := StreamMessage) json with
      | .ok stream => pure stream
      | .error err => throw <| IO.userError s!"invalid Beam daemon response payload: {err}"

private def captureClientFailure
    (kind : BrokerClientFailureKind)
    (action : IO α) : IO (Except BrokerClientFailure α) := do
  try
    pure <| .ok (← action)
  catch e =>
    pure <| .error { kind, detail := e.toString }

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
  let blocking :=
    if diagnostic.completionBlocking then
      " completionBlocking=true"
    else
      ""
  s!"beam: diagnostic {severity}{blocking} {diagnostic.path}:{line}:{character}: {message}"

/-- Send one request while preserving transport, response, and callback failures as typed data. -/
partial def sendRequestWithStreamResult
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit) : IO (Except BrokerClientFailure Response) := do
  let client ←
    match ← captureClientFailure .transport (Transport.connect endpoint) with
    | .ok client => pure client
    | .error failure => return .error failure
  try
    match ← captureClientFailure .transport <|
        Transport.sendMsg client (toJson req).compress with
    | .ok () => pure ()
    | .error failure => return .error failure
    let rec loop : IO (Except BrokerClientFailure Response) := do
      let msg ←
        match ← captureClientFailure .transport (Transport.recvMsg client) with
        | .ok msg => pure msg
        | .error failure => return .error failure
      let stream ←
        match ← captureClientFailure .invalidResponse (decodeStreamMessage msg) with
        | .ok stream => pure stream
        | .error failure => return .error failure
      unless stream.clientRequestId? == req.clientRequestId? do
        return .error {
          kind := .invalidResponse
          detail :=
            s!"Beam daemon stream request id {stream.clientRequestId?} does not match request id {req.clientRequestId?}"
        }
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

partial def sendRequestWithStream
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit) : IO Response := do
  match ← sendRequestWithStreamResult endpoint req onStream with
  | .ok response => pure response
  | .error failure => throw <| IO.userError failure.detail

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
  | .error failure => throw <| IO.userError failure.detail
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

/-- Render a CLI response, optionally adding caller-visible correlation at the presentation edge. -/
def responseOutputJson (resp : Response) (clientRequestId? : Option String := none) : Json :=
  match clientRequestId? with
  | some clientRequestId =>
      (toJson resp).setObjVal! "clientRequestId" (toJson clientRequestId)
  | none =>
      toJson resp

def printResponse (resp : Response) (clientRequestId? : Option String := none) : IO Unit := do
  IO.println <| Beam.orderedJsonPretty (responseOutputJson resp clientRequestId?)

def failOnError (resp : Response) : IO Unit := do
  match resp with
  | .successResult .. => pure ()
  | .errorResult failure => throw <| IO.userError failure.error.message

end Beam.Broker
