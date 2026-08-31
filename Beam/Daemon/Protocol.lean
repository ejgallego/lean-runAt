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

def registrySchemaVersion : Nat :=
  4

inductive RegistryLifecycle where
  | live
  | draining
  deriving BEq, Repr

instance : ToJson RegistryLifecycle where
  toJson
    | .live => "live"
    | .draining => "draining"

instance : FromJson RegistryLifecycle where
  fromJson?
    | .str "live" => .ok .live
    | .str "draining" => .ok .draining
    | json => .error s!"expected registry lifecycle 'live' or 'draining', got {json.compress}"

local instance : ToJson UInt16 where
  toJson port := toJson port.toNat

local instance : FromJson UInt16 where
  fromJson? json := do
    let port ← fromJson? (α := Nat) json
    if port < UInt16.size then
      pure port.toUInt16
    else
      throw s!"expected TCP port below {UInt16.size}, got {port}"

/-- One statically configured workspace owned by a CLI session. -/
structure WorkspaceBinding where
  workspaceId : WorkspaceId
  root : String
  leanCmd? : Option String := none
  plugin? : Option String := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  bundleId? : Option String := none
  deriving FromJson, ToJson

/--
The private descriptor for one wrapper-owned CLI session.

Wrapper sessions deliberately own exactly one workspace. Standalone broker and MCP runtimes retain
their independent multi-workspace models.
-/
structure SessionDescriptor where
  schemaVersion : Nat
  lifecycle : RegistryLifecycle
  daemonId : String
  capability : String
  pid : Nat
  ownerPid : Nat
  port : UInt16
  workspace : WorkspaceBinding
  /-- Hash of the complete frozen session configuration. -/
  configHash : String
  daemonBin? : Option String := none
  startedAt : String
  deriving FromJson, ToJson

def SessionDescriptor.identity (entry : SessionDescriptor) : DaemonIdentity := {
  daemonId := entry.daemonId
  configHash := entry.configHash
}

def SessionDescriptor.redactedJson (entry : SessionDescriptor) : Json :=
  (toJson entry).setObjVal! "capability" (toJson "<redacted>")

/-- Whether this single-workspace descriptor belongs to a canonical or equivalent project root. -/
def SessionDescriptor.matchesRoot
    (entry : SessionDescriptor)
    (root : System.FilePath) : IO Bool := do
  Beam.sameFilePath (System.FilePath.mk entry.workspace.root) root

structure DesiredConfig where
  root : System.FilePath
  leanCmd? : Option String := none
  plugin? : Option System.FilePath := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  daemonBin : System.FilePath
  bundleId : String
  configHash : String
  deriving Repr

def registryEndpoint (entry : SessionDescriptor) : Transport.Endpoint :=
  .tcp entry.port

def endpointSummary (endpoint : Transport.Endpoint) : String :=
  Transport.endpointDescription endpoint

private structure DaemonProbe where
  root : String
  identity? : Option DaemonIdentity

private def daemonProbeResponseTimeoutMs : Nat :=
  2000

private def daemonProbeOfResponse (resp : Response) : Except BrokerClientFailure DaemonProbe :=
  match resp with
  | .errorResult _ =>
      .error <| .invalidResponse s!"Beam daemon stats probe failed: {(toJson resp).compress}"
  | .successResult result _ => do
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
    (workspaceId : WorkspaceId)
    (capability? : Option String := none) : IO (Except BrokerClientFailure DaemonProbe) := do
  match ← sendRequestWithStreamTimeoutResult endpoint
      { op := .stats, workspaceId? := some workspaceId, daemonCapability? := capability? }
      daemonProbeResponseTimeoutMs (fun _ => pure ()) with
  | .ok resp => pure <| daemonProbeOfResponse resp
  | .error failure => pure <| .error failure

def endpointOccupancyError
    (endpoint : Transport.Endpoint)
    (daemonRoot requestedRoot : System.FilePath) : String :=
  s!"selected endpoint {endpointSummary endpoint} already serves Beam root {daemonRoot}, not {requestedRoot}"

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

def shouldRetryStartup
    (tries : Nat)
    (endpointOccupied startupAddressInUse : Bool) : Bool :=
  tries > 0 && (endpointOccupied || startupAddressInUse)

def endpointAcceptsConnection (endpoint : Transport.Endpoint) : IO Bool := do
  try
    let conn ← Transport.connect endpoint
    Transport.closeConnection conn
    pure true
  catch _ =>
    pure false

inductive DaemonGenerationStatus where
  | unavailable
  | unrecognized (failure : BrokerClientFailure)
  | wrongRoot (daemonRoot : String)
  | wrongGeneration (daemonRoot : String)
  | exact
  deriving Repr

/-- Classify one endpoint observation against the expected root and wrapper daemon generation. -/
def daemonGenerationStatus
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (identity : DaemonIdentity)
    (capability : String) : IO DaemonGenerationStatus := do
  match ← daemonProbe endpoint workspaceId (some capability) with
  | .error failure =>
      match failure with
      | .transport _ _ =>
          if ← endpointAcceptsConnection endpoint then
            pure <| .unrecognized failure
          else
            pure .unavailable
      | .invalidResponse _ | .streamCallback _ | .responseTimeout _ =>
          pure <| .unrecognized failure
  | .ok probe =>
      unless ← Beam.sameFilePath (System.FilePath.mk probe.root) root do
        return .wrongRoot probe.root
      if probe.identity? == some identity then
        pure .exact
      else
        pure <| .wrongGeneration probe.root

end Beam.Daemon
