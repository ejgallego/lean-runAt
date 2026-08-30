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
import Beam.Daemon.Registry

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

private def projectControl
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO ProjectControl := do
  let dir ← controlDirFor root explicitControlDir?
  pure { root, dir, registry := dir / "beam-daemon.json" }

private def rejectControlDirObservation
    (dir : System.FilePath)
    (observation : Beam.PrivateDirObservation) : IO Unit := do
  Beam.requirePrivateDir "Beam session directory" dir observation

/-- Accept an existing control path only when it is a real, account-private directory. -/
private def validatePrivateControlDir (dir : System.FilePath) : IO Unit := do
  rejectControlDirObservation dir (← Beam.observePrivateDir dir)

/-- Validate an existing session selection without creating it; absence remains observable. -/
private def validateControlDirForObservation (dir : System.FilePath) : IO Unit := do
  match ← Beam.observePrivateDir dir with
  | .absent | .privateDir => pure ()
  | observation => rejectControlDirObservation dir observation

/-- Recognize absence without creating a session directory or accepting an unsafe existing leaf. -/
private def sessionDescriptorAbsent (control : ProjectControl) : IO Bool := do
  match ← Beam.observePrivateDir control.dir with
  | .absent => pure true
  | .privateDir =>
      match ← readRegistryAt control.registry with
      | .absent => pure true
      | .legacy | .unsupported _ | .malformed _ | .current _ => pure false
  | .symlink | .nonPrivate _ | .notDirectory => pure false

/--
Create a missing dedicated control leaf as private, or validate an existing path without mutating
it. The directory is ready before Beam creates its lock or any capability-bearing descriptor.
-/
private def preparePrivateControlDir (dir : System.FilePath) : IO Unit := do
  Beam.ensurePrivateDir "Beam session directory" dir

/-- Supply project registry mutation only for the dynamic extent of the project control lock. -/
private def withProjectControl
    (root : System.FilePath)
    (act : ProjectControl → IO α)
    (explicitControlDir? : Option System.FilePath := none) : IO α := do
  let control ← projectControl root explicitControlDir?
  preparePrivateControlDir control.dir
  withLockTimeout (control.dir / "lock") (← projectControlLockTimeoutMs) do
    act control

/--
Run teardown under the project lock without recreating a control directory that disappeared with
its project root.
-/
private def withExistingProjectControl
    (root : System.FilePath)
    (act : ProjectControl → IO Unit)
    (explicitControlDir? : Option System.FilePath := none) : IO Unit := do
  let control ← projectControl root explicitControlDir?
  match ← Beam.observePrivateDir control.dir with
  | .privateDir => pure ()
  | .absent | .symlink | .nonPrivate _ | .notDirectory => return
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

private def hexDigit (n : Nat) : Char :=
  if n < 10 then
    Char.ofNat ('0'.toNat + n)
  else
    Char.ofNat ('a'.toNat + n - 10)

private def byteHex (byte : UInt8) : List Char :=
  [hexDigit (byte.toNat / 16), hexDigit (byte.toNat % 16)]

private def newRegistryTempPath (control : ProjectControl) : IO System.FilePath := do
  let nonce := String.ofList <| (← IO.getRandomBytes 16).toList.flatMap byteHex
  pure <| control.dir / s!"beam-daemon-{nonce}.tmp"

private def writeRegistry (control : ProjectControl) (entry : SessionDescriptor) : IO Unit := do
  let tmp ← newRegistryTempPath control
  try
    IO.FS.withFile tmp .writeNew fun handle => do
      -- The private control directory protects the inode from its creation. The exclusive random
      -- path also refuses pre-existing files and symlinks; mode 0600 remains defense in depth and
      -- protects the descriptor after publication if directory permissions later change.
      IO.setAccessRights tmp {
        user := { read := true, write := true }
      }
      handle.putStr ((toJson entry).pretty ++ "\n")
      handle.flush
    IO.FS.rename tmp control.registry
  catch err =>
    try
      if ← tmp.pathExists then
        IO.FS.removeFile tmp
    catch _ =>
      pure ()
    throw err

private def writeExistingRegistry (control : ProjectControl) (entry : SessionDescriptor) : IO Unit := do
  -- Teardown must not create a path while the project tree is being removed. Rewrite through an
  -- already existing file handle; if the registry was concurrently unlinked, this updates only the
  -- unlinked inode and cannot recreate the project or control directory.
  IO.FS.withFile control.registry .readWrite fun handle => do
    handle.rewind
    handle.putStr ((toJson entry).pretty ++ "\n")
    handle.flush
    handle.truncate

private def removeRegistry (control : ProjectControl) : IO Unit := do
  if ← control.registry.pathExists then
    IO.FS.removeFile control.registry

private def sameRegistryGeneration (left right : SessionDescriptor) : Bool :=
  left.daemonId == right.daemonId && left.capability == right.capability

/-- Remove a registry entry only when it still names the observed daemon generation. -/
private def removeRegistryGeneration (control : ProjectControl) (entry : SessionDescriptor) : IO Unit := do
  match ← readRegistryAt control.registry with
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
  | invalidEndpoint
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
  | live (entry : SessionDescriptor)
  | draining (entry : SessionDescriptor)
  | selectorMismatch (entry : SessionDescriptor)
  | unusable (entry : SessionDescriptor) (reason : RegistryUnsafeReason)

/-- Select the unique descriptor binding for a canonical or filesystem-equivalent project root. -/
def sessionWorkspaceForRoot?
    (entry : SessionDescriptor)
    (root : System.FilePath) : IO (Option WorkspaceBinding) := do
  if ← Beam.sameFilePath (System.FilePath.mk entry.workspace.root) root then
    pure (some entry.workspace)
  else
    pure none

private def observeProjectRegistryAt
    (root registry : System.FilePath) : IO RegistryObservation := do
  match ← readRegistryAt registry with
  | .absent => pure .absent
  | .legacy => pure .legacy
  | .unsupported schemaVersion => pure <| .unsupported schemaVersion
  | .malformed detail => pure <| .malformed detail
  | .current entry =>
      if entry.daemonId.isEmpty || entry.capability.isEmpty then
        return .unusable entry .invalidIdentity
      let some workspace ← sessionWorkspaceForRoot? entry root
        | return .selectorMismatch entry
      if entry.lifecycle == .draining then
        return .draining entry
      let some endpoint := registryEndpoint? entry
        | return .unusable entry .invalidEndpoint
      match ← daemonGenerationStatus endpoint workspace.workspaceId root
          entry.identity entry.capability with
      | .exact => pure <| .live entry
      | .unavailable => pure <| .unusable entry .endpointUnavailable
      | .unrecognized failure =>
          pure <| .unusable entry (.endpointUnrecognized failure.detail)
      | .wrongRoot daemonRoot =>
          pure <| .unusable entry (.wrongEndpointRoot daemonRoot)
      | .wrongGeneration daemonRoot =>
          pure <| .unusable entry (.wrongGeneration daemonRoot)

private def observeProjectControl
    (root : System.FilePath)
    (control : ProjectControl) : IO RegistryObservation := do
  validateControlDirForObservation control.dir
  observeProjectRegistryAt root control.registry

def observeProjectRegistry
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO RegistryObservation := do
  observeProjectControl root (← projectControl root explicitControlDir?)

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

private def pruneDaemonFailureIncidents
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO Unit := do
  let entries ← Beam.Daemon.daemonFailureIncidentEntries root explicitControlDir?
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
    (kind observedAt : String)
    (explicitControlDir? : Option System.FilePath := none) : IO System.FilePath := do
  let dir ← daemonFailureIncidentDirFor root explicitControlDir?
  let pid ← IO.Process.getPID
  let unique ← IO.monoNanosNow
  let stamp := daemonFailureIncidentTimestampLabel observedAt
  pure (dir / s!"incident-{stamp}-{pid}-{unique}-{kind}.json")

private def writeDaemonFailureIncident?
    (root : System.FilePath)
    (kind detail : String)
    (logTail? : Option (System.FilePath × String))
    (explicitControlDir? : Option System.FilePath := none) : IO (Option System.FilePath) := do
  try
    let dir ← daemonFailureIncidentDirFor root explicitControlDir?
    IO.FS.createDirAll dir
    let registryFile ← registryPathFor root explicitControlDir?
    let registryRead ← readRegistryAt registryFile
    let registry := registryRead.entry?
    let endpoint := registry.map registryEndpointSummary
    let control ← controlDirFor root explicitControlDir?
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
        entry.redactedJson
      registryEndpoint := endpoint
      startupLogPath := logTail?.map (fun (path, _) => path.toString)
      startupLogTail := logTail?.map (fun (_, tail) => tail)
    }
    let path ← daemonFailureIncidentPath root kind observedAt explicitControlDir?
    let tmp := path.withExtension "tmp"
    IO.FS.writeFile tmp ((toJson incident).pretty ++ "\n")
    IO.FS.rename tmp path
    try
      pruneDaemonFailureIncidents root explicitControlDir?
    catch _ =>
      pure ()
    pure (some path)
  catch _ =>
    pure none

def daemonFailureMessage
    (root : System.FilePath)
    (failure : BrokerClientFailure)
    (explicitControlDir? : Option System.FilePath := none) : IO String := do
  let detail := failure.detail
  match daemonFailureIncidentKind? failure with
  | none =>
    pure detail
  | some kind =>
    let msg := appendMaybeSection detail (← daemonRegistryContext? root explicitControlDir?)
    let logTail? ← startupLogTail? root explicitControlDir?
    let msg :=
      match logTail? with
      | none => msg
      | some (logPath, logTail) => msg ++ s!"\nBeam daemon log tail ({logPath}):\n{logTail}"
    let incidentPath? ← writeDaemonFailureIncident? root kind detail logTail? explicitControlDir?
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
  try
    child.stdin.putStrLn capability
    child.stdin.flush
    pure child
  catch err =>
    -- Once spawned, the retained child handle owns the whole setsid process group. Do not leak
    -- that acquisition when publishing the capability through the owner pipe fails.
    terminateDaemonChild child
    throw err

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

private def newDaemonCapability : IO String := do
  let bytes ← IO.getRandomBytes 32
  pure <| String.ofList <| bytes.toList.flatMap byteHex

private def registryEntryFor
    (desired : DesiredConfig)
    (daemonId : String)
    (capability : String)
    (pid : Nat)
    (endpoint : Transport.Endpoint)
    (opts : CliOptions) : IO SessionDescriptor := do
  let port? :=
    match endpoint with
    | .tcp port => some port.toNat
  let ownerPid ← IO.Process.getPID
  pure {
    schemaVersion := registrySchemaVersion
    lifecycle := .live
    daemonId
    capability
    pid
    ownerPid := ownerPid.toNat
    port?
    workspace := {
      workspaceId := projectDaemonWorkspaceId
      root := desired.root.toString
      leanCmd? := desired.leanCmd?
      plugin? := desired.plugin?.map (·.toString)
      rocqCmd? := desired.rocqCmd?
      toolchain? := desired.toolchain?
      bundleId? := some desired.bundleId
    }
    configHash := desired.configHash
    clientBin? := some desired.clientBin.toString
    daemonBin? := some desired.daemonBin.toString
    startedAt := ← Beam.utcTimestamp
    requestedPort? := requestedPortNat? opts
  }

private partial def startDaemonEntry
    (desired : DesiredConfig)
    (opts : CliOptions)
    (controlDir : System.FilePath)
    (tries : Nat := 10) : IO (Transport.Endpoint × SessionDescriptor × IO.Process.Child daemonStdio) := do
  let endpoint ← selectUnoccupiedEndpoint desired opts
  let logPath ← daemonStartupLogPathFor desired.root (some controlDir)
  let daemonId ← newDaemonGenerationId desired.configHash
  let identity : DaemonIdentity := { daemonId, configHash := desired.configHash }
  let capability ← newDaemonCapability
  let child ← startDaemon desired endpoint logPath identity capability
  let readiness : Except DaemonStartupFailure SessionDescriptor ←
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
      return ← startDaemonEntry desired opts controlDir (tries - 1)
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
  workspaceId : WorkspaceId
  controlDir : System.FilePath

def ProjectDaemonClient.authorize
    (client : ProjectDaemonClient)
    (request : Request) : Request :=
  { request with daemonCapability? := some client.capability }

private def projectDaemonClient
    (entry : SessionDescriptor)
    (workspace : WorkspaceBinding)
    (controlDir : System.FilePath) : IO ProjectDaemonClient := do
  pure {
    endpoint := ← Beam.Daemon.endpointFromEntry entry
    capability := entry.capability
    workspaceId := workspace.workspaceId
    controlDir
  }

private def workspaceSupportsBackend (workspace : WorkspaceBinding) : Backend → Bool
  | .lean => workspace.leanCmd?.isSome && workspace.plugin?.isSome
  | .rocq => workspace.rocqCmd?.isSome

private def selectWorkspaceBackend
    (root : System.FilePath)
    (entry : SessionDescriptor)
    (backend? : Option Backend) : IO WorkspaceBinding := do
  let some workspace ← sessionWorkspaceForRoot? entry root
    | throw <| IO.userError s!"the selected Beam session does not contain workspace {root}"
  if let some backend := backend? then
    unless workspaceSupportsBackend workspace backend do
      throw <| IO.userError <|
        s!"the owned Beam session for {root} does not provide the {toJson backend |>.compress} backend; " ++
        "interrupt its foreground owner and start a session configured for that backend"
  pure workspace

structure SelectedProjectDaemon where
  client : ProjectDaemonClient
  workspace : WorkspaceBinding

def RegistryUnsafeReason.message : RegistryUnsafeReason → String
  | .invalidIdentity => "registry identity or capability is empty"
  | .invalidEndpoint => "registry endpoint is invalid"
  | .endpointUnavailable => "the recorded daemon endpoint is unavailable"
  | .endpointUnrecognized detail => s!"the recorded endpoint is not a recognized Beam generation: {detail}"
  | .wrongEndpointRoot daemonRoot => s!"the recorded endpoint serves another root: {daemonRoot}"
  | .wrongGeneration daemonRoot =>
      s!"the recorded endpoint serves another Beam generation for {daemonRoot}"

private def activeOwnerMessage (root : System.FilePath) : String :=
  s!"Beam session for {root} is already owned by a foreground process; " ++
    "interrupt that 'lean-beam serve' process before starting another owner"

private def configMismatchMessage
    (root : System.FilePath)
    (sessionDir : System.FilePath)
    (entry : SessionDescriptor)
    (expectedHash : String)
    (backend : Backend) : String :=
  s!"the live Beam session for {root} uses configuration {entry.configHash}, " ++
    s!"but this command requires {expectedHash}; the current owner was preserved. " ++
    "Interrupt its foreground owner, then start a new one with the desired configuration:\n" ++
    wrapperSessionCommand root sessionDir (.serve backend)

private def drainingOwnerMessage (root : System.FilePath) (entry : SessionDescriptor) : String :=
  s!"Beam session {entry.daemonId} for {root} is draining; " ++
    "wait for its foreground owner to exit before starting or attaching to another session"

def sessionSelectorMismatchMessage
    (root sessionDir : System.FilePath)
    (entry : SessionDescriptor) : String :=
  let recordedRoot := entry.workspace.root
  s!"sessionSelectorMismatch: selected workspace {root}, but Beam session {entry.daemonId} " ++
    s!"in {sessionDir} belongs to workspace {recordedRoot}. Use the recorded exact selector:\n" ++
    wrapperSessionCommand (System.FilePath.mk recordedRoot) sessionDir .status

private def registryRecoveryMessage
    (root : System.FilePath)
    (detail : String) : String :=
  s!"Beam cannot safely use or replace the daemon registry for {root}: {detail}. " ++
    "The session remains fenced; preserve its descriptor and use explicit recovery with the same " ++
    "--root and --session-dir selection after stopping the matching owner or daemon"

private def generationRecoveryMessage
    (root : System.FilePath)
    (sessionDir : System.FilePath)
    (entry : SessionDescriptor)
    (reason : RegistryUnsafeReason) : String :=
  let message := registryRecoveryMessage root reason.message
  let recovery := wrapperSessionCommand root sessionDir
    (.recoverGeneration entry.daemonId)
  message ++ s!"; when recovery is safe, run:\n{recovery}"

private def registryReadRecoveryMessage
    (root : System.FilePath)
    (sessionDir : System.FilePath)
    (registryRead : RegistryRead) : String :=
  registryRecoveryMessage root
    (registryRead.detail?.getD s!"unexpected registry state '{registryRead.status}'") ++
    "; opaque state can be quarantined explicitly with:\n" ++
    wrapperSessionCommand root sessionDir .recoverForce

private inductive RegistryDrainTransition where
  | committed
  | alreadyDraining
  | changedUnderfoot

private def markRegistryDraining
    (control : ProjectControl)
    (entry : SessionDescriptor) : IO RegistryDrainTransition := do
  match ← readRegistryAt control.registry with
  | .current current =>
      if !sameRegistryGeneration current entry then
        pure .changedUnderfoot
      else if current.lifecycle == .draining then
        pure .alreadyDraining
      else
        writeExistingRegistry control { current with lifecycle := .draining }
        pure .committed
  | .absent | .legacy | .unsupported _ | .malformed _ => pure .changedUnderfoot

private inductive ShutdownPlan where
  | none
  | alreadyStopping
  | committed (entry : SessionDescriptor)

/-- Delivery of the authenticated shutdown request after the draining fence was committed. -/
inductive ProjectDaemonStopDelivery where
  | acknowledged
  | rejected (failure : ResponseFailure)
  | failed (failure : BrokerClientFailure)

/-- Authoritative state committed by an explicit wrapper-session stop operation. -/
inductive ProjectDaemonStopResult where
  | absent
  | stopping (changed : Bool) (delivery? : Option ProjectDaemonStopDelivery)

/-- Fence and request shutdown of the exact wrapper-owned generation without PID signalling. -/
def shutdownRegisteredProjectDaemon
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) :
    IO ProjectDaemonStopResult := do
  let selected ← projectControl root explicitControlDir?
  if ← sessionDescriptorAbsent selected then
    return .absent
  let plan : ShutdownPlan ← withProjectControl root
      (explicitControlDir? := explicitControlDir?) fun control => do
    match ← observeProjectRegistryAt root control.registry with
    | .absent => pure ShutdownPlan.none
    | .live entry =>
        match ← markRegistryDraining control entry with
        | .committed => pure <| ShutdownPlan.committed entry
        | .alreadyDraining => pure ShutdownPlan.alreadyStopping
        | .changedUnderfoot =>
            throw <| IO.userError <|
              "Beam session descriptor changed while committing its draining fence; " ++
                "the shutdown request was not sent"
    | .draining _ => pure ShutdownPlan.alreadyStopping
    | .legacy =>
        throw <| IO.userError <| registryReadRecoveryMessage root control.dir .legacy
    | .unsupported schemaVersion =>
        throw <| IO.userError <|
          registryReadRecoveryMessage root control.dir (.unsupported schemaVersion)
    | .malformed detail =>
        throw <| IO.userError <| registryReadRecoveryMessage root control.dir (.malformed detail)
    | .selectorMismatch entry =>
        throw <| IO.userError <|
          sessionSelectorMismatchMessage root control.dir entry
    | .unusable entry reason =>
        throw <| IO.userError <| generationRecoveryMessage root control.dir entry reason
  match plan with
  | .none => pure .absent
  | .alreadyStopping => pure <| .stopping false none
  | .committed entry =>
      let delivery ←
        match registryEndpoint? entry with
        | none =>
            pure <| ProjectDaemonStopDelivery.failed <|
              .invalidResponse "draining Beam session descriptor has no valid endpoint"
        | some endpoint =>
            match ← requestDaemonShutdown endpoint entry.capability with
            | .ok (.successResult ..) => pure .acknowledged
            | .ok (.errorResult failure) => pure <| .rejected failure
            | .error failure => pure <| .failed failure
      pure <| .stopping true (some delivery)

structure RecoveryResult where
  recovered : Bool
  generation? : Option String := none
  quarantinedPath? : Option String := none
  reason? : Option String := none
  deriving ToJson

private def quarantineRegistry (control : ProjectControl) : IO System.FilePath := do
  let nonce ← IO.monoNanosNow
  let quarantine := control.dir / s!"beam-daemon.recovered-{nonce}.json"
  IO.FS.rename control.registry quarantine
  pure quarantine

private def registeredGenerationResponds
    (root : System.FilePath)
    (workspace : WorkspaceBinding)
    (entry : SessionDescriptor) : IO Bool := do
  let some endpoint := registryEndpoint? entry
    | pure false
  match ← daemonGenerationStatus endpoint workspace.workspaceId root entry.identity entry.capability with
  | .exact => pure true
  | .unavailable | .unrecognized _ | .wrongRoot _ | .wrongGeneration _ => pure false

/--
Explicitly quarantine one unusable session descriptor without treating persisted PIDs as signal
capabilities. Current descriptors require their exact generation; opaque descriptors require force.
-/
def recoverProjectDaemon
    (root : System.FilePath)
    (generation? : Option String)
    (forceOpaque : Bool)
    (explicitControlDir? : Option System.FilePath := none) : IO RecoveryResult := do
  let selected ← projectControl root explicitControlDir?
  if ← sessionDescriptorAbsent selected then
    return { recovered := false, reason? := some "absent" }
  withProjectControl root (explicitControlDir? := explicitControlDir?) fun control => do
    match ← readRegistryAt control.registry with
    | .absent =>
        pure { recovered := false, reason? := some "absent" }
    | .current entry =>
        let some generation := generation?
          | throw <| IO.userError
              s!"recovery of current session {entry.daemonId} requires --generation {entry.daemonId}"
        unless generation == entry.daemonId do
          throw <| IO.userError <|
            s!"recovery generation '{generation}' does not match recorded generation '{entry.daemonId}'"
        let some workspace ← sessionWorkspaceForRoot? entry root
          | throw <| IO.userError <|
              s!"selected root {root} is not a workspace in session {entry.daemonId}; " ++
              s!"recorded workspace root: {entry.workspace.root}"
        if ← registeredGenerationResponds root workspace entry then
          throw <| IO.userError <|
            s!"Beam session {entry.daemonId} still responds; stop its foreground owner or use authenticated shutdown"
        let quarantine ← quarantineRegistry control
        pure {
          recovered := true
          generation? := some entry.daemonId
          quarantinedPath? := some quarantine.toString
        }
    | .legacy | .unsupported _ | .malformed _ =>
        unless forceOpaque do
          throw <| IO.userError
            "opaque legacy, unsupported, or malformed session state requires recover --force"
        let quarantine ← quarantineRegistry control
        pure {
          recovered := true
          quarantinedPath? := some quarantine.toString
          reason? := some "opaque"
        }

private abbrev detachedDaemonStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .null

private structure OwnedProjectDaemon where
  client : ProjectDaemonClient
  entry : SessionDescriptor
  child : IO.Process.Child daemonStdio

structure ProjectDaemonOwner where
  client : ProjectDaemonClient
  private root : System.FilePath
  private controlDir : System.FilePath
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

def ProjectDaemonOwner.generation (owner : ProjectDaemonOwner) : String :=
  owner.daemonId

/-- Whether this owner generation is still the one published for its project. -/
def ProjectDaemonOwner.registered (owner : ProjectDaemonOwner) : IO Bool := do
  match ← readRegistryAt (owner.controlDir / "beam-daemon.json") with
  | .current current =>
      pure (current.daemonId == owner.daemonId &&
        current.capability == owner.client.capability && current.lifecycle == .live)
  | .absent | .legacy | .unsupported _ | .malformed _ => pure false

private def missingOwnerCommand : Option Backend → WrapperSessionCommand
  | some .rocq => .serve .rocq
  | some .lean | none => .serve .lean

private def missingOwnerMessage
    (root sessionDir : System.FilePath)
    (backend? : Option Backend) : String :=
  let command := wrapperSessionCommand root sessionDir (missingOwnerCommand backend?)
  s!"no live Beam session owner is registered for {root}; " ++
    s!"start this foreground owner and keep it running while using wrapper commands:\n{command}"

private def startOwnedProjectDaemon
    (control : ProjectControl)
    (desired : DesiredConfig)
    (backend : Backend)
    (opts : CliOptions) : IO OwnedProjectDaemon := do
  match ← observeProjectRegistryAt desired.root control.registry with
  | .absent => pure ()
  | .live entry =>
      if entry.configHash == desired.configHash then
        throw <| IO.userError (activeOwnerMessage desired.root)
      else
        throw <| IO.userError
          (configMismatchMessage desired.root control.dir entry desired.configHash backend)
  | .draining entry => throw <| IO.userError (drainingOwnerMessage desired.root entry)
  | .legacy =>
      throw <| IO.userError <| registryReadRecoveryMessage desired.root control.dir .legacy
  | .unsupported schemaVersion =>
      throw <| IO.userError <|
        registryReadRecoveryMessage desired.root control.dir (.unsupported schemaVersion)
  | .malformed detail =>
      throw <| IO.userError <|
        registryReadRecoveryMessage desired.root control.dir (.malformed detail)
  | .selectorMismatch entry =>
      throw <| IO.userError <|
        sessionSelectorMismatchMessage desired.root control.dir entry
  | .unusable entry reason =>
      throw <| IO.userError <|
        generationRecoveryMessage desired.root control.dir entry reason
  let (endpoint, entry, child) ← startDaemonEntry desired opts control.dir
  try
    writeRegistry control entry
  catch err =>
    terminateDaemonChild child
    throw err
  pure {
    client := {
      endpoint
      capability := entry.capability
      workspaceId := projectDaemonWorkspaceId
      controlDir := control.dir
    }
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

private def removeOwnedRegistry
    (root controlDir : System.FilePath)
    (entry : SessionDescriptor) : IO Unit := do
  try
    withExistingProjectControl root (explicitControlDir? := some controlDir) fun control =>
      removeRegistryGeneration control entry
  catch _ =>
    pure ()

private def attemptCleanup (act : IO Unit) : IO Unit := do
  try
    act
  catch _ =>
    pure ()

private inductive OwnedDaemonFinish where
  | exitedCleanly
  | forcedReaped
  | exitedAbnormally (exitCode : UInt32)
  | unreaped

private def classifyOwnedDaemonExit (exitCode : UInt32) : OwnedDaemonFinish :=
  if exitCode == 0 then .exitedCleanly else .exitedAbnormally exitCode

private def forceOwnedDaemonChild
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO OwnedDaemonFinish := do
  let killSent ←
    try
      child.kill
      pure true
    catch _ =>
      pure false
  attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 20
  match ← exitCodeRef.get with
  | some exitCode =>
      if killSent then pure .forcedReaped else pure <| classifyOwnedDaemonExit exitCode
  | none => pure .unreaped

private def finishOwnedDaemonChild
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO OwnedDaemonFinish := do
  if let some exitCode ← exitCodeRef.get then
    return classifyOwnedDaemonExit exitCode
  try
    let child ← closeDaemonOwnerPipe owned.child
    attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 100
    match ← exitCodeRef.get with
    | some exitCode => pure <| classifyOwnedDaemonExit exitCode
    | none =>
        -- `startDaemon` uses `setsid`; Lean's retained child handle therefore kills the complete
        -- daemon process group rather than only the broker PID.
        forceOwnedDaemonChild child exitCodeRef
  catch _ =>
    forceOwnedDaemonChild owned.child exitCodeRef

private def markOwnedRegistryDraining
    (root controlDir : System.FilePath)
    (entry : SessionDescriptor) : IO Unit := do
  try
    withExistingProjectControl root (explicitControlDir? := some controlDir) fun control =>
      discard <| markRegistryDraining control entry
  catch _ =>
    pure ()

private def restoreOwnedRegistryRecoveryFence
    (root controlDir : System.FilePath)
    (entry : SessionDescriptor) : IO Unit := do
  try
    withExistingProjectControl root (explicitControlDir? := some controlDir) fun control => do
      match ← readRegistryAt control.registry with
      | .current current =>
          if sameRegistryGeneration current entry && current.lifecycle == .draining then
            -- A current `live` descriptor whose endpoint no longer responds projects to the public
            -- `recoveryRequired` state. Restore that conservative fence after a failed drain.
            writeExistingRegistry control { current with lifecycle := .live }
      | .absent | .legacy | .unsupported _ | .malformed _ => pure ()
  catch _ =>
    pure ()

private def finishOwnedProjectDaemon
    (root : System.FilePath)
    (controlDir : System.FilePath)
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO Unit := do
  let exitedBeforeOwnerCleanup ←
    match ← exitCodeRef.get with
    | some _ => pure true
    | none =>
        match ← owned.child.tryWait with
        | some exitCode =>
            exitCodeRef.set (some exitCode)
            pure true
        | none => pure false
  let registryWasDraining ←
    match ← readRegistryAt (controlDir / "beam-daemon.json") with
    | .current current =>
        pure (sameRegistryGeneration current owned.entry && current.lifecycle == .draining)
    | .absent | .legacy | .unsupported _ | .malformed _ => pure false
  if exitedBeforeOwnerCleanup && !registryWasDraining then
    -- An unexpected daemon exit is not evidence that its complete process tree disappeared. Keep
    -- the exact live generation fenced so observation projects it to recovery-required state.
    pure ()
  else
    markOwnedRegistryDraining root controlDir owned.entry
    match ← finishOwnedDaemonChild owned exitCodeRef with
    | .exitedCleanly | .forcedReaped =>
        removeOwnedRegistry root controlDir owned.entry
    | .exitedAbnormally _ =>
        restoreOwnedRegistryRecoveryFence root controlDir owned.entry
    | .unreaped =>
        pure ()

def withProjectDaemonOwner
    (home root : System.FilePath)
    (backend : Backend)
    (opts : CliOptions)
    (act : ProjectDaemonOwner → IO α) : IO α := do
  let controlDir ← controlDirFor root opts.explicitControlDir?
  -- Establish or validate the control boundary before bundle resolution can create project-local
  -- `.beam` state for a previously unseen toolchain.
  preparePrivateControlDir controlDir
  let desired ← desiredConfig home root backend
  let owned ← withProjectControl root (explicitControlDir? := some controlDir) fun control =>
    startOwnedProjectDaemon control desired backend opts
  let exitCodeRef ← IO.mkRef (none : Option UInt32)
  try
    act {
        client := owned.client
        root
        controlDir
        daemonId := owned.entry.daemonId
        child := owned.child
        exitCodeRef
      }
  finally
    finishOwnedProjectDaemon root controlDir owned exitCodeRef

private def lookupProjectDaemon
    (root : System.FilePath)
    (backend? : Option Backend := none)
    (explicitControlDir? : Option System.FilePath := none) : IO SelectedProjectDaemon := do
  let control ← projectControl root explicitControlDir?
  match ← observeProjectControl root control with
  | .live entry =>
      let workspace ← selectWorkspaceBackend root entry backend?
      pure { client := ← projectDaemonClient entry workspace control.dir, workspace }
  | .absent =>
      throw <| IO.userError (missingOwnerMessage root control.dir backend?)
  | .draining entry => throw <| IO.userError (drainingOwnerMessage root entry)
  | .legacy =>
      throw <| IO.userError <| registryReadRecoveryMessage root control.dir .legacy
  | .unsupported schemaVersion =>
      throw <| IO.userError <|
        registryReadRecoveryMessage root control.dir (.unsupported schemaVersion)
  | .malformed detail =>
      throw <| IO.userError <| registryReadRecoveryMessage root control.dir (.malformed detail)
  | .selectorMismatch entry =>
      throw <| IO.userError <|
        sessionSelectorMismatchMessage root control.dir entry
  | .unusable entry reason =>
      throw <| IO.userError <| generationRecoveryMessage root control.dir entry reason

def withProjectDaemon
    (root : System.FilePath)
    (backend : Backend)
    (act : ProjectDaemonClient → IO α)
    (explicitControlDir? : Option System.FilePath := none) : IO α := do
  act (← lookupProjectDaemon root (some backend) explicitControlDir?).client

def withExistingProjectDaemon
    (root : System.FilePath)
    (act : ProjectDaemonClient → IO α)
    (explicitControlDir? : Option System.FilePath := none) : IO α := do
  act (← lookupProjectDaemon root (explicitControlDir? := explicitControlDir?)).client

/-- Select one live workspace session without resolving local toolchain or bundle configuration. -/
def withSelectedProjectDaemon
    (root : System.FilePath)
    (act : SelectedProjectDaemon → IO α)
    (explicitControlDir? : Option System.FilePath := none) : IO α := do
  act (← lookupProjectDaemon root (explicitControlDir? := explicitControlDir?))
end Beam.Cli
