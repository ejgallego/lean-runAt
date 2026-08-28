/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Daemon.Paths
import Beam.Daemon.Protocol

open Lean

namespace Beam.Daemon

/-- Typed result of reading the versioned on-disk daemon registry. -/
inductive RegistryRead where
  | absent
  | legacy
  | unsupported (schemaVersion : Nat)
  | malformed (detail : String)
  | current (entry : SessionDescriptor)

def RegistryRead.entry? : RegistryRead → Option SessionDescriptor
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

private def validateWorkspaceBindings (workspaces : Array WorkspaceBinding) : Except String Unit := do
  if workspaces.isEmpty then
    throw "session descriptor must contain at least one workspace"
  let mut ids : Std.TreeSet String compare := {}
  let mut roots : Std.TreeSet String compare := {}
  for workspace in workspaces do
    if workspace.workspaceId.isEmpty then
      throw "session workspace id must not be empty"
    if workspace.root.isEmpty then
      throw s!"session workspace '{workspace.workspaceId}' has an empty root"
    let rootPath := System.FilePath.mk workspace.root
    unless rootPath.isAbsolute do
      throw s!"session workspace '{workspace.workspaceId}' root is not absolute"
    if workspace.configHash.isEmpty then
      throw s!"session workspace '{workspace.workspaceId}' has an empty configuration hash"
    if ids.contains workspace.workspaceId then
      throw s!"duplicate session workspace id '{workspace.workspaceId}'"
    let normalizedRoot := rootPath.normalize.toString
    if roots.contains normalizedRoot then
      throw s!"duplicate session workspace root '{workspace.root}'"
    ids := ids.insert workspace.workspaceId
    roots := roots.insert normalizedRoot

private def validateSessionDescriptor (entry : SessionDescriptor) : Except String Unit := do
  if entry.daemonId.isEmpty then
    throw "session descriptor daemonId must not be empty"
  if entry.capability.isEmpty then
    throw "session descriptor capability must not be empty"
  if entry.configHash.isEmpty then
    throw "session descriptor configuration hash must not be empty"
  validateWorkspaceBindings entry.workspaces

def readRegistryAt (path : System.FilePath) : IO RegistryRead := do
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
        | .ok entry =>
            match validateSessionDescriptor entry with
            | .ok () => pure <| .current entry
            | .error err => pure <| .malformed s!"invalid registry schema: {err}"
        | .error err => pure <| .malformed s!"invalid registry schema: {err}"
  catch err =>
    pure <| .malformed s!"could not read registry: {err}"

def readRegistry (root : System.FilePath) : IO RegistryRead := do
  readRegistryAt (← registryPath root)

end Beam.Daemon
