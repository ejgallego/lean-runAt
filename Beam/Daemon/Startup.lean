/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Daemon

def startupReadySchemaVersion : Nat :=
  1

/-- One typed message emitted after a wrapper daemon has bound its OS-assigned listener. -/
structure StartupReady where
  schemaVersion : Nat := startupReadySchemaVersion
  port : Nat
  identity : Beam.Broker.DaemonIdentity
  deriving FromJson, ToJson

end Beam.Daemon
