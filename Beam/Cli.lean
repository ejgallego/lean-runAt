/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Transport
import RunAt.Lib.NativeLib
import RunAt.Protocol
import Std.Internal.UV.Signal

open Lean

namespace Beam.Cli

open Beam.Broker

private structure BundlePaths where
  daemon : System.FilePath
  client : System.FilePath
  plugin : System.FilePath
  deriving Repr

private structure BundleMetadata where
  toolchain : String
  sourceHash : String
  workspace : String
  builtAt : String
  deriving FromJson, ToJson

private structure InstallLayout where
  rootFiles : List String
  sourceDirs : List String
  runtimePaths : List String
  wrapperPaths : List String
  sourceHashInputs : List String
  deriving ToJson

private structure RegistryEntry where
  daemonId : String
  pid : Nat
  transport : String := "unix"
  port? : Option Nat := none
  socket? : Option String := none
  root : String
  configHash : String
  leanCmd? : Option String := none
  plugin? : Option String := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  clientBin? : Option String := none
  daemonBin? : Option String := none
  bundleId? : Option String := none
  startedAt : String
  requestedPort? : Option Nat := none
  deriving FromJson, ToJson

private structure DesiredConfig where
  root : System.FilePath
  leanCmd? : Option String := none
  plugin? : Option System.FilePath := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  daemonBin : System.FilePath
  clientBin : System.FilePath
  bundleId : String
  configHash : String
  deriving Repr

private structure CliOptions where
  explicitRoot? : Option System.FilePath := none
  requestedPort? : Option UInt16 := none
  requestedSocket? : Option System.FilePath := none
  args : List String := []

private structure ParsedTextArg where
  text? : Option String := none
  source : String := "argv"

private def parseNatArg (name value : String) : IO Nat := do
  let some n := value.toNat?
    | throw <| IO.userError s!"invalid {name} '{value}'"
  pure n

private def joinTextArgs (args : List String) : Option String :=
  if args.isEmpty then none else some <| String.intercalate " " args

private def hasSubstring (text needle : String) : Bool :=
  match text.splitOn needle with
  | [_] => false
  | _ => true

private def textArgUsage (cmdHead : String) : String :=
  s!"usage: beam [--root PATH] [--socket PATH | --port N] {cmdHead} [--stdin | --text-file <path> | -- <text...> | <text...>]"

private def textArgReadsStdin (args : List String) : Bool :=
  match args with
  | ["--stdin"] => true
  | _ => false

private def parseTextArg (cmdHead : String) (args : List String) : IO ParsedTextArg := do
  match args with
  | [] => pure {}
  | ["--stdin"] =>
      pure { text? := some (← (← IO.getStdin).readToEnd), source := "stdin" }
  | ["--text-file", path] =>
      pure { text? := some (← IO.FS.readFile (System.FilePath.mk path)), source := s!"text-file:{path}" }
  | "--" :: rest =>
      pure { text? := joinTextArgs rest, source := "argv" }
  | "--stdin" :: _ =>
      throw <| IO.userError (textArgUsage cmdHead)
  | "--text-file" :: _ =>
      throw <| IO.userError (textArgUsage cmdHead)
  | _ =>
      pure { text? := joinTextArgs args, source := "argv" }

private def parseJsonText (label text : String) : IO Json := do
  match Json.parse text with
  | .ok json => pure json
  | .error err => throw <| IO.userError s!"invalid {label}: {err}"

private def parseJsonArg (label arg : String) : IO Json := do
  let raw ←
    if arg == "-" then
      (← IO.getStdin).readToEnd
    else
      pure arg
  parseJsonText label raw

private def handleArgUsage (cmdHead : String) : String :=
  s!"usage: beam [--root PATH] [--socket PATH | --port N] {cmdHead} <handle-json|-|--handle-file <path>>"

private def handleArgReadsStdin (args : List String) : Bool :=
  match args with
  | "-" :: _ => true
  | _ => false

private def extractHandleJson (json : Json) : Json :=
  match json.getObjVal? "handle" with
  | .ok handle => handle
  | .error _ =>
      match json.getObjVal? "result" with
      | .ok result =>
          match result.getObjVal? "handle" with
          | .ok handle => handle
          | .error _ => json
      | .error _ => json

private def parseHandleText (raw : String) : IO Handle := do
  let json ← parseJsonText "handle json" raw
  match fromJson? (extractHandleJson json) with
  | .ok handle => pure handle
  | .error err =>
      throw <| IO.userError s!"invalid handle payload: {err}"

private def parseHandleArg (arg : String) : IO Handle := do
  let raw ←
    if arg == "-" then
      (← IO.getStdin).readToEnd
    else
      pure arg
  parseHandleText raw

private def parseHandleInput (cmdHead : String) (args : List String) : IO (Handle × List String) := do
  match args with
  | [] =>
      throw <| IO.userError (handleArgUsage cmdHead)
  | "--handle-file" :: path :: rest =>
      pure ((← parseHandleText (← IO.FS.readFile (System.FilePath.mk path))), rest)
  | "--handle-file" :: _ =>
      throw <| IO.userError (handleArgUsage cmdHead)
  | arg :: rest =>
      pure ((← parseHandleArg arg), rest)

private def parseLeanSyncArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-sync <path> [+full]"

private def parseLeanRefreshArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-refresh <path> [+full]"

private def parseLeanSaveArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-save <path> [+full]"

private def parseLeanCloseSaveArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-close-save <path> [+full]"

private def shellQuote (text : String) : String :=
  "'" ++ text.replace "'" "'\\''" ++ "'"

private def trimLine (text : String) : String :=
  text.trimAscii.toString

private def readCmdTrim (cmd : String) (args : Array String := #[]) (cwd? : Option System.FilePath := none) : IO String := do
  let out ← IO.Process.output {
    cmd
    args
    cwd := cwd?.map (·.toString)
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"command failed: {cmd} {String.intercalate " " args.toList}\n{out.stderr}"
  pure <| trimLine out.stdout

private def commandAvailable (cmd : String) (args : Array String := #["--help"]) : IO Bool := do
  try
    let child ← IO.Process.spawn {
      cmd := cmd
      args := args
      stdin := .null
      stdout := .null
      stderr := .null
    }
    if (← child.tryWait).isNone then
      try
        child.kill
      catch _ =>
        pure ()
      try
        discard <| child.wait
      catch _ =>
        pure ()
    pure true
  catch _ =>
    pure false

private partial def climbParents (path : System.FilePath) (count : Nat) : System.FilePath :=
  match count with
  | 0 => path
  | n + 1 => climbParents (path.parent.getD path) n

private def runAtHome : IO System.FilePath := do
  match ← IO.getEnv "BEAM_HOME" with
  | some root =>
      IO.FS.realPath <| System.FilePath.mk root
  | none =>
      let app ← IO.appPath
      IO.FS.realPath <| climbParents app 4

private def defaultBundlePaths (home : System.FilePath) : IO BundlePaths := do
  let installedDaemon := home / "libexec" / "beam-daemon"
  let installedClient := home / "libexec" / "beam-client"
  let installedPlugin := RunAt.Lib.pluginSharedLibPath (home / "libexec")
  let checkoutDaemon := home / ".lake" / "build" / "bin" / "beam-daemon"
  let checkoutClient := home / ".lake" / "build" / "bin" / "beam-client"
  let checkoutPlugin := RunAt.Lib.pluginSharedLibPath (home / ".lake" / "build" / "lib")
  let installedReady :=
    (← installedDaemon.pathExists) &&
    (← installedClient.pathExists) &&
    (← installedPlugin.pathExists)
  pure <|
    if installedReady then
      {
        daemon := installedDaemon
        client := installedClient
        plugin := installedPlugin
      }
    else
      {
        daemon := checkoutDaemon
        client := checkoutClient
        plugin := checkoutPlugin
      }

private def ensurePathExists (kind : String) (path : System.FilePath) : IO Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"missing {kind} at {path}"

private def ensureBundleExists (paths : BundlePaths) : IO Unit := do
  ensurePathExists "CLI client" paths.client
  ensurePathExists "Beam daemon" paths.daemon

private def ensureLeanBundleExists (paths : BundlePaths) : IO Unit := do
  ensureBundleExists paths
  ensurePathExists "runAt plugin" paths.plugin

private def userHome : IO System.FilePath := do
  match ← IO.getEnv "HOME" with
  | some path => pure <| System.FilePath.mk path
  | none => throw <| IO.userError "missing HOME in environment"

private def runAtStateDirName : String :=
  ".beam"

private def installBundlesDirName : String :=
  "install-bundles"

private def runtimeBundlesDirName : String :=
  "bundles"

private def runAtStateDir (root : System.FilePath) : System.FilePath :=
  root / runAtStateDirName

private def skillInstallBundleCacheRoot (agentHome : System.FilePath) : System.FilePath :=
  agentHome / "skills" / "lean-beam" / runAtStateDirName / installBundlesDirName

private def defaultEnvPath (name : String) (fallback : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv name with
  | some path => pure <| System.FilePath.mk path
  | none => pure fallback

private def installBundleCacheRoots : IO (List System.FilePath) := do
  match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
  | some path => pure [System.FilePath.mk path]
  | none =>
      let home ← userHome
      let codexHome ← defaultEnvPath "CODEX_HOME" (home / ".codex")
      let claudeHome ← defaultEnvPath "CLAUDE_HOME" (home / ".claude")
      pure [
        skillInstallBundleCacheRoot codexHome,
        skillInstallBundleCacheRoot claudeHome
      ]

private def runtimeBundleCacheRoot (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_BUNDLE_DIR" with
  | some path => pure (System.FilePath.mk path)
  | none => pure (runAtStateDir root / runtimeBundlesDirName)

private def supportedLeanToolchainsPath (home : System.FilePath) : System.FilePath :=
  home / "supported-lean-toolchains"

private def nonCommentLines (text : String) : List String :=
  (text.splitOn "\n").filterMap fun raw =>
    let line := trimLine raw
    if line.isEmpty || line.startsWith "#" then none else some line

private def supportedLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := supportedLeanToolchainsPath home
  unless ← path.pathExists do
    throw <| IO.userError s!"missing supported Lean toolchain registry at {path}"
  pure (path, nonCommentLines (← IO.FS.readFile path))

private def ensureSupportedLeanToolchain (home : System.FilePath) (toolchain : String) : IO Unit := do
  let (path, toolchains) ← supportedLeanToolchains home
  unless toolchains.elem toolchain do
    throw <| IO.userError <| String.intercalate "\n" [
      s!"unsupported Lean toolchain: {toolchain}",
      s!"supported toolchain registry: {path}",
      "run `lean-beam supported-toolchains` to list the validated toolchains"
    ]

private def boolText (value : Bool) : String :=
  if value then "true" else "false"

private def parseEnvFlag (raw : String) : Bool :=
  let normalized := raw.trimAscii.toString.toLower
  !(normalized.isEmpty || normalized == "0" || normalized == "false" || normalized == "no")

private def envFlag? (name : String) : IO (Option Bool) := do
  match ← IO.getEnv name with
  | some raw => pure <| some (parseEnvFlag raw)
  | none => pure none

private def hexDigit (n : Nat) : Char :=
  if n < 10 then
    Char.ofNat (48 + n)
  else
    Char.ofNat (87 + n)

private def hexByte (byte : UInt8) : String :=
  let n := byte.toNat
  String.singleton (hexDigit (n / 16)) ++ String.singleton (hexDigit (n % 16))

private def utf8Hex (bytes : ByteArray) : String :=
  String.intercalate " " <| Id.run do
    let mut parts : Array String := #[]
    for byte in bytes do
      parts := parts.push (hexByte byte)
    return parts.toList

private def bundleWorkspaceFor (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "workspace"

private def bundlePathsFor (workspace : System.FilePath) : BundlePaths :=
  {
    daemon := workspace / ".lake" / "build" / "bin" / "beam-daemon"
    client := workspace / ".lake" / "build" / "bin" / "beam-client"
    plugin := RunAt.Lib.pluginSharedLibPath (workspace / ".lake" / "build" / "lib")
  }

private def bundleArtifactsReady (workspace : System.FilePath) : IO Bool := do
  let paths := bundlePathsFor workspace
  return (← paths.daemon.pathExists) && (← paths.client.pathExists) && (← paths.plugin.pathExists)

private def bundlePlatform : IO String := do
  let system := ← readCmdTrim "uname" #["-s"]
  let machine := ← readCmdTrim "uname" #["-m"]
  pure s!"{system.toLower}-{machine.toLower}"

private def hashByte (acc : UInt64) (byte : UInt8) : UInt64 :=
  (acc ^^^ byte.toUInt64) * 1099511628211

private def hashBytes (bytes : ByteArray) (init : UInt64 := 14695981039346656037) : UInt64 :=
  bytes.foldl hashByte init

private def hashString (text : String) (init : UInt64 := 14695981039346656037) : UInt64 :=
  hashBytes text.toUTF8 init

private def mixField (acc : UInt64) (text : String) : UInt64 :=
  hashString text <| hashByte acc 0

private def bundleRootFiles : List String :=
  ["RunAt.lean", "Beam.lean", "lakefile.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain",
    "supported-lean-toolchains"]

private def bundleSourceDirs : List String :=
  ["RunAt", "Beam", "ffi"]

private def bundleSourceHashInputLabels : List String :=
  bundleRootFiles ++ bundleSourceDirs.map (· ++ "/**")

private def installRuntimePaths : List String :=
  ["libexec/beam-cli", "libexec/beam-daemon", "libexec/beam-client",
    s!"libexec/{RunAt.Lib.pluginSharedLibName}", ".lake/packages"]

private def installWrapperPaths : List String :=
  ["bin/lean-beam", "bin/lean-beam-search"]

private def installLayout : InstallLayout :=
  {
    rootFiles := bundleRootFiles
    sourceDirs := bundleSourceDirs
    runtimePaths := installRuntimePaths
    wrapperPaths := installWrapperPaths
    sourceHashInputs := bundleSourceHashInputLabels
  }

private def installManifestJson (payloadHash : String) (sourceCommit? : Option String) (toolchains : List String) :
    Json :=
  Json.mkObj [
    ("schemaVersion", toJson (2 : Nat)),
    ("payloadHash", toJson payloadHash),
    ("toolchains", toJson toolchains),
    ("sourceCommit", sourceCommit?.map toJson |>.getD Json.null),
    ("artifacts", toJson installLayout)
  ]

private partial def collectTreeFiles (current : System.FilePath) : IO (Array System.FilePath) := do
  let entries := (← current.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut files := #[]
  for entry in entries do
    if ← entry.path.isDir then
      files := files ++ (← collectTreeFiles entry.path)
    else
      files := files.push entry.path
  pure files

private def relativePathString (root path : System.FilePath) : String :=
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  if pathStr.startsWith rootPrefix then
    (pathStr.drop rootPrefix.length).toString
  else
    pathStr

private def sortedPaths (paths : Array System.FilePath) : Array System.FilePath :=
  paths.qsort (fun a b => a.toString < b.toString)

private def collectBundleSourceFiles (root : System.FilePath) : IO (Array System.FilePath) := do
  let mut files := #[]
  for name in bundleRootFiles do
    let path := root / name
    if ← path.pathExists then
      files := files.push path
  for dirName in bundleSourceDirs do
    let dir := root / dirName
    if ← dir.pathExists then
      files := files ++ (← collectTreeFiles dir)
  pure <| sortedPaths files

private def mixFileHash (acc : UInt64) (root path : System.FilePath) : IO UInt64 := do
  let rel := relativePathString root path
  let acc := mixField acc rel
  let bytes ← IO.FS.readBinFile path
  pure <| hashBytes bytes <| hashByte acc 0

private def sourceHash (home : System.FilePath) : IO String := do
  let root ← IO.FS.realPath home
  let files ← collectBundleSourceFiles root
  let mut acc : UInt64 := 14695981039346656037
  for path in files do
    acc ← mixFileHash acc root path
  pure s!"{acc.toNat}"

private def bundleIdFor (toolchain source platformKey : String) : String :=
  s!"{mixField (mixField (mixField 14695981039346656037 toolchain) source) platformKey |>.toNat}"

private def bundleDirFor (cacheRoot home : System.FilePath) (toolchain : String) : IO (System.FilePath × String × String) := do
  let platformKey ← bundlePlatform
  let srcHash ← sourceHash home
  let bundleId := bundleIdFor toolchain srcHash platformKey
  pure (cacheRoot / platformKey / bundleId, bundleId, srcHash)

private def copyFileInto (srcRoot dstRoot srcPath : System.FilePath) : IO Unit := do
  let rel := relativePathString srcRoot srcPath
  let dst := dstRoot / rel
  if let some parent := dst.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile dst (← IO.FS.readBinFile srcPath)

private def copyTreeInto (srcRoot dstRoot : System.FilePath) : IO Unit := do
  let files ← collectTreeFiles srcRoot
  for path in files do
    copyFileInto srcRoot dstRoot path

private def syncBundleWorkspace (home workspace : System.FilePath) : IO Unit := do
  if ← workspace.pathExists then
    IO.FS.removeDirAll workspace
  IO.FS.createDirAll workspace
  let files ← collectBundleSourceFiles home
  for path in files do
    copyFileInto home workspace path
  let packagesDir := home / ".lake" / "packages"
  if ← packagesDir.pathExists then
    copyTreeInto packagesDir (workspace / ".lake" / "packages")

private def utcTimestamp : IO String := do
  readCmdTrim "date" #["-u", "+%Y-%m-%dT%H:%M:%SZ"]

private def writeBundleMetadata (bundleDir : System.FilePath) (toolchain srcHash : String) (workspace : System.FilePath) : IO Unit := do
  let metadata : BundleMetadata := {
    toolchain
    sourceHash := srcHash
    workspace := workspace.toString
    builtAt := ← utcTimestamp
  }
  let path := bundleDir / "metadata.json"
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path ((toJson metadata).pretty ++ "\n")

private def ensureElan : IO Unit := do
  unless ← commandAvailable "elan" do
    throw <| IO.userError "missing elan on PATH"

private def fallbackBuildFailureMessage (toolchain : String) (cacheRoot bundleDir : System.FilePath)
    (stderr : String) : String :=
  String.intercalate "\n" [
    s!"failed to build local beam fallback bundle for toolchain {toolchain}",
    s!"install bundle cache did not provide a matching bundle; attempted local fallback under {cacheRoot}",
    s!"bundle workspace: {bundleWorkspaceFor bundleDir}",
    "this fallback path runs `lake build` and may need network access on a cold machine if dependencies have not been fetched yet",
    "if you want to avoid that at runtime, prebuild the installed skill bundle for the supported toolchain first",
    "",
    "lake stderr:",
    stderr
  ]

private def killCommand : IO String := do
  let candidates := [System.FilePath.mk "/bin/kill", System.FilePath.mk "/usr/bin/kill"]
  for candidate in candidates do
    if ← candidate.pathExists then
      return candidate.toString
  if ← commandAvailable "kill" #["-l"] then
    pure "kill"
  else
    throw <| IO.userError "could not find kill command"

private def pidAlive (pid : Nat) : IO Bool := do
  let out ← IO.Process.output { cmd := (← killCommand), args := #["-0", toString pid] }
  pure (out.exitCode == 0)

private partial def acquireLock (lockDir : System.FilePath) : IO Unit := do
  if let some parent := lockDir.parent then
    IO.FS.createDirAll parent
  let selfPid ← IO.Process.getPID
  try
    IO.FS.createDir lockDir
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
  catch _ =>
    let stalePid? ←
      if ← (lockDir / "pid").pathExists then
        let text ← IO.FS.readFile (lockDir / "pid")
        pure <| trimLine text |>.toNat?
      else
        pure none
    if let some stalePid := stalePid? then
      if !(← pidAlive stalePid) then
        if ← lockDir.pathExists then
          IO.FS.removeDirAll lockDir
    IO.sleep 100
    acquireLock lockDir

private def releaseLock (lockDir : System.FilePath) : IO Unit := do
  if ← lockDir.pathExists then
    IO.FS.removeDirAll lockDir

private def withLock (lockDir : System.FilePath) (act : IO α) : IO α := do
  acquireLock lockDir
  try
    act
  finally
    releaseLock lockDir

private def buildToolchainBundle (home : System.FilePath) (toolchain srcHash : String)
    (cacheRoot bundleDir workspace : System.FilePath) : IO Unit := do
  ensureElan
  syncBundleWorkspace home workspace
  IO.eprintln s!"building beam bundle for {toolchain}"
  let out ← IO.Process.output {
    cmd := "elan"
    args := #["run", toolchain, "lake", "build", "RunAt:shared", "beam-daemon", "beam-client"]
    cwd := workspace.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| fallbackBuildFailureMessage toolchain cacheRoot bundleDir out.stderr
  writeBundleMetadata bundleDir toolchain srcHash workspace

private def existingToolchainBundle? (cacheRoot home : System.FilePath) (toolchain : String) : IO (Option (BundlePaths × String)) := do
  let (bundleDir, bundleId, _) ← bundleDirFor cacheRoot home toolchain
  let workspace := bundleWorkspaceFor bundleDir
  if ← bundleArtifactsReady workspace then
    pure <| some (bundlePathsFor workspace, bundleId)
  else
    pure none

private partial def existingToolchainBundleInAny? (cacheRoots : List System.FilePath) (home : System.FilePath)
    (toolchain : String) : IO (Option (BundlePaths × String)) := do
  match cacheRoots with
  | [] => pure none
  | cacheRoot :: rest =>
      match ← existingToolchainBundle? cacheRoot home toolchain with
      | some bundle => pure <| some bundle
      | none => existingToolchainBundleInAny? rest home toolchain

private def ensureToolchainBundleIn (cacheRoot home : System.FilePath) (toolchain : String) : IO (BundlePaths × String) := do
  ensureSupportedLeanToolchain home toolchain
  let (bundleDir, bundleId, srcHash) ← bundleDirFor cacheRoot home toolchain
  let workspace := bundleWorkspaceFor bundleDir
  withLock (bundleDir / "lock") do
    unless ← bundleArtifactsReady workspace do
      buildToolchainBundle home toolchain srcHash cacheRoot bundleDir workspace
  pure (bundlePathsFor workspace, bundleId)

private def ensureToolchainBundle (root home : System.FilePath) (toolchain : String) : IO (BundlePaths × String) := do
  ensureSupportedLeanToolchain home toolchain
  match ← existingToolchainBundleInAny? (← installBundleCacheRoots) home toolchain with
  | some bundle => pure bundle
  | none =>
      let cacheRoot ← runtimeBundleCacheRoot root
      ensureToolchainBundleIn cacheRoot home toolchain

private def ensureDefaultDaemonHelpers (home : System.FilePath) : IO BundlePaths := do
  let paths ← defaultBundlePaths home
  if (← paths.daemon.pathExists) && (← paths.client.pathExists) then
    pure paths
  else
    let out ← IO.Process.output {
      cmd := "lake"
      args := #["build", "beam-daemon", "beam-client"]
      cwd := home.toString
    }
    if out.exitCode != 0 then
      throw <| IO.userError s!"failed to build default Beam daemon helpers\n{out.stderr}"
    ensureBundleExists paths
    pure paths

private def predictedToolchainBundle (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (BundlePaths × String) := do
  let (bundleDir, bundleId, _) ← bundleDirFor cacheRoot home toolchain
  pure (bundlePathsFor (bundleWorkspaceFor bundleDir), bundleId)

private def hasLeanProject (root : System.FilePath) : IO Bool := do
  return (← (root / "lean-toolchain").pathExists) ||
    (← (root / "lakefile.toml").pathExists) ||
    (← (root / "lakefile.lean").pathExists)

private def hasRocqProject (root : System.FilePath) : IO Bool := do
  return (← (root / "_RocqProject").pathExists) ||
    (← (root / "_CoqProject").pathExists)

private partial def findRootUpwards (start : System.FilePath) (backend : Backend) : IO (Option System.FilePath) := do
  let dir ← IO.FS.realPath start
  let rec loop (dir : System.FilePath) : IO (Option System.FilePath) := do
    let found ←
      match backend with
      | .lean => hasLeanProject dir
      | .rocq => hasRocqProject dir
    if found then
      pure (some dir)
    else if dir == System.FilePath.mk "/" then
      pure none
    else
      loop (dir.parent.getD dir)
  loop dir

private def projectRoot (opts : CliOptions) (backend : Backend) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none =>
      match ← findRootUpwards (System.FilePath.mk ".") backend with
      | some root => pure root
      | none =>
          let backendName := match backend with | .lean => "lean" | .rocq => "rocq"
          throw <| IO.userError s!"could not infer {backendName} project root; use --root PATH"

private def projectRootAny (opts : CliOptions) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none =>
      if let some root ← findRootUpwards (System.FilePath.mk ".") .lean then
        pure root
      else if let some root ← findRootUpwards (System.FilePath.mk ".") .rocq then
        pure root
      else
        throw <| IO.userError "could not infer project root; use --root PATH"

private def controlDir (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_CONTROL_DIR" with
  | some dir =>
      let tag := toString (hash root.toString)
      pure (System.FilePath.mk dir / tag)
  | none =>
      pure (runAtStateDir root)

private def registryPath (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "beam-daemon.json")

private def leanToolchain (root : System.FilePath) : IO String := do
  let path := root / "lean-toolchain"
  unless ← path.pathExists do
    throw <| IO.userError s!"missing lean-toolchain in {root}"
  pure <| trimLine (← IO.FS.readFile path)

private def leanBin (root : System.FilePath) : IO String := do
  readCmdTrim "elan" #["which", "lean"] (some root)

private def rocqCandidates (root : System.FilePath) : List System.FilePath :=
  [root / "_opam" / "bin" / "coq-lsp", root / "_opam" / "_opam" / "bin" / "coq-lsp"]

private def maybeRocqCmd (root : System.FilePath) : IO (Option String) := do
  for candidate in rocqCandidates root do
    if ← candidate.pathExists then
      return some candidate.toString
  match ← IO.getEnv "BEAM_ROCQ_CMD" with
  | some cmd => pure (some cmd)
  | none =>
      if ← commandAvailable "coq-lsp" then
        pure (some "coq-lsp")
      else
        pure none

private def rocqCmd (root : System.FilePath) : IO String := do
  match ← maybeRocqCmd root with
  | some cmd => pure cmd
  | none => throw <| IO.userError s!"could not find coq-lsp for {root}"

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

private def readRegistry? (root : System.FilePath) : IO (Option RegistryEntry) := do
  let path ← registryPath root
  unless ← path.pathExists do
    return none
  try
    let text ← IO.FS.readFile path
    let json ← IO.ofExcept <| Json.parse text
    let entry ← IO.ofExcept <| fromJson? json
    pure (some entry)
  catch _ =>
    pure none

private def removeRegistry (root : System.FilePath) : IO Unit := do
  let path ← registryPath root
  if ← path.pathExists then
    IO.FS.removeFile path

private def natToPort? (n : Nat) : Option UInt16 :=
  if n < UInt16.size then some n.toUInt16 else none

private def registryEndpoint? (entry : RegistryEntry) : Option Transport.Endpoint := do
  match entry.transport with
  | "tcp" => (natToPort? =<< entry.port?).map Transport.Endpoint.tcp
  | "unix" => entry.socket?.map (fun path => Transport.Endpoint.unix (System.FilePath.mk path))
  | _ => none

private def endpointFromEntry (entry : RegistryEntry) : IO Transport.Endpoint := do
  match registryEndpoint? entry with
  | some endpoint => pure endpoint
  | none => throw <| IO.userError s!"invalid Beam daemon transport data in registry for {entry.root}"

private def endpointSummary (endpoint : Transport.Endpoint) : String :=
  Transport.endpointDescription endpoint

private def daemonResponds (endpoint : Transport.Endpoint) : IO Bool := do
  try
    let resp ← sendRequest endpoint { op := .stats }
    pure resp.ok
  catch _ =>
    pure false

private def killPid (pid : Nat) : IO Unit := do
  try
    let _ ← IO.Process.output { cmd := (← killCommand), args := #[toString pid] }
    pure ()
  catch _ =>
    pure ()

private partial def waitForPidGone (pid : Nat) (tries : Nat := 20) : IO Unit := do
  if tries == 0 then
    pure ()
  else if ← pidAlive pid then
    IO.sleep 100
    waitForPidGone pid (tries - 1)
  else
    pure ()

private def stopDaemonEntry (entry : RegistryEntry) : IO Unit := do
  if let some endpoint := registryEndpoint? entry then
    if ← daemonResponds endpoint then
      try
        let _ ← sendRequest endpoint { op := .shutdown }
      catch _ =>
        pure ()
  if entry.pid > 0 && (← pidAlive entry.pid) then
    killPid entry.pid
    waitForPidGone entry.pid

private def stopRegisteredDaemon (root : System.FilePath) : IO Unit := do
  match ← readRegistry? root with
  | none =>
      removeRegistry root
  | some entry =>
      stopDaemonEntry entry
      removeRegistry root

private def requestedPortNat? (opts : CliOptions) : Option Nat :=
  opts.requestedPort?.map (·.toNat)

private def selectSocketPath (root : System.FilePath) (opts : CliOptions) : IO System.FilePath := do
  match opts.requestedSocket? with
  | some path => pure path
  | none => pure ((← controlDir root) / "beam-daemon.sock")

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
  match opts.requestedSocket? with
  | some socketPath => pure <| .unix socketPath
  | none => pure <| .tcp (← selectPort opts)

private def daemonStartupLogPath (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "beam-daemon-startup.log")

private def tailLines (text : String) (count : Nat := 20) : String :=
  let lines := text.splitOn "\n"
  let keep := min count lines.length
  String.intercalate "\n" <| lines.drop (lines.length - keep)

private def daemonFailureMessage (root : System.FilePath) (detail : String) : IO String := do
  let shouldAppend :=
    detail.contains "Beam daemon connection closed" ||
    detail.contains "no live Beam daemon registered for "
  if !shouldAppend then
    pure detail
  else
    let logPath ← daemonStartupLogPath root
    if ← logPath.pathExists then
      let logText := trimLine (← IO.FS.readFile logPath)
      if logText.isEmpty then
        pure detail
      else
        pure <| detail ++ s!"\nBeam daemon log tail ({logPath}):\n{tailLines logText}"
    else
      pure detail

private def startupFailureMessage (endpoint : Transport.Endpoint) (logPath : System.FilePath) (detail : String) : IO String := do
  let msg := if detail.isEmpty then
    s!"failed to start Beam daemon on {endpointSummary endpoint}"
  else
    s!"failed to start Beam daemon on {endpointSummary endpoint}\n{detail}"
  if ← logPath.pathExists then
    let logText := trimLine (← IO.FS.readFile logPath)
    if logText.isEmpty then
      pure msg
    else
      pure <| msg ++ s!"\nstartup log ({logPath}):\n{logText}"
  else
    pure msg

private def startDaemon (desired : DesiredConfig) (endpoint : Transport.Endpoint) (logPath : System.FilePath) : IO Nat := do
  let mut args : List String := ["--root", desired.root.toString]
  match endpoint with
  | .tcp port =>
      args := args ++ ["--port", toString port.toNat]
  | .unix socket =>
      args := args ++ ["--socket", socket.toString]
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
    cmd := "sh"
    args := #["-c", shell]
    cwd := some desired.root
    stdin := .null
    stdout := .null
    stderr := .null
  }
  let pid := child.pid.toNat
  pure pid

private partial def waitForDaemon (pid : Nat) (endpoint : Transport.Endpoint) (logPath : System.FilePath)
    (tries : Nat := 300) : IO Unit := do
  if ← daemonResponds endpoint then
    pure ()
  else if !(← pidAlive pid) then
    throw <| IO.userError (← startupFailureMessage endpoint logPath "Beam daemon process exited before responding")
  else if tries == 0 then
    throw <| IO.userError (← startupFailureMessage endpoint logPath "Beam daemon did not become ready before timeout")
  else
    IO.sleep 100
    waitForDaemon pid endpoint logPath (tries - 1)

private def registryEntryFor (desired : DesiredConfig) (pid : Nat) (endpoint : Transport.Endpoint) (opts : CliOptions) :
    IO RegistryEntry := do
  let (transport, port?, socket?) :=
    match endpoint with
    | .tcp port => ("tcp", some port.toNat, none)
    | .unix path => ("unix", none, some path.toString)
  pure {
    daemonId := s!"{desired.configHash.take 12}-{pid}"
    pid
    transport
    port?
    socket?
    root := desired.root.toString
    configHash := desired.configHash
    leanCmd? := desired.leanCmd?
    plugin? := desired.plugin?.map (·.toString)
    rocqCmd? := desired.rocqCmd?
    toolchain? := desired.toolchain?
    clientBin? := some desired.clientBin.toString
    daemonBin? := some desired.daemonBin.toString
    bundleId? := some desired.bundleId
    startedAt := ← utcTimestamp
    requestedPort? := requestedPortNat? opts
  }

private def startDaemonEntry (desired : DesiredConfig) (opts : CliOptions) : IO (Transport.Endpoint × RegistryEntry) := do
  let endpoint ← selectEndpoint opts
  let logPath ← daemonStartupLogPath desired.root
  let pid ← startDaemon desired endpoint logPath
  try
    waitForDaemon pid endpoint logPath
  catch err =>
    if pid > 0 && (← pidAlive pid) then
      killPid pid
      waitForPidGone pid
    throw err
  let entry ← registryEntryFor desired pid endpoint opts
  pure (endpoint, entry)

private def desiredConfig (home root : System.FilePath) (required : Backend) : IO DesiredConfig := do
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

private def registryLiveFor (root : System.FilePath) (expectedHash? : Option String := none) : IO (Option RegistryEntry) := do
  match ← readRegistry? root with
  | none => pure none
  | some entry =>
      let rootOk := entry.root == root.toString
      let hashOk := expectedHash?.map (· == entry.configHash) |>.getD true
      if !rootOk || !hashOk then
        pure none
      else if entry.pid == 0 || !(← pidAlive entry.pid) then
        pure none
      else if let some endpoint := registryEndpoint? entry then
        if !(← daemonResponds endpoint) then
          pure none
        else
          pure (some entry)
      else
        pure none

private def ensureProjectDaemon (home root : System.FilePath) (backend : Backend) (opts : CliOptions) :
    IO (Transport.Endpoint × DesiredConfig) := do
  let desired ← desiredConfig home root backend
  let lockDir ← controlDir root
  let lockDir := lockDir / "lock"
  withLock lockDir do
    if let some live ← registryLiveFor root desired.configHash then
      if let some endpoint := registryEndpoint? live then
        return (endpoint, desired)
      removeRegistry root
    let live? ← registryLiveFor root
    if live?.isNone then
      removeRegistry root
    let (endpoint, entry) ← startDaemonEntry desired opts
    writeRegistry root entry
    if let some live := live? then
      unless live.pid == entry.pid &&
          live.transport == entry.transport &&
          live.port? == entry.port? &&
          live.socket? == entry.socket? do
        stopDaemonEntry live
    pure (endpoint, desired)

private def lookupProjectDaemon (root : System.FilePath) : IO RegistryEntry := do
  let lockDir ← controlDir root
  let lockDir := lockDir / "lock"
  withLock lockDir do
    match ← registryLiveFor root with
    | some entry => pure entry
    | none =>
        stopRegisteredDaemon root
        throw <| IO.userError (← daemonFailureMessage root s!"no live Beam daemon registered for {root}")

private def printJsonLine (json : Json) : IO Unit := do
  IO.println json.pretty

private def envClientRequestId? : IO (Option String) := do
  match ← IO.getEnv "BEAM_REQUEST_ID" with
  | some raw =>
      let trimmed := raw.trimAscii.toString
      pure <| if trimmed.isEmpty then none else some trimmed
  | none =>
      pure none

private def withEnvClientRequestId (req : Request) : IO Request := do
  pure { req with clientRequestId? := req.clientRequestId? <|> (← envClientRequestId?) }

private def annotateRunatMessage (clientRequestId? : Option String) (msg : String) : String :=
  match clientRequestId? with
  | some clientRequestId =>
      if msg.startsWith "beam:" then
        s!"beam[{clientRequestId}]:" ++ (msg.drop 6).toString
      else
        s!"beam[{clientRequestId}]: {msg}"
  | none =>
      msg

private def debugTextEnabled : IO Bool := do
  pure <| (← envFlag? "BEAM_DEBUG_TEXT").getD false

private def maybeEmitTextDebug (clientRequestId? : Option String) (action source : String) (text? : Option String) : IO Unit := do
  if !(← debugTextEnabled) then
    pure ()
  else
    match text? with
    | none => pure ()
    | some text =>
        let bytes := text.toUTF8
        let containsLiteralBackslashN := hasSubstring text "\\n"
        IO.eprintln <| annotateRunatMessage clientRequestId?
          s!"beam: debug text for {action}: source={source} utf8Bytes={bytes.size} containsNewline={boolText (text.contains '\n')} containsLiteralBackslashN={boolText containsLiteralBackslashN}"
        IO.eprintln <| annotateRunatMessage clientRequestId?
          s!"beam: debug text escaped={(Json.str text).compress}"
        IO.eprintln <| annotateRunatMessage clientRequestId?
          s!"beam: debug text utf8Hex={utf8Hex bytes}"

private def decodeRunAtResult? (resp : Response) : Option RunAt.Result :=
  match resp.result? with
  | none => none
  | some result =>
      match fromJson? result with
      | .ok payload => some payload
      | .error _ => none

private def responseErrorSummary? (action failureBoundary : String) (resp : Response) : Option String :=
  resp.error?.map fun err =>
    s!"beam: {action} request failed {failureBoundary} ({err.code}): {err.message}"

private def runAtPayloadSummary? (action noun : String) (resp : Response) : Option String :=
  match decodeRunAtResult? resp with
  | some result =>
      if result.success then
        none
      else
        some s!"beam: {action} {noun} failed inside Lean; the request completed and returned result.success=false"
  | none =>
      none

private def maybeEmitLiteralBackslashNewlineHint (req : Request) (resp : Response) : IO Unit := do
  match req.op with
  | .runAt | .runWith =>
      match req.text?, decodeRunAtResult? resp with
      | some text, some result =>
          if !result.success && hasSubstring text "\\n" && !text.contains '\n' then
            IO.eprintln <| annotateRunatMessage req.clientRequestId?
              "beam: hint: the probe text contains the literal characters '\\n'; if you meant a real newline, use --stdin or --text-file."
          else
            pure ()
      | _, _ =>
          pure ()
  | _ =>
      pure ()

private def withBrokerErrorContext {α} (root : System.FilePath) (action : IO α) : IO α := do
  try
    action
  catch e =>
    throw <| IO.userError (← daemonFailureMessage root e.toString)

private def callBroker (root : System.FilePath) (endpoint : Transport.Endpoint) (req : Request) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId req
    let resp ← sendRequest endpoint req
    printResponse resp
    failOnError resp

private def callBrokerQuiet (root : System.FilePath) (endpoint : Transport.Endpoint) (req : Request) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId req
    let resp ← sendRequest endpoint req
    failOnError resp

private def decodeSyncFileResult? (resp : Response) : Option SyncFileResult := do
  let result ← resp.result?
  fromJson? result |>.toOption

private def responseFileProgress? (resp : Response) : Option SyncFileProgress :=
  resp.fileProgress?

private def syncFileProgressSuffix (progress? : Option SyncFileProgress) : String :=
  match progress? with
  | none => ""
  | some progress =>
      let doneSuffix :=
        if progress.done then
          ""
        else
          " done=false"
      s!", fp updates={progress.updates}{doneSuffix}"

private structure BrokerWaitSpec where
  action : String
  startMsg : String
  progressMsg : SyncFileProgress → String
  stillWaitingMsg : Nat → String
  completeMsg : Response → String
  failureBoundary : String := "before the request completed"
  responseNote? : Response → Option String := fun _ => none

private structure InterruptWatcher where
  signal : Std.Internal.UV.Signal
  task : Task (Except IO.Error Unit)

private def progressEnabled : IO Bool := do
  match ← envFlag? "BEAM_PROGRESS" with
  | some enabled =>
      pure enabled
  | none =>
      (← IO.getStderr).isTty

private def mkInterruptWatcher? (clientRequestId? : Option String) : IO (Option InterruptWatcher) := do
  match clientRequestId? with
  | none => pure none
  | some _ =>
      let signal ← Std.Internal.UV.Signal.mk 2 false
      let task ← IO.asTask do
        let promise ← Std.Internal.UV.Signal.next signal
        let some _ ← IO.wait promise.result?
          | throw <| IO.userError "SIGINT watcher promise dropped"
        pure ()
      pure <| some { signal, task }

private def awaitBrokerResponse
    (task : Task (Except IO.Error Response))
    (endpoint : Transport.Endpoint)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Response := do
  let req ← withEnvClientRequestId req
  let interruptWatcher? ← mkInterruptWatcher? req.clientRequestId?
  let mut cancelSent := false
  let emit := fun msg => IO.eprintln <| annotateRunatMessage req.clientRequestId? msg
  emit spec.startMsg
  let mut waitedMs := 0
  try
    while !(← IO.hasFinished task) do
      match interruptWatcher? with
      | some watcher =>
          if !cancelSent && (← IO.hasFinished watcher.task) then
            cancelSent := true
            emit "beam: requesting broker cancellation"
            let cancelReq : Request := {
              op := .cancel
              root? := req.root?
              cancelRequestId? := req.clientRequestId?
            }
            discard <| sendRequest endpoint (← withEnvClientRequestId cancelReq)
      | none =>
          pure ()
      IO.sleep 500
      if !(← IO.hasFinished task) then
        waitedMs := waitedMs + 500
        if waitedMs % 1000 == 0 then
          emit <| spec.stillWaitingMsg (waitedMs / 1000)
    let resp ←
      match (← IO.wait task) with
      | .ok resp => pure resp
      | .error err => throw err
    emit <| spec.completeMsg resp
    pure resp
  finally
    match interruptWatcher? with
    | some watcher => Std.Internal.UV.Signal.stop watcher.signal
    | none => pure ()

private def syncWaitSpec (path : String) : BrokerWaitSpec :=
  {
    action := "lean-sync"
    startMsg := s!"beam: syncing {path} and waiting for Lean diagnostics"
    progressMsg := fun progress => s!"beam: sync progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still syncing {path} ({seconds}s)"
    completeMsg := fun resp =>
      match decodeSyncFileResult? resp with
      | some result =>
          let suffix := syncFileProgressSuffix (responseFileProgress? resp)
          let readinessSuffix :=
            if result.saveReady then
              ""
            else
              s!", saveReady=false ({result.saveReadyReason}, " ++
              s!"stateErrorCount={result.stateErrorCount}, " ++
                s!"stateCommandErrorCount={result.stateCommandErrorCount})"
          s!"beam: sync complete for {path} (version {result.version}{suffix}{readinessSuffix})"
      | none =>
        s!"beam: sync complete for {path}"
    failureBoundary := "before a complete diagnostics barrier was available"
  }

private def refreshWaitSpec (path : String) : BrokerWaitSpec :=
  {
    action := "lean-refresh"
    startMsg := s!"beam: refreshing {path} by closing and resyncing"
    progressMsg := fun progress => s!"beam: refresh progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still refreshing {path} ({seconds}s)"
    completeMsg := fun resp =>
      match decodeSyncFileResult? resp with
      | some result =>
          let suffix := syncFileProgressSuffix (responseFileProgress? resp)
          let readinessSuffix :=
            if result.saveReady then
              ""
            else
              s!", saveReady=false ({result.saveReadyReason}, " ++
              s!"stateErrorCount={result.stateErrorCount}, " ++
                s!"stateCommandErrorCount={result.stateCommandErrorCount})"
          s!"beam: refresh complete for {path} (version {result.version}{suffix}{readinessSuffix})"
      | none =>
        s!"beam: refresh complete for {path}"
    failureBoundary := "before a complete diagnostics barrier was available"
  }

private def leanRunAtWaitSpec (action path : String) (line character : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: snapshot progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for a ready Lean snapshot for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before probe execution"
    responseNote? := runAtPayloadSummary? action "probe"
  }

private def leanHoverWaitSpec (path : String) (line character : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := "lean-hover"
    startMsg := s!"beam: running lean-hover on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: hover progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for lean-hover on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: lean-hover complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before hover data was available"
  }

private def leanGoalsWaitSpec (path : String) (line character : Nat) (mode : GoalMode) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  let action :=
    match mode with
    | .after => "lean-goals-after"
    | .prev => "lean-goals-prev"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: goals progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before goal inspection completed"
  }

private def leanRequestAtWaitSpec (path : String) (line character : Nat) (method : String) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := s!"lean-request-at {method}"
    startMsg := s!"beam: forwarding experimental {method} at {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: request-at progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for experimental {method} at {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: experimental {method} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := s!"before experimental {method} completed"
  }

private def leanRunWithWaitSpec (path : String) (linear : Bool := false) : BrokerWaitSpec :=
  let action := if linear then "lean-run-with-linear" else "lean-run-with"
  {
    action := action
    startMsg := s!"beam: running {action} on {path} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before speculative continuation completed"
    responseNote? := runAtPayloadSummary? action "continuation"
  }

private def leanSaveWaitSpec (path : String) (closeAfter : Bool := false) : BrokerWaitSpec :=
  let action := if closeAfter then "lean-close-save" else "lean-save"
  let verb := if closeAfter then "closing and saving" else "saving"
  {
    action := action
    startMsg := s!"beam: {verb} {path} and waiting for Lean diagnostics/artifacts"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp => s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before save artifacts were finalized"
  }

private def callBrokerWithProgress
    (root : System.FilePath)
    (endpoint : Transport.Endpoint)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId req
    let showProgress ← progressEnabled
    let callbacks : StreamCallbacks := {
      onFileProgress := fun clientRequestId? progress => do
        if showProgress then
          IO.eprintln <| annotateRunatMessage clientRequestId? (spec.progressMsg progress)
      onDiagnostic := fun clientRequestId? diagnostic =>
        IO.eprintln <| annotateRunatMessage clientRequestId? (formatStreamDiagnostic diagnostic)
    }
    let resp ←
      if showProgress then
        let task ← IO.asTask <| sendRequestWithCallbacks endpoint req callbacks
        awaitBrokerResponse task endpoint req spec
      else
        sendRequestWithCallbacks endpoint req callbacks
    match responseErrorSummary? spec.action spec.failureBoundary resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage req.clientRequestId? note
    | none =>
        pure ()
    match spec.responseNote? resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage req.clientRequestId? note
    | none =>
        pure ()
    maybeEmitLiteralBackslashNewlineHint req resp
    printResponse resp
    failOnError resp

private def usage : String :=
  String.intercalate "\n" [
    "usage:",
    "  beam [--root PATH] [--socket PATH | --port N] ensure lean|rocq",
    "  beam [--root PATH] cancel <request-id>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-at <path> <line> <character> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-at-handle <path> <line> <character> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-hover <path> <line> <character>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-goals-after <path> <line> <character>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-goals-prev <path> <line> <character>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-with <path> <handle-json|-|--handle-file <path>> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-with-linear <path> <handle-json|-|--handle-file <path>> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-release <path> <handle-json|-|--handle-file <path>>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-sync <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-refresh <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-save <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-close <path>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-close-save <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] rocq-goals-after <path> <line> <character> [text...]",
    "  beam [--root PATH] [--socket PATH | --port N] rocq-goals-prev <path> <line> <character> [text...]",
    "  beam bundle-install <toolchain>",
    "  beam supported-toolchains lean",
    "  beam [--root PATH] doctor lean|rocq",
    "  beam [--root PATH] open-files",
    "  beam [--root PATH] cancel <request-id>",
    "  beam [--root PATH] stats",
    "  beam [--root PATH] reset-stats",
    "  beam [--root PATH] shutdown",
    "  beam experimental",
    "",
    "Lean edit loop: save the file, then run lean-sync. lean-save is lean-sync plus a",
    "workspace-module checkpoint, lean-refresh is lean-close plus lean-sync, and lean-close-save",
    "adds closing the tracked file afterward.",
    "Separate lean-run-at calls are independent probes on the current saved file snapshot.",
    "For exact speculative chaining, use lean-run-at-handle and then lean-run-with /",
    "lean-run-with-linear.",
    "For multiline text-carrying Lean probes, prefer --stdin or --text-file <path>; use -- before",
    "text that itself starts with --.",
    "For handle-based commands, use --handle-file <path> when you do not want to inline handle json.",
    "For lean-sync / lean-refresh / lean-save / lean-close-save, diagnostics always stream for the",
    "current request;",
    "default is errors only, and +full widens the stream to warnings, info, and hints.",
    "Wrapper diagnostics and progress are human-facing on stderr.",
    "Set BEAM_DEBUG_TEXT=1 to print the exact escaped text and UTF-8 bytes sent for text-carrying",
    "Lean probe requests.",
    "For machine-readable streaming diagnostics/progress, use beam-client request-stream.",
    "",
    "Expert-only experimental commands are documented in docs/experimental.md.",
    "For the Lean workflow contract and anti-patterns, see skills/lean-beam/SKILL.md."
  ]

private def printExperimentalInfo (home : System.FilePath) : IO Unit := do
  let doc := home / "docs" / "experimental.md"
  IO.println s!"Experimental expert commands live in {doc}"
  IO.println "This is an unstable broker escape hatch, not part of the stable runAt contract."
  IO.println "Current experimental entry point: lean-request-at"
  IO.println "Unsupported or broken compatibility aliases may still exist for tests; they are not part of the supported or experimental surface."

private def runLeanRunAt
    (home : System.FilePath)
    (opts : CliOptions)
    (action path lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let root ← projectRoot opts .lean
  let (endpoint, _) ← ensureProjectDaemon home root .lean opts
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let parsedText ← parseTextArg s!"{action} <path> <line> <character>" textArgs
  let req ← withEnvClientRequestId {
    op := .runAt
    backend := .lean
    root? := some root.toString
    path? := some path
    line? := some line
    character? := some character
    text? := parsedText.text?
    storeHandle? := if storeHandle then some true else none
  }
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
  callBrokerWithProgress root endpoint req (leanRunAtWaitSpec action path line character)

private def runLeanRunWith
    (home : System.FilePath)
    (opts : CliOptions)
    (action path : String)
    (args : List String)
    (linear : Bool := false) : IO Unit := do
  let textArgs :=
    match args with
    | [] => []
    | "--handle-file" :: _ :: rest => rest
    | _ :: rest => rest
  if handleArgReadsStdin args && textArgReadsStdin textArgs then
    throw <| IO.userError <| String.intercalate "\n" [
      textArgUsage s!"{action} <path> <handle-json|-|--handle-file <path>>",
      "cannot read both handle json and continuation text from stdin; pass the handle inline, use --handle-file, or use --text-file for the text"
    ]
  let root ← projectRoot opts .lean
  let (endpoint, _) ← ensureProjectDaemon home root .lean opts
  let (handle, textArgs) ← parseHandleInput s!"{action} <path>" args
  let parsedText ← parseTextArg s!"{action} <path> <handle-json|-|--handle-file <path>>" textArgs
  let req ← withEnvClientRequestId {
    op := .runWith
    backend := .lean
    root? := some root.toString
    path? := some path
    handle? := some handle
    text? := parsedText.text?
    storeHandle? := some true
    linear? := some linear
  }
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
  callBrokerWithProgress root endpoint req (leanRunWithWaitSpec path (linear := linear))

private def runLeanRelease
    (home : System.FilePath)
    (opts : CliOptions)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts .lean
  let (endpoint, _) ← ensureProjectDaemon home root .lean opts
  let (handle, extra) ← parseHandleInput "lean-release <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage "lean-release <path>")
  callBroker root endpoint {
    op := .release
    backend := .lean
    root? := some root.toString
    path? := some path
    handle? := some handle
  }

private partial def parseCliOptions (opts : CliOptions) : List String → IO CliOptions
  | [] => pure opts
  | "--root" :: root :: rest => do
      let root ← IO.FS.realPath <| System.FilePath.mk root
      parseCliOptions { opts with explicitRoot? := some root } rest
  | "--port" :: port :: rest => do
      let port ← IO.ofExcept <| parsePortText "port" port
      parseCliOptions { opts with requestedPort? := some port } rest
  | "--socket" :: socketPath :: rest =>
      parseCliOptions { opts with requestedSocket? := some (System.FilePath.mk socketPath) } rest
  | arg :: rest =>
      parseCliOptions { opts with args := opts.args ++ [arg] } rest

private def printLeanDoctorInfo (home root : System.FilePath) : IO Unit := do
  let toolchain ← leanToolchain root
  let (supportPath, supportedToolchains) ← supportedLeanToolchains home
  let toolchainSupported := supportedToolchains.elem toolchain
  let leanCmd ← leanBin root
  let runtimeRoot ← runtimeBundleCacheRoot root
  let platform ← bundlePlatform
  let srcHash ← sourceHash home
  let installed? ← existingToolchainBundleInAny? (← installBundleCacheRoots) home toolchain
  let runtime? ← existingToolchainBundle? runtimeRoot home toolchain
  let (paths, bundleId, source, ready) ←
    match installed? with
    | some (paths, bundleId) => pure (paths, bundleId, "installed", true)
    | none =>
        match runtime? with
        | some (paths, bundleId) => pure (paths, bundleId, "runtime", true)
        | none =>
            let (paths, bundleId) ← predictedToolchainBundle runtimeRoot home toolchain
            pure (paths, bundleId, "missing", false)
  IO.println s!"project toolchain: {toolchain}"
  IO.println s!"project toolchain supported: {boolText toolchainSupported}"
  IO.println s!"supported toolchains registry: {supportPath}"
  IO.println s!"lean binary: {leanCmd}"
  IO.println s!"bundle platform: {platform}"
  IO.println s!"bundle source: {source}"
  IO.println s!"bundle source hash: {srcHash}"
  IO.println "bundle key inputs: toolchain, platform, source hash"
  IO.println s!"bundle source inputs: {String.intercalate ", " bundleSourceHashInputLabels}"
  IO.println s!"bundle id: {bundleId}"
  IO.println s!"bundle ready: {boolText ready}"
  IO.println s!"bundle daemon: {paths.daemon}"
  IO.println s!"bundle client: {paths.client}"
  IO.println s!"plugin: {paths.plugin}"

private def printRocqDoctorInfo (home root : System.FilePath) : IO Unit := do
  let paths ← defaultBundlePaths home
  let helpersReady := (← paths.daemon.pathExists) && (← paths.client.pathExists)
  IO.println s!"coq-lsp: {(← maybeRocqCmd root).getD ""}"
  IO.println s!"daemon helpers ready: {boolText helpersReady}"
  IO.println s!"daemon binary: {paths.daemon}"
  IO.println s!"client binary: {paths.client}"

private def doctor (home : System.FilePath) (opts : CliOptions) (backend : Backend) : IO Unit := do
  let root ← projectRoot opts backend
  IO.println s!"beam home: {home}"
  IO.println s!"project root: {root}"
  match backend with
  | .lean => printLeanDoctorInfo home root
  | .rocq => printRocqDoctorInfo home root
  let registry ← registryPath root
  IO.println s!"registry: {registry}"
  match ← registryLiveFor root with
  | some entry =>
      IO.println "daemon status: live"
      IO.println s!"daemon pid: {entry.pid}"
      if let some endpoint := registryEndpoint? entry then
        IO.println s!"daemon endpoint: {endpointSummary endpoint}"
      else
        IO.println "daemon endpoint: invalid"
      IO.println s!"daemon config hash: {entry.configHash}"
  | none =>
      if ← registry.pathExists then
        IO.println "daemon status: stale"
      else
        IO.println "daemon status: absent"

private def printSupportedToolchains (home : System.FilePath) (backendName : String) : IO Unit := do
  match backendName with
  | "lean" =>
      let (_, toolchains) ← supportedLeanToolchains home
      for toolchain in toolchains do
        IO.println toolchain
  | _ =>
      throw <| IO.userError "usage: lean-beam supported-toolchains"

private def printInstallLayout : IO Unit := do
  printJsonLine (toJson installLayout)

private def printInstallManifest (payloadHash : String) (sourceCommitArg : String) (toolchains : List String) : IO Unit := do
  if toolchains.isEmpty then
    throw <| IO.userError "usage: beam install-manifest <payload-hash> <source-commit|-> <toolchain...>"
  let sourceCommit? :=
    if sourceCommitArg == "-" then
      none
    else
      some sourceCommitArg
  printJsonLine (installManifestJson payloadHash sourceCommit? toolchains)

private def shutdownProjectDaemon (opts : CliOptions) : IO Unit := do
  let root ← projectRootAny opts
  let lockDir ← controlDir root
  let lockDir := lockDir / "lock"
  withLock lockDir do
    match ← registryLiveFor root with
    | some entry =>
        if let some endpoint := registryEndpoint? entry then
          let resp ← sendRequest endpoint { op := .shutdown }
          printResponse resp
          waitForPidGone entry.pid
          if ← pidAlive entry.pid then
            killPid entry.pid
            waitForPidGone entry.pid
          removeRegistry root
        else
          stopRegisteredDaemon root
          printJsonLine <| Json.mkObj [
            ("result", Json.mkObj [("shutdown", toJson false), ("reason", toJson ("notFound" : String))])
          ]
    | none =>
        stopRegisteredDaemon root
        printJsonLine <| Json.mkObj [
          ("result", Json.mkObj [("shutdown", toJson false), ("reason", toJson ("notFound" : String))])
        ]

private def runCommand (home : System.FilePath) (opts : CliOptions) : IO Unit := do
  match opts.args with
  | [] =>
      throw <| IO.userError usage
  | "experimental" :: [] =>
      printExperimentalInfo home
  | "bundle-install" :: toolchain :: [] =>
      let cacheRoot ←
        match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
        | some path => pure <| System.FilePath.mk path
        | none =>
            let roots ← installBundleCacheRoots
            pure <| roots.headD (runAtStateDir home / installBundlesDirName)
      let _ ← ensureToolchainBundleIn cacheRoot home toolchain
      pure ()
  | "supported-toolchains" :: backend :: [] =>
      printSupportedToolchains home backend
  | "install-layout" :: [] =>
      printInstallLayout
  | "install-manifest" :: payloadHash :: sourceCommitArg :: toolchains =>
      printInstallManifest payloadHash sourceCommitArg toolchains
  | "ensure" :: backend :: [] =>
      let backend := if backend == "rocq" then Backend.rocq else Backend.lean
      let root ← projectRoot opts backend
      let (endpoint, _) ← ensureProjectDaemon home root backend opts
      callBroker root endpoint { op := .ensure, backend := backend, root? := some root.toString }
  | "lean-run-at" :: path :: line :: character :: text =>
      runLeanRunAt home opts "lean-run-at" path line character text
  | "lean-run-at-handle" :: path :: line :: character :: text =>
      runLeanRunAt home opts "lean-run-at-handle" path line character text (storeHandle := true)
  | "lean-hover" :: path :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      callBrokerWithProgress root endpoint {
        op := .requestAt
        backend := .lean
        root? := some root.toString
        path? := some path
        line? := some line
        character? := some character
        method? := some "textDocument/hover"
      } (leanHoverWaitSpec path line character)
  | "lean-goals-after" :: path :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      callBrokerWithProgress root endpoint {
        op := .goals
        backend := .lean
        root? := some root.toString
        path? := some path
        line? := some line
        character? := some character
        mode? := some .after
      } (leanGoalsWaitSpec path line character .after)
  | "lean-goals-prev" :: path :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      callBrokerWithProgress root endpoint {
        op := .goals
        backend := .lean
        root? := some root.toString
        path? := some path
        line? := some line
        character? := some character
        mode? := some .prev
      } (leanGoalsWaitSpec path line character .prev)
  | "lean-request-at" :: path :: line :: character :: method :: extra => do
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let params? ←
        match extra with
        | [] => pure none
        | [raw] => pure <| some (← parseJsonArg "request params json" raw)
        | _ => throw <| IO.userError usage
      callBrokerWithProgress root endpoint {
        op := .requestAt
        backend := .lean
        root? := some root.toString
        path? := some path
        line? := some line
        character? := some character
        method? := some method
        params? := params?
      } (leanRequestAtWaitSpec path line character method)
  | "lean-run-with" :: path :: args =>
      runLeanRunWith home opts "lean-run-with" path args
  | "lean-run-with-linear" :: path :: args =>
      runLeanRunWith home opts "lean-run-with-linear" path args (linear := true)
  | "lean-release" :: path :: args =>
      runLeanRelease home opts path args
  | "lean-deps" :: path :: [] =>
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      callBroker root endpoint { op := .deps, backend := .lean, root? := some root.toString, path? := some path }
  | "lean-save" :: path :: extra => do
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanSaveArgs extra
      callBrokerWithProgress root endpoint
        {
          op := .saveOlean
          backend := .lean
          root? := some root.toString
          path? := some path
          fullDiagnostics? := some fullDiagnostics
        }
        (leanSaveWaitSpec path)
  | "lean-sync" :: path :: extra => do
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanSyncArgs extra
      callBrokerWithProgress root endpoint
        {
          op := .syncFile
          backend := .lean
          root? := some root.toString
          path? := some path
          fullDiagnostics? := some fullDiagnostics
        }
        (syncWaitSpec path)
  | "lean-refresh" :: path :: extra => do
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanRefreshArgs extra
      callBrokerQuiet root endpoint {
        op := .close
        backend := .lean
        root? := some root.toString
        path? := some path
      }
      callBrokerWithProgress root endpoint
        {
          op := .syncFile
          backend := .lean
          root? := some root.toString
          path? := some path
          fullDiagnostics? := some fullDiagnostics
        }
        (refreshWaitSpec path)
  | "lean-close" :: path :: [] =>
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      callBroker root endpoint { op := .close, backend := .lean, root? := some root.toString, path? := some path }
  | "lean-close-save" :: path :: extra =>
      let root ← projectRoot opts .lean
      let (endpoint, _) ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanCloseSaveArgs extra
      callBrokerWithProgress root endpoint {
        op := .close
        backend := .lean
        root? := some root.toString
        path? := some path
        saveArtifacts? := some true
        fullDiagnostics? := some fullDiagnostics
      } (leanSaveWaitSpec path (closeAfter := true))
  | "rocq-goals-after" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      let (endpoint, _) ← ensureProjectDaemon home root .rocq opts
      callBroker root endpoint {
        op := .goals
        backend := .rocq
        root? := some root.toString
        path? := some path
        line? := some (← parseNatArg "line" line)
        character? := some (← parseNatArg "character" character)
        mode? := some .after
        compact? := some false
        ppFormat? := some .str
        text? := joinTextArgs text
      }
  | "rocq-goals-prev" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      let (endpoint, _) ← ensureProjectDaemon home root .rocq opts
      callBroker root endpoint {
        op := .goals
        backend := .rocq
        root? := some root.toString
        path? := some path
        line? := some (← parseNatArg "line" line)
        character? := some (← parseNatArg "character" character)
        mode? := some .prev
        compact? := some false
        ppFormat? := some .str
        text? := joinTextArgs text
      }
  | "doctor" :: backend :: [] =>
      doctor home opts (if backend == "rocq" then .rocq else .lean)
  | "open-files" :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint { op := .openDocs, root? := some root.toString }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "cancel" :: requestId :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint {
          op := .cancel
          root? := some root.toString
          cancelRequestId? := some requestId
        }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "stats" :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint { op := .stats }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "reset-stats" :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint { op := .resetStats }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "shutdown" :: [] =>
      shutdownProjectDaemon opts
  | _ =>
      throw <| IO.userError usage

def main (args : List String) : IO Unit := do
  let home ← runAtHome
  let opts ← parseCliOptions {} args
  runCommand home opts

end Beam.Cli

def main := Beam.Cli.main
