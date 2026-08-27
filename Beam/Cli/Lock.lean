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

private def lockTimeoutMessage
    (lockPath : System.FilePath)
    (waitedMs timeoutMs : Nat) : String :=
  s!"timed out after {waitedMs} ms waiting for Beam lock {lockPath}; " ++
    s!"timeout: {timeoutMs} ms"

/--
Open the stable file whose kernel lock protects one Beam critical section.

The file is deliberately retained after unlock. Removing a lock file would let a later contender
lock a new inode while an earlier waiter still holds or waits on the old one.
-/
private def openLockHandle (lockPath : System.FilePath) : IO IO.FS.Handle := do
  if let some parent := lockPath.parent then
    IO.FS.createDirAll parent
  IO.FS.Handle.mk lockPath .append

/-- Open a lock without creating a missing parent directory during teardown. -/
private def openExistingLockHandle (lockPath : System.FilePath) : IO IO.FS.Handle := do
  IO.FS.Handle.mk lockPath .readWrite

private partial def acquireLockUntil
    (handle : IO.FS.Handle)
    (lockPath : System.FilePath)
    (deadline : LockDeadline) : IO Unit := do
  if ← handle.tryLock then
    return
  let now ← IO.monoNanosNow
  if now >= deadline.deadlineNanos then
    let waitedMs := (now - deadline.startedNanos) / 1000000
    throw <| IO.userError <|
      lockTimeoutMessage lockPath waitedMs deadline.timeoutMs
  IO.sleep lockPollMs.toUInt32
  acquireLockUntil handle lockPath deadline

/-- Run `act` while holding an unbounded kernel-backed file lock. -/
def withLock (lockPath : System.FilePath) (act : IO α) : IO α := do
  let handle ← openLockHandle lockPath
  handle.lock
  try
    act
  finally
    handle.unlock

/-- Run `act` while holding a kernel-backed file lock until an absolute monotonic deadline. -/
def withLockTimeout (lockPath : System.FilePath) (timeoutMs : Nat) (act : IO α) : IO α := do
  let handle ← openLockHandle lockPath
  let startedNanos ← IO.monoNanosNow
  acquireLockUntil handle lockPath {
    timeoutMs
    startedNanos
    deadlineNanos := startedNanos + timeoutMs * 1000000
  }
  try
    act
  finally
    handle.unlock

/--
Run `act` under a kernel-backed lock without creating the lock's parent directory.

This is reserved for teardown after an owned project root may have disappeared.
-/
def withExistingLockTimeout
    (lockPath : System.FilePath)
    (timeoutMs : Nat)
    (act : IO α) : IO α := do
  let handle ← openExistingLockHandle lockPath
  let startedNanos ← IO.monoNanosNow
  acquireLockUntil handle lockPath {
    timeoutMs
    startedNanos
    deadlineNanos := startedNanos + timeoutMs * 1000000
  }
  try
    act
  finally
    handle.unlock

end Beam.Cli
