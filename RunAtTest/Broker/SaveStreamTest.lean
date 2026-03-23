/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import RunAtTest.Broker.TestUtil
import Lean

open Lean

namespace RunAtTest.Broker.SaveStreamTest

open RunAtTest.Broker.TestUtil

private def expectNoTrackedLeanDoc (payload : Json) (path : String) : IO Unit := do
  let sessions ← IO.ofExcept <| payload.getObjVal? "sessions"
  let leanSession ← IO.ofExcept <| sessions.getObjVal? "lean"
  let files ← IO.ofExcept <| leanSession.getObjVal? "files"
  let .arr files := files
    | throw <| IO.userError s!"expected open_docs lean.files array, got {files.compress}"
  for file in files do
    let trackedPath ← IO.ofExcept <| file.getObjValAs? String "path"
    if trackedPath == path then
      throw <| IO.userError s!"expected {path} to be closed, but it is still tracked in {(toJson files).compress}"

def main : IO Unit := do
  let port : UInt16 := ((← IO.monoNanosNow) % 20000 + 30000).toUInt16
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-daemon-save-stream"
  copySaveProjectFixture root
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReady endpoint
    discard <| expectOk (← runClient endpoint { op := .ensure, root? := some root.toString })

    writeSaveWarningFile root "-- default warning-only save"
    let (defaultResp, defaultProgress, defaultDiagnostics) ← runClientWithStream endpoint {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
    }
    let defaultPayload ← expectOk defaultResp
    expectNoReplayDiagnosticsField "default save_olean" defaultPayload
    let defaultVersion ← IO.ofExcept <| defaultPayload.getObjValAs? Nat "version"
    if defaultVersion != 1 then
      throw <| IO.userError s!"expected default save_olean version 1, got {defaultVersion}"
    let defaultTop := ← requireFileProgress "default save_olean" defaultResp
    if !defaultTop.done then
      throw <| IO.userError s!"expected default save_olean top-level fileProgress.done = true, got {(toJson defaultTop).compress}"
    let some defaultLast := defaultProgress.back?
      | throw <| IO.userError "expected default save_olean to stream fileProgress events"
    if !defaultLast.done then
      throw <| IO.userError s!"expected default save_olean streamed progress to finish, got {(toJson defaultLast).compress}"
    unless defaultDiagnostics.isEmpty do
      throw <| IO.userError s!"expected default save_olean to suppress warning diagnostics, got {(toJson defaultDiagnostics).compress}"

    writeSaveWarningFile root "-- full warning-only save"
    let (fullResp, fullProgress, fullDiagnostics) ← runClientWithStream endpoint {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      fullDiagnostics? := some true
    }
    let fullPayload ← expectOk fullResp
    expectNoReplayDiagnosticsField "full save_olean" fullPayload
    let fullVersion ← IO.ofExcept <| fullPayload.getObjValAs? Nat "version"
    if fullVersion != 2 then
      throw <| IO.userError s!"expected full save_olean version 2 after a fresh edit, got {fullVersion}"
    let fullTop := ← requireFileProgress "full save_olean" fullResp
    if !fullTop.done then
      throw <| IO.userError s!"expected full save_olean top-level fileProgress.done = true, got {(toJson fullTop).compress}"
    let some fullLast := fullProgress.back?
      | throw <| IO.userError "expected full save_olean to stream fileProgress events"
    if !fullLast.done then
      throw <| IO.userError s!"expected full save_olean streamed progress to finish, got {(toJson fullLast).compress}"
    if fullDiagnostics.isEmpty then
      throw <| IO.userError "expected full save_olean to stream diagnostics"
    expectNonErrorDiagnosticsForPath "full save_olean" "SaveSmoke/B.lean" fullDiagnostics
    expectWarningDiagnosticPresent "full save_olean" fullDiagnostics

    let (repeatResp, repeatProgress, repeatDiagnostics) ← runClientWithStream endpoint {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      fullDiagnostics? := some true
    }
    let repeatPayload ← expectOk repeatResp
    expectNoReplayDiagnosticsField "unchanged full save_olean" repeatPayload
    let repeatVersion ← IO.ofExcept <| repeatPayload.getObjValAs? Nat "version"
    if repeatVersion != 2 then
      throw <| IO.userError s!"expected unchanged full save_olean version 2, got {repeatVersion}"
    let repeatTop := ← requireFileProgress "unchanged full save_olean" repeatResp
    if !repeatTop.done then
      throw <| IO.userError
        s!"expected unchanged full save_olean top-level fileProgress.done = true, got {(toJson repeatTop).compress}"
    if let some repeatLast := repeatProgress.back? then
      if !repeatLast.done then
        throw <| IO.userError
          s!"expected unchanged full save_olean streamed progress to finish, got {(toJson repeatLast).compress}"
    unless repeatDiagnostics.isEmpty do
      throw <| IO.userError
        s!"expected unchanged full save_olean to avoid replaying stale diagnostics, got {(toJson repeatDiagnostics).compress}"

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") <| String.intercalate "\n" [
      "def bVal : Nat := 1",
      "",
      "def brokenSave : Nat := \"oops\""
    ] ++ "\n"
    let (errorResp, _errorProgress, errorDiagnostics) ← runClientWithStream endpoint {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      fullDiagnostics? := some true
    }
    expectErrCode errorResp "invalidParams"
    let some error := errorResp.error?
      | throw <| IO.userError s!"expected save_olean error payload, got {(toJson errorResp).compress}"
    if !error.message.contains "cannot save artifacts for a document with errors;" then
      throw <| IO.userError
        s!"expected save_olean error to explain artifact rejection, got {error.message}"
    if !error.message.contains "diagnostics:" then
      throw <| IO.userError
        s!"expected save_olean error to include diagnostic details, got {error.message}"
    unless errorDiagnostics.any (fun diagnostic =>
      diagnostic.path == "SaveSmoke/B.lean" && diagnostic.severity? == some .error) do
      throw <| IO.userError
        s!"expected save_olean error stream to include an error diagnostic for SaveSmoke/B.lean, got {(toJson errorDiagnostics).compress}"

    writeSaveWarningFile root "-- full close-save"
    let (closeResp, closeProgress, closeDiagnostics) ← runClientWithStream endpoint {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      saveArtifacts? := some true
      fullDiagnostics? := some true
    }
    let closePayload ← expectOk closeResp
    expectNoReplayDiagnosticsField "full close-save" closePayload
    let closeClosed ← IO.ofExcept <| closePayload.getObjValAs? Bool "closed"
    if !closeClosed then
      throw <| IO.userError s!"expected close-save payload to report closed = true, got {closePayload.compress}"
    let savedPayload ← IO.ofExcept <| closePayload.getObjVal? "saved"
    let closeVersion ← IO.ofExcept <| savedPayload.getObjValAs? Nat "version"
    if closeVersion != 4 then
      throw <| IO.userError s!"expected close-save saved version 4 after a fresh edit, got {closeVersion}"
    let closeTop := ← requireFileProgress "full close-save" closeResp
    if !closeTop.done then
      throw <| IO.userError s!"expected full close-save top-level fileProgress.done = true, got {(toJson closeTop).compress}"
    let some closeLast := closeProgress.back?
      | throw <| IO.userError "expected full close-save to stream fileProgress events"
    if !closeLast.done then
      throw <| IO.userError
        s!"expected full close-save streamed progress to finish, got {(toJson closeLast).compress}"
    if closeDiagnostics.isEmpty then
      throw <| IO.userError "expected full close-save to stream diagnostics"
    expectNonErrorDiagnosticsForPath "full close-save" "SaveSmoke/B.lean" closeDiagnostics
    expectWarningDiagnosticPresent "full close-save" closeDiagnostics

    let openDocsPayload ← expectOk <| ← runClient endpoint {
      op := .openDocs
      root? := some root.toString
    }
    expectNoTrackedLeanDoc openDocsPayload "SaveSmoke/B.lean"

    discard <| expectOk (← runClient endpoint { op := .shutdown })
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

end RunAtTest.Broker.SaveStreamTest
