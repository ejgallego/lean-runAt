/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Parser.Module

open Lean
open Lean.Lsp

namespace Beam.Broker

/--
Workspace dependency scanning is currently implemented in the broker as a stopgap helper for local
tooling such as `lean-beam deps`. This is not the right long-term source of dependency truth: the
broker should eventually delegate richer workspace dependency queries to Lake or to a stronger
backend-facing primitive, rather than maintaining its own scanner here.
-/

private def sessionUri (path : System.FilePath) : String :=
  (System.Uri.pathToUri path : String)

def workspacePath? (root : System.FilePath) (uri : DocumentUri) : Option String := do
  let path ← System.Uri.fileUriToPath? uri
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  if pathStr.startsWith rootPrefix then
    some <| (pathStr.drop rootPrefix.length).toString
  else if pathStr == rootStr then
    some "."
  else
    none

def fallbackModuleName? (root path : System.FilePath) : Option String := do
  let relPath ← workspacePath? root (sessionUri path)
  if !relPath.endsWith ".lean" then
    none
  else
    let parts := (System.FilePath.mk relPath).components
    let stem ← (System.FilePath.mk relPath).fileStem
    let init := parts.dropLast
    some <| String.intercalate "." (init ++ [stem])

def normalizeModuleForPath (root path : System.FilePath) (uri : DocumentUri) (module? : Option LeanModule) : Option LeanModule :=
  match module? with
  | some module =>
      if module.name.startsWith "«external:" then
        match fallbackModuleName? root path with
        | some name => some { name, uri, data? := module.data? }
        | none => some module
      else
        some module
  | none =>
      match fallbackModuleName? root path with
      | some name => some { name, uri }
      | none => none

def moduleJson (root : System.FilePath) (module : LeanModule) : Json :=
  let path? := workspacePath? root module.uri
  Json.mkObj <|
    [
      ("name", toJson module.name),
      ("uri", toJson module.uri),
      ("workspace", toJson path?.isSome)
    ] ++
    match path? with
    | some path => [("path", toJson path)]
    | none => []

def importJson (root : System.FilePath) (imp : LeanImport) : Json :=
  Json.mkObj [
    ("module", moduleJson root imp.module),
    ("kind", toJson imp.kind)
  ]

def depsPayload (root : System.FilePath) (module : LeanModule)
    (imports importedBy : Array LeanImport)
    (importClosure importedByClosure : Std.TreeMap String LeanImport) : Json :=
  Json.mkObj [
    ("module", moduleJson root module),
    ("imports", Json.arr <| imports.map (importJson root)),
    ("importedBy", Json.arr <| importedBy.map (importJson root)),
    ("importClosure", Json.arr <| importClosure.toList.map (fun (_, imp) => importJson root imp) |>.toArray),
    ("importedByClosure", Json.arr <| importedByClosure.toList.map (fun (_, imp) => importJson root imp) |>.toArray)
  ]

def importInfoToWorkspaceImport?
    (moduleIndex : Std.TreeMap String System.FilePath)
    (info : ImportInfo) : Option LeanImport := do
  let path ← moduleIndex.get? info.module
  some {
    module := { name := info.module, uri := sessionUri path, data? := none }
    kind := {
      isPrivate := info.isPrivate
      isAll := info.isAll
      metaKind := if info.isMeta then .«meta» else .nonMeta
    }
  }

partial def workspaceLeanFiles (root dir : System.FilePath) : IO (Array System.FilePath) := do
  let entries := (← dir.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut files := #[]
  for entry in entries do
    if ← entry.path.isDir then
      let name := entry.fileName
      unless name == ".git" || name == ".lake" || name == "build" || name == "_opam" || name == "_eval" || name == ".beam" do
        files := files ++ (← workspaceLeanFiles root entry.path)
    else if entry.fileName.endsWith ".lean" then
      files := files.push entry.path
  pure files

def workspaceModuleIndex (root : System.FilePath) : IO (Std.TreeMap String System.FilePath) := do
  let files ← workspaceLeanFiles root root
  pure <| files.foldl (init := {}) fun index path =>
    match fallbackModuleName? root path with
    | some name => index.insert name path
    | none => index

def parseHeaderImports (path : System.FilePath) : IO (Array ImportInfo) := do
  let text ← IO.FS.readFile path
  let inputCtx := Lean.Parser.mkInputContext text path.toString
  let (header, _, messages) ← Lean.Parser.parseHeader inputCtx
  if messages.toList.any (fun msg => msg.severity == .error) then
    throw <| IO.userError s!"failed to parse imports for {path}"
  pure <| Lean.Server.collectImports header

def directWorkspaceImports
    (moduleIndex : Std.TreeMap String System.FilePath)
    (path : System.FilePath) : IO (Array LeanImport) := do
  let infos ← parseHeaderImports path
  pure <| infos.foldl (init := #[]) fun imports info =>
    match importInfoToWorkspaceImport? moduleIndex info with
    | some imp =>
        if imports.any (fun existing => existing.module.name == imp.module.name) then
          imports
        else
          imports.push imp
    | none =>
        imports

structure DepsQueryState where
  moduleIndex : Std.TreeMap String System.FilePath
  importsCache : IO.Ref (Std.TreeMap String (Except String (Array LeanImport)))
  importedByCache : IO.Ref (Std.TreeMap String (Array LeanImport))
  textCache : IO.Ref (Std.TreeMap String String)

def mkDepsQueryState (root : System.FilePath) : IO DepsQueryState := do
  pure {
    moduleIndex := ← workspaceModuleIndex root
    importsCache := ← IO.mkRef {}
    importedByCache := ← IO.mkRef {}
    textCache := ← IO.mkRef {}
  }

def moduleText (state : DepsQueryState) (moduleName : String) (path : System.FilePath) : IO String := do
  if let some text := (← state.textCache.get).get? moduleName then
    pure text
  else
    let text ← IO.FS.readFile path
    state.textCache.modify fun cache => cache.insert moduleName text
    pure text

def cachedDirectImports (state : DepsQueryState) (moduleName : String) : IO (Except String (Array LeanImport)) := do
  if let some cached := (← state.importsCache.get).get? moduleName then
    pure cached
  else
    let result ←
      match state.moduleIndex.get? moduleName with
      | none =>
          pure (.ok #[])
      | some path =>
          try
            return .ok (← directWorkspaceImports state.moduleIndex path)
          catch e =>
            return .error e.toString
    state.importsCache.modify fun cache => cache.insert moduleName result
    pure result

def requireDirectImports (state : DepsQueryState) (moduleName : String) : IO (Array LeanImport) := do
  match ← cachedDirectImports state moduleName with
  | .ok imports => pure imports
  | .error err => throw <| IO.userError err

def directImportedBy (state : DepsQueryState) (targetModule : String) : IO (Array LeanImport) := do
  if let some cached := (← state.importedByCache.get).get? targetModule then
    pure cached
  else
    let mut importers := #[]
    for (candidateModule, candidatePath) in state.moduleIndex.toList do
      if candidateModule != targetModule then
        let text ← moduleText state candidateModule candidatePath
        if text.contains targetModule then
          match ← cachedDirectImports state candidateModule with
          | .ok imports =>
              if let some imp := imports.find? (·.module.name == targetModule) then
                let importer := {
                  module := { name := candidateModule, uri := sessionUri candidatePath, data? := none }
                  kind := imp.kind
                }
                if !importers.any (fun existing => existing.module.name == importer.module.name) then
                  importers := importers.push importer
          | .error _ =>
              pure ()
    state.importedByCache.modify fun cache => cache.insert targetModule importers
    pure importers

partial def collectImportClosure
    (state : DepsQueryState)
    (rootModule : String)
    (visited : Std.TreeSet String := {})
    (acc : Std.TreeMap String LeanImport := {}) : IO (Std.TreeMap String LeanImport) := do
  if visited.contains rootModule then
    pure acc
  else
    let visited := visited.insert rootModule
    let edges ← requireDirectImports state rootModule
    let acc := edges.foldl (init := acc) fun acc imp =>
      if acc.contains imp.module.name then acc else acc.insert imp.module.name imp
    edges.foldlM (init := acc) fun acc imp =>
      collectImportClosure state imp.module.name visited acc

partial def collectImportedByClosure
    (state : DepsQueryState)
    (rootModule : String)
    (visited : Std.TreeSet String := {})
    (acc : Std.TreeMap String LeanImport := {}) : IO (Std.TreeMap String LeanImport) := do
  if visited.contains rootModule then
    pure acc
  else
    let visited := visited.insert rootModule
    let edges ← directImportedBy state rootModule
    let acc := edges.foldl (init := acc) fun acc imp =>
      if acc.contains imp.module.name then acc else acc.insert imp.module.name imp
    edges.foldlM (init := acc) fun acc imp =>
      collectImportedByClosure state imp.module.name visited acc

end Beam.Broker
