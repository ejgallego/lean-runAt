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
import Beam.Daemon.Ownership
import Beam.Daemon.Paths
import Std.Internal.UV.Timer

open Lean

namespace Beam.Cli

open Beam.Daemon.Ownership

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

def projectControlLockDir (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "lock")

/--
Run `act` while holding the per-project daemon control lock.

Project control operations should fail with owner diagnostics instead of waiting forever behind a
live but stuck wrapper process. Longer bundle build locks intentionally use the lower-level
unbounded lock helper.
-/
def withProjectControlLock (root : System.FilePath) (act : IO α) : IO α := do
  withLockTimeout (← projectControlLockDir root) (← projectControlLockTimeoutMs) act

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

private def writeRegistry (root : System.FilePath) (entry : RegistryEntry) : IO Unit := do
  let path ← registryPath root
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  let tmp := path.withExtension "tmp"
  IO.FS.writeFile tmp ((toJson entry).pretty ++ "\n")
  IO.FS.rename tmp path

def removeRegistry (root : System.FilePath) : IO Unit := do
  let path ← registryPath root
  if ← path.pathExists then
    IO.FS.removeFile path

private partial def waitForRecordedPidGone
    (recorded : Beam.RecordedPid)
    (tries : Nat := 20) : IO Unit := do
  if tries == 0 then
    return
  match ← recorded.observe with
  | .local true =>
      IO.sleep 100
      waitForRecordedPidGone recorded (tries - 1)
  | .invalid | .local false | .differentDomain | .unknownDomain =>
      pure ()

/--
Finish a graceful daemon shutdown with a PID fallback only when the registry PID belongs to the
current process domain. A PID from another or unknown domain must never be probed or killed.
-/
def finishRegistryDaemonShutdown (entry : RegistryEntry) : IO Unit := do
  let recorded : Beam.RecordedPid := { pid := entry.pid, domain? := entry.pidDomain? }
  waitForRecordedPidGone recorded
  match ← recorded.observe with
  | .local true =>
      if ← recorded.terminateIfLocal then
        waitForRecordedPidGone recorded
  | .invalid | .local false | .differentDomain | .unknownDomain =>
      pure ()

private def stopDaemonEntry (entry : RegistryEntry) : IO Unit := do
  let mayKillPid ←
    match registryEndpoint? entry with
    | some endpoint =>
        match ← daemonRoot? endpoint projectDaemonWorkspaceId with
        | some daemonRoot =>
            if ← Beam.sameFilePath (System.FilePath.mk daemonRoot) (System.FilePath.mk entry.root) then
              try
                let _ ← sendRequest endpoint { op := .shutdown }
                pure ()
              catch _ =>
                pure ()
              pure true
            else
              pure false
        | none =>
            pure true
    | none =>
        pure true
  if mayKillPid then
    finishRegistryDaemonShutdown entry

def stopRegisteredDaemon (root : System.FilePath) : IO Unit := do
  match ← readRegistry? root with
  | none =>
      removeRegistry root
  | some entry =>
      stopDaemonEntry entry
      removeRegistry root

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
  match ← daemonRoot? endpoint projectDaemonWorkspaceId with
  | none =>
      pure ()
  | some daemonRoot =>
      if usesAutomaticTcpEndpoint opts && tries > 0 then
        return ← selectUnoccupiedEndpoint desired opts (tries - 1)
      else
        throw <| IO.userError (endpointOccupancyError endpoint (System.FilePath.mk daemonRoot) desired.root)
  if ← endpointAcceptsConnection endpoint then
    if usesAutomaticTcpEndpoint opts && tries > 0 then
      return ← selectUnoccupiedEndpoint desired opts (tries - 1)
    else
      throw <| IO.userError (endpointInUseError endpoint)
  else
    pure endpoint

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
  registry : Option RegistryEntry := none
  registryPidStatus : Option String := none
  registryEndpoint : Option String := none
  startupLogPath : Option String := none
  startupLogTail : Option String := none
  deriving ToJson

private def daemonFailureIncidentSchemaVersion : Nat :=
  1

private def daemonFailureKind? (detail : String) : Option String :=
  if detail.contains "Beam daemon connection closed" then
    some "connectionClosed"
  else if detail.contains "no live Beam daemon registered for " then
    some "noLiveDaemon"
  else
    none

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
    let registry ← readRegistry? root
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
      registry
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

def daemonFailureMessage (root : System.FilePath) (detail : String) : IO String := do
  match daemonFailureKind? detail with
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

private def startupFailureMessage (endpoint : Transport.Endpoint) (logPath : System.FilePath) (detail : String) :
    IO String := do
  let msg := if detail.isEmpty then
    s!"failed to start Beam daemon on {endpointSummary endpoint}"
  else
    s!"failed to start Beam daemon on {endpointSummary endpoint}\n{detail}"
  if ← logPath.pathExists then
    let logText := Beam.trimLine (← IO.FS.readFile logPath)
    if logText.isEmpty then
      pure msg
    else
      pure <| msg ++ s!"\nstartup log ({logPath}):\n{logText}"
  else
    pure msg

private abbrev daemonStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .null

private partial def waitForDaemonChildExit
    (child : IO.Process.Child daemonStdio)
    (tries : Nat := 20) : IO Unit := do
  if tries == 0 || (← child.tryWait).isSome then
    return
  IO.sleep 100
  waitForDaemonChildExit child (tries - 1)

private def terminateDaemonChild (child : IO.Process.Child daemonStdio) : IO Unit := do
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
    (daemonId : String) : IO (IO.Process.Child daemonStdio) := do
  let mut args : List String := [
    "--root", desired.root.toString,
    "--workspace-id", projectDaemonWorkspaceId,
    "--daemon-id", daemonId
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
  let shell := s!"exec {cmd} >{shellQuote logPath.toString} 2>&1 < /dev/null"
  let child ← IO.Process.spawn {
    toStdioConfig := daemonStdio
    cmd := "sh"
    args := #["-c", shell]
    cwd := some desired.root
  }
  pure child

private partial def waitForDaemon
    (child : IO.Process.Child daemonStdio)
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (root : System.FilePath)
    (tries : Nat := 300) : IO Unit := do
  match ← daemonRoot? endpoint projectDaemonWorkspaceId with
  | some daemonRoot =>
      if ← Beam.sameFilePath (System.FilePath.mk daemonRoot) root then
        pure ()
      else
        throw <| IO.userError (endpointOccupancyError endpoint (System.FilePath.mk daemonRoot) root)
  | none =>
      if (← child.tryWait).isSome then
        throw <| IO.userError (← startupFailureMessage endpoint logPath "Beam daemon process exited before responding")
      else if tries == 0 then
        throw <| IO.userError (← startupFailureMessage endpoint logPath "Beam daemon did not become ready before timeout")
      else
        IO.sleep 100
        waitForDaemon child endpoint logPath root (tries - 1)

private def newDaemonGenerationId (configHash : String) : IO String := do
  let startedMonoNanos ← IO.monoNanosNow
  let nonce := ByteArray.toUInt64LE! (← IO.getRandomBytes 8)
  pure s!"{configHash.take 12}-{startedMonoNanos}-{nonce}"

private def registryEntryFor
    (desired : DesiredConfig)
    (daemonId : String)
    (pid : Nat)
    (endpoint : Transport.Endpoint)
    (opts : CliOptions) : IO RegistryEntry := do
  let port? :=
    match endpoint with
    | .tcp port => some port.toNat
  let pidDomain? ← Beam.currentPidDomain?
  pure {
    daemonId
    pid
    pidDomain?
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
    (tries : Nat := 10) : IO (Transport.Endpoint × RegistryEntry) := do
  let endpoint ← selectUnoccupiedEndpoint desired opts
  let logPath ← daemonStartupLogPath desired.root
  let daemonId ← newDaemonGenerationId desired.configHash
  let child ← startDaemon desired endpoint logPath daemonId
  try
    waitForDaemon child endpoint logPath desired.root
  catch err =>
    terminateDaemonChild child
    let endpointOccupied ← endpointAcceptsConnection endpoint
    let startupAddressInUse := startupFailureSuggestsEndpointInUse (toString err)
    if shouldRetryAutomaticStartup (usesAutomaticTcpEndpoint opts) tries endpointOccupied startupAddressInUse then
      return ← startDaemonEntry desired opts (tries - 1)
    throw err
  let pid := child.pid.toNat
  let entry ← registryEntryFor desired daemonId pid endpoint opts
  pure (endpoint, entry)

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

def registryLiveFor (root : System.FilePath) (expectedHash? : Option String := none) : IO (Option RegistryEntry) := do
  match ← readRegistry? root with
  | none => pure none
  | some entry =>
      let rootOk ← Beam.sameFilePath (System.FilePath.mk entry.root) root
      let hashOk := expectedHash?.map (· == entry.configHash) |>.getD true
      if !rootOk || !hashOk then
        pure none
      else if let some endpoint := registryEndpoint? entry then
        -- PID observations are not a liveness fallback across isolated sandboxes; only a
        -- root-matching endpoint proves that this registry entry is live.
        if ← daemonServesRoot endpoint projectDaemonWorkspaceId root then
          pure (some entry)
        else
          pure none
      else
        pure none

private def wrapperLeaseHeartbeatIntervalMs : UInt32 :=
  250

private def wrapperLeaseHeartbeatTimeoutNanos : Nat :=
  5000000000

private def wrapperLeaseHeartbeatWriteRetryMs : UInt32 :=
  50

private def wrapperLeaseHeartbeatWriteRetries : Nat :=
  3

private def wrapperLifecyclePollMs : UInt32 :=
  50

private def daemonRequestProbeTimeoutMs : Nat :=
  1000

private def wrapperLeaseActionCancelWaitMs : Nat :=
  5000

private structure WrapperLease where
  root : System.FilePath
  path : System.FilePath
  stopHeartbeat : IO.Ref Bool
  heartbeatTimer : Std.Internal.UV.Timer
  heartbeatTask : Task (Except IO.Error Unit)

/-- Internal typed target for one wrapper request to a daemon generation. -/
structure ProjectDaemonClient where
  endpoint : Transport.Endpoint
  wrapperLease : WrapperLeaseContext

private structure DaemonRetirement where
  daemonId : String
  ownerLeaseFile : String
  deriving FromJson, ToJson

private inductive EnsuredProjectDaemon where
  | reused (client : ProjectDaemonClient) (lease : WrapperLease)
  | started (client : ProjectDaemonClient) (lease : WrapperLease)

private def projectDaemonClient
    (endpoint : Transport.Endpoint)
    (daemonId : String)
    (lease : WrapperLease) : ProjectDaemonClient :=
  {
    endpoint
    wrapperLease := {
      daemonId
      leaseFile := lease.path.fileName.getD lease.path.toString
    }
  }

private def removeFileIfExists (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    IO.FS.removeFile path

private def removeFileIfExistsBestEffort (path : System.FilePath) : IO Unit := do
  try
    removeFileIfExists path
  catch _ =>
    pure ()

private def ensureWrapperLeaseNotRevoked (path : System.FilePath) : IO Unit := do
  if ← (wrapperLeaseRevocationPath path).pathExists then
    throw <| IO.userError s!"wrapper daemon-lifetime lease was revoked: {path}"

private def writeWrapperLeaseMetadata
    (path : System.FilePath)
    (metadata : WrapperLeaseMetadata) : IO Unit := do
  ensureWrapperLeaseNotRevoked path
  let tmp := path.withExtension "tmp"
  IO.FS.writeFile tmp ((toJson metadata).pretty ++ "\n")
  try
    ensureWrapperLeaseNotRevoked path
  catch err =>
    removeFileIfExistsBestEffort tmp
    throw err
  IO.FS.rename tmp path
  try
    ensureWrapperLeaseNotRevoked path
  catch err =>
    removeFileIfExistsBestEffort path
    throw err

private partial def writeWrapperLeaseHeartbeat
    (path : System.FilePath)
    (metadata : WrapperLeaseMetadata)
    (retries : Nat := wrapperLeaseHeartbeatWriteRetries) : IO Unit := do
  try
    writeWrapperLeaseMetadata path metadata
  catch err =>
    if retries == 0 then
      throw err
    IO.sleep wrapperLeaseHeartbeatWriteRetryMs
    writeWrapperLeaseHeartbeat path metadata (retries - 1)

private partial def wrapperLeaseHeartbeatLoop
    (path : System.FilePath)
    (metadata : WrapperLeaseMetadata)
    (stop : IO.Ref Bool)
    (timer : Std.Internal.UV.Timer)
    (tick : IO.Promise Unit) : IO Unit := do
  let tickResult ← IO.wait tick.result?
  if ← stop.get then
    return
  let some _ := tickResult
    | return
  let heartbeatMonoNanos ← IO.monoNanosNow
  let metadata := { metadata with heartbeatMonoNanos }
  writeWrapperLeaseHeartbeat path metadata
  wrapperLeaseHeartbeatLoop path metadata stop timer (← timer.next)

private def acquireWrapperLease (root : System.FilePath) : IO WrapperLease := do
  let dir ← wrapperLeaseDir root
  IO.FS.createDirAll dir
  let pid ← IO.Process.getPID
  let stamp ← IO.monoNanosNow
  let nonce := ByteArray.toUInt64LE! (← IO.getRandomBytes 8)
  let path := dir / s!"{stamp}-{pid}-{nonce}.lease"
  let metadata : WrapperLeaseMetadata := {
    pid := pid.toNat
    pidDomain? := ← Beam.currentPidDomain?
    heartbeatMonoNanos := stamp
  }
  writeWrapperLeaseMetadata path metadata
  let stopHeartbeat ← IO.mkRef false
  let heartbeatTimer ← Std.Internal.UV.Timer.mk wrapperLeaseHeartbeatIntervalMs.toUInt64 true
  let firstTick ← heartbeatTimer.next
  let heartbeatTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    wrapperLeaseHeartbeatLoop path metadata stopHeartbeat heartbeatTimer firstTick
  pure { root, path, stopHeartbeat, heartbeatTimer, heartbeatTask }

private def stopWrapperLeaseHeartbeat (lease : WrapperLease) : IO Unit := do
  lease.stopHeartbeat.set true
  Std.Internal.UV.Timer.stop lease.heartbeatTimer
  match ← IO.wait lease.heartbeatTask with
  | .ok () => pure ()
  | .error err => throw err

private def releaseWrapperLease (lease : WrapperLease) : IO Unit := do
  try
    stopWrapperLeaseHeartbeat lease
  finally
    removeFileIfExistsBestEffort lease.path
    removeFileIfExistsBestEffort (wrapperLeaseRevocationPath lease.path)

private def readWrapperLeaseMetadata? (path : System.FilePath) : IO (Option WrapperLeaseMetadata) := do
  unless ← path.pathExists do
    return none
  let text ←
    try
      IO.FS.readFile path
    catch err =>
      if ← path.pathExists then
        throw err
      else
        return none
  match Json.parse text with
  | .error _ => pure none
  | .ok json =>
      match fromJson? json with
      | .error _ => pure none
      | .ok metadata => pure (some metadata)

private def staleWrapperLease? (path : System.FilePath) : IO Bool := do
  if ← (wrapperLeaseRevocationPath path).pathExists then
    return true
  match ← readWrapperLeaseMetadata? path with
  | none => pure true
  | some metadata =>
      let now ← IO.monoNanosNow
      let pidObservation ←
        (Beam.RecordedPid.mk metadata.pid metadata.pidDomain?).observe
      pure <| wrapperLeaseStaleFromObservation pidObservation now
        wrapperLeaseHeartbeatTimeoutNanos metadata

private def revokeWrapperLease (path : System.FilePath) : IO Unit := do
  let revocationPath := wrapperLeaseRevocationPath path
  unless ← revocationPath.pathExists do
    let tmp := revocationPath.withExtension "revoking"
    let revocation : WrapperLeaseRevocation := { revokedMonoNanos := ← IO.monoNanosNow }
    IO.FS.writeFile tmp ((toJson revocation).pretty ++ "\n")
    IO.FS.rename tmp revocationPath
  removeFileIfExists path

private def reapAndObserveOtherWrapperLeases (lease : WrapperLease) :
    IO OtherWrapperLeasesObservation := do
  try
    let dir ← wrapperLeaseDir lease.root
    unless ← dir.pathExists do
      return .drained
    let entries ← dir.readDir
    for entry in entries do
      if entry.path != lease.path && entry.fileName.endsWith ".lease" then
        let stale? ←
          try
            pure <| some (← staleWrapperLease? entry.path)
          catch _ =>
            pure none
        match stale? with
        | none => return .activeOrUnreadable
        | some true =>
            try
              revokeWrapperLease entry.path
            catch _ =>
              return .activeOrUnreadable
        | some false => return .activeOrUnreadable
    pure .drained
  catch _ =>
    pure .activeOrUnreadable

private def removeDaemonRetirement (root : System.FilePath) : IO Unit := do
  removeFileIfExists (← daemonRetirementPath root)

private inductive OwnershipRegistryRead where
  | missing
  | invalid
  | unreadable (error : IO.Error)
  | present (entry : RegistryEntry)

private def readOwnershipRegistry (root : System.FilePath) : IO OwnershipRegistryRead := do
  let path ← registryPath root
  try
    unless ← path.pathExists do
      return .missing
    let text ← IO.FS.readFile path
    match Json.parse text with
    | .error _ => pure .invalid
    | .ok json =>
        match fromJson? json with
        | .error _ => pure .invalid
        | .ok entry => pure (.present entry)
  catch err =>
    pure (.unreadable err)

private def readOrDiscardInvalidDaemonRetirement?
    (root : System.FilePath) : IO (Option DaemonRetirement) := do
  let path ← daemonRetirementPath root
  unless ← path.pathExists do
    return none
  let text ← IO.FS.readFile path
  let retirement? := do
    let json ← Json.parse text
    fromJson? json
  match retirement? with
  | .ok retirement => pure (some retirement)
  | .error _ =>
      removeDaemonRetirement root
      pure none

private def writeDaemonRetirement
    (root : System.FilePath)
    (retirement : DaemonRetirement) : IO Unit := do
  let path ← daemonRetirementPath root
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  let tmp := path.withExtension "tmp"
  IO.FS.writeFile tmp ((toJson retirement).pretty ++ "\n")
  IO.FS.rename tmp path

/-- Reconcile stale or invalid retirement state and report whether it still blocks admission. -/
private def reconcileRetirementAdmission (lease : WrapperLease) : IO Bool := do
  let some retirement ← readOrDiscardInvalidDaemonRetirement? lease.root
    | return false
  let registry ←
    match ← readOwnershipRegistry lease.root with
    | .missing | .invalid =>
        removeDaemonRetirement lease.root
        return false
    | .unreadable err => throw err
    | .present registry => pure registry
  if registry.daemonId != retirement.daemonId then
    removeDaemonRetirement lease.root
    return false
  unless validWrapperLeaseFileName retirement.ownerLeaseFile do
    removeDaemonRetirement lease.root
    return false
  let ownerPath := (← wrapperLeaseDir lease.root) / retirement.ownerLeaseFile
  if ← staleWrapperLease? ownerPath then
    revokeWrapperLease ownerPath
    removeDaemonRetirement lease.root
    pure false
  else
    pure true

private partial def ensureProjectDaemonUnderLease
    (desired : DesiredConfig)
    (opts : CliOptions)
    (lease : WrapperLease) : IO EnsuredProjectDaemon := do
  let admitted? ← withProjectControlLock desired.root do
    if ← reconcileRetirementAdmission lease then
      pure none
    else
      if let some live ← registryLiveFor desired.root desired.configHash then
        if let some endpoint := registryEndpoint? live then
          return some <| EnsuredProjectDaemon.reused
            (projectDaemonClient endpoint live.daemonId lease) lease
        removeRegistry desired.root
      let live? ← registryLiveFor desired.root
      if live?.isNone then
        removeRegistry desired.root
      let (endpoint, entry) ← startDaemonEntry desired opts
      writeRegistry desired.root entry
      if let some live := live? then
        unless live.pid == entry.pid && live.port? == entry.port? do
          stopDaemonEntry live
      pure <| some <| EnsuredProjectDaemon.started
        (projectDaemonClient endpoint entry.daemonId lease) lease
  match admitted? with
  | some daemon => pure daemon
  | none =>
      IO.sleep wrapperLifecyclePollMs
      ensureProjectDaemonUnderLease desired opts lease

private def acquireWrapperLeaseForAdmission (root : System.FilePath) : IO WrapperLease :=
  withProjectControlLock root do
    acquireWrapperLease root

private def admitProjectDaemon
    (home root : System.FilePath)
    (backend : Backend)
    (opts : CliOptions) : IO EnsuredProjectDaemon := do
  let lease ← acquireWrapperLeaseForAdmission root
  try
    let desired ← desiredConfig home root backend
    ensureProjectDaemonUnderLease desired opts lease
  catch err =>
    releaseWrapperLease lease
    throw err

private def requestDaemonStatsWithin
    (endpoint : Transport.Endpoint) : IO (Option Response) := do
  let task ← IO.asTask (prio := Task.Priority.dedicated) <|
    sendRequest endpoint { op := .stats }
  let mut remainingMs := daemonRequestProbeTimeoutMs
  while !(← IO.hasFinished task) && remainingMs > 0 do
    IO.sleep wrapperLifecyclePollMs
    remainingMs := remainingMs - min remainingMs wrapperLifecyclePollMs.toNat
  if ← IO.hasFinished task then
    match ← IO.wait task with
    | .ok response => pure (some response)
    | .error _ => pure none
  else
    IO.cancel task
    pure none

private def registryDaemonProvenGone (registry : RegistryEntry) : IO Bool := do
  let recorded : Beam.RecordedPid := { pid := registry.pid, domain? := registry.pidDomain? }
  match ← recorded.observe with
  | .local false => pure true
  | .local true => pure <| (← recorded.zombieIfLocal?).getD false
  | .invalid | .differentDomain | .unknownDomain => pure false

private def observeDaemonRequests
    (registry : RegistryEntry)
    (endpoint : Transport.Endpoint) : IO DaemonRequestsObservation := do
  try
    let some resp ← requestDaemonStatsWithin endpoint
      | return if ← registryDaemonProvenGone registry then .provenGone else .activeOrUnreadable
    unless resp.ok do
      return .activeOrUnreadable
    let some result := resp.result?
      | return .activeOrUnreadable
    let activeRequestCount ← IO.ofExcept <| result.getObjValAs? Nat "activeRequestCount"
    pure <| if activeRequestCount == 0 then .drained else .activeOrUnreadable
  catch _ =>
    pure .activeOrUnreadable

private def tryCommitDaemonRetirement
    (client : ProjectDaemonClient)
    (lease : WrapperLease) : IO RetirementDecision := do
  withProjectControlLock lease.root do
    let observation ←
      match ← readOwnershipRegistry lease.root with
      | .present registry =>
          if registry.daemonId != client.wrapperLease.daemonId then
            pure RetirementObservation.replacement
          else
            let otherLeases ← reapAndObserveOtherWrapperLeases lease
            let daemonRequests ←
              match otherLeases with
              | .drained => observeDaemonRequests registry client.endpoint
              | .activeOrUnreadable => pure .activeOrUnreadable
            pure <| RetirementObservation.current otherLeases daemonRequests
      | .missing | .invalid | .unreadable _ =>
          pure <| RetirementObservation.unavailable (← reapAndObserveOtherWrapperLeases lease)
    match retirementDecision observation with
    | .wait => pure .wait
    | .obsolete => pure .obsolete
    | .commit =>
        let ownerLeaseFile := lease.path.fileName.getD lease.path.toString
        writeDaemonRetirement lease.root {
          daemonId := client.wrapperLease.daemonId
          ownerLeaseFile
        }
        pure .commit

private partial def retireStartedProjectDaemon
    (client : ProjectDaemonClient)
    (lease : WrapperLease) : IO Bool := do
  match ← tryCommitDaemonRetirement client lease with
  | .commit => pure true
  | .obsolete => pure false
  | .wait =>
      IO.sleep wrapperLifecyclePollMs
      retireStartedProjectDaemon client lease

private def finishStartedProjectDaemonAdmission
    (client : ProjectDaemonClient)
    (lease : WrapperLease) : IO Unit := do
  if ← retireStartedProjectDaemon client lease then
    -- Leave the final heartbeat on disk. A successor with matching PID-domain identity can
    -- prove this process exited by PID; an unknown or different domain waits for the heartbeat
    -- to expire before it clears the retirement fence and observes the daemon endpoint.
    stopWrapperLeaseHeartbeat lease
  else
    releaseWrapperLease lease

private partial def awaitWrapperLeaseAction
    (lease : WrapperLease)
    (actionTask : Task (Except IO.Error α)) : IO α := do
  if ← IO.hasFinished actionTask then
    match ← IO.wait actionTask with
    | .ok value => pure value
    | .error err => throw err
  else if ← IO.hasFinished lease.heartbeatTask then
    let heartbeatResult ← IO.wait lease.heartbeatTask
    IO.cancel actionTask
    let mut remainingMs := wrapperLeaseActionCancelWaitMs
    while !(← IO.hasFinished actionTask) && remainingMs > 0 do
      IO.sleep wrapperLifecyclePollMs
      remainingMs := remainingMs - min remainingMs wrapperLifecyclePollMs.toNat
    match heartbeatResult with
    | .ok () => throw <| IO.userError "wrapper lease heartbeat stopped unexpectedly"
    | .error err => throw err
  else
    IO.sleep wrapperLifecyclePollMs
    awaitWrapperLeaseAction lease actionTask

private def runWhileWrapperLeaseHealthy
    (lease : WrapperLease)
    (act : IO α) : IO α := do
  let actionTask ← IO.asTask (prio := Task.Priority.dedicated) act
  awaitWrapperLeaseAction lease actionTask

def withProjectDaemon
    (home root : System.FilePath)
    (backend : Backend)
    (opts : CliOptions)
    (act : ProjectDaemonClient → IO α) : IO α := do
  match ← admitProjectDaemon home root backend opts with
  | .reused client lease =>
      let result ←
        try
          pure <| Except.ok (← runWhileWrapperLeaseHealthy lease (act client))
        catch err =>
          pure <| Except.error err
      releaseWrapperLease lease
      match result with
      | .ok value => pure value
      | .error err => throw err
  | .started client lease =>
      -- The starter owns this daemon generation for its process lifetime. Unlike a reuser, it
      -- must finish already-admitted work even if its filesystem heartbeat becomes unhealthy,
      -- then retain ownership through broker draining and retirement.
      let result ←
        try
          pure <| Except.ok (← act client)
        catch err =>
          pure <| Except.error err
      finishStartedProjectDaemonAdmission client lease
      match result with
      | .ok value => pure value
      | .error err => throw err

private partial def lookupProjectDaemonUnderLease (lease : WrapperLease) : IO ProjectDaemonClient := do
  let endpoint? ← withProjectControlLock lease.root do
    if ← reconcileRetirementAdmission lease then
      pure none
    else
      match ← registryLiveFor lease.root with
      | some entry =>
          let endpoint ← Beam.Daemon.endpointFromEntry entry
          pure <| some <| projectDaemonClient endpoint entry.daemonId lease
      | none =>
          let msg ← daemonFailureMessage lease.root s!"no live Beam daemon registered for {lease.root}"
          stopRegisteredDaemon lease.root
          throw <| IO.userError msg
  match endpoint? with
  | some endpoint => pure endpoint
  | none =>
      IO.sleep wrapperLifecyclePollMs
      lookupProjectDaemonUnderLease lease

def withExistingProjectDaemon
    (root : System.FilePath)
    (act : ProjectDaemonClient → IO α) : IO α := do
  let lease ← acquireWrapperLeaseForAdmission root
  let result ←
    try
      let client ← lookupProjectDaemonUnderLease lease
      pure <| Except.ok (← runWhileWrapperLeaseHealthy lease (act client))
    catch err =>
      pure <| Except.error err
  releaseWrapperLease lease
  match result with
  | .ok value => pure value
  | .error err => throw err

end Beam.Cli
