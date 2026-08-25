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

private def gracefulDaemonShutdownWaitTries : Nat :=
  50

/--
Finish a graceful daemon shutdown with a PID fallback only when the registry PID belongs to the
current process domain. A PID from another or unknown domain must never be probed or killed.
-/
def finishRegistryDaemonShutdown (entry : RegistryEntry) : IO Unit := do
  let recorded : Beam.RecordedPid := { pid := entry.pid, domain? := entry.pidDomain? }
  -- A broker may spend up to three seconds completing the bounded LSP shutdown path before its
  -- accept loop exits. Do not turn that orderly session close into SIGTERM just before it finishes.
  waitForRecordedPidGone recorded gracefulDaemonShutdownWaitTries
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
    (logPath : System.FilePath) : IO (IO.Process.Child daemonStdio) := do
  let mut args : List String := [
    "--root", desired.root.toString,
    "--workspace-id", projectDaemonWorkspaceId,
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
  }
  pure child

private partial def waitForDaemon
    (child : IO.Process.Child daemonStdio)
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (root : System.FilePath)
    (tries : Nat := 300) : IO (Except DaemonStartupFailure Unit) := do
  match ← daemonRoot? endpoint projectDaemonWorkspaceId with
  | some daemonRoot =>
      if ← Beam.sameFilePath (System.FilePath.mk daemonRoot) root then
        pure (.ok ())
      else
        pure <| .error {
          message := endpointOccupancyError endpoint (System.FilePath.mk daemonRoot) root
          endpointInUse := true
        }
  | none =>
      if (← child.tryWait).isSome then
        .error <$> daemonStartupFailure endpoint logPath "Beam daemon process exited before responding"
      else if tries == 0 then
        .error <$> daemonStartupFailure endpoint logPath "Beam daemon did not become ready before timeout"
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
  let ownerPid ← IO.Process.getPID
  pure {
    daemonId
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
  let child ← startDaemon desired endpoint logPath
  match ← waitForDaemon child endpoint logPath desired.root with
  | .ok () => pure ()
  | .error failure =>
    terminateDaemonChild child
    let endpointOccupied ← endpointAcceptsConnection endpoint
    if shouldRetryAutomaticStartup
        (usesAutomaticTcpEndpoint opts) tries endpointOccupied failure.endpointInUse then
      return ← startDaemonEntry desired opts (tries - 1)
    throw <| IO.userError failure.message
  let pid := child.pid.toNat
  let entry ← registryEntryFor desired daemonId pid endpoint opts
  pure (endpoint, entry, child)

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

private def projectDaemonClient (entry : RegistryEntry) : IO ProjectDaemonClient := do
  pure {
    endpoint := ← Beam.Daemon.endpointFromEntry entry
  }

private def registryOwnerObservable (entry : RegistryEntry) : IO Bool := do
  if entry.ownerPid == 0 then
    return false
  let recorded : Beam.RecordedPid := {
    pid := entry.ownerPid
    domain? := entry.ownerPidDomain?
  }
  match ← recorded.observe with
  | .invalid | .local false => pure false
  | .local true | .differentDomain | .unknownDomain => pure true

def registryLiveFor
    (root : System.FilePath)
    (expectedHash? : Option String := none) : IO (Option RegistryEntry) := do
  match ← readRegistry? root with
  | none => pure none
  | some entry =>
      let rootOk ← Beam.sameFilePath (System.FilePath.mk entry.root) root
      let hashOk := expectedHash?.map (· == entry.configHash) |>.getD true
      if !rootOk || !hashOk || !(← registryOwnerObservable entry) then
        pure none
      else
        match registryEndpoint? entry with
        | none => pure none
        | some endpoint =>
            -- The owner pipe makes endpoint liveness authoritative across PID domains. A
            -- same-domain dead owner is rejected immediately; another domain is never probed.
            if ← daemonServesRoot endpoint projectDaemonWorkspaceId root then
              pure (some entry)
            else
              pure none

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

def ProjectDaemonOwner.exited (owner : ProjectDaemonOwner) : IO Bool :=
  return (← owner.exitCode?).isSome

/-- Whether this owner generation is still the one published for its project. -/
def ProjectDaemonOwner.registered (owner : ProjectDaemonOwner) : IO Bool := do
  match ← readRegistry? owner.root with
  | some current => pure (current.daemonId == owner.daemonId)
  | none => pure false

private def activeOwnerMessage (root : System.FilePath) (entry : RegistryEntry) : String :=
  s!"Beam session for {root} is already owned by wrapper pid {entry.ownerPid}; " ++
    "interrupt that 'lean-beam ensure --hold' process before starting another owner"

private def missingOwnerMessage (root : System.FilePath) : String :=
  s!"no live Beam session owner is registered for {root}; " ++
    "start 'lean-beam ensure --hold' for this project and keep it running while using wrapper commands"

private def startOwnedProjectDaemon
    (desired : DesiredConfig)
    (opts : CliOptions) : IO OwnedProjectDaemon := do
  if let some live ← registryLiveFor desired.root then
    throw <| IO.userError (activeOwnerMessage desired.root live)
  -- A non-live registry may refer to a daemon still winding down after owner loss. Ask that exact
  -- root-matching endpoint to stop, and use PID fallback only through the typed domain boundary.
  stopRegisteredDaemon desired.root
  let (endpoint, entry, child) ← startDaemonEntry desired opts
  try
    writeRegistry desired.root entry
  catch err =>
    terminateDaemonChild child
    throw err
  pure {
    client := { endpoint }
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

private def removeOwnedRegistry (root : System.FilePath) (daemonId : String) : IO Unit := do
  try
    withProjectControlLock root do
      match ← readRegistry? root with
      | some current =>
          if current.daemonId == daemonId then
            removeRegistry root
      | none => pure ()
  catch _ =>
    pure ()

private def attemptCleanup (act : IO Unit) : IO Unit := do
  try
    act
  catch _ =>
    pure ()

private def finishOwnedDaemonChild
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO Unit := do
  try
    let child ← closeDaemonOwnerPipe owned.child
    attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 100
    if (← exitCodeRef.get).isNone then
      attemptCleanup child.kill
      attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 20
    pure ()
  catch _ =>
    attemptCleanup owned.child.kill
    attemptCleanup <| waitForOwnedDaemonExit owned.child exitCodeRef 20

private def finishOwnedProjectDaemon
    (root : System.FilePath)
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO Unit := do
  finishOwnedDaemonChild owned exitCodeRef
  removeOwnedRegistry root owned.entry.daemonId

def withProjectDaemonOwner
    (home root : System.FilePath)
    (backend : Backend)
    (opts : CliOptions)
    (act : ProjectDaemonOwner → IO α) : IO α := do
  let desired ← desiredConfig home root backend
  let owned ← withProjectControlLock root do
    startOwnedProjectDaemon desired opts
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
    (expectedHash? : Option String := none) : IO ProjectDaemonClient := do
  withProjectControlLock root do
    match ← registryLiveFor root expectedHash? with
    | some entry => projectDaemonClient entry
    | none =>
        stopRegisteredDaemon root
        throw <| IO.userError (missingOwnerMessage root)

def withProjectDaemon
    (home root : System.FilePath)
    (backend : Backend)
    (act : ProjectDaemonClient → IO α) : IO α := do
  let desired ← desiredConfig home root backend
  act (← lookupProjectDaemon root (some desired.configHash))

def withExistingProjectDaemon
    (root : System.FilePath)
    (act : ProjectDaemonClient → IO α) : IO α := do
  act (← lookupProjectDaemon root)
end Beam.Cli
