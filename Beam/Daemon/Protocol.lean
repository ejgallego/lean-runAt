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

private def daemonProbeResponseTimeoutMs : Nat :=
  2000

private def daemonProbeOfResponse (resp : Response) : Except BrokerClientFailure DaemonProbe := do
  unless resp.ok do
    throw <| .invalidResponse s!"Beam daemon stats probe failed: {(toJson resp).compress}"
  let some result := resp.result?
    | throw <| .invalidResponse "Beam daemon stats probe omitted its result"
  let root ←
    match result.getObjValAs? String "root" with
    | .ok root => pure root
    | .error err => throw <| .invalidResponse s!"invalid Beam daemon stats root: {err}"
  let identity? ←
    match result.getObjVal? "daemonIdentity" with
    | .error _ => pure none
    | .ok identityJson =>
        match fromJson? identityJson with
        | .ok identity => pure (some identity)
        | .error err =>
            throw <| .invalidResponse s!"invalid Beam daemon identity: {err}"
  pure { root, identity? }

private def daemonProbe
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId) : IO (Except BrokerClientFailure DaemonProbe) := do
  match ← sendRequestWithStreamTimeoutResult endpoint
      { op := .stats, workspaceId? := some workspaceId }
      daemonProbeResponseTimeoutMs (fun _ => pure ()) with
  | .ok resp => pure <| daemonProbeOfResponse resp
  | .error failure => pure <| .error failure

def daemonRootResult
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId) : IO (Except BrokerClientFailure String) := do
  pure <| (← daemonProbe endpoint workspaceId).map (·.root)

def endpointOccupancyError
    (endpoint : Transport.Endpoint)
    (daemonRoot requestedRoot : System.FilePath) : String :=
  s!"selected endpoint {endpointSummary endpoint} already serves Beam root {daemonRoot}, not {requestedRoot}"

def endpointInUseError (endpoint : Transport.Endpoint) : String :=
  s!"selected endpoint {endpointSummary endpoint} is already in use"

def endpointGenerationMismatchError
    (endpoint : Transport.Endpoint)
    (daemonRoot : System.FilePath) : String :=
  s!"selected endpoint {endpointSummary endpoint} already serves Beam root {daemonRoot} " ++
    "with another daemon generation"

def endpointProtocolError (endpoint : Transport.Endpoint) (detail : String) : String :=
  s!"selected endpoint {endpointSummary endpoint} did not return a valid Beam daemon response: {detail}"

def startupLogSuggestsEndpointInUse (logText : String) : Bool :=
  logText.contains "address already in use" ||
  logText.contains "Address already in use"

def shouldRetryAutomaticStartup
    (usesAutomaticEndpoint : Bool)
    (tries : Nat)
    (endpointOccupied startupAddressInUse : Bool) : Bool :=
  usesAutomaticEndpoint && tries > 0 && (endpointOccupied || startupAddressInUse)

def endpointAcceptsConnection (endpoint : Transport.Endpoint) : IO Bool := do
  try
    let conn ← Transport.connect endpoint
    Transport.closeConnection conn
    pure true
  catch _ =>
    pure false

inductive DaemonGenerationStatus where
  | unavailable
  | unrecognized (detail : String)
  | wrongRoot (daemonRoot : String)
  | wrongGeneration (daemonRoot : String)
  | exact
  deriving Repr

/-- Classify one endpoint observation against the expected root and wrapper daemon generation. -/
def daemonGenerationStatus
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (identity : DaemonIdentity) : IO DaemonGenerationStatus := do
  match ← daemonProbe endpoint workspaceId with
  | .error failure =>
      match failure with
      | .transport _ =>
          if ← endpointAcceptsConnection endpoint then
            pure <| .unrecognized failure.detail
          else
            pure .unavailable
      | .invalidResponse _ | .streamCallback _ | .responseTimeout _ =>
          pure <| .unrecognized failure.detail
  | .ok probe =>
      unless ← Beam.sameFilePath (System.FilePath.mk probe.root) root do
        return .wrongRoot probe.root
      if probe.identity? == some identity then
        pure .exact
      else
        pure <| .wrongGeneration probe.root

end Beam.Daemon
