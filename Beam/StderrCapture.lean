/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Std.Sync.Mutex

namespace Beam

/-- A best-effort stderr sink returns whether it should receive another chunk. -/
abbrev StderrSink := ByteArray → IO Bool

/--
One owned stderr drain. Source failures remain task failures; sink failures are recorded and disable
only that sink, so a broken evidence file can never stop the pipe drain and deadlock its child.
-/
structure StderrCapture where
  private tail : Std.Mutex ByteArray
  private sinkRef : IO.Ref (Option StderrSink)
  private sinkFailureRef : IO.Ref (Option IO.Error)
  drainTask : Task (Except IO.Error Unit)

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
    (sinkRef : IO.Ref (Option StderrSink))
    (sinkFailureRef : IO.Ref (Option IO.Error)) : IO Unit := do
  let chunk ← source.read 8192
  unless chunk.isEmpty do
    appendBoundedTail tail tailLimit chunk
    if let some sink ← sinkRef.get then
      try
        unless ← sink chunk do
          sinkRef.set none
      catch err =>
        if (← sinkFailureRef.get).isNone then
          sinkFailureRef.set (some err)
        sinkRef.set none
    drainStderr source tail tailLimit sinkRef sinkFailureRef

def StderrCapture.start
    (source : IO.FS.Handle)
    (tailLimit : Nat)
    (sink? : Option StderrSink := none) : IO StderrCapture := do
  let tail ← Std.Mutex.new ByteArray.empty
  let sinkRef ← IO.mkRef sink?
  let sinkFailureRef ← IO.mkRef (none : Option IO.Error)
  let drainTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    drainStderr source tail tailLimit sinkRef sinkFailureRef
  pure { tail, sinkRef, sinkFailureRef, drainTask }

def StderrCapture.snapshot (capture : StderrCapture) : IO String := do
  let bytes ← capture.tail.atomically get
  pure <| (String.fromUTF8? bytes).getD "<stderr tail is not valid UTF-8>"

def StderrCapture.sinkFailure? (capture : StderrCapture) : IO (Option IO.Error) :=
  capture.sinkFailureRef.get

/-- Stop persisting stderr while leaving its source drain and bounded in-memory tail active. -/
def StderrCapture.disableSink (capture : StderrCapture) : IO Unit :=
  capture.sinkRef.set none

end Beam
