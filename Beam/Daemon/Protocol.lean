/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path
import Beam.Broker.Client
import Beam.Broker.Transport

open Lean

namespace Beam.Daemon

open Beam.Broker

structure RegistryEntry where
  daemonId : String
  pid : Nat
  pidDomain? : Option String := none
  ownerPid : Nat
  ownerPidDomain? : Option String := none
  port? : Option Nat := none
  root : String
  configHash : String
  leanCmd? : Option String := none
  plugin? : Option String := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  clientBin? : Option String := none
  daemonBin? : Option String := none
  bundleId? : Option String := none
  startedAt : String
  requestedPort? : Option Nat := none
  deriving FromJson, ToJson

def RegistryEntry.identity (entry : RegistryEntry) : DaemonIdentity := {
  daemonId := entry.daemonId
  configHash := entry.configHash
}

structure DesiredConfig where
  root : System.FilePath
  leanCmd? : Option String := none
  plugin? : Option System.FilePath := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  daemonBin : System.FilePath
  clientBin : System.FilePath
  bundleId : String
  configHash : String
  deriving Repr

def natToPort? (n : Nat) : Option UInt16 :=
  if n < UInt16.size then some n.toUInt16 else none

def registryEndpoint? (entry : RegistryEntry) : Option Transport.Endpoint := do
  (natToPort? =<< entry.port?).map Transport.Endpoint.tcp

def endpointFromEntry (entry : RegistryEntry) : IO Transport.Endpoint := do
  match registryEndpoint? entry with
  | some endpoint => pure endpoint
  | none => throw <| IO.userError s!"invalid Beam daemon transport data in registry for {entry.root}"

def endpointSummary (endpoint : Transport.Endpoint) : String :=
  Transport.endpointDescription endpoint

private structure DaemonProbe where
  root : String
  identity? : Option DaemonIdentity

private def daemonProbeOfResponse? (resp : Response) : Option DaemonProbe := do
  let result ← resp.result?
  let root ← result.getObjValAs? String "root" |>.toOption
  let identity? := result.getObjValAs? DaemonIdentity "daemonIdentity" |>.toOption
  pure { root, identity? }

private def daemonProbe?
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId) : IO (Option DaemonProbe) := do
  try
    let resp ← sendRequest endpoint { op := .stats, workspaceId? := some workspaceId }
    if resp.ok then
      pure (daemonProbeOfResponse? resp)
    else
      pure none
  catch _ =>
    pure none

def daemonRoot?
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId) : IO (Option String) := do
  pure <| (← daemonProbe? endpoint workspaceId).map (·.root)

def endpointOccupancyError
    (endpoint : Transport.Endpoint)
    (daemonRoot requestedRoot : System.FilePath) : String :=
  s!"selected endpoint {endpointSummary endpoint} already serves Beam root {daemonRoot}, not {requestedRoot}"

def endpointInUseError (endpoint : Transport.Endpoint) : String :=
  s!"selected endpoint {endpointSummary endpoint} is already in use"

def startupLogSuggestsEndpointInUse (logText : String) : Bool :=
  logText.contains "address already in use" ||
  logText.contains "Address already in use"

def shouldRetryAutomaticStartup
    (usesAutomaticEndpoint : Bool)
    (tries : Nat)
    (endpointOccupied startupAddressInUse : Bool) : Bool :=
  usesAutomaticEndpoint && tries > 0 && (endpointOccupied || startupAddressInUse)

-- A listening TCP port is not enough evidence that it belongs to this project:
-- random auto-port selection can collide with an unrelated Beam daemon.
def daemonServesRoot
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath) : IO Bool := do
  match ← daemonRoot? endpoint workspaceId with
  | some daemonRoot => Beam.sameFilePath (System.FilePath.mk daemonRoot) root
  | none => pure false

/-- Whether an endpoint serves the expected root and exact wrapper-owned daemon generation. -/
def daemonServesGeneration
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (identity : DaemonIdentity) : IO Bool := do
  match ← daemonProbe? endpoint workspaceId with
  | some probe =>
      if probe.identity? != some identity then
        pure false
      else
        Beam.sameFilePath (System.FilePath.mk probe.root) root
  | none => pure false

def endpointAcceptsConnection (endpoint : Transport.Endpoint) : IO Bool := do
  try
    let conn ← Transport.connect endpoint
    Transport.closeConnection conn
    pure true
  catch _ =>
    pure false

end Beam.Daemon
