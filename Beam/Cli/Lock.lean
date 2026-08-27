/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path
import Beam.System

open Lean

namespace Beam.Cli

private def lockPollMs : Nat :=
  100

private structure LockDeadline where
  timeoutMs : Nat
  startedNanos : Nat
  deadlineNanos : Nat

private structure LockOwner where
  pid : Nat
  pidDomain? : Option String

private def readRegularFile? (path : System.FilePath) : IO (Option String) := do
  try
    if ← Beam.regularNonSymlinkFile path then
      pure <| some (Beam.trimLine (← IO.FS.readFile path))
    else
      pure none
  catch _ =>
    pure none

private def readLockOwner? (lockDir : System.FilePath) : IO (Option LockOwner) := do
  let some pidText ← readRegularFile? (lockDir / "pid")
    | return none
  let some pid := pidText.toNat?
    | return none
  let pidDomain? ← readRegularFile? (lockDir / "pid-domain")
  pure <| some { pid, pidDomain? := pidDomain?.filter (fun domain => !domain.isEmpty) }

private def lockOwnerDescription : Option LockOwner → String
  | some owner => s!"pid {owner.pid}"
  | none => "unknown owner"

private def lockTimeoutMessage
    (lockDir : System.FilePath)
    (owner? : Option LockOwner)
    (waitedMs timeoutMs : Nat) : String :=
  s!"timed out after {waitedMs} ms waiting for Beam lock {lockDir}; " ++
    s!"lock owner: {lockOwnerDescription owner?}; timeout: {timeoutMs} ms"

private def removeStaleLock? (lockDir : System.FilePath) (owner? : Option LockOwner) : IO Bool := do
  match owner? with
  | some owner =>
      match ← (Beam.RecordedPid.mk owner.pid owner.pidDomain?).observe with
      | .local false =>
        if ← lockDir.pathExists then
          IO.FS.removeDirAll lockDir
        pure true
      | .invalid | .local true | .differentDomain | .unknownDomain => pure false
  | none =>
      pure false

private partial def acquireLockCore
    (lockDir : System.FilePath)
    (deadline? : Option LockDeadline) : IO Unit := do
  if let some parent := lockDir.parent then
    IO.FS.createDirAll parent
  let selfPid ← IO.Process.getPID
  let acquired ←
    try
      IO.FS.createDir lockDir
      pure true
    catch
    | .alreadyExists .. =>
      pure false
    | error =>
      throw error
  if acquired then
    try
      IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
      if let some pidDomain := ← Beam.currentPidDomain? then
        IO.FS.writeFile (lockDir / "pid-domain") s!"{pidDomain}\n"
      return
    catch error =>
      try
        if ← lockDir.pathExists then
          IO.FS.removeDirAll lockDir
      catch cleanupError =>
        throw <| IO.userError <|
          s!"failed to publish Beam lock owner at {lockDir}: {error}; " ++
            s!"also failed to remove the acquired lock: {cleanupError}"
      throw error
  else
    let owner? ← readLockOwner? lockDir
    if ← removeStaleLock? lockDir owner? then
      acquireLockCore lockDir deadline?
    else
      match deadline? with
      | some deadline =>
          let now ← IO.monoNanosNow
          if now >= deadline.deadlineNanos then
            let waitedMs := (now - deadline.startedNanos) / 1000000
            throw <| IO.userError <|
              lockTimeoutMessage lockDir owner? waitedMs deadline.timeoutMs
      | none =>
          pure ()
      IO.sleep lockPollMs.toUInt32
      acquireLockCore lockDir deadline?

private def acquireLock (lockDir : System.FilePath) : IO Unit :=
  acquireLockCore lockDir none

private def acquireLockTimeout (lockDir : System.FilePath) (timeoutMs : Nat) : IO Unit := do
  let startedNanos ← IO.monoNanosNow
  acquireLockCore lockDir <| some {
    timeoutMs
    startedNanos
    deadlineNanos := startedNanos + timeoutMs * 1000000
  }

private def releaseLock (lockDir : System.FilePath) : IO Unit := do
  if ← lockDir.pathExists then
    IO.FS.removeDirAll lockDir

/-- Run `act` while holding an unbounded directory lock. -/
def withLock (lockDir : System.FilePath) (act : IO α) : IO α := do
  acquireLock lockDir
  try
    act
  finally
    releaseLock lockDir

/-- Run `act` while holding a directory lock until an absolute monotonic deadline. -/
def withLockTimeout (lockDir : System.FilePath) (timeoutMs : Nat) (act : IO α) : IO α := do
  acquireLockTimeout lockDir timeoutMs
  try
    act
  finally
    releaseLock lockDir

end Beam.Cli
