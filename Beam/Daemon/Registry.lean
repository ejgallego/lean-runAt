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

/-- Why a present session descriptor cannot be decoded as the current schema. -/
inductive RegistryProblem where
  | missingSchema
  | unsupportedSchema (schemaVersion : Nat)
  | malformed (detail : String)

def RegistryProblem.detail : RegistryProblem → String
  | .missingSchema => "session descriptor has no schemaVersion"
  | .unsupportedSchema version => s!"unsupported session descriptor schemaVersion {version}"
  | .malformed detail => detail

/-- Typed result of reading the versioned on-disk session descriptor. -/
inductive RegistryRead where
  | absent
  | invalid (problem : RegistryProblem)
  | current (entry : SessionDescriptor)

def RegistryRead.entry? : RegistryRead → Option SessionDescriptor
  | .current entry => some entry
  | .absent | .invalid _ => none

def RegistryRead.status : RegistryRead → String
  | .absent => "absent"
  | .invalid _ => "invalid"
  | .current _ => "current"

def RegistryRead.detail? : RegistryRead → Option String
  | .invalid problem => some problem.detail
  | .absent | .current _ => none

private def validateWorkspaceBinding (workspace : WorkspaceBinding) : Except String Unit := do
  if workspace.workspaceId.isEmpty then
    throw "session workspace id must not be empty"
  if workspace.root.isEmpty then
    throw s!"session workspace '{workspace.workspaceId}' has an empty root"
  let rootPath := System.FilePath.mk workspace.root
  unless rootPath.isAbsolute do
    throw s!"session workspace '{workspace.workspaceId}' root is not absolute"
  if let some leanCmd := workspace.leanCmd? then
    if leanCmd.isEmpty then
      throw s!"session workspace '{workspace.workspaceId}' Lean command must not be empty"
  if let some plugin := workspace.plugin? then
    if plugin.isEmpty then
      throw s!"session workspace '{workspace.workspaceId}' Lean plugin must not be empty"
  if let some rocqCmd := workspace.rocqCmd? then
    if rocqCmd.isEmpty then
      throw s!"session workspace '{workspace.workspaceId}' Rocq command must not be empty"
  if let some toolchain := workspace.toolchain? then
    if toolchain.isEmpty then
      throw s!"session workspace '{workspace.workspaceId}' Lean toolchain must not be empty"
  if workspace.leanCmd?.isSome != workspace.plugin?.isSome then
    throw s!"session workspace '{workspace.workspaceId}' must configure the Lean command and plugin together"
  if workspace.leanCmd?.isNone && workspace.rocqCmd?.isNone then
    throw s!"session workspace '{workspace.workspaceId}' must configure at least one backend"
  if workspace.toolchain?.isSome && workspace.leanCmd?.isNone then
    throw s!"session workspace '{workspace.workspaceId}' cannot name a Lean toolchain without a Lean backend"
  if workspace.bundleId.isEmpty then
    throw s!"session workspace '{workspace.workspaceId}' bundle id must not be empty"
private def validateSessionDescriptor (entry : SessionDescriptor) : Except String Unit := do
  if entry.daemonId.isEmpty then
    throw "session descriptor daemonId must not be empty"
  if entry.capability.isEmpty then
    throw "session descriptor capability must not be empty"
  if entry.configHash.isEmpty then
    throw "session descriptor configuration hash must not be empty"
  if entry.daemonBin.isEmpty then
    throw "session descriptor daemon binary must not be empty"
  if entry.port == 0 then
    throw "session descriptor port must be in range 1-65535"
  validateWorkspaceBinding entry.workspace

def readRegistryAt (path : System.FilePath) : IO RegistryRead := do
  unless ← path.pathExists do
    return .absent
  try
    let text ← IO.FS.readFile path
    let json ←
      match Json.parse text with
      | .ok json => pure json
      | .error err => return .invalid <| .malformed s!"invalid registry JSON: {err}"
    match json.getObjVal? "schemaVersion" with
    | .error _ => pure <| .invalid .missingSchema
    | .ok schemaJson =>
        let schemaVersion ←
          match fromJson? (α := Nat) schemaJson with
          | .ok schemaVersion => pure schemaVersion
          | .error err => return .invalid <| .malformed s!"invalid registry schemaVersion: {err}"
        unless schemaVersion == registrySchemaVersion do
          return .invalid <| .unsupportedSchema schemaVersion
        match fromJson? json with
        | .ok entry =>
            match validateSessionDescriptor entry with
            | .ok () => pure <| .current entry
            | .error err => pure <| .invalid <| .malformed s!"invalid registry schema: {err}"
        | .error err => pure <| .invalid <| .malformed s!"invalid registry schema: {err}"
  catch err =>
    pure <| .invalid <| .malformed s!"could not read registry: {err}"

def readRegistry (root : System.FilePath) : IO RegistryRead := do
  readRegistryAt (← registryPath root)

end Beam.Daemon
