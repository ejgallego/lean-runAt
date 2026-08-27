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

end Beam.Daemon
