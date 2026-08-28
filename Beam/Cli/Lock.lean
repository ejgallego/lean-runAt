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

/-- Ensure the stable lock file can be opened without replacing its inode. -/
private def ensureLockParent (lockPath : System.FilePath) : IO Unit := do
  if let some parent := lockPath.parent then
    IO.FS.createDirAll parent

private def withAcquiredLock
    (lockPath : System.FilePath)
    (mode : IO.FS.Mode)
    (acquire : IO.FS.Handle → IO Unit)
    (act : IO α) : IO α := do
  IO.FS.withFile lockPath mode fun handle => do
    acquire handle
    try
      act
    finally
      handle.unlock

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
  ensureLockParent lockPath
  withAcquiredLock lockPath .append (·.lock) act

/-- Run `act` while holding a kernel-backed file lock until an absolute monotonic deadline. -/
def withLockTimeout (lockPath : System.FilePath) (timeoutMs : Nat) (act : IO α) : IO α := do
  ensureLockParent lockPath
  let startedNanos ← IO.monoNanosNow
  let deadline := {
    timeoutMs
    startedNanos
    deadlineNanos := startedNanos + timeoutMs * 1000000
  }
  withAcquiredLock lockPath .append (fun handle => acquireLockUntil handle lockPath deadline) act

/--
Run `act` under a kernel-backed lock without creating the lock's parent directory.

This is reserved for teardown after an owned project root may have disappeared.
-/
def withExistingLockTimeout
    (lockPath : System.FilePath)
    (timeoutMs : Nat)
    (act : IO α) : IO α := do
  let startedNanos ← IO.monoNanosNow
  let deadline := {
    timeoutMs
    startedNanos
    deadlineNanos := startedNanos + timeoutMs * 1000000
  }
  withAcquiredLock lockPath .readWrite (fun handle => acquireLockUntil handle lockPath deadline) act

end Beam.Cli
