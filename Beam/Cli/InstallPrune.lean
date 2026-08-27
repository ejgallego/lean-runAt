/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.InstallLayout
import Beam.Cli.Lock
import Beam.Cli.RuntimeBundle.Metadata
import Beam.Cli.RuntimeBundle.Paths
import Beam.Cli.RuntimeBundle.Source
import Beam.Path

open Lean

namespace Beam.Cli

private structure InstallPruneOptions where
  apply : Bool := false
  bundles : Bool := false
  help : Bool := false

private structure InstallPruneContext where
  home : System.FilePath
  installRoot : System.FilePath
  versionsRoot : System.FilePath
  bundleRoot : System.FilePath

private structure InstallPrunePlan where
  oldRuntimes : Array System.FilePath := #[]
  staleBundles : Array System.FilePath := #[]

private def installLockPollMs : Nat :=
  100

/--
Coordinate pruning with the bootstrap shell installer, which owns `.install-lock` as a directory.

Unlike the old generic directory lock, this compatibility boundary never reaps a purportedly stale
owner: `mkdir` is the only acquisition operation and only the process that created the directory
removes it. A crashed installer therefore fails closed and requires explicit operator recovery.
-/
private partial def acquireInstallLockUntil
    (lockDir : System.FilePath)
    (startedNanos deadlineNanos timeoutMs : Nat) : IO Unit := do
  let acquired ←
    try
      IO.FS.createDir lockDir
      pure true
    catch
    | .alreadyExists .. => pure false
    | error => throw error
  if acquired then
    let selfPid ← IO.Process.getPID
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
    if let some pidDomain := ← Beam.currentPidDomain? then
      IO.FS.writeFile (lockDir / "pid-domain") s!"{pidDomain}\n"
    return
  let now ← IO.monoNanosNow
  if now >= deadlineNanos then
    let waitedMs := (now - startedNanos) / 1000000
    throw <| IO.userError <|
      s!"timed out after {waitedMs} ms waiting for Beam lock {lockDir}; timeout: {timeoutMs} ms"
  IO.sleep installLockPollMs.toUInt32
  acquireInstallLockUntil lockDir startedNanos deadlineNanos timeoutMs

private def releaseInstallLock (lockDir : System.FilePath) : IO Unit := do
  for name in #["pid", "pid-domain"] do
    let path := lockDir / name
    if ← path.pathExists then
      IO.FS.removeFile path
  IO.FS.removeDir lockDir

private def withInstallLockTimeout
    (lockDir : System.FilePath)
    (timeoutMs : Nat)
    (act : IO α) : IO α := do
  let startedNanos ← IO.monoNanosNow
  acquireInstallLockUntil lockDir startedNanos
    (startedNanos + timeoutMs * 1000000) timeoutMs
  try
    act
  finally
    releaseInstallLock lockDir

private def installPruneUsage : String :=
  "usage: lean-beam prune [--apply] [--bundles]"

private def installPruneHelp : String :=
  String.intercalate "\n" [
    installPruneUsage,
    "",
    "Preview and optionally remove old installed Beam runtimes.",
    "",
    "options:",
    "  --apply      remove the displayed paths",
    "  --bundles    also select stale or incomplete installed bundle-cache entries",
    "  -h, --help   show this help",
    "",
    "Restart active agents and MCP clients before using --apply.",
    "Apply removes one validated path at a time and reports each successful removal immediately."
  ]

private def parseInstallPruneOptions (args : List String) : Except String InstallPruneOptions := do
  let mut opts : InstallPruneOptions := {}
  for arg in args do
    match arg with
    | "--apply" => opts := { opts with apply := true }
    | "--bundles" => opts := { opts with bundles := true }
    | "-h" | "--help" => opts := { opts with help := true }
    | _ => throw s!"{installPruneUsage}\nunknown prune option: {arg}"
  pure opts

private def fail (message : String) : IO α :=
  throw <| IO.userError message

private def requireOwnedInstallRoot (installRoot : System.FilePath) : IO Unit := do
  let marker := installRoot / ".lean-beam-install-root"
  match ← checkInstallRootMarker installRoot with
  | .ok () => pure ()
  | .error .missing =>
      fail s!"refusing to prune unmarked Beam install root: {installRoot}"
  | .error .invalid =>
      fail s!"refusing to prune invalid Beam install root marker: {marker}"
  | .error .missingRoot =>
      fail s!"refusing to prune install root marker without root: {marker}"
  | .error .mismatchedRoot =>
      fail s!"refusing to prune install root with mismatched marker root: {marker}"

private def validatedRuntimePayload (versionsRoot : System.FilePath)
    (path : System.FilePath) : IO Unit := do
  let resolved ← Beam.resolveExistingPath path
  unless resolved.toString == path.toString do
    fail s!"refusing to prune symlinked runtime path: {path}"
  unless resolved.parent == some versionsRoot do
    fail s!"refusing to prune non-canonical runtime path: {path}"
  let some location := installedRuntimeLocation? resolved
    | fail s!"runtime path has no installed-runtime location: {resolved}"
  unless location.versionsRoot == versionsRoot do
    fail s!"refusing to prune runtime outside versions root: {resolved}"
  match ← resolveRuntimeHome resolved with
  | .installed _ => pure ()
  | .source _ =>
      fail s!"refusing to prune unmarked runtime directory: {resolved}"
  | .invalidInstalled runtime =>
      match runtime.error with
      | .missingManifest =>
          fail s!"refusing to prune unmarked runtime directory: {resolved}"
      | .invalidManifest _ =>
          fail s!"refusing to prune runtime with invalid manifest: {resolved / "manifest.json"}"
      | .mismatchedPayload _ =>
          fail <| s!"refusing to prune runtime with mismatched manifest payloadHash: {resolved}"
      | .invalidInstallRootMarker _ =>
          fail <| s!"refusing to prune runtime under an invalid Beam install root: {resolved}"

private def resolveInstallPruneContext (home : System.FilePath) : IO InstallPruneContext := do
  let home ← Beam.resolveExistingPath home
  let some location := installedRuntimeLocation? home
    | fail s!"prune is only available from an installed Beam runtime: {home}"
  pure {
    home
    installRoot := location.installRoot
    versionsRoot := location.versionsRoot
    bundleRoot := location.installRoot / "state" / installBundlesDirName
  }

private def validateInstallPruneContext (ctx : InstallPruneContext) : IO Unit := do
  let home := ctx.home
  let installRoot := ctx.installRoot
  requireOwnedInstallRoot installRoot
  let currentPath := installRoot / "current"
  unless ← currentPath.pathExists do
    fail s!"missing current Beam runtime link: {currentPath}"
  let current ← Beam.resolveExistingPath currentPath
  unless current.toString == home.toString do
    fail <| String.intercalate "\n" [
      s!"refusing to prune from a non-current Beam runtime: {home}",
      s!"current Beam runtime: {current}",
      "rerun prune through the installed `lean-beam` command"
    ]
  validatedRuntimePayload ctx.versionsRoot home

private def oldRuntimePaths (ctx : InstallPruneContext) : IO (Array System.FilePath) := do
  let entries := (← ctx.versionsRoot.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut paths := #[]
  for entry in entries do
    unless ← entry.path.isDir do
      fail s!"refusing to prune unexpected non-directory in versions root: {entry.path}"
    let resolved ← Beam.resolveExistingPath entry.path
    validatedRuntimePayload ctx.versionsRoot entry.path
    if resolved.toString != ctx.home.toString then
      paths := paths.push resolved
  pure paths

private def isDecimalName (path : System.FilePath) : Bool :=
  match path.fileName with
  | some name => !name.isEmpty && name.toList.all Char.isDigit
  | none => false

private def staleBundlePath? (bundleRoot : System.FilePath) (currentSourceHash : String)
    (path : System.FilePath) : IO Bool := do
  unless ← path.isDir do
    return false
  unless isDecimalName path do
    return false
  let resolved ← Beam.resolveExistingPath path
  unless resolved.toString == path.toString do
    return false
  let some platformRoot := resolved.parent
    | return false
  let some resolvedBundleRoot := platformRoot.parent
    | return false
  unless resolvedBundleRoot.toString == bundleRoot.toString do
    return false
  return (← completeBundleSourceHash? resolved) != some currentSourceHash

private def staleBundlePaths (ctx : InstallPruneContext) : IO (Array System.FilePath) := do
  unless ← ctx.bundleRoot.pathExists do
    return #[]
  let bundleRoot ← Beam.resolveExistingPath ctx.bundleRoot
  unless bundleRoot.toString == ctx.bundleRoot.toString do
    fail s!"refusing to prune symlinked installed bundle cache root: {ctx.bundleRoot}"
  let currentSourceHash ← sourceHash ctx.home
  let platforms := (← bundleRoot.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut paths := #[]
  for platform in platforms do
    if ← platform.path.isDir then
      let entries := (← platform.path.readDir).qsort (fun a b => a.fileName < b.fileName)
      for entry in entries do
        if ← staleBundlePath? bundleRoot currentSourceHash entry.path then
          paths := paths.push (← Beam.resolveExistingPath entry.path)
  pure paths

private def installPrunePlan (ctx : InstallPruneContext)
    (opts : InstallPruneOptions) : IO InstallPrunePlan := do
  let oldRuntimes ← oldRuntimePaths ctx
  let staleBundles ← if opts.bundles then staleBundlePaths ctx else pure #[]
  pure { oldRuntimes, staleBundles }

private def printInstallPrunePlan (ctx : InstallPruneContext)
    (opts : InstallPruneOptions) (plan : InstallPrunePlan) : IO Unit := do
  IO.println s!"Beam install prune ({if opts.apply then "apply" else "dry run"})"
  IO.println s!"install root: {ctx.installRoot}"
  IO.println s!"current runtime: {ctx.home}"
  for path in plan.oldRuntimes do
    IO.println s!"old runtime: {path}"
  for path in plan.staleBundles do
    IO.println s!"stale bundle: {path}"
  IO.println s!"old runtimes: {plan.oldRuntimes.size}"
  if opts.bundles then
    IO.println s!"stale bundles: {plan.staleBundles.size}"
  if !opts.apply && (!plan.oldRuntimes.isEmpty || !plan.staleBundles.isEmpty) then
    let bundleArg := if opts.bundles then " --bundles" else ""
    IO.println "restart active agents and MCP clients before applying this cleanup"
    IO.println s!"dry run only; rerun `lean-beam prune --apply{bundleArg}` to remove these paths"

private def removeOldRuntime (ctx : InstallPruneContext) (path : System.FilePath) : IO Bool := do
  if !(← path.pathExists) then
    return false
  let resolved ← Beam.resolveExistingPath path
  if resolved.toString == ctx.home.toString then
    fail s!"refusing to prune current Beam runtime: {resolved}"
  validatedRuntimePayload ctx.versionsRoot resolved
  IO.FS.removeDirAll resolved
  pure true

private def removeStaleBundle (ctx : InstallPruneContext)
    (currentSourceHash : String) (path : System.FilePath) : IO Bool := do
  if !(← path.pathExists) then
    return false
  let some platformRoot := path.parent
    | fail s!"stale bundle path has no platform root: {path}"
  let some bundleId := path.fileName
    | fail s!"stale bundle path has no bundle id: {path}"
  withLockTimeout (bundleBuildLockPath platformRoot bundleId) 1000 do
    if ← staleBundlePath? ctx.bundleRoot currentSourceHash path then
      IO.FS.removeDirAll path
      pure true
    else
      pure false

private def applyInstallPrune (ctx : InstallPruneContext)
    (opts : InstallPruneOptions) (plan : InstallPrunePlan) : IO (Nat × Nat) := do
  let mut runtimesRemoved := 0
  for path in plan.oldRuntimes do
    if ← removeOldRuntime ctx path then
      runtimesRemoved := runtimesRemoved + 1
      IO.println s!"removed runtime: {path}"
  let mut bundlesRemoved := 0
  if opts.bundles then
    let currentSourceHash ← sourceHash ctx.home
    for path in plan.staleBundles do
      if ← removeStaleBundle ctx currentSourceHash path then
        bundlesRemoved := bundlesRemoved + 1
        IO.println s!"removed stale bundle: {path}"
  pure (runtimesRemoved, bundlesRemoved)

def runInstallPrune (home : System.FilePath) (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| parseInstallPruneOptions args
  if opts.help then
    IO.println installPruneHelp
    return
  let ctx ← resolveInstallPruneContext home
  withInstallLockTimeout (ctx.installRoot / ".install-lock") 1000 do
    validateInstallPruneContext ctx
    let plan ← installPrunePlan ctx opts
    printInstallPrunePlan ctx opts plan
    if opts.apply then
      try
        let (runtimesRemoved, bundlesRemoved) ← applyInstallPrune ctx opts plan
        IO.println s!"removed runtimes: {runtimesRemoved}"
        if opts.bundles then
          IO.println s!"removed stale bundles: {bundlesRemoved}"
      catch e =>
        IO.eprintln <|
          "prune stopped before completing the displayed plan; any removals reported above were applied"
        let bundleArg := if opts.bundles then " --bundles" else ""
        IO.eprintln s!"rerun `lean-beam prune{bundleArg}` to preview the remaining paths"
        throw e

end Beam.Cli
