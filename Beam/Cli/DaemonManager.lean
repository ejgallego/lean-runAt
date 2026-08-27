/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Transport
import Beam.Cli.Args
import Beam.Cli.Lock
import Beam.Cli.Project
import Beam.Daemon.Debug
import Beam.Daemon.Paths

open Lean

namespace Beam.Cli

open Beam.Broker
open Beam.Daemon

/-- Private broker workspace used by the one-project daemon managed by the CLI. -/
def projectDaemonWorkspaceId : WorkspaceId :=
  "beam-cli-project"

private def defaultProjectControlLockTimeoutMs : Nat :=
  60000

private def projectControlLockTimeoutMs : IO Nat := do
  match ← IO.getEnv "BEAM_CONTROL_LOCK_TIMEOUT_MS" with
  | none =>
      pure defaultProjectControlLockTimeoutMs
  | some raw =>
      let some timeoutMs := raw.toNat?
        | throw <| IO.userError
            s!"invalid BEAM_CONTROL_LOCK_TIMEOUT_MS value '{raw}': expected milliseconds"
      if timeoutMs == 0 then
        throw <| IO.userError
          "invalid BEAM_CONTROL_LOCK_TIMEOUT_MS value '0': expected a positive timeout"
      pure timeoutMs

/--
Run `act` while holding the per-project daemon control lock.

Project control operations should fail with owner diagnostics instead of waiting forever behind a
live but stuck wrapper process. Longer bundle build locks intentionally use the lower-level
unbounded lock helper.
-/
private structure ProjectControl where
  root : System.FilePath
  dir : System.FilePath
  registry : System.FilePath

private def projectControl (root : System.FilePath) : IO ProjectControl := do
  let dir ← controlDir root
  pure { root, dir, registry := dir / "beam-daemon.json" }

/-- Supply project registry mutation only for the dynamic extent of the project control lock. -/
private def withProjectControl
    (root : System.FilePath)
    (act : ProjectControl → IO α) : IO α := do
  let control ← projectControl root
  withLockTimeout (control.dir / "lock") (← projectControlLockTimeoutMs) do
    act control

/--
Run teardown under the project lock without recreating a control directory that disappeared with
its project root.
-/
private def withExistingProjectControl
    (root : System.FilePath)
    (act : ProjectControl → IO Unit) : IO Unit := do
  let control ← projectControl root
  unless ← control.dir.isDir do
    return
  try
    withExistingLockTimeout (control.dir / "lock") (← projectControlLockTimeoutMs) do
      act control
  catch
  | .noFileOrDirectory .. => pure ()
  | err => throw err

private def computeConfigHash
    (root : System.FilePath)
    (leanCmd? : Option String)
    (plugin? : Option System.FilePath)
    (rocqCmd? : Option String)
    (daemonBin clientBin : System.FilePath)
    (bundleId : String) : String := Id.run do
  let mut acc : UInt64 := 14695981039346656037
  acc := mixField acc root.toString
  acc := mixField acc (leanCmd?.getD "")
  acc := mixField acc (plugin?.map (·.toString) |>.getD "")
  acc := mixField acc (rocqCmd?.getD "")
  acc := mixField acc daemonBin.toString
  acc := mixField acc clientBin.toString
  acc := mixField acc bundleId
  s!"{acc.toNat}"

private def writeRegistry (control : ProjectControl) (entry : RegistryEntry) : IO Unit := do
  if let some parent := control.registry.parent then
    IO.FS.createDirAll parent
  let tmp := control.registry.withExtension "tmp"
  IO.FS.writeFile tmp ((toJson entry).pretty ++ "\n")
  IO.setAccessRights tmp {
    user := { read := true, write := true }
  }
  IO.FS.rename tmp control.registry

private def writeExistingRegistry (control : ProjectControl) (entry : RegistryEntry) : IO Unit := do
  -- Teardown must not create a path while the project tree is being removed. Rewrite through an
  -- already existing file handle; if the registry was concurrently unlinked, this updates only the
  -- unlinked inode and cannot recreate the project or control directory.
  let handle ← IO.FS.Handle.mk control.registry .readWrite
  handle.rewind
  handle.putStr ((toJson entry).pretty ++ "\n")
  handle.flush
  handle.truncate

private def removeRegistry (control : ProjectControl) : IO Unit := do
  if ← control.registry.pathExists then
    IO.FS.removeFile control.registry

private def sameRegistryGeneration (left right : RegistryEntry) : Bool :=
  left.daemonId == right.daemonId && left.capability == right.capability

/-- Remove a registry entry only when it still names the observed daemon generation. -/
private def removeRegistryGeneration (control : ProjectControl) (entry : RegistryEntry) : IO Unit := do
  match ← readRegistry control.root with
  | .current current =>
      if sameRegistryGeneration current entry then
        removeRegistry control
  | .absent | .legacy | .unsupported _ | .malformed _ => pure ()

private def daemonShutdownResponseTimeoutMs : Nat :=
  30000

/-- Ask a daemon to shut down without allowing its response stream to hold CLI control forever. -/
def requestDaemonShutdown
    (endpoint : Transport.Endpoint)
    (capability : String)
    (responseTimeoutMs : Nat := daemonShutdownResponseTimeoutMs) :
    IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamTimeoutResult endpoint {
      op := .shutdown
      daemonCapability? := some capability
    }
    responseTimeoutMs (fun _ => pure ())

inductive RegistryUnsafeReason where
  | invalidIdentity
  | wrongRegistryRoot (recordedRoot : String)
  | invalidEndpoint
  | ownerDead
  | endpointUnavailable
  | endpointUnrecognized (detail : String)
  | wrongEndpointRoot (daemonRoot : String)
  | wrongGeneration (daemonRoot : String)
  deriving BEq, Repr

inductive RegistryObservation where
  | absent
  | legacy
  | unsupported (schemaVersion : Nat)
  | malformed (detail : String)
  | liveExact (entry : RegistryEntry)
  | liveConfigMismatch (entry : RegistryEntry) (expectedHash : String)
  | draining (entry : RegistryEntry)
  | staleConfirmed (entry : RegistryEntry)
  | unusable (entry : RegistryEntry) (reason : RegistryUnsafeReason)

private def recordedPidGone (pid : Nat) (domain? : Option String) : IO Bool := do
  match ← (Beam.RecordedPid.mk pid domain?).observe with
  | .local false => pure true
  | .invalid | .local true | .differentDomain | .unknownDomain => pure false

private def registryProcessesGone (entry : RegistryEntry) : IO Bool := do
  if !(← recordedPidGone entry.ownerPid entry.ownerPidDomain?) then
    return false
  recordedPidGone entry.pid entry.pidDomain?

private def registryOwnerKnownDead (entry : RegistryEntry) : IO Bool :=
  recordedPidGone entry.ownerPid entry.ownerPidDomain?

def observeProjectRegistry
    (root : System.FilePath)
    (expectedHash? : Option String := none) : IO RegistryObservation := do
  match ← readRegistry root with
  | .absent => pure .absent
  | .legacy => pure .legacy
  | .unsupported schemaVersion => pure <| .unsupported schemaVersion
  | .malformed detail => pure <| .malformed detail
  | .current entry =>
      if entry.daemonId.isEmpty || entry.capability.isEmpty then
        return .unusable entry .invalidIdentity
      unless ← Beam.sameFilePath (System.FilePath.mk entry.root) root do
        return .unusable entry (.wrongRegistryRoot entry.root)
      if entry.lifecycle == .draining then
        if ← registryProcessesGone entry then
          return .staleConfirmed entry
        return .draining entry
      let ownerDead ← registryOwnerKnownDead entry
      let some endpoint := registryEndpoint? entry
        | if ownerDead && (← registryProcessesGone entry) then
            return .staleConfirmed entry
          else
            return .unusable entry .invalidEndpoint
      match ← daemonGenerationStatus endpoint projectDaemonWorkspaceId root
          entry.identity entry.capability with
      | .exact =>
          if ownerDead then
            pure <| .unusable entry .ownerDead
          else
            match expectedHash? with
            | some expectedHash =>
                if expectedHash == entry.configHash then
                  pure <| .liveExact entry
                else
                  pure <| .liveConfigMismatch entry expectedHash
            | none => pure <| .liveExact entry
      | .unavailable =>
          if ownerDead && (← registryProcessesGone entry) then
            pure <| .staleConfirmed entry
          else
            pure <| .unusable entry .endpointUnavailable
      | .unrecognized failure =>
          pure <| .unusable entry (.endpointUnrecognized failure.detail)
      | .wrongRoot daemonRoot =>
          pure <| .unusable entry (.wrongEndpointRoot daemonRoot)
      | .wrongGeneration daemonRoot =>
          pure <| .unusable entry (.wrongGeneration daemonRoot)

private def requestedPortNat? (opts : CliOptions) : Option Nat :=
  opts.requestedPort?.map (·.toNat)

private def selectPort (opts : CliOptions) : IO UInt16 := do
  match opts.requestedPort? with
  | some port => pure port
  | none =>
      let now ← IO.monoNanosNow
      let seed := now % 20000 + 30000
      if seed < UInt16.size then
        pure seed.toUInt16
      else
        pure 37654

private def selectEndpoint (opts : CliOptions) : IO Transport.Endpoint := do
  pure <| .tcp (← selectPort opts)

private def usesAutomaticTcpEndpoint (opts : CliOptions) : Bool :=
  opts.requestedPort?.isNone

private partial def selectUnoccupiedEndpoint
    (desired : DesiredConfig)
    (opts : CliOptions)
    (tries : Nat := 10) : IO Transport.Endpoint := do
  let endpoint ← selectEndpoint opts
  let retryOrReject (message : String) : IO Transport.Endpoint := do
    if usesAutomaticTcpEndpoint opts && tries > 0 then
      selectUnoccupiedEndpoint desired opts (tries - 1)
    else
      throw <| IO.userError message
  match ← daemonRootResult endpoint projectDaemonWorkspaceId with
  | .ok daemonRoot =>
      retryOrReject <| endpointOccupancyError endpoint
        (System.FilePath.mk daemonRoot) desired.root
  | .error failure =>
      let occupied ←
        match failure with
        | .transport _ _ => endpointAcceptsConnection endpoint
        | .invalidResponse _ | .streamCallback _ | .responseTimeout _ => pure true
      if !occupied then
        pure endpoint
      else
        let message :=
          match failure with
          | .transport _ _ => endpointInUseError endpoint
          | .invalidResponse _ | .streamCallback _ | .responseTimeout _ =>
              endpointProtocolError endpoint failure.detail
        retryOrReject message

private def daemonFailureIncidentRetainCount : Nat :=
  50

private def pruneDaemonFailureIncidents (root : System.FilePath) : IO Unit := do
  let entries ← Beam.Daemon.daemonFailureIncidentEntries root
  let keep := min daemonFailureIncidentRetainCount entries.size
  let deleteCount := entries.size - keep
  for entry in entries.toList.take deleteCount do
    try
      IO.FS.removeFile entry.path
    catch _ =>
      pure ()

private def appendMaybeSection (msg : String) : Option String → String
  | none => msg
  | some context => msg ++ "\n" ++ context

private structure DaemonFailureIncident where
  schemaVersion : Nat
  kind : String
  detail : String
  observedAt : String
  root : String
  controlDir : String
  registryPath : String
  registry : Option Json := none
  registryPidStatus : Option String := none
  registryEndpoint : Option String := none
  startupLogPath : Option String := none
  startupLogTail : Option String := none
  deriving ToJson

private def daemonFailureIncidentSchemaVersion : Nat :=
  1

private def daemonFailureIncidentKind? : BrokerClientFailure → Option String
  | .transport _ _ => some "brokerTransportFailure"
  | .invalidResponse _ => some "invalidBrokerResponse"
  | .streamCallback _ => none
  | .responseTimeout _ => some "brokerResponseTimeout"

private def daemonFailureIncidentTimestampLabel (timestamp : String) : String :=
  (timestamp.replace "-" "").replace ":" ""

private def daemonFailureIncidentPath
    (root : System.FilePath)
    (kind observedAt : String) : IO System.FilePath := do
  let dir ← daemonFailureIncidentDir root
  let pid ← IO.Process.getPID
  let unique ← IO.monoNanosNow
  let stamp := daemonFailureIncidentTimestampLabel observedAt
  pure (dir / s!"incident-{stamp}-{pid}-{unique}-{kind}.json")

private def writeDaemonFailureIncident?
    (root : System.FilePath)
    (kind detail : String)
    (logTail? : Option (System.FilePath × String)) : IO (Option System.FilePath) := do
  try
    let dir ← daemonFailureIncidentDir root
    IO.FS.createDirAll dir
    let registryFile ← registryPath root
    let registryRead ← readRegistry root
    let registry := registryRead.entry?
    let pidStatus ←
      match registry with
      | none => pure none
      | some entry => some <$> registryPidStatus entry
    let endpoint := registry.map registryEndpointSummary
    let control ← controlDir root
    let observedAt ← Beam.utcTimestamp
    let incident : DaemonFailureIncident := {
      schemaVersion := daemonFailureIncidentSchemaVersion
      kind
      detail
      observedAt
      root := root.toString
      controlDir := control.toString
      registryPath := registryFile.toString
      registry := registry.map fun entry =>
        (toJson entry).setObjVal! "capability" (toJson "<redacted>")
      registryPidStatus := pidStatus
      registryEndpoint := endpoint
      startupLogPath := logTail?.map (fun (path, _) => path.toString)
      startupLogTail := logTail?.map (fun (_, tail) => tail)
    }
    let path ← daemonFailureIncidentPath root kind observedAt
    let tmp := path.withExtension "tmp"
    IO.FS.writeFile tmp ((toJson incident).pretty ++ "\n")
    IO.FS.rename tmp path
    try
      pruneDaemonFailureIncidents root
    catch _ =>
      pure ()
    pure (some path)
  catch _ =>
    pure none

def daemonFailureMessage
    (root : System.FilePath)
    (failure : BrokerClientFailure) : IO String := do
  let detail := failure.detail
  match daemonFailureIncidentKind? failure with
  | none =>
    pure detail
  | some kind =>
    let msg := appendMaybeSection detail (← daemonRegistryContext? root)
    let logTail? ← startupLogTail? root
    let msg :=
      match logTail? with
      | none => msg
      | some (logPath, logTail) => msg ++ s!"\nBeam daemon log tail ({logPath}):\n{logTail}"
    let incidentPath? ← writeDaemonFailureIncident? root kind detail logTail?
    pure <| appendMaybeSection msg <|
      incidentPath?.map fun path => s!"Beam daemon incident: {path}"

private structure DaemonStartupFailure where
  message : String
  endpointInUse : Bool := false

private def daemonStartupFailure
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (detail : String) : IO DaemonStartupFailure := do
  let msg := if detail.isEmpty then
    s!"failed to start Beam daemon on {endpointSummary endpoint}"
  else
    s!"failed to start Beam daemon on {endpointSummary endpoint}\n{detail}"
  if ← logPath.pathExists then
    let logText := Beam.trimLine (← IO.FS.readFile logPath)
    if logText.isEmpty then
      pure { message := msg }
    else
      pure {
        message := msg ++ s!"\nstartup log ({logPath}):\n{logText}"
        endpointInUse := startupLogSuggestsEndpointInUse logText
      }
  else
    pure { message := msg }

private abbrev daemonStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .null
  stderr := .null

private partial def waitForDaemonChildExit
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (tries : Nat := 20) : IO Unit := do
  if tries == 0 || (← child.tryWait).isSome then
    return
  IO.sleep 100
  waitForDaemonChildExit child (tries - 1)

private def terminateDaemonChild
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg) : IO Unit := do
  try
    if (← child.tryWait).isNone then
      child.kill
    waitForDaemonChildExit child
  catch _ =>
    pure ()

private def startDaemon
    (desired : DesiredConfig)
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (identity : DaemonIdentity)
    (capability : String) : IO (IO.Process.Child daemonStdio) := do
  let mut args : List String := [
    "--root", desired.root.toString,
    "--workspace-id", projectDaemonWorkspaceId,
    "--daemon-id", identity.daemonId,
    "--config-hash", identity.configHash,
    "--session-owner-stdin"
  ]
  match endpoint with
  | .tcp port =>
      args := args ++ ["--port", toString port.toNat]
  if let some leanCmd := desired.leanCmd? then
    args := args ++ ["--lean-cmd", leanCmd]
  if let some plugin := desired.plugin? then
    args := args ++ ["--lean-plugin", plugin.toString]
  if let some rocqCmd := desired.rocqCmd? then
    args := args ++ ["--rocq-cmd", rocqCmd]
  if let some parent := logPath.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile logPath ""
  let cmd := String.intercalate " " ((desired.daemonBin.toString :: args).map shellQuote)
  let shell := s!"exec {cmd} >{shellQuote logPath.toString} 2>&1"
  let child ← IO.Process.spawn {
    toStdioConfig := daemonStdio
    cmd := "sh"
    args := #["-c", shell]
    cwd := some desired.root
    setsid := true
  }
  child.stdin.putStrLn capability
  child.stdin.flush
  pure child

private def daemonStartupTimeoutMs : Nat :=
  30000

private partial def waitForDaemonUntil
    (child : IO.Process.Child daemonStdio)
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (root : System.FilePath)
    (identity : DaemonIdentity)
    (capability : String)
    (deadlineNanos : Nat)
    (timeoutDetail : String) : IO (Except DaemonStartupFailure Unit) := do
  if (← child.tryWait).isSome then
    return .error (← daemonStartupFailure endpoint logPath
      "Beam daemon process exited before responding")
  if (← IO.monoNanosNow) >= deadlineNanos then
    return .error (← daemonStartupFailure endpoint logPath timeoutDetail)
  let retryOrFail (detail : String) : IO (Except DaemonStartupFailure Unit) := do
    if (← child.tryWait).isSome then
      .error <$> daemonStartupFailure endpoint logPath "Beam daemon process exited before responding"
    else if (← IO.monoNanosNow) >= deadlineNanos then
      .error <$> daemonStartupFailure endpoint logPath detail
    else
      IO.sleep 100
      waitForDaemonUntil child endpoint logPath root identity capability deadlineNanos detail
  match ← daemonGenerationStatus endpoint projectDaemonWorkspaceId root identity capability with
  | .exact => pure (.ok ())
  | .wrongRoot daemonRoot =>
      pure <| .error {
        message := endpointOccupancyError endpoint (System.FilePath.mk daemonRoot) root
        endpointInUse := true
      }
  | .wrongGeneration daemonRoot =>
      pure <| .error {
        message := endpointGenerationMismatchError endpoint (System.FilePath.mk daemonRoot)
        endpointInUse := true
      }
  | .unrecognized failure =>
      retryOrFail (endpointProtocolError endpoint failure.detail)
  | .unavailable =>
      retryOrFail "Beam daemon did not become ready before timeout"

private def waitForDaemon
    (child : IO.Process.Child daemonStdio)
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (root : System.FilePath)
    (identity : DaemonIdentity)
    (capability : String) : IO (Except DaemonStartupFailure Unit) := do
  let deadlineNanos := (← IO.monoNanosNow) + daemonStartupTimeoutMs * 1000000
  waitForDaemonUntil child endpoint logPath root identity capability deadlineNanos
    "Beam daemon did not become ready before timeout"

private def newDaemonGenerationId (configHash : String) : IO String := do
  let startedMonoNanos ← IO.monoNanosNow
  let nonce := ByteArray.toUInt64LE! (← IO.getRandomBytes 8)
  pure s!"{configHash.take 12}-{startedMonoNanos}-{nonce}"

private def hexDigit (n : Nat) : Char :=
  if n < 10 then
    Char.ofNat ('0'.toNat + n)
  else
    Char.ofNat ('a'.toNat + n - 10)

private def byteHex (byte : UInt8) : List Char :=
  [hexDigit (byte.toNat / 16), hexDigit (byte.toNat % 16)]

private def newDaemonCapability : IO String := do
  let bytes ← IO.getRandomBytes 32
  pure <| String.ofList <| bytes.toList.flatMap byteHex

private def registryEntryFor
    (desired : DesiredConfig)
    (daemonId : String)
    (capability : String)
    (pid : Nat)
    (endpoint : Transport.Endpoint)
    (opts : CliOptions) : IO RegistryEntry := do
  let port? :=
    match endpoint with
    | .tcp port => some port.toNat
  let pidDomain? ← Beam.currentPidDomain?
  let ownerPid ← IO.Process.getPID
  pure {
    schemaVersion := registrySchemaVersion
    lifecycle := .live
    daemonId
    capability
    pid
    pidDomain?
    ownerPid := ownerPid.toNat
    ownerPidDomain? := pidDomain?
    port?
    root := desired.root.toString
    configHash := desired.configHash
    leanCmd? := desired.leanCmd?
    plugin? := desired.plugin?.map (·.toString)
    rocqCmd? := desired.rocqCmd?
    toolchain? := desired.toolchain?
    clientBin? := some desired.clientBin.toString
    daemonBin? := some desired.daemonBin.toString
    bundleId? := some desired.bundleId
    startedAt := ← Beam.utcTimestamp
    requestedPort? := requestedPortNat? opts
  }

private partial def startDaemonEntry
    (desired : DesiredConfig)
    (opts : CliOptions)
    (tries : Nat := 10) : IO (Transport.Endpoint × RegistryEntry × IO.Process.Child daemonStdio) := do
  let endpoint ← selectUnoccupiedEndpoint desired opts
  let logPath ← daemonStartupLogPath desired.root
  let daemonId ← newDaemonGenerationId desired.configHash
  let identity : DaemonIdentity := { daemonId, configHash := desired.configHash }
  let capability ← newDaemonCapability
  let child ← startDaemon desired endpoint logPath identity capability
  let readiness : Except DaemonStartupFailure RegistryEntry ←
    try
      match ← waitForDaemon child endpoint logPath desired.root identity capability with
      | .ok () =>
          let entry ← registryEntryFor desired daemonId capability child.pid.toNat endpoint opts
          pure (.ok entry)
      | .error failure =>
          pure (.error failure)
    catch err =>
      terminateDaemonChild child
      throw err
  match readiness with
  | .ok entry =>
      pure (endpoint, entry, child)
  | .error failure =>
    terminateDaemonChild child
    let endpointOccupied ← endpointAcceptsConnection endpoint
    if shouldRetryAutomaticStartup
        (usesAutomaticTcpEndpoint opts) tries endpointOccupied failure.endpointInUse then
      return ← startDaemonEntry desired opts (tries - 1)
    throw <| IO.userError failure.message

def desiredConfig (home root : System.FilePath) (required : Backend) : IO DesiredConfig := do
  let defaultPaths ← defaultBundlePaths home
  let mut daemonBin := defaultPaths.daemon
  let mut clientBin := defaultPaths.client
  let mut plugin? : Option System.FilePath := none
  let mut leanCmd? : Option String := none
  let mut rocqCmd? : Option String := none
  let mut toolchain? : Option String := none
  let mut bundleId := "default"
  match required with
  | .lean =>
      if ← hasLeanProject root then
        let toolchain ← leanToolchain root
        let (bundle, id) ← ensureToolchainBundle root home toolchain
        ensureLeanBundleExists bundle
        daemonBin := bundle.daemon
        clientBin := bundle.client
        plugin? := some bundle.plugin
        leanCmd? := some (← leanBin root)
        toolchain? := some toolchain
        bundleId := id
      else
        throw <| IO.userError s!"could not resolve Lean Beam daemon config for {root}"
  | .rocq =>
      let helpers ← ensureDefaultDaemonHelpers home
      daemonBin := helpers.daemon
      clientBin := helpers.client
  if ← hasRocqProject root then
    rocqCmd? ← maybeRocqCmd root
  else if required == .rocq then
    rocqCmd? := some (← rocqCmd root)
  match required with
  | .lean =>
      if leanCmd?.isNone || plugin?.isNone then
        throw <| IO.userError s!"could not resolve Lean Beam daemon config for {root}"
  | .rocq =>
      if rocqCmd?.isNone then
        throw <| IO.userError s!"could not resolve Rocq Beam daemon config for {root}"
  let configHash := computeConfigHash root leanCmd? plugin? rocqCmd? daemonBin clientBin bundleId
  pure {
    root
    leanCmd?
    plugin?
    rocqCmd?
    toolchain?
    daemonBin
    clientBin
    bundleId
    configHash
  }

structure ProjectDaemonClient where
  endpoint : Transport.Endpoint
  capability : String

def ProjectDaemonClient.authorize
    (client : ProjectDaemonClient)
    (request : Request) : Request :=
  { request with daemonCapability? := some client.capability }

private def projectDaemonClient (entry : RegistryEntry) : IO ProjectDaemonClient := do
  pure {
    endpoint := ← Beam.Daemon.endpointFromEntry entry
    capability := entry.capability
  }

def RegistryUnsafeReason.message : RegistryUnsafeReason → String
  | .invalidIdentity => "registry identity or capability is empty"
  | .wrongRegistryRoot recordedRoot => s!"registry records another root: {recordedRoot}"
  | .invalidEndpoint => "registry endpoint is invalid"
  | .ownerDead => "the recorded owner is dead while its daemon still responds"
  | .endpointUnavailable => "the recorded daemon endpoint is unavailable"
  | .endpointUnrecognized detail => s!"the recorded endpoint is not a recognized Beam generation: {detail}"
  | .wrongEndpointRoot daemonRoot => s!"the recorded endpoint serves another root: {daemonRoot}"
  | .wrongGeneration daemonRoot =>
      s!"the recorded endpoint serves another Beam generation for {daemonRoot}"

private def activeOwnerMessage (root : System.FilePath) (entry : RegistryEntry) : String :=
  s!"Beam session for {root} is already owned by wrapper pid {entry.ownerPid}; " ++
    "interrupt that 'lean-beam ensure --hold' process before starting another owner"

private def configMismatchMessage
    (root : System.FilePath)
    (entry : RegistryEntry)
    (expectedHash : String) : String :=
  s!"the live Beam session for {root} uses configuration {entry.configHash}, " ++
    s!"but this command requires {expectedHash}; the current owner was preserved. " ++
    "Interrupt its 'lean-beam ensure --hold' process, then start a new owner with the desired configuration"

private def drainingOwnerMessage (root : System.FilePath) (entry : RegistryEntry) : String :=
  s!"Beam session {entry.daemonId} for {root} is draining; " ++
    "wait for its foreground owner to exit before starting or attaching to another session"

private def registryRecoveryMessage (root : System.FilePath) (detail : String) : String :=
  s!"Beam cannot safely use or replace the daemon registry for {root}: {detail}. " ++
    "Preserve the registry, stop the matching foreground owner or daemon explicitly, and retry"

private def markRegistryDraining (control : ProjectControl) (entry : RegistryEntry) : IO Unit := do
  match ← readRegistry control.root with
  | .current current =>
      if sameRegistryGeneration current entry && current.lifecycle == .live then
        writeExistingRegistry control { current with lifecycle := .draining }
  | .absent | .legacy | .unsupported _ | .malformed _ => pure ()

private inductive ShutdownPlan where
  | none
  | request (entry : RegistryEntry)

/-- Fence and request shutdown of the exact wrapper-owned generation without PID signalling. -/
def shutdownRegisteredProjectDaemon
    (root : System.FilePath) : IO (Except BrokerClientFailure (Option Response)) := do
  let plan : ShutdownPlan ← withProjectControl root fun control => do
    match ← observeProjectRegistry root with
    | .absent => pure ShutdownPlan.none
    | .staleConfirmed entry =>
        removeRegistryGeneration control entry
        pure ShutdownPlan.none
    | .liveExact entry =>
        markRegistryDraining control entry
        pure <| ShutdownPlan.request entry
    | .draining entry => pure <| ShutdownPlan.request entry
    | .liveConfigMismatch entry _ =>
        markRegistryDraining control entry
        pure <| ShutdownPlan.request entry
    | .legacy =>
        throw <| IO.userError <| registryRecoveryMessage root <|
          RegistryRead.legacy.detail?.getD "legacy registry"
    | .unsupported schemaVersion =>
        throw <| IO.userError <| registryRecoveryMessage root <|
          (RegistryRead.unsupported schemaVersion).detail?.getD "unsupported registry"
    | .malformed detail =>
        throw <| IO.userError <| registryRecoveryMessage root detail
    | .unusable _ reason =>
        throw <| IO.userError <| registryRecoveryMessage root reason.message
  match plan with
  | ShutdownPlan.none => pure <| .ok none
  | ShutdownPlan.request entry =>
      let some endpoint := registryEndpoint? entry
        | return .error <| .invalidResponse "draining Beam registry has no valid endpoint"
      pure <| (← requestDaemonShutdown endpoint entry.capability).map some

private abbrev detachedDaemonStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .null

private structure OwnedProjectDaemon where
  client : ProjectDaemonClient
  entry : RegistryEntry
  child : IO.Process.Child daemonStdio

structure ProjectDaemonOwner where
  client : ProjectDaemonClient
  private root : System.FilePath
  private daemonId : String
  private child : IO.Process.Child daemonStdio
  private exitCodeRef : IO.Ref (Option UInt32)

def ProjectDaemonOwner.exitCode? (owner : ProjectDaemonOwner) : IO (Option UInt32) := do
  match ← owner.exitCodeRef.get with
  | some exitCode => pure (some exitCode)
  | none =>
      let exitCode? ← owner.child.tryWait
      if let some exitCode := exitCode? then
        owner.exitCodeRef.set (some exitCode)
      pure exitCode?

/-- Whether this owner generation is still the one published for its project. -/
def ProjectDaemonOwner.registered (owner : ProjectDaemonOwner) : IO Bool := do
  match ← readRegistry owner.root with
  | .current current =>
      pure (current.daemonId == owner.daemonId &&
        current.capability == owner.client.capability && current.lifecycle == .live)
  | .absent | .legacy | .unsupported _ | .malformed _ => pure false

private def missingOwnerCommand : Option Backend → String
  | some .rocq => "lean-beam ensure rocq --hold"
  | some .lean | none => "lean-beam ensure --hold"

private def missingOwnerMessage (root : System.FilePath) (backend? : Option Backend) : String :=
  s!"no live Beam session owner is registered for {root}; " ++
    s!"start '{missingOwnerCommand backend?}' for this project and keep it running while using wrapper commands"

private def startOwnedProjectDaemon
    (control : ProjectControl)
    (desired : DesiredConfig)
    (opts : CliOptions) : IO OwnedProjectDaemon := do
  match ← observeProjectRegistry desired.root (some desired.configHash) with
  | .absent => pure ()
  | .staleConfirmed entry => removeRegistryGeneration control entry
  | .liveExact entry => throw <| IO.userError (activeOwnerMessage desired.root entry)
  | .liveConfigMismatch entry expectedHash =>
      throw <| IO.userError (configMismatchMessage desired.root entry expectedHash)
  | .draining entry => throw <| IO.userError (drainingOwnerMessage desired.root entry)
  | .legacy =>
      throw <| IO.userError <| registryRecoveryMessage desired.root <|
        RegistryRead.legacy.detail?.getD "legacy registry"
  | .unsupported schemaVersion =>
      throw <| IO.userError <| registryRecoveryMessage desired.root <|
        (RegistryRead.unsupported schemaVersion).detail?.getD "unsupported registry"
  | .malformed detail =>
      throw <| IO.userError <| registryRecoveryMessage desired.root detail
  | .unusable _ reason =>
      throw <| IO.userError <| registryRecoveryMessage desired.root reason.message
  let (endpoint, entry, child) ← startDaemonEntry desired opts
  try
    writeRegistry control entry
  catch err =>
    terminateDaemonChild child
    throw err
  pure {
    client := { endpoint, capability := entry.capability }
    entry
    child
  }

private def closeDaemonOwnerPipe
    (child : IO.Process.Child daemonStdio) :
    IO (IO.Process.Child detachedDaemonStdio) := do
  let (_ownerPipe, child) ← child.takeStdin
  pure child

private partial def waitForOwnedDaemonExit
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (exitCodeRef : IO.Ref (Option UInt32))
    (tries : Nat) : IO Unit := do
  if (← exitCodeRef.get).isSome || tries == 0 then
    return
  if let some exitCode ← child.tryWait then
    exitCodeRef.set (some exitCode)
  else
    IO.sleep 100
    waitForOwnedDaemonExit child exitCodeRef (tries - 1)

private def removeOwnedRegistry (root : System.FilePath) (entry : RegistryEntry) : IO Unit := do
  try
    withExistingProjectControl root fun control =>
      removeRegistryGeneration control entry
  catch _ =>
    pure ()

private def attemptCleanup (act : IO Unit) : IO Unit := do
  try
    act
  catch _ =>
    pure ()

private def finishOwnedDaemonChild
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO Bool := do
  try
    let child ← closeDaemonOwnerPipe owned.child
    attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 100
    if (← exitCodeRef.get).isNone then
      -- `startDaemon` uses `setsid`; Lean's retained child handle therefore kills the complete
      -- daemon process group rather than only the broker PID.
      attemptCleanup child.kill
      attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 20
  catch _ =>
    attemptCleanup owned.child.kill
    attemptCleanup <| waitForOwnedDaemonExit owned.child exitCodeRef 20
  pure (← exitCodeRef.get).isSome

private def markOwnedRegistryDraining (root : System.FilePath) (entry : RegistryEntry) : IO Unit := do
  try
    withExistingProjectControl root fun control =>
      markRegistryDraining control entry
  catch _ =>
    pure ()

private def finishOwnedProjectDaemon
    (root : System.FilePath)
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO Unit := do
  markOwnedRegistryDraining root owned.entry
  if ← finishOwnedDaemonChild owned exitCodeRef then
    removeOwnedRegistry root owned.entry

def withProjectDaemonOwner
    (home root : System.FilePath)
    (backend : Backend)
    (opts : CliOptions)
    (act : ProjectDaemonOwner → IO α) : IO α := do
  let desired ← desiredConfig home root backend
  let owned ← withProjectControl root fun control =>
    startOwnedProjectDaemon control desired opts
  let exitCodeRef ← IO.mkRef (none : Option UInt32)
  try
    act {
        client := owned.client
        root
        daemonId := owned.entry.daemonId
        child := owned.child
        exitCodeRef
      }
  finally
    finishOwnedProjectDaemon root owned exitCodeRef

private def lookupProjectDaemon
    (root : System.FilePath)
    (expectedHash? : Option String := none)
    (backend? : Option Backend := none) : IO ProjectDaemonClient := do
  withProjectControl root fun _control => do
    match ← observeProjectRegistry root expectedHash? with
    | .liveExact entry => projectDaemonClient entry
    | .absent | .staleConfirmed _ =>
        throw <| IO.userError (missingOwnerMessage root backend?)
    | .liveConfigMismatch entry expectedHash =>
        throw <| IO.userError (configMismatchMessage root entry expectedHash)
    | .draining entry => throw <| IO.userError (drainingOwnerMessage root entry)
    | .legacy =>
        throw <| IO.userError <| registryRecoveryMessage root <|
          RegistryRead.legacy.detail?.getD "legacy registry"
    | .unsupported schemaVersion =>
        throw <| IO.userError <| registryRecoveryMessage root <|
          (RegistryRead.unsupported schemaVersion).detail?.getD "unsupported registry"
    | .malformed detail =>
        throw <| IO.userError <| registryRecoveryMessage root detail
    | .unusable _ reason =>
        throw <| IO.userError <| registryRecoveryMessage root reason.message

def withProjectDaemon
    (home root : System.FilePath)
    (backend : Backend)
    (act : ProjectDaemonClient → IO α) : IO α := do
  let desired ← desiredConfig home root backend
  act (← lookupProjectDaemon root (some desired.configHash) (some backend))

def withExistingProjectDaemon
    (root : System.FilePath)
    (act : ProjectDaemonClient → IO α) : IO α := do
  act (← lookupProjectDaemon root)
end Beam.Cli
