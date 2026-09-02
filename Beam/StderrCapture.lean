/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.System
import Std.Sync.Mutex

namespace Beam

/-- A best-effort stderr sink returns whether it should receive another chunk. -/
abbrev StderrSink := ByteArray → IO Bool

/-- The bounded result of releasing an owned stderr capture. -/
inductive StderrCaptureOutcome where
  /-- The writer exited and the source reached EOF. -/
  | drained
  /-- The source stopped with an I/O error after the writer exited. -/
  | sourceFailed (error : IO.Error)
  /-- The writer, or another process holding its pipe, could not be proven gone. -/
  | writerUnreaped

private structure StderrSinkState where
  sink? : Option StderrSink
  failure? : Option IO.Error := none

/--
One owned stderr drain. Source failures remain task failures; sink failures are recorded and disable
only that sink, so a broken evidence file can never stop the pipe drain and deadlock its child.
-/
structure StderrCapture where
  private tail : Std.Mutex ByteArray
  private sinkState : Std.Mutex StderrSinkState
  private drainTask : Task (Except IO.Error Unit)

private def isUtf8ContinuationByte (byte : UInt8) : Bool :=
  decide (128 ≤ byte.toNat ∧ byte.toNat < 192)

private def utf8BoundaryAtOrAfter (bytes : ByteArray) (offset : Nat) : Nat :=
  let rec loop (offset : Nat) : Nat → Nat
    | 0 => offset
    | fuel + 1 =>
        if h : offset < bytes.size then
          if isUtf8ContinuationByte bytes[offset] then
            loop (offset + 1) fuel
          else
            offset
        else
          offset
  loop offset 3

private def appendBoundedTail
    (tail : Std.Mutex ByteArray)
    (limit : Nat)
    (chunk : ByteArray) : IO Unit := do
  tail.atomically do
    let combined := (← get) ++ chunk
    if combined.size > limit then
      let start := utf8BoundaryAtOrAfter combined (combined.size - limit)
      set <| combined.extract start combined.size
    else
      set combined

private partial def drainStderr
    (source : IO.FS.Handle)
    (tail : Std.Mutex ByteArray)
    (tailLimit : Nat)
    (sinkState : Std.Mutex StderrSinkState) : IO Unit := do
  let chunk ← source.read 8192
  unless chunk.isEmpty do
    appendBoundedTail tail tailLimit chunk
    sinkState.atomically do
      let state ← get
      if let some sink := state.sink? then
        try
          unless ← sink chunk do
            set { state with sink? := none }
        catch err =>
          set { state with
            sink? := none
            failure? := state.failure? <|> some err
          }
    drainStderr source tail tailLimit sinkState

def StderrCapture.start
    (source : IO.FS.Handle)
    (tailLimit : Nat)
    (sink? : Option StderrSink := none) : IO StderrCapture := do
  let tail ← Std.Mutex.new ByteArray.empty
  let sinkState ← Std.Mutex.new ({ sink? } : StderrSinkState)
  let drainTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    drainStderr source tail tailLimit sinkState
  pure { tail, sinkState, drainTask }

def StderrCapture.snapshot (capture : StderrCapture) : IO String := do
  let bytes ← capture.tail.atomically get
  pure <| (String.fromUTF8? bytes).getD "<stderr tail is not valid UTF-8>"

/--
Stop persisting stderr and wait for any write already in progress. The returned failure is stable:
no later sink write can begin after this operation returns.
-/
def StderrCapture.disableSinkAndAwaitCurrentWrite
    (capture : StderrCapture) : IO (Option IO.Error) :=
  capture.sinkState.atomically do
    let state ← get
    set { state with sink? := none }
    pure state.failure?

/--
Finish a capture after its writer has been reaped. This operation never tries to cancel the blocking
pipe read: Lean task cancellation cannot interrupt the synchronous `Handle.read`. If EOF is not
observed within the bound, a descendant still owns the pipe (or writer exit was misclassified), so
the caller receives `writerUnreaped` instead of waiting indefinitely.
-/
def StderrCapture.finishAfterWriterExit
    (capture : StderrCapture)
    (timeoutMs : Nat := 1000) : IO StderrCaptureOutcome := do
  match ← Beam.waitTaskWithTimeout capture.drainTask timeoutMs with
  | some (.ok ()) => pure .drained
  | some (.error err) => pure <| .sourceFailed err
  | none => pure .writerUnreaped

end Beam
