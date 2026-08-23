/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.System

open Lean

namespace Beam.Daemon.Ownership

/-- Internal on-disk metadata for one wrapper's daemon-lifetime lease. -/
structure WrapperLeaseMetadata where
  pid : Nat
  pidDomain? : Option String := none
  heartbeatMonoNanos : Nat
  deriving FromJson, ToJson

/-- Persistent evidence that an expired lease basename may no longer be renewed or used. -/
structure WrapperLeaseRevocation where
  revokedMonoNanos : Nat
  deriving ToJson

private def wrapperLeaseHeartbeatExpired
    (now heartbeat timeout : Nat) : Bool :=
  now < heartbeat || now - heartbeat > timeout

/-- Pure lease-staleness policy, separated from PID and clock observation. -/
def wrapperLeaseStaleFromObservation
    (pidObservation : Beam.RecordedPidObservation)
    (now timeout : Nat)
    (metadata : WrapperLeaseMetadata) : Bool :=
  metadata.pid == 0 ||
    wrapperLeaseHeartbeatExpired now metadata.heartbeatMonoNanos timeout ||
    match pidObservation with
    | .invalid => true
    | .local alive => !alive
    | .differentDomain | .unknownDomain => false

/-- Retirement markers may refer only to one lease basename inside `wrapper-leases`. -/
def validWrapperLeaseFileName (name : String) : Bool :=
  !name.isEmpty &&
    name.endsWith ".lease" &&
    !(name.contains '/') &&
    !(name.contains '\\')

/-- The tombstone paired with one wrapper lease path. -/
def wrapperLeaseRevocationPath (path : System.FilePath) : System.FilePath :=
  path.withExtension "revoked"

/-- Conservative summary of every lease other than the starter's own lease. -/
inductive OtherWrapperLeasesObservation where
  | drained
  | activeOrUnreadable
  deriving BEq, Repr

/-- Whether the daemon still owns broker requests admitted before retirement fencing. -/
inductive DaemonRequestsObservation where
  | drained
  | activeOrUnreadable
  | provenGone
  deriving BEq, Repr

/-- Typed input to the retirement policy. Replacement generations need no sibling inspection. -/
inductive RetirementObservation where
  | current
      (otherLeases : OtherWrapperLeasesObservation)
      (daemonRequests : DaemonRequestsObservation)
  | replacement
  | unavailable (otherLeases : OtherWrapperLeasesObservation)
  deriving BEq, Repr

inductive RetirementDecision where
  | wait
  | commit
  | obsolete
  deriving BEq, Repr

/--
Decide the starter's next step without performing filesystem mutations.

A proven replacement or a provably dead current daemon makes the starter obsolete immediately,
avoiding a generation-to-generation lease deadlock. A live current generation commits retirement
only after both sibling leases and admitted broker requests drain. Missing, malformed, or unreadable
registry state can release the starter only after all sibling leases are provably drained.
-/
def retirementDecision
    (observation : RetirementObservation) : RetirementDecision :=
  match observation with
  | .replacement => .obsolete
  | .current others requests =>
      match others, requests with
      | .drained, .drained => .commit
      | .drained, .provenGone => .obsolete
      | _, _ => .wait
  | .unavailable others =>
      match others with
      | .drained => .obsolete
      | .activeOrUnreadable => .wait

end Beam.Daemon.Ownership
