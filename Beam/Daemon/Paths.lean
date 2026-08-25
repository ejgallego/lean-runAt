/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Daemon

private def beamStateDir (root : System.FilePath) : System.FilePath :=
  root / ".beam"

def controlDir (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_CONTROL_DIR" with
  | some dir =>
      let tag := toString (hash root.toString)
      pure (System.FilePath.mk dir / tag)
  | none =>
      pure (beamStateDir root)

def registryPath (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "beam-daemon.json")

def daemonStartupLogPath (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "beam-daemon-startup.log")

def daemonFailureIncidentDir (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "daemon-failures")

end Beam.Daemon
