/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lake.Build.Run
import Lake.Build.Targets
import Lake.Build.Job.Monad
import Lake.Build.Common
import Lake.Build.InitFacets
import Beam.Broker.Config

open Lean
open System
open Std

namespace Beam.Broker

open Lake

structure LeanSaveSpec where
  relPath : String
  moduleName : Name
  oleanPath : FilePath
  oleanServerPath? : Option FilePath := none
  oleanPrivatePath? : Option FilePath := none
  ileanPath : FilePath
  irPath? : Option FilePath := none
  cPath : FilePath
  bcPath? : Option FilePath := none
  tracePath : FilePath
  depTrace : BuildTrace

structure SourceSnapshot where
  hash : Hash
  mtime : MTime

inductive SaveTargetEligibility where
  | eligible (moduleName : Name)
  | notModule
  | workspaceLoadFailed (message : String)

private def traceOptions (opts : LeanOptions) (caption := "opts") : BuildTrace :=
  opts.values.foldl (init := .nil caption) fun t n v =>
    let opt := s!"-D{n}={v.asCliFlagValue}"
    t.mix <| .ofHash (pureHash opt) opt

-- Lean/Lake v4.28 compatibility shim: newer Lake versions let `addPureTrace` hash any `Hashable`
-- value directly, but v4.28 lacks that generic `ComputeHash` instance. When we drop v4.28 support,
-- replace this helper with the upstream-style `addPureTrace mod.name` / `addPureTrace mod.pkg.id?`.
private def hashOfHashable [Hashable α] (a : α) : Hash :=
  Hash.mix Hash.nil <| Hash.mk <| hash a

private def addHashablePureTrace [ToString α] [Hashable α] (a : α) (caption := "pure") : JobM PUnit :=
  addTrace <| .ofHash (hashOfHashable a) s!"{caption}: {toString a}"

private def quietBuildConfig : BuildConfig :=
  { noBuild := true, verbosity := .quiet }

private def quietLogConfig : LogConfig :=
  { outLv := .error }

private def workspaceRelPath? (root path : FilePath) : Option String := do
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{FilePath.pathSeparator}"
  if pathStr.startsWith rootPrefix then
    some <| (pathStr.drop rootPrefix.length).toString
  else if pathStr == rootStr then
    some "."
  else
    none

private def computeLakeEnv (leanCmd? : Option String) : IO Lake.Env := do
  let elan? ← Lake.findElanInstall?
  let lean? ←
    match leanCmd? with
    | some leanCmd =>
        if leanCmd.trimAscii.isEmpty then
          pure none
        else
          Lake.findLeanCmdInstall? leanCmd
    | none =>
        pure none
  let (lean?, lake?) ←
    match lean? with
    | some lean => pure (some lean, some (Lake.LakeInstall.ofLean lean))
    | none =>
        let (_, lean?, lake?) ← Lake.findInstall?
        pure (lean?, lake?)
  let some lean := lean?
    | throw <| IO.userError "could not locate Lean installation for Lake workspace loading"
  let some lake := lake?
    | throw <| IO.userError "could not locate Lake installation for workspace loading"
  match ← (Lake.Env.compute lake lean elan?).toBaseIO with
  | .ok env => pure env
  | .error err => throw <| IO.userError s!"failed to compute Lake environment: {err}"

private def detectConfigFile (root : FilePath) : IO (FilePath × FilePath) := do
  let leanConfig := root / "lakefile.lean"
  if ← leanConfig.pathExists then
    pure (System.FilePath.mk "lakefile.lean", leanConfig)
  else
    let tomlConfig := root / "lakefile.toml"
    if ← tomlConfig.pathExists then
      pure (System.FilePath.mk "lakefile.toml", tomlConfig)
    else
      throw <| IO.userError s!"could not find lakefile.lean or lakefile.toml under {root}"

private def trimLeftAscii (s : String) : String :=
  (s.dropWhile fun c => c.isWhitespace).toString

private partial def findPackageNameInLines : List String → Option String
  | [] => none
  | line :: rest =>
      let line := trimLeftAscii line
      if line.startsWith "package \"" then
        let tail := (line.drop "package \"".length).toString
        match tail.splitOn "\"" with
        | name :: _ => if name.isEmpty then none else some name
        | _ => none
      else
        findPackageNameInLines rest

private def packageNameFromLakefileLean? (text : String) : Option String :=
  findPackageNameInLines (text.splitOn "\n")

private partial def collectLeanLibNamesInLines : List String → List String → List String
  | [], acc => acc.reverse
  | line :: rest, acc =>
      let line := trimLeftAscii line
      if line.startsWith "lean_lib " then
        let tail := trimLeftAscii (line.drop "lean_lib ".length).toString
        let name := (tail.takeWhile fun c => !c.isWhitespace).toString
        if name.isEmpty then
          collectLeanLibNamesInLines rest acc
        else
          collectLeanLibNamesInLines rest (name :: acc)
      else
        collectLeanLibNamesInLines rest acc

private def leanLibNamesFromLakefileLean (text : String) : List String :=
  collectLeanLibNamesInLines (text.splitOn "\n") []

private def compatTomlForLakefileLean (configFile : FilePath) : IO FilePath := do
  let text ← IO.FS.readFile configFile
  let some packageName := packageNameFromLakefileLean? text
    | throw <| IO.userError s!"could not infer package name from {configFile}"
  let libNames := leanLibNamesFromLakefileLean text
  if libNames.isEmpty then
    throw <| IO.userError s!"could not infer any lean_lib declarations from {configFile}"
  let mut toml := s!"name = {repr packageName}\n"
  for libName in libNames do
    toml := toml ++ s!"\n[[lean_lib]]\nname = {repr libName}\n"
  let tmpPath := System.FilePath.mk s!"/tmp/runat-lake-compat-{(← IO.monoNanosNow)}.toml"
  IO.FS.writeFile tmpPath toml
  pure tmpPath

private def loadWorkspaceWithConfig (root : FilePath) (lakeEnv : Lake.Env)
    (relConfigFile configFile : FilePath) : IO (Option Workspace × Array String) := do
  let loadConfig : LoadConfig := {
    lakeEnv := lakeEnv
    wsDir := root
    relPkgDir := System.FilePath.mk "."
    pkgDir := root
    relConfigFile := relConfigFile
    configFile := configFile
  }
  let (ws?, log) ← LoggerIO.captureLog <| Lake.loadWorkspace loadConfig
  let messages := log.entries.map fun entry => entry.toString
  pure (ws?, messages)

private def loadWorkspaceFailureMessage
    (root : FilePath)
    (messages : Array String)
    (extra : Array String := #[]) : String :=
  let lines :=
    #[s!"failed to load Lake workspace at {root}"] ++
    (if messages.isEmpty then #[] else #["Lake log:"] ++ messages) ++
    extra
  String.intercalate "\n" lines.toList

private def loadWorkspaceForSave (root : FilePath) (leanCmd? : Option String) : IO Workspace := do
  let (relConfigFile, configFile) ← detectConfigFile root
  let lakeEnv ← computeLakeEnv leanCmd?
  let (ws?, messages) ← loadWorkspaceWithConfig root lakeEnv relConfigFile configFile
  if let some ws := ws? then
    pure ws
  else if relConfigFile == System.FilePath.mk "lakefile.lean" then
    let compatConfig ← compatTomlForLakefileLean configFile
    try
      let (ws?, compatMessages) ←
        loadWorkspaceWithConfig root lakeEnv (System.FilePath.mk "lakefile.toml") compatConfig
      let some ws := ws?
        | throw <| IO.userError <| loadWorkspaceFailureMessage root messages
            (#[s!"compat lakefile.toml fallback also failed: {compatConfig}"] ++ compatMessages)
      pure ws
    finally
      try
        IO.FS.removeFile compatConfig
      catch _ =>
        pure ()
  else
    throw <| IO.userError <| loadWorkspaceFailureMessage root messages

private def sourceTrace (path : FilePath) (snapshot : SourceSnapshot) : BuildTrace :=
  {
    caption := path.toString
    hash := snapshot.hash
    mtime := snapshot.mtime
  }

private def buildDepTrace
    (ws : Workspace)
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : IO (BuildTrace × Bool) :=
  ws.runBuild (cfg := quietBuildConfig) do
    let setupJob ← mod.setup.fetch
    setupJob.mapM (sync := true) fun setup => do
      addLeanTrace
      addTrace <| sourceTrace mod.leanFile snapshot
      addTrace <| traceOptions setup.options "options"
      addPureTrace setup.isModule "isModule"
      addHashablePureTrace mod.name "Module.name"
      addHashablePureTrace mod.pkg.id? "Package.id?"
      addPureTrace mod.leanArgs "Module.leanArgs"
      setTraceCaption s!"{mod.name.toString}:leanArts"
      return (← getTrace, setup.isModule)

def mkLeanSaveSpec
    (root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd? : Option String := none) : IO LeanSaveSpec := do
  let root ← IO.FS.realPath root
  let path ← IO.FS.realPath (if path.isAbsolute then path else root / path)
  let ws ← loadWorkspaceForSave root leanCmd?
  let some mod := ws.findModuleBySrc? path
    | throw <| IO.userError <|
        s!"could not resolve a Lake module for {path}. " ++
        "lean-save only works for synced files that belong to the current Lake workspace package graph."
  let (depTrace, isModule) ← buildDepTrace ws mod snapshot
  let relPath := (workspaceRelPath? root path).getD path.toString
  pure {
    relPath
    moduleName := mod.name
    oleanPath := mod.oleanFile
    oleanServerPath? := if isModule then some mod.oleanServerFile else none
    oleanPrivatePath? := if isModule then some mod.oleanPrivateFile else none
    ileanPath := mod.ileanFile
    irPath? := if isModule then some mod.irFile else none
    cPath := mod.cFile
    bcPath? := if Lean.Internal.hasLLVMBackend () then some mod.bcFile else none
    tracePath := mod.traceFile
    depTrace
  }

def checkLeanSaveTarget
    (root path : FilePath)
    (leanCmd? : Option String := none) : IO SaveTargetEligibility := do
  let root ← IO.FS.realPath root
  let path ← IO.FS.realPath (if path.isAbsolute then path else root / path)
  try
    let ws ← loadWorkspaceForSave root leanCmd?
    match ws.findModuleBySrc? path with
    | some mod => pure <| .eligible mod.name
    | none => pure .notModule
  catch e =>
    pure <| .workspaceLoadFailed e.toString

private def hashDescr (path : FilePath) (ext : String) : IO ArtifactDescr :=
  return artifactWithExt (← computeHash path) ext

def writeLeanSaveTrace (spec : LeanSaveSpec) : IO Unit := do
  let outputs : ModuleOutputDescrs := {
    olean := ← hashDescr spec.oleanPath "olean"
    oleanServer? := ← spec.oleanServerPath?.mapM (fun path => hashDescr path "olean.server")
    oleanPrivate? := ← spec.oleanPrivatePath?.mapM (fun path => hashDescr path "olean.private")
    ilean := ← hashDescr spec.ileanPath "ilean"
    ir? := ← spec.irPath?.mapM (fun path => hashDescr path "ir")
    c := ← hashDescr spec.cPath "c"
    bc? := ← spec.bcPath?.mapM (fun path => hashDescr path "bc")
  }
  writeBuildTrace spec.tracePath spec.depTrace outputs {}

end Beam.Broker
