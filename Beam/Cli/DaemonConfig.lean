/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.RuntimeBundle.Source
import Beam.Daemon.Protocol

open Lean

namespace Beam.Cli

open Beam.Broker

/-- The complete resolved configuration of a Lean backend in a wrapper-owned session. -/
structure LeanBackendConfig where
  command : String
  plugin : System.FilePath
  toolchain : String
  bundleId : String
  deriving Repr

/-- The complete temporary Rocq backend configuration in a wrapper-owned session. -/
structure RocqBackendConfig where
  command : String
  deriving Repr

/-- A nonempty set of complete backend configurations for one wrapper-owned workspace. -/
inductive BackendSet where
  /-- A Lean workspace may also expose the temporary Rocq backend. -/
  | lean (lean : LeanBackendConfig) (rocq? : Option RocqBackendConfig)
  /-- A Rocq-owned session uses only the temporary Rocq backend. -/
  | rocq (rocq : RocqBackendConfig)
  deriving Repr

namespace BackendSet

private def rocqOnlyDescriptorBundleId : String :=
  "default"

private def descriptorBundleId : BackendSet → String
  | .lean leanConfig _ => leanConfig.bundleId
  | .rocq _ => rocqOnlyDescriptorBundleId

/-- Lower a complete internal backend set into the private session descriptor wire shape. -/
def toWorkspaceBinding
    (backends : BackendSet)
    (workspaceId : WorkspaceId)
    (root : System.FilePath) : Beam.Daemon.WorkspaceBinding :=
  let common : Beam.Daemon.WorkspaceBinding := {
    workspaceId
    root := root.toString
    bundleId := backends.descriptorBundleId
  }
  match backends with
  | .lean leanConfig rocq? => {
      common with
      leanCmd? := some leanConfig.command
      plugin? := some leanConfig.plugin.toString
      rocqCmd? := rocq?.map (·.command)
      toolchain? := some leanConfig.toolchain
    }
  | .rocq rocqConfig => {
      common with
      rocqCmd? := some rocqConfig.command
    }

/-- Command-line arguments that install this complete backend set in a Beam daemon. -/
def daemonArgs : BackendSet → Array String
  | .lean leanConfig rocq? =>
      #["--lean-cmd", leanConfig.command, "--lean-plugin", leanConfig.plugin.toString] ++
        match rocq? with
        | some rocqConfig => #["--rocq-cmd", rocqConfig.command]
        | none => #[]
  | .rocq rocqConfig =>
      #["--rocq-cmd", rocqConfig.command]

private def hashFields
    (backends : BackendSet)
    (daemonBin : System.FilePath) : List String :=
  match backends with
  | .lean leanConfig rocq? =>
      [
        leanConfig.command,
        leanConfig.plugin.toString,
        rocq?.map (·.command) |>.getD "",
        daemonBin.toString,
        backends.descriptorBundleId
      ]
  | .rocq rocqConfig =>
      ["", "", rocqConfig.command, daemonBin.toString, backends.descriptorBundleId]

end BackendSet

/-- Source configuration for one wrapper-owned daemon generation. -/
structure DesiredConfig where
  root : System.FilePath
  backends : BackendSet
  daemonBin : System.FilePath
  deriving Repr

/-- Hash the complete desired configuration using the established wrapper session field order. -/
def DesiredConfig.configHash (config : DesiredConfig) : String :=
  let fields := config.root.toString :: config.backends.hashFields config.daemonBin
  let hash := fields.foldl mixField 14695981039346656037
  s!"{hash.toNat}"

end Beam.Cli
