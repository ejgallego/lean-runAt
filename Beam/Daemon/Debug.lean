/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Daemon.Paths
import Beam.Daemon.Protocol
import Beam.System

open Lean

namespace Beam.Daemon

inductive RegistryRead where
  | absent
  | legacy
  | unsupported (schemaVersion : Nat)
  | malformed (detail : String)
  | current (entry : RegistryEntry)

def RegistryRead.entry? : RegistryRead → Option RegistryEntry
  | .current entry => some entry
  | .absent | .legacy | .unsupported _ | .malformed _ => none

def RegistryRead.status : RegistryRead → String
  | .absent => "absent"
  | .legacy => "legacy"
  | .unsupported _ => "unsupported"
  | .malformed _ => "malformed"
  | .current _ => "current"

def RegistryRead.detail? : RegistryRead → Option String
  | .legacy => some "legacy registry has no schemaVersion"
  | .unsupported version => some s!"unsupported registry schemaVersion {version}"
  | .malformed detail => some detail
  | .absent | .current _ => none

def readRegistry (root : System.FilePath) : IO RegistryRead := do
  let path ← registryPath root
  unless ← path.pathExists do
    return .absent
  try
    let text ← IO.FS.readFile path
    let json ←
      match Json.parse text with
      | .ok json => pure json
      | .error err => return .malformed s!"invalid registry JSON: {err}"
    match json.getObjVal? "schemaVersion" with
    | .error _ => pure .legacy
    | .ok schemaJson =>
        let schemaVersion ←
          match fromJson? (α := Nat) schemaJson with
          | .ok schemaVersion => pure schemaVersion
          | .error err => return .malformed s!"invalid registry schemaVersion: {err}"
        unless schemaVersion == registrySchemaVersion do
          return .unsupported schemaVersion
        match fromJson? json with
        | .ok entry => pure <| .current entry
        | .error err => pure <| .malformed s!"invalid registry schema: {err}"
  catch err =>
    pure <| .malformed s!"could not read registry: {err}"

def daemonFailureIncidentEntries (root : System.FilePath) : IO (Array IO.FS.DirEntry) := do
  try
    let dir ← daemonFailureIncidentDir root
    unless ← dir.pathExists do
      return #[]
    let entries ← dir.readDir
    pure <| (entries.filter (fun entry => entry.fileName.endsWith ".json")).qsort
      (fun a b => a.fileName < b.fileName)
  catch _ =>
    pure #[]

def recentDaemonFailureIncidentPaths (root : System.FilePath) (limit : Nat := 5) :
    IO (Array System.FilePath) := do
  let entries ← daemonFailureIncidentEntries root
  let keep := min limit entries.size
  let recent := entries.toList.drop (entries.size - keep)
  pure <| recent.foldl (fun acc entry => acc.push entry.path) #[]

private def recentDaemonFailureIncidentJson (root : System.FilePath) (limit : Nat := 5) :
    IO (Array Json) := do
  let paths ← recentDaemonFailureIncidentPaths root limit
  let mut incidents := #[]
  for path in paths do
    let payload ←
      try
        let text ← IO.FS.readFile path
        match Json.parse text with
        | .ok json => pure json
        | .error err =>
            pure <| Json.mkObj [
              ("path", toJson path.toString),
              ("parseError", toJson err)
            ]
      catch e =>
        pure <| Json.mkObj [
          ("path", toJson path.toString),
          ("readError", toJson e.toString)
        ]
    incidents := incidents.push <| payload.setObjVal! "path" (toJson path.toString)
  pure incidents

private def tailLines (text : String) (count : Nat := 20) : String :=
  let lines := text.splitOn "\n"
  let keep := min count lines.length
  String.intercalate "\n" <| lines.drop (lines.length - keep)

def registryEndpointSummary (entry : RegistryEntry) : String :=
  match registryEndpoint? entry with
  | some endpoint => endpointSummary endpoint
  | none => "invalid"

def registryPidStatus (entry : RegistryEntry) : IO String := do
  let recorded : Beam.RecordedPid := { pid := entry.pid, domain? := entry.pidDomain? }
  try
    match ← recorded.observe with
    | .invalid => pure "unknown"
    | .local true => pure "alive"
    | .local false => pure "not alive"
    | .differentDomain => pure "different PID domain"
    | .unknownDomain => pure "unavailable"
  catch _ =>
    pure "unavailable"

def startupLogTail? (root : System.FilePath) : IO (Option (System.FilePath × String)) := do
  try
    let logPath ← daemonStartupLogPath root
    if ← logPath.pathExists then
      let logText := Beam.trimLine (← IO.FS.readFile logPath)
      if logText.isEmpty then
        pure none
      else
        pure <| some (logPath, tailLines logText)
    else
      pure none
  catch _ =>
    pure none

private def jsonStringField? (json : Json) (field : String) : Option String :=
  match json.getObjValAs? String field with
  | .ok value => some value
  | .error _ => none

private def jsonNonNullField (json : Json) (field : String) : Bool :=
  match json.getObjVal? field with
  | .ok Json.null => false
  | .ok _ => true
  | .error _ => false

def daemonDebugWarnings (debug : Json) : Array String := Id.run do
  let mut warnings := #[]
  let recoveryHint := "Run `lean-beam shutdown`, then start `lean-beam ensure --hold` from the project root to refresh the owned session."
  if jsonNonNullField debug "registry" then
    match jsonStringField? debug "registryPidStatus" with
    | some "not alive" =>
        let detail :=
          if jsonNonNullField debug "registryEndpoint" then
            " while a registry endpoint is recorded"
          else
            ""
        warnings := warnings.push
          s!"Beam daemon registry pid is not alive{detail}; stats/open-files may come from a live endpoint with stale registry metadata. {recoveryHint}"
    | some "unavailable" =>
        warnings := warnings.push
          s!"Beam could not verify the daemon registry pid; stats/open-files may reflect a daemon whose registry metadata cannot be trusted. {recoveryHint}"
    | _ =>
        pure ()
  warnings

private def optionLine (label : String) : Option String → Option String
  | none => none
  | some value => some s!"  {label}: {value}"

def daemonRegistryContext? (root : System.FilePath) : IO (Option String) := do
  try
    match ← readRegistry root with
    | .absent => pure none
    | .legacy =>
        let path ← registryPath root
        pure <| some s!"Beam daemon registry ({path}):\n  status: legacy\n  detail: legacy registry has no schemaVersion"
    | .unsupported schemaVersion =>
        let path ← registryPath root
        let detail := (RegistryRead.unsupported schemaVersion).detail?.getD "unsupported registry"
        pure <| some s!"Beam daemon registry ({path}):\n  status: unsupported\n  detail: {detail}"
    | .malformed detail =>
        let path ← registryPath root
        pure <| some s!"Beam daemon registry ({path}):\n  status: malformed\n  detail: {detail}"
    | .current entry =>
        let path ← registryPath root
        let pidStatus ← registryPidStatus entry
        let lines := ([
          s!"Beam daemon registry ({path}):",
          s!"  schemaVersion: {entry.schemaVersion}",
          s!"  lifecycle: {repr entry.lifecycle}",
          s!"  daemonId: {entry.daemonId}",
          s!"  pid: {entry.pid} ({pidStatus})",
          s!"  endpoint: {registryEndpointSummary entry}",
          s!"  startedAt: {entry.startedAt}",
          s!"  configHash: {entry.configHash}",
          s!"  root: {entry.root}"
        ] ++
          (optionLine "toolchain" entry.toolchain?).toList ++
          (optionLine "bundleId" entry.bundleId?).toList ++
          (optionLine "pidDomain" entry.pidDomain?).toList)
        pure <| some <| String.intercalate "\n" lines
  catch _ =>
    pure none

def daemonDebugContextJson (root : System.FilePath) : IO Json := do
  let registryFile ← registryPath root
  let registryRead ← readRegistry root
  let registry := registryRead.entry?
  let registryPidStatus ←
    match registry with
    | some entry => some <$> registryPidStatus entry
    | none => pure none
  let startupLogTail ← startupLogTail? root
  let incidents ← recentDaemonFailureIncidentJson root
  pure <| Json.mkObj <|
    [
      ("registryPath", toJson registryFile.toString),
      ("registryReadStatus", toJson registryRead.status),
      ("registryReadDetail", match registryRead.detail? with
        | some detail => toJson detail
        | none => Json.null),
      ("registry", match registry with
        | some entry => (toJson entry).setObjVal! "capability" (toJson "<redacted>")
        | none => Json.null),
      ("registryPidStatus", match registryPidStatus with | some status => toJson status | none => Json.null),
      ("registryEndpoint", match registry.map registryEndpointSummary with | some endpoint => toJson endpoint | none => Json.null),
      ("recentDaemonIncidents", toJson incidents)
    ] ++
    (match startupLogTail with
    | some (path, tail) => [
        ("startupLogPath", toJson path.toString),
        ("startupLogTail", toJson tail)
      ]
    | none => [])

end Beam.Daemon
