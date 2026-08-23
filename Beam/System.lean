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

private def killCommand : IO String := do
  let candidates := [System.FilePath.mk "/bin/kill", System.FilePath.mk "/usr/bin/kill"]
  for candidate in candidates do
    if ← candidate.pathExists then
      return candidate.toString
  if ← commandAvailable "kill" #["-l"] then
    pure "kill"
  else
    throw <| IO.userError "could not find kill command"

/--
Test a PID already known to belong to the caller's process domain.

For PIDs loaded from registries, locks, or other persisted metadata, use `RecordedPid.observe`
instead so a numeric PID from another domain is never probed locally.
-/
private def localPidAlive (pid : Nat) : IO Bool := do
  let out ← IO.Process.output { cmd := (← killCommand), args := #["-0", toString pid] }
  pure (out.exitCode == 0)

/-- Inspect zombie state for a PID already known to belong to the caller's process domain. -/
private def localPidZombie (pid : Nat) : IO Bool := do
  try
    let out ← IO.Process.output {
      cmd := "ps"
      args := #["-o", "stat=", "-p", toString pid]
      stdin := .null
      stderr := .null
    }
    pure <| out.exitCode == 0 && (trimLine out.stdout).startsWith "Z"
  catch _ =>
    pure false

def currentPidDomain? : IO (Option String) := do
  try
    let domain ← readCmdTrim "readlink" #["/proc/self/ns/pid"]
    pure <| if domain.isEmpty then none else some domain
  catch _ =>
    try
      let system ← readCmdTrim "uname" #["-s"]
      -- Darwin has no PID namespaces. A stable host-domain marker lets two processes on the same
      -- supported platform compare PID observations without weakening Linux's fail-closed fallback
      -- when `/proc` namespace identity is unexpectedly unavailable.
      pure <| if system == "Darwin" then some "host:Darwin" else none
    catch _ =>
      pure none

/-- A PID loaded together with the process-domain identity recorded by its owner. -/
structure RecordedPid where
  pid : Nat
  domain? : Option String
  deriving BEq, Repr

/-- The only safe outcomes of observing a PID loaded from persisted metadata. -/
inductive RecordedPidObservation where
  | invalid
  | local (alive : Bool)
  | differentDomain
  | unknownDomain
  deriving BEq, Repr

private inductive RecordedPidDomainRelation where
  | invalid
  | local
  | different
  | unknown

private def RecordedPid.domainRelation (recorded : RecordedPid) : IO RecordedPidDomainRelation := do
  if recorded.pid == 0 then
    return .invalid
  match ← currentPidDomain?, recorded.domain? with
  | some current, some owner =>
      pure <| if current == owner then .local else .different
  | _, _ =>
      pure .unknown

/--
Observe a persisted PID only when its recorded process domain matches the caller's current domain.
Different and unknown domains never reach the local PID probe.
-/
def RecordedPid.observe (recorded : RecordedPid) : IO RecordedPidObservation := do
  match ← recorded.domainRelation with
  | .invalid => pure .invalid
  | .local => pure <| .local (← localPidAlive recorded.pid)
  | .different => pure .differentDomain
  | .unknown => pure .unknownDomain

/-- Return zombie state only when a persisted PID belongs to the caller's current process domain. -/
def RecordedPid.zombieIfLocal? (recorded : RecordedPid) : IO (Option Bool) := do
  match ← recorded.domainRelation with
  | .local => some <$> localPidZombie recorded.pid
  | .invalid | .different | .unknown => pure none

/-- Send the default termination signal only to a persisted PID in the caller's current domain. -/
def RecordedPid.terminateIfLocal (recorded : RecordedPid) : IO Bool := do
  match ← recorded.domainRelation with
  | .local =>
      try
        let out ← IO.Process.output { cmd := (← killCommand), args := #[toString recorded.pid] }
        pure (out.exitCode == 0)
      catch _ =>
        pure false
  | .invalid | .different | .unknown => pure false

def utcTimestamp : IO String := do
  readCmdTrim "date" #["-u", "+%Y-%m-%dT%H:%M:%SZ"]

end Beam
