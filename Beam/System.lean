/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam

def trimLine (text : String) : String :=
  text.trimAscii.toString

def readCmdTrim (cmd : String) (args : Array String := #[]) (cwd? : Option System.FilePath := none) :
    IO String := do
  let out ← IO.Process.output {
    cmd
    args
    cwd := cwd?.map (·.toString)
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"command failed: {cmd} {String.intercalate " " args.toList}\n{out.stderr}"
  pure <| trimLine out.stdout

def commandAvailable (cmd : String) (args : Array String := #["--help"]) : IO Bool := do
  try
    let child ← IO.Process.spawn {
      cmd := cmd
      args := args
      stdin := .null
      stdout := .null
      stderr := .null
    }
    if (← child.tryWait).isNone then
      try
        child.kill
      catch _ =>
        pure ()
      try
        discard <| child.wait
      catch _ =>
        pure ()
    pure true
  catch _ =>
    pure false

def utcTimestamp : IO String := do
  readCmdTrim "date" #["-u", "+%Y-%m-%dT%H:%M:%SZ"]

end Beam
