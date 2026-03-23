/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Protocol
import Beam.Broker.Transport
import RunAtTest.TestHarness

open Lean

namespace RunAtTest.Broker.TestUtil

structure ProgressEvent where
  clientRequestId? : Option String := none
  progress : Beam.Broker.SyncFileProgress

abbrev nullBrokerStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .null
def daemonExe : IO System.FilePath := do
  pure <| (← IO.appPath).parent.getD (System.FilePath.mk ".") / "beam-daemon"

def clientExe : IO System.FilePath := do
  pure <| (← IO.appPath).parent.getD (System.FilePath.mk ".") / "beam-client"

def repoRoot : IO System.FilePath := do
  IO.FS.realPath <| System.FilePath.mk "."

def mkTempProjectRoot (namePrefix : String) : IO System.FilePath := do
  pure <| System.FilePath.mk s!"/tmp/{namePrefix}-{← IO.monoNanosNow}"

def copySaveProjectFixture (dest : System.FilePath) : IO Unit := do
  let src := (← repoRoot) / "tests" / "save_olean_project"
  IO.FS.createDirAll dest
  let out ← IO.Process.output {
    cmd := "rsync"
    args := #["-a", s!"{src.toString}/", s!"{dest.toString}/"]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to copy save_olean_project fixture\n{out.stderr}"

def saveWarningFileText (marker : String) : String :=
  String.intercalate "\n" [
    "def bVal : Nat := 1",
    "",
    "set_option linter.unusedVariables true in",
    "theorem warnOnly (n : Nat) : True := by",
    "  trivial",
    "",
    marker
  ] ++ "\n"

def writeSaveWarningFile (root : System.FilePath) (marker : String) : IO Unit := do
  IO.FS.writeFile (root / "SaveSmoke" / "B.lean") (saveWarningFileText marker)

private structure ProcessInfo where
  pid : Nat
  ppid : Nat
  state : String
  cmd : String

private def isZombie (proc : ProcessInfo) : Bool :=
  proc.state.contains "Z"

private def listProcesses : IO (Array ProcessInfo) := do
  let out ← IO.Process.output {
    cmd := "ps"
    args := #["-eo", "pid=,ppid=,state=,args="]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to list processes\n{out.stderr}"
  let mut procs := #[]
  for rawLine in out.stdout.split (· == '\n') do
    let parts : List String :=
      (rawLine.trimAscii.toString.split (· == ' ') |>.filterMap fun part =>
        let part := part.trimAscii.toString
        if part.isEmpty then none else some part).toList
    match parts with
    | pidText :: ppidText :: stateText :: cmdParts =>
        match pidText.toNat?, ppidText.toNat? with
        | some pid, some ppid =>
            procs := procs.push {
              pid
              ppid
              state := stateText
              cmd := String.intercalate " " cmdParts
            }
        | _, _ =>
            pure ()
    | _ =>
        pure ()
  pure procs

private def requireUniquePid (label : String) (candidates : Array ProcessInfo) : IO Nat := do
  match candidates.toList with
  | [proc] =>
      pure proc.pid
  | [] =>
      throw <| IO.userError s!"expected one {label} process, found none"
  | _ =>
      throw <| IO.userError s!"expected one {label} process, found {candidates.size}"

private partial def waitForPidGone (pid : Nat) (tries : Nat := 40) : IO Unit := do
  if tries == 0 then
    throw <| IO.userError s!"timed out waiting for pid {pid} to exit"
  let procs ← listProcesses
  if procs.any (fun proc => proc.pid == pid && !isZombie proc) then
    IO.sleep 100
    waitForPidGone pid (tries - 1)
  else
    pure ()

def killLeanServerForEndpoint
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let port ←
    match endpoint with
    | .tcp port => pure port
    | .unix _ => throw <| IO.userError "worker-death helper only supports tcp endpoints"
  let procs ← listProcesses
  let brokerPid ← requireUniquePid "broker daemon" <| procs.filter fun proc =>
    proc.cmd.contains "beam-daemon" &&
      proc.cmd.contains s!"--port {port.toNat}" &&
      proc.cmd.contains s!"--root {root.toString}"
  let serverPid ← requireUniquePid "Lean server" <| procs.filter fun proc =>
    proc.ppid == brokerPid && proc.cmd.contains "--server"
  let out ← IO.Process.output {
    cmd := "kill"
    args := #["-9", toString serverPid]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to kill Lean server pid {serverPid}\n{out.stderr}"
  waitForPidGone serverPid

def spawnLeanBrokerWithPlugin
    (endpoint : Beam.Broker.Endpoint)
    (root leanPlugin : System.FilePath)
    (leanCmd : String := "lean") : IO (IO.Process.Child nullBrokerStdio) := do
  let port ←
    match endpoint with
    | .tcp port => pure port
    | .unix _ => throw <| IO.userError "test Lean broker helpers only support tcp endpoints"
  IO.Process.spawn {
    toStdioConfig := nullBrokerStdio
    cmd := (← daemonExe).toString
    args := #[
      "--port", toString port.toNat,
      "--root", root.toString,
      "--lean-cmd", leanCmd,
      "--lean-plugin", leanPlugin.toString
    ]
    setsid := true
  }

def spawnLeanBroker
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (leanCmd : String := "lean") : IO (IO.Process.Child nullBrokerStdio) := do
  spawnLeanBrokerWithPlugin endpoint root (← RunAtTest.TestHarness.pluginPath) leanCmd

partial def waitForBrokerReady
    (endpoint : Beam.Broker.Endpoint)
    (tries : Nat := 50) : IO Unit := do
  try
    let conn ← Beam.Broker.Transport.connect endpoint
    Beam.Broker.Transport.closeConnection conn
  catch _ =>
    if tries == 0 then
      throw <| IO.userError s!"timed out waiting for Beam daemon at {Beam.Broker.Transport.endpointDescription endpoint}"
    IO.sleep 100
    waitForBrokerReady endpoint (tries - 1)

def runClientWithStream
    (endpoint : Beam.Broker.Endpoint)
    (req : Beam.Broker.Request) :
    IO (Beam.Broker.Response × Array Beam.Broker.SyncFileProgress × Array Beam.Broker.StreamDiagnostic) := do
  let progressRef ← IO.mkRef #[]
  let diagnosticRef ← IO.mkRef #[]
  let resp ← Beam.Broker.sendRequestWithCallbacks endpoint req {
    onFileProgress := fun _ progress =>
      progressRef.modify fun seen => seen.push progress
    onDiagnostic := fun _ diagnostic =>
      diagnosticRef.modify fun seen => seen.push diagnostic
  }
  pure (resp, ← progressRef.get, ← diagnosticRef.get)

def runClientWithProgress
    (endpoint : Beam.Broker.Endpoint)
    (req : Beam.Broker.Request) : IO (Beam.Broker.Response × Array ProgressEvent) := do
  let progressRef ← IO.mkRef #[]
  let resp ← Beam.Broker.sendRequestWithCallbacks endpoint req {
    onFileProgress := fun clientRequestId? progress =>
      progressRef.modify fun seen => seen.push { clientRequestId?, progress }
  }
  pure (resp, ← progressRef.get)

def runClient (endpoint : Beam.Broker.Endpoint) (req : Beam.Broker.Request) : IO Beam.Broker.Response := do
  let (resp, _) ← runClientWithProgress endpoint req
  pure resp

def requireFileProgress (label : String) (resp : Beam.Broker.Response) :
    IO Beam.Broker.SyncFileProgress := do
  let some progress := resp.fileProgress?
    | throw <| IO.userError s!"expected {label} to include top-level fileProgress"
  pure progress

def expectNoReplayDiagnosticsField (label : String) (payload : Json) : IO Unit := do
  match payload.getObjVal? "diagnostics" with
  | .ok diagnostics =>
      throw <| IO.userError s!"expected {label} payload to omit replayed diagnostics, got {diagnostics.compress}"
  | .error _ =>
      pure ()

def requireFinalStreamResponse
    (label : String)
    (messages : Array Beam.Broker.StreamMessage) : IO Beam.Broker.Response := do
  if messages.isEmpty then
    throw <| IO.userError s!"expected {label} stream messages"
  let responseCount := messages.foldl (init := 0) fun acc msg =>
    acc + if msg.kind == .response then 1 else 0
  if responseCount != 1 then
    throw <| IO.userError s!"expected exactly one {label} response message, got {(toJson messages).compress}"
  let some last := messages.back?
    | throw <| IO.userError s!"expected {label} final response"
  if last.kind != .response then
    throw <| IO.userError s!"expected {label} response to arrive last, got {(toJson messages).compress}"
  let some resp := last.response?
    | throw <| IO.userError s!"expected {label} final response payload"
  pure resp

def expectStreamKindsOnly
    (label : String)
    (messages : Array Beam.Broker.StreamMessage) : IO Unit := do
  unless messages.all (fun msg =>
      msg.kind == .diagnostic || msg.kind == .fileProgress || msg.kind == .response) do
    throw <| IO.userError
      s!"expected {label} kinds to stay within diagnostic/fileProgress/response, got {(toJson messages).compress}"

def requireAnyStreamDiagnostics
    (label : String)
    (messages : Array Beam.Broker.StreamMessage) : IO (Array Beam.Broker.StreamDiagnostic) := do
  let diagnostics := messages.filterMap (·.diagnostic?)
  if diagnostics.isEmpty then
    throw <| IO.userError s!"expected {label} to stream diagnostics, got {(toJson messages).compress}"
  pure diagnostics

def requireAnyStreamFileProgress
    (label : String)
    (messages : Array Beam.Broker.StreamMessage) : IO (Array Beam.Broker.SyncFileProgress) := do
  let progress := messages.filterMap (·.fileProgress?)
  if progress.isEmpty then
    throw <| IO.userError s!"expected {label} to stream fileProgress, got {(toJson messages).compress}"
  pure progress

def expectDiagnosticsForPath
    (label path : String)
    (diagnostics : Array Beam.Broker.StreamDiagnostic) : IO Unit := do
  unless diagnostics.all (fun diagnostic => diagnostic.path == path) do
    throw <| IO.userError s!"expected {label} diagnostics for {path}, got {(toJson diagnostics).compress}"

def expectNonErrorDiagnosticsForPath
    (label path : String)
    (diagnostics : Array Beam.Broker.StreamDiagnostic) : IO Unit := do
  unless diagnostics.all (fun diagnostic =>
      diagnostic.path == path && diagnostic.severity? != some .error) do
    throw <| IO.userError
      s!"expected {label} non-error diagnostics for {path}, got {(toJson diagnostics).compress}"

def expectWarningDiagnosticPresent
    (label : String)
    (diagnostics : Array Beam.Broker.StreamDiagnostic) : IO Unit := do
  unless diagnostics.any (fun diagnostic => diagnostic.severity? == some .warning) do
    throw <| IO.userError
      s!"expected {label} diagnostics to include at least one warning, got {(toJson diagnostics).compress}"

def expectOk (resp : Beam.Broker.Response) : IO Json := do
  if !resp.ok then
    throw <| IO.userError s!"unexpected Beam daemon error: {(toJson resp).compress}"
  return resp.result?.getD Json.null

def expectErrCode (resp : Beam.Broker.Response) (code : String) : IO Unit := do
  if resp.ok then
    throw <| IO.userError s!"expected error {code}, got success {(toJson resp).compress}"
  let actual := resp.error?.map (·.code)
  if actual != some code && actual != some "-32602" then
    throw <| IO.userError s!"expected error {code}, got {(toJson resp).compress}"

def expectOpCountAtLeast (payload : Json) (backend op : String) (minCount : Nat) : IO Unit := do
  let byBackend ← IO.ofExcept <| payload.getObjVal? "byBackend"
  let backendPayload ← IO.ofExcept <| byBackend.getObjVal? backend
  let ops ← IO.ofExcept <| backendPayload.getObjVal? "ops"
  let opPayload ← IO.ofExcept <| ops.getObjVal? op
  let count ← IO.ofExcept <| opPayload.getObjValAs? Nat "count"
  if count < minCount then
    throw <| IO.userError s!"expected {backend}/{op} count >= {minCount}, got {count}"

def expectBackendMetricAtLeast (payload : Json) (backend field : String) (minCount : Nat) : IO Unit := do
  let byBackend ← IO.ofExcept <| payload.getObjVal? "byBackend"
  let backendPayload ← IO.ofExcept <| byBackend.getObjVal? backend
  let count ← IO.ofExcept <| backendPayload.getObjValAs? Nat field
  if count < minCount then
    throw <| IO.userError s!"expected {backend}.{field} >= {minCount}, got {count}"

def expectOpMetricAtLeast (payload : Json) (backend op field : String) (minCount : Nat) : IO Unit := do
  let byBackend ← IO.ofExcept <| payload.getObjVal? "byBackend"
  let backendPayload ← IO.ofExcept <| byBackend.getObjVal? backend
  let ops ← IO.ofExcept <| backendPayload.getObjVal? "ops"
  let opPayload ← IO.ofExcept <| ops.getObjVal? op
  let count ← IO.ofExcept <| opPayload.getObjValAs? Nat field
  if count < minCount then
    throw <| IO.userError s!"expected {backend}/{op}.{field} >= {minCount}, got {count}"

end RunAtTest.Broker.TestUtil
