/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Mcp.Stdio

/-- Whether writing failed because the output resource has disappeared, including POSIX `EPIPE`. -/
def isClosedOutputError : IO.Error → Bool
  | .resourceVanished _ _ => true
  | _ => false

def stripLineEnding (line : String) : String :=
  let line :=
    if !line.isEmpty && line.back == '\n' then
      line.dropEnd 1 |>.copy
    else
      line
  if !line.isEmpty && line.back == '\r' then
    line.dropEnd 1 |>.copy
  else
    line

def writeJsonLineToHandle (handle : IO.FS.Handle) (json : Json) : IO Unit := do
  handle.putStr (json.compress ++ "\n")
  handle.flush

end Beam.Mcp.Stdio
