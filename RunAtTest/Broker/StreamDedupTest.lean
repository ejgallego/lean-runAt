/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtCli.Broker.Protocol
import RunAtCli.Broker.Server
import Lean

open Lean

namespace RunAtTest.Broker.StreamDedupTest

private def jsonPos (line character : Nat) : Json :=
  Json.mkObj [
    ("line", toJson line),
    ("character", toJson character)
  ]

private def jsonRange (line character endCharacter : Nat) : Json :=
  Json.mkObj [
    ("start", jsonPos line character),
    ("end", jsonPos line endCharacter)
  ]

private def jsonDiagnostic (line character endCharacter severity : Nat) (message : String) : Json :=
  Json.mkObj [
    ("range", jsonRange line character endCharacter),
    ("severity", toJson severity),
    ("message", toJson message)
  ]

private def jsonPublishDiagnostics
    (uri : String)
    (version : Nat)
    (diagnostics : Array Json) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson ("2.0" : String)),
    ("method", toJson ("textDocument/publishDiagnostics" : String)),
    ("params", Json.mkObj [
      ("uri", toJson uri),
      ("version", toJson version),
      ("diagnostics", Json.arr diagnostics)
    ])
  ]

private def jsonResponse (id : Nat) (result : Json := Json.mkObj []) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson ("2.0" : String)),
    ("id", toJson id),
    ("result", result)
  ]

private def lspFrame (json : Json) : String :=
  let body := json.compress
  s!"Content-Length: {body.length}\r\n\r\n{body}"

private def writeTranscript (messages : Array Json) : IO System.FilePath := do
  let path := System.FilePath.mk s!"/tmp/runat-broker-transcript-{← IO.monoNanosNow}.txt"
  IO.FS.writeFile path <| String.intercalate "" <| messages.toList.map lspFrame
  pure path

private def fakeTrackedSession (root transcript : System.FilePath) : IO RunAtCli.Broker.Session := do
  let proc ← IO.Process.spawn {
    toStdioConfig := RunAtCli.Broker.brokerStdio
    cmd := "bash"
    args := #["-lc", s!"cat {transcript}; sleep 1"]
    cwd := root.toString
  }
  let pending ← Std.Mutex.new ({} : Std.TreeMap Lean.JsonRpc.RequestID RunAtCli.Broker.PendingRequest)
  let session : RunAtCli.Broker.Session := {
    backend := .lean
    root
    epoch := 1
    sessionToken := "fake-tracked-session"
    proc
    stdin := IO.FS.Stream.ofHandle proc.stdin
    stdout := IO.FS.Stream.ofHandle proc.stdout
    pending
  }
  let _ ← IO.asTask <| RunAtCli.Broker.sessionReaderLoop session
  pure session

def check : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/runat-broker-dedup-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  let path := root / "Tracked.lean"
  IO.FS.writeFile path "-- fake tracked file\n"
  let uri := RunAtCli.Broker.sessionUri path
  let first := jsonDiagnostic 0 0 4 2 "first warning"
  let second := jsonDiagnostic 1 2 6 2 "second warning"
  let transcript ← writeTranscript #[
    jsonPublishDiagnostics uri 1 #[first],
    jsonPublishDiagnostics uri 1 #[first],
    jsonPublishDiagnostics uri 1 #[first, second],
    jsonPublishDiagnostics uri 1 #[first, second],
    jsonResponse 1
  ]
  let session ← fakeTrackedSession root transcript
  let streamedRef ← IO.mkRef #[]
  try
    let (_session, _result, _progress?, diagnostics) ←
      RunAtCli.Broker.sendRequestJsonTrackedDetailed session "textDocument/waitForDiagnostics"
        (toJson <| Lean.Lsp.WaitForDiagnosticsParams.mk uri 1)
        (tracked := some (uri, 1))
        (fullDiagnostics := true)
        (emitDiagnostic? := some fun diagnostic =>
          streamedRef.modify fun seen => seen.push diagnostic)
    let streamed ← streamedRef.get
    if streamed.size != 2 then
      throw <| IO.userError s!"expected two deduped streamed diagnostics, got {(toJson streamed).compress}"
    unless streamed.all (fun diagnostic => diagnostic.path == "Tracked.lean") do
      throw <| IO.userError s!"expected deduped diagnostic paths to stay relative, got {(toJson streamed).compress}"
    unless streamed.map (·.message) == #["first warning", "second warning"] do
      throw <| IO.userError s!"expected deduped diagnostics in first-seen order, got {(toJson streamed).compress}"
    unless diagnostics.map (·.message) == #["first warning", "second warning"] do
      throw <| IO.userError s!"expected final tracked diagnostics snapshot to keep both warnings, got {(toJson diagnostics).compress}"
  finally
    try
      session.proc.kill
    catch _ =>
      pure ()
    discard <| session.proc.tryWait

#eval check

end RunAtTest.Broker.StreamDedupTest
