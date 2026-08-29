/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace BeamTest.Broker.TestUtil

def repoRoot : IO System.FilePath := do
  IO.FS.realPath <| System.FilePath.mk "."

def mkTempProjectRoot (namePrefix : String) : IO System.FilePath := do
  pure <| System.FilePath.mk s!"/tmp/{namePrefix}-{← IO.monoNanosNow}"

def copySaveProjectFixture (dest : System.FilePath) : IO Unit := do
  let src := (← repoRoot) / "tests" / "save_olean_project"
  IO.FS.createDirAll dest
  let out ← IO.Process.output {
    cmd := "rsync"
    -- Local wrapper/install tests may leave an ignored runtime cache in this source fixture. It is
    -- neither fixture input nor safe to duplicate into every isolated broker test project.
    args := #["-a", "--exclude", ".beam/", s!"{src.toString}/", s!"{dest.toString}/"]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to copy save_olean_project fixture\n{out.stderr}"

def saveWarningFileText (marker : String) : String :=
  String.intercalate "\n" [
    "def bVal : Nat := 1",
    "",
    "set_option linter.unusedVariables true in",
    "theorem warnOnly (n : Nat) : True := by",
    "  trivial",
    "",
    marker
  ] ++ "\n"

def writeSaveWarningFile (root : System.FilePath) (marker : String) : IO Unit := do
  IO.FS.writeFile (root / "SaveSmoke" / "B.lean") (saveWarningFileText marker)

end BeamTest.Broker.TestUtil
