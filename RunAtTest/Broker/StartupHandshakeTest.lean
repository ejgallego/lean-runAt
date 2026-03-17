/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Broker.TestUtil
import Lean

open Lean

namespace RunAtTest.Broker.StartupHandshakeTest

open RunAtTest.Broker.TestUtil

private def writeFakeServer (root : System.FilePath) : IO System.FilePath := do
  let script := root / "fake-lean-startup.sh"
  let body := String.intercalate "\n" [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "frame() {",
    "  local body=\"$1\"",
    "  printf 'Content-Length: %s\\r\\n\\r\\n%s' \"${#body}\" \"$body\"",
    "}",
    "notif='{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":4,\"message\":\"early startup message\"}}'",
    "err='{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32603,\"message\":\"initialize failed\"}}'",
    "frame \"$notif\"",
    "frame \"$err\"",
    "sleep 5"
  ] ++ "\n"
  IO.FS.writeFile script body
  let out ← IO.Process.output {
    cmd := "chmod"
    args := #["+x", script.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to chmod fake startup server\n{out.stderr}"
  pure script

def main : IO Unit := do
  let port : UInt16 := ((← IO.monoNanosNow) % 20000 + 30000).toUInt16
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-daemon-startup"
  IO.FS.createDirAll root
  let fakeServer ← writeFakeServer root
  let broker ← spawnLeanBrokerWithPlugin endpoint root (← RunAtTest.TestHarness.pluginPath) fakeServer.toString
  try
    IO.sleep 200
    let resp ← runClient endpoint { op := .ensure, root? := some root.toString }
    if resp.ok then
      throw <| IO.userError s!"expected startup handshake failure, got success {(toJson resp).compress}"
    let some err := resp.error?
      | throw <| IO.userError s!"expected startup handshake error payload, got {(toJson resp).compress}"
    if err.code != "internalError" then
      throw <| IO.userError s!"expected internalError for startup failure, got {(toJson resp).compress}"
    unless err.message.contains "initialize failed" do
      throw <| IO.userError s!"expected startup failure to mention initialize failure, got {(toJson resp).compress}"
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    discard <| broker.tryWait
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

end RunAtTest.Broker.StartupHandshakeTest
