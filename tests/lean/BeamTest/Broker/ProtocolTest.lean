/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.Readiness
import Beam.Broker.RequestArgs
import Beam.Broker.Server
import Beam.JsonPretty
import BeamTest.Broker.JsonAssert
import Lean

open Lean
open Lean.Lsp
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.ProtocolTest

private def decodeResponse (label : String) (json : Json) : IO Response := do
  match fromJson? json with
  | .ok resp => pure resp
  | .error err => throw <| IO.userError s!"{label}: failed to decode response: {err}"

private def expectDecodeFailure (α : Type) [FromJson α] [ToJson α]
    (label : String) (json : Json) : IO Unit := do
  match fromJson? (α := α) json with
  | .ok value =>
      throw <| IO.userError s!"{label}: expected decode failure, got {(toJson value).compress}"
  | .error _ =>
      pure ()

private def requireError
    (label : String)
    (expectedCode : String)
    (expectedMessage : String)
    (resp : Response) : IO Error := do
  match resp with
  | .successResult .. =>
      throw <| IO.userError s!"{label}: expected error response, got {(toJson resp).compress}"
  | .errorResult failure =>
      let err := failure.error
      if err.code != expectedCode then
        throw <| IO.userError s!"{label}: expected code={expectedCode}, got {(toJson resp).compress}"
      if err.message != expectedMessage then
        throw <| IO.userError s!"{label}: expected message={expectedMessage}, got {(toJson resp).compress}"
      pure err

private def requireResponseResult (label : String) (resp : Response) : IO Json := do
  match resp with
  | .successResult result .. => pure result
  | .errorResult .. =>
      throw <| IO.userError s!"{label}: expected result payload, got {(toJson resp).compress}"

private def requireErrorData (label : String) (err : Error) : IO Json := do
  match err.data? with
  | some data => pure data
  | none => throw <| IO.userError s!"{label}: expected error data, got {(toJson err).compress}"

private def expectRequestArgError
    (label : String)
    (expectedMessage : String)
    (result : Except ResponseFailure α) : IO Unit := do
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected invalidParams response"
  | .error failure =>
      discard <| requireError label "invalidParams" expectedMessage failure.toResponse

private def lspPos (line character : Nat) : Lsp.Position :=
  { line, character }

private def lspRange (line character endCharacter : Nat) : Lsp.Range :=
  { start := lspPos line character, «end» := lspPos line endCharacter }

private def diagnostic (severity : DiagnosticSeverity) (message : String) : Diagnostic :=
  let range := lspRange 0 0 1
  {
    range
    fullRange? := some range
    severity? := some severity
    message
  }

private def syncResultFor
    (version : Nat)
    (saveReady : Bool := true)
    (reason : String := "ok")
    (blockingErrorCount : Nat := 0)
    (warningCount : Nat := 0) : SyncFileResult := {
  path := "Demo.lean"
  version
  diagnostics := { counts := { warning := warningCount } }
  readiness := {
    saveReady
    reason
    blockingErrorCount
  }
}

private def syncDiagnosticCountsJson : Json :=
  Json.mkObj [
    ("error", toJson (0 : Nat)),
    ("warning", toJson (0 : Nat)),
    ("information", toJson (0 : Nat)),
    ("hint", toJson (0 : Nat)),
    ("unknown", toJson (0 : Nat)),
    ("total", toJson (0 : Nat))
  ]

private def syncReadinessJson (saveReady : Bool := true) : Json :=
  Json.mkObj [
    ("saveReady", toJson saveReady),
    ("reason", toJson "ok"),
    ("blockingErrorCount", toJson (0 : Nat)),
    ("blockingDiagnostics", toJson (#[] : Array SyncBlockingDiagnostic)),
    ("blockingMessages", toJson (#[] : Array SyncBlockingCommandMessage))
  ]

private def syncFileResultJson (version : Nat) (readiness : Json) : Json :=
  Json.mkObj [
    ("path", toJson "Demo.lean"),
    ("version", toJson version),
    ("diagnostics", Json.mkObj [("counts", syncDiagnosticCountsJson)]),
    ("readiness", readiness)
  ]

private def checkResponseJsonShape : IO Unit := do
  let successJson := toJson <| Response.success (Json.mkObj [("value", toJson (1 : Nat))])
  requireJsonBool "success response" "ok" true successJson
  requireFieldPresent "success response" "result" successJson
  requireFieldAbsent "success response" "error" successJson

  let errorJson := toJson <| (responseFailureFor .invalidParams "bad request").toResponse
  requireJsonBool "error response" "ok" false errorJson
  requireFieldPresent "error response" "error" errorJson
  requireFieldAbsent "error response" "result" errorJson

  requireFieldAbsent "semantic success response" "clientRequestId" successJson

private def checkStreamMessageDecode : IO Unit := do
  let response := Response.success (Json.mkObj [("value", toJson (1 : Nat))])
  let validResponse ← expectOk "valid response stream" <|
    fromJson? (α := StreamMessage) (toJson <| StreamMessage.response none response)
  match validResponse with
  | .response none _ => pure ()
  | other => throw <| IO.userError s!"valid response stream decoded as {(toJson other).compress}"

  let correlatedResponseJson :=
    toJson <| StreamMessage.response (some "req-response") response
  requireJsonString "correlated response stream" "clientRequestId" "req-response"
    correlatedResponseJson
  let correlatedResponsePayload ←
    requireObjVal "correlated response stream" "payload" correlatedResponseJson
  requireFieldAbsent "correlated response payload" "clientRequestId" correlatedResponsePayload
  let validCorrelatedResponse ← expectOk "valid correlated response stream" <|
    fromJson? (α := StreamMessage) correlatedResponseJson
  match validCorrelatedResponse with
  | .response clientRequestId? decodedResponse =>
      require "valid correlated response stream preserves envelope request id"
        (clientRequestId? == some "req-response")
      require "valid correlated response stream preserves response payload"
        (decodedResponse.result?.isSome)
  | other =>
      throw <| IO.userError s!"valid correlated response decoded as {(toJson other).compress}"

  let progress : SyncFileProgress := { updates := 2, done := false }
  let validProgress ← expectOk "valid progress stream" <|
    fromJson? (α := StreamMessage) (toJson <| StreamMessage.fileProgress (some "req-1") progress)
  match validProgress with
  | .fileProgress clientRequestId? decodedProgress =>
      require "valid progress stream preserves request id" (clientRequestId? == some "req-1")
      require "valid progress stream preserves payload" (decodedProgress.updates == 2)
  | other => throw <| IO.userError s!"valid progress stream decoded as {(toJson other).compress}"

  let diagnostic : StreamDiagnostic := {
    path := "Demo.lean"
    uri := "file:///repo/Demo.lean"
    version? := some 3
    severity? := some .warning
    range := lspRange 0 0 1
    message := "unused variable"
  }
  let validDiagnostic ← expectOk "valid diagnostic stream" <|
    fromJson? (α := StreamMessage) <|
      toJson <| StreamMessage.diagnostic (some "req-2") diagnostic
  match validDiagnostic with
  | .diagnostic clientRequestId? decodedDiagnostic =>
      require "valid diagnostic stream preserves request id" (clientRequestId? == some "req-2")
      require "valid diagnostic stream preserves payload"
        (decodedDiagnostic.path == "Demo.lean" && decodedDiagnostic.message == "unused variable")
  | other =>
      throw <| IO.userError s!"valid diagnostic stream decoded as {(toJson other).compress}"

  let responseJson := toJson response
  let progressJson := toJson progress
  let diagnosticJson := toJson diagnostic
  expectDecodeFailure StreamMessage "response stream missing payload" <|
    Json.mkObj [("kind", toJson "response")]
  expectDecodeFailure StreamMessage "progress stream with response payload" <|
    Json.mkObj [("kind", toJson "fileProgress"), ("payload", responseJson)]
  expectDecodeFailure StreamMessage "response stream with legacy variant payload field" <|
    Json.mkObj [("kind", toJson "response"), ("response", responseJson)]
  expectDecodeFailure StreamMessage "progress stream with legacy variant payload field" <|
    Json.mkObj [("kind", toJson "fileProgress"), ("fileProgress", progressJson)]
  expectDecodeFailure StreamMessage "diagnostic stream with legacy variant payload field" <|
    Json.mkObj [("kind", toJson "diagnostic"), ("diagnostic", diagnosticJson)]
  expectDecodeFailure StreamMessage "response stream with nested request id" <|
    Json.mkObj [
      ("kind", toJson "response"),
      ("payload", (toJson response).setObjVal! "clientRequestId" (toJson "req-response")),
      ("clientRequestId", toJson "req-response")
    ]
  expectDecodeFailure StreamMessage "stream with undeclared field" <|
    Json.mkObj [
      ("kind", toJson "fileProgress"),
      ("payload", progressJson),
      ("extra", toJson true)
    ]

private def checkResponseJsonDecode : IO Unit := do
  let success ← decodeResponse "success" <| Json.mkObj [
    ("ok", toJson true),
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  unless success.ok do
    throw <| IO.userError s!"success: expected ok=true, got {(toJson success).compress}"

  let error ← decodeResponse "error" <| Json.mkObj [
    ("ok", toJson false),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  if error.ok then
    throw <| IO.userError s!"error: expected ok=false, got {(toJson error).compress}"

  expectDecodeFailure Response "missing ok success" <| Json.mkObj [
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  expectDecodeFailure Response "missing ok error" <| Json.mkObj [
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure Response "error with result" <| Json.mkObj [
    ("ok", toJson false),
    ("result", Json.null),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure Response "ok with error" <| Json.mkObj [
    ("ok", toJson true),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure Response "ok=false without error" <| Json.mkObj [
    ("ok", toJson false)
  ]
  expectDecodeFailure Response "ok=true without result" <| Json.mkObj [
    ("ok", toJson true)
  ]
  expectDecodeFailure Response "response with undeclared field" <| Json.mkObj [
    ("ok", toJson true),
    ("result", Json.mkObj []),
    ("extra", toJson true)
  ]
private def checkSaveResultJsonDecode : IO Unit := do
  let saveResult : SaveOleanResult := {
    module := "Demo"
    sourceHash := "9a9bdc9950870951"
    olean := "/tmp/Demo.olean"
    ilean := "/tmp/Demo.ilean"
    c := "/tmp/Demo.c"
    trace := "/tmp/Demo.olean.trace"
    oleanServer? := some "/tmp/Demo.olean.server"
    sync := syncResultFor 7
  }
  let decodedSave ← expectOk "save result round-trip" <|
    fromJson? (α := SaveOleanResult) (toJson saveResult)
  require "save result round-trip preserves source hash"
    (decodedSave.sourceHash == saveResult.sourceHash)
  require "save result derives its path from nested sync"
    (decodedSave.path == "Demo.lean")
  require "save result derives its version from nested sync"
    (decodedSave.version == 7)
  require "save result round-trip preserves nested sync version"
    (decodedSave.sync.version == saveResult.sync.version)

  let closeSaveResult : CloseSaveResult := { saved := saveResult }
  let decodedCloseSave ← expectOk "close-save result round-trip" <|
    fromJson? (α := CloseSaveResult) (toJson closeSaveResult)
  require "close-save result round-trip preserves closure and nested save"
    (decodedCloseSave.closed && decodedCloseSave.saved.module == saveResult.module)

  let missingOlean :=
    match toJson saveResult with
    | .obj fields => Json.obj <| fields.erase "olean"
    | other => other
  expectDecodeFailure SaveOleanResult "save result missing required artifact" missingOlean

  expectDecodeFailure SaveOleanResult "save result path does not match nested sync" <|
    (toJson saveResult).setObjVal! "path" (toJson "Other.lean")
  expectDecodeFailure SaveOleanResult "save result version does not match nested sync" <|
    (toJson saveResult).setObjVal! "version" (toJson (8 : Nat))

  let malformedNestedSave := Json.mkObj [
    ("closed", toJson true),
    ("saved", (toJson saveResult).setObjVal! "extra" (toJson true))
  ]
  expectDecodeFailure CloseSaveResult
    "close-save result with malformed nested save" malformedNestedSave
  expectDecodeFailure CloseSaveResult "close-save result reports closed=false" <|
    (toJson closeSaveResult).setObjVal! "closed" (toJson false)

private def checkOrderedJsonPretty : IO Unit := do
  let resp : Response :=
    (Response.success <| toJson <| syncResultFor 3).withFileProgress {
      updates := 2
      done := true
      rangeEndLine? := some 1
    }
  let json := toJson resp
  let rendered := Beam.orderedJsonPretty json
  let expected := String.intercalate "\n" [
    "{",
    "  \"ok\": true,",
    "  \"result\": {",
    "    \"path\": \"Demo.lean\",",
    "    \"version\": 3,",
    "    \"diagnostics\": {",
    "      \"counts\": {",
    "        \"error\": 0,",
    "        \"warning\": 0,",
    "        \"information\": 0,",
    "        \"hint\": 0,",
    "        \"unknown\": 0,",
    "        \"total\": 0",
    "      }",
    "    },",
    "    \"readiness\": {",
    "      \"saveReady\": true,",
    "      \"reason\": \"ok\",",
    "      \"blockingErrorCount\": 0,",
    "      \"blockingDiagnostics\": [],",
    "      \"blockingMessages\": []",
    "    }",
    "  },",
    "  \"fileProgress\": {",
    "    \"done\": true,",
    "    \"updates\": 2,",
    "    \"rangeEndLine\": 1",
    "  }",
    "}"
  ]
  if rendered != expected then
    throw <| IO.userError s!"ordered JSON pretty output changed:\n{rendered}"
  let parsed ← expectOk "ordered JSON pretty parse" (Json.parse rendered)
  require "ordered JSON pretty output should round-trip" (parsed.compress == json.compress)
  let progress ← requireObjVal "ordered JSON pretty output" "fileProgress" json
  requireFieldAbsent "ordered JSON pretty progress" "line" progress
  requireFieldAbsent "ordered JSON pretty progress" "totalLines" progress
  requireJsonInt "ordered JSON pretty progress" "rangeEndLine" 1 progress

private def checkSyncFileResultDecode : IO Unit := do
  let valid := syncFileResultJson 7 (syncReadinessJson true)
  discard <| IO.ofExcept <| fromJson? (α := SyncFileResult) valid
  expectDecodeFailure SyncDiagnosticCounts "diagnostic total differs from severity sum" <|
    syncDiagnosticCountsJson.setObjVal! "total" (toJson (1 : Nat))
  for field in #[
    "saveReady",
    "errorCount",
    "warningCount",
    "saveReadyReason",
    "blockingDiagnostics",
    "blockingCommandMessages",
    "stateErrorCount",
    "stateCommandErrorCount"
  ] do
    expectDecodeFailure SyncFileResult s!"sync result removed top-level field {field}" <|
      valid.setObjVal! field Json.null
  let incompleteReadiness := Json.mkObj [
    ("reason", toJson "ok"),
    ("blockingErrorCount", toJson (0 : Nat)),
    ("blockingDiagnostics", toJson (#[] : Array SyncBlockingDiagnostic)),
    ("blockingMessages", toJson (#[] : Array SyncBlockingCommandMessage))
  ]
  expectDecodeFailure SyncFileResult "sync result missing saveReady" <|
    syncFileResultJson 7 incompleteReadiness

private def checkFailureResponseConversions : IO Unit := do
  let data := Json.mkObj [("uri", toJson "file:///A.lean")]
  let failure : BrokerFailure := {
    code := .contentModified
    message := "file changed"
    data? := some data
  }
  let err ← requireError "broker failure response" "contentModified" "file changed" <|
    failure.toResponse
  match err.data? with
  | some actual =>
      if actual.compress != data.compress then
        throw <| IO.userError s!"broker failure response: expected data {data.compress}, got {actual.compress}"
  | none =>
      throw <| IO.userError "broker failure response: expected error data"

  let progress : SyncFileProgress := { updates := 3, done := false, rangeEndLine? := some 17 }
  let responseFailure : ResponseFailure := {
    error := { code := "backendSpecific", message := "backend failed", data? := some data }
    fileProgress? := some progress
  }
  match responseFailure.toResponse with
  | .successResult .. =>
      throw <| IO.userError "response failure converted to a successful response"
  | .errorResult failure =>
      require "response failure preserves an arbitrary backend code"
        (failure.error.code == "backendSpecific")
      require "response failure preserves progress metadata"
        (failure.fileProgress? == some progress)

private def checkDocumentVersionMismatchErrorData : IO Unit := do
  let data := documentVersionMismatchErrorData 1 2
    (currentVersion? := some 2)
    (uri? := some "file:///A.lean")
  requireJsonString "version mismatch data" "reason" "documentVersionMismatch" data
  requireJsonInt "version mismatch data" "expectedVersion" 1 data
  requireJsonInt "version mismatch data" "acceptedVersion" 2 data
  requireJsonInt "version mismatch data" "currentVersion" 2 data
  requireJsonString "version mismatch data" "uri" "file:///A.lean" data

private def checkReadinessBoundary : IO Unit := do
  let uri := "file:///workspace/SaveSmoke/A.lean"
  let clean := decideSyncBarrier uri 7 (some { updates := 1, done := true }) none #[]
  require "clean readiness barrier should be complete" (!clean.incomplete)
  require "clean readiness barrier preserves prior progress"
    (clean.fileProgress? == some { updates := 1, done := true })

  let partialBarrier := decideSyncBarrier uri 7 none (some { updates := 2, done := false }) #[]
  require "partial readiness barrier should be incomplete" partialBarrier.incomplete
  require "partial readiness barrier should explain the incomplete barrier"
    (partialBarrier.message?.any (·.contains "Lean diagnostics barrier did not complete"))

  let incompleteDiagnostic := diagnostic .information "Failed to build module dependencies."
  let diagnosticBarrier :=
    decideSyncBarrier uri 7 none (some { updates := 4, done := true }) #[incompleteDiagnostic]
  require "stale dependency diagnostic should force an incomplete barrier" diagnosticBarrier.incomplete
  require "stale dependency diagnostic should force progress done=false"
    (diagnosticBarrier.fileProgress? == some { updates := 4, done := false })

  let hints : Array StaleDirectDepHint := #[{
    module := "SaveSmoke.B"
    path := "SaveSmoke/B.lean"
    needsSave := true
  }]
  let incompleteResp :=
    (syncBarrierIncompleteFailure uri 7 "SaveSmoke/A.lean" hints #[incompleteDiagnostic]
      diagnosticBarrier.fileProgress?).toResponse
  let err ← requireError
    "readiness incomplete response"
    syncBarrierIncompleteCode
    (syncBarrierIncompleteMessage uri 7 diagnosticBarrier.fileProgress?)
    incompleteResp
  require "readiness incomplete response should preserve fileProgress"
    (incompleteResp.fileProgress? == diagnosticBarrier.fileProgress?)
  let data ← requireErrorData "readiness incomplete response" err
  requireJsonString "readiness incomplete response data" "targetPath" "SaveSmoke/A.lean" data
  let saveDepsJson ← requireObjVal "readiness incomplete response data" "saveDeps" data
  let saveDeps ← expectOk "readiness saveDeps decode"
    (fromJson? (α := Array String) saveDepsJson)
  require "readiness incomplete response should include dependency save hint"
    (saveDeps[0]? == some "SaveSmoke/B.lean")
  let completionBlocking ← requireObjVal
    "readiness incomplete response data" "completionBlockingDiagnostics" data
  let completionBlockingItems ← expectOk "readiness completion-blocking diagnostics decode"
    (fromJson? (α := Array SyncBlockingDiagnostic) completionBlocking)
  require "readiness incomplete response should flag completion-blocking diagnostics"
    (completionBlockingItems.any (fun diagnostic =>
      diagnostic.completionBlocking &&
        diagnostic.message.contains "Failed to build module dependencies."))
  let recoveryPlanJson ← requireObjVal "readiness incomplete response data" "recoveryPlan" data
  let recoveryPlan ← expectOk "readiness recovery plan decode"
    (fromJson? (α := Array String) recoveryPlanJson)
  require "readiness recovery plan should start with dependency save"
    (recoveryPlan[0]? == some "lean-beam save \"SaveSmoke/B.lean\"")
  require "readiness recovery plan should include target refresh"
    (recoveryPlan[1]? == some "lean-beam refresh \"SaveSmoke/A.lean\"")
  require "readiness recovery plan should end with lake build"
    (recoveryPlan[2]? == some "lake build")

  let successResp := syncFileSuccessResponse
    (syncResultFor 9 (saveReady := false) (reason := "documentErrors")
      (blockingErrorCount := 1))
    (some { updates := 5, done := true })
  require "readiness success response should be ok" successResp.ok
  require "readiness success response should keep fileProgress"
    (successResp.fileProgress? == some { updates := 5, done := true })
  let successResult ← requireResponseResult "readiness success response" successResp
  requireJsonInt "readiness success payload" "version" 9 successResult
  requireJsonString "readiness success payload" "path" "Demo.lean" successResult
  requireFieldAbsent "readiness success payload" "warningCount" successResult
  requireFieldAbsent "readiness success payload" "stateErrorCount" successResult
  requireFieldAbsent "readiness success payload" "stateCommandErrorCount" successResult
  requireFieldAbsent "readiness success payload" "blockingDiagnostics" successResult
  requireFieldAbsent "readiness success payload" "blockingCommandMessages" successResult
  requireFieldAbsent "readiness success payload" "saveReady" successResult
  requireFieldAbsent "readiness success payload" "saveReadyReason" successResult
  let successSyncResult ← expectOk "readiness success payload decode" <|
    fromJson? (α := SyncFileResult) successResult
  require "readiness success payload nested saveReady"
    (!successSyncResult.readiness.saveReady)
  require "readiness success payload distinguishes blocking evidence from diagnostic counts"
    (successSyncResult.readiness.blockingErrorCount == 1 &&
      successSyncResult.diagnostics.counts.error == 0)

  let streamedErrorDiagnostic := diagnostic .error "streamed error only"
  let stableCountsResp := syncFileSuccessResponse
    (syncResultFor 10 (saveReady := false) (reason := "documentErrors")
      (blockingErrorCount := 1) (warningCount := 5))
    none
  let stableCountsResult ← requireResponseResult "readiness stable-count response" stableCountsResp
  requireFieldAbsent "readiness stable-count payload" "errorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "warningCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "stateErrorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "stateCommandErrorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "blockingDiagnostics" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "blockingCommandMessages" stableCountsResult

  if syncErrorCount #[streamedErrorDiagnostic] != 1 then
    throw <| IO.userError
      s!"readiness diagnostic fixture should count as an error, got {syncErrorCount #[streamedErrorDiagnostic]}"

  let interactiveOnlyResp := syncFileSuccessResponse (syncResultFor 11) none
  let interactiveOnlyResult ← requireResponseResult
    "readiness interactive-only diagnostic response" interactiveOnlyResp
  requireFieldAbsent "readiness interactive-only payload" "errorCount" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "stateErrorCount" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "stateCommandErrorCount"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "blockingDiagnostics"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "blockingCommandMessages"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "saveReady" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "saveReadyReason"
    interactiveOnlyResult
  let interactiveOnlySyncResult ← expectOk "readiness interactive-only payload decode" <|
    fromJson? (α := SyncFileResult) interactiveOnlyResult
  require "readiness interactive-only payload nested saveReady"
    interactiveOnlySyncResult.readiness.saveReady

private def checkStaleDirectDepHints : IO Unit := do
  let directImports := #["SaveSmoke.B"]

  let unsavedHistory : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "SaveSmoke.B" ({
      path := "SaveSmoke/B.lean"
      lastSyncEventSeq := 9
      lastSaveEventSeq := 2
      lastTextHash? := some 11
      lastTextChangeEventSeq := 9
    } : ModuleHistory)
  let unsavedHints := collectStaleDirectDepHints directImports 7 unsavedHistory
  let some unsavedHint := unsavedHints[0]?
    | throw <| IO.userError "expected unsaved stale direct dependency hint"
  require "unsaved stale direct dependency should need save" unsavedHint.needsSave
  require "unsaved stale direct dependency should name module"
    (unsavedHint.module == "SaveSmoke.B")
  require "unsaved stale direct dependency should name path"
    (unsavedHint.path == "SaveSmoke/B.lean")

  let savedHistory : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "SaveSmoke.B" ({
      path := "SaveSmoke/B.lean"
      lastSyncEventSeq := 9
      lastSaveEventSeq := 10
      lastTextHash? := some 11
      lastTextChangeEventSeq := 9
    } : ModuleHistory)
  let savedHints := collectStaleDirectDepHints directImports 7 savedHistory
  let some savedHint := savedHints[0]?
    | throw <| IO.userError "expected saved stale direct dependency hint"
  require "saved stale direct dependency should not need save" (!savedHint.needsSave)

  let noopSyncHistory : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "SaveSmoke.B" ({
      path := "SaveSmoke/B.lean"
      lastSyncEventSeq := 10
      lastSaveEventSeq := 2
      lastTextHash? := some 11
      lastTextChangeEventSeq := 4
    } : ModuleHistory)
  let noopSyncHints := collectStaleDirectDepHints directImports 7 noopSyncHistory
  require "no-op dependency sync after target should not create stale hint"
    noopSyncHints.isEmpty

private def checkRequestArgsBoundary : IO Unit := do
  let runAtMissingVersion : Request := {
    op := .runAt
    path? := some "Demo.lean"
    line? := some 1
    character? := some 2
    text? := some "exact trivial"
  }
  expectRequestArgError "run_at args missing version" "missing 'version'" runAtMissingVersion.runAtArgs

  let runAtMissingText : Request := {
    op := .runAt
    path? := some "Demo.lean"
    version? := some 7
    line? := some 1
    character? := some 2
  }
  expectRequestArgError "run_at args missing text" "missing 'text'" runAtMissingText.runAtArgs

  let runAtRocqUnsupported : Request := {
    op := .runAt
    backend := .rocq
    path? := some "Demo.v"
    version? := some 7
    line? := some 1
    character? := some 2
    text? := some "Check nat."
  }
  expectRequestArgError
    "rocq run_at args"
    "rocq backend does not support run_at yet"
    runAtRocqUnsupported.runAtArgs

  let codeActionResolveMissingAction : Request := {
    op := .codeActionResolve
    path? := some "Demo.lean"
    version? := some 7
  }
  expectRequestArgError
    "code_action_resolve args missing codeAction"
    "missing 'codeAction'"
    codeActionResolveMissingAction.codeActionResolveArgs

  let codeActionResolveRocqUnsupported : Request := {
    op := .codeActionResolve
    backend := .rocq
    path? := some "Demo.v"
    version? := some 7
    codeAction? := some {
      title := "Resolve"
    }
  }
  expectRequestArgError
    "rocq code_action_resolve args"
    "rocq backend does not support code action resolution"
    codeActionResolveRocqUnsupported.codeActionResolveArgs

private def checkWorkspaceRoutingFields : IO Unit := do
  let processWideOps := #[Op.listWorkspaces, .resetStats, .shutdown]
  let optionallyScopedOps := #[Op.openDocs, .stats]

  for op in Op.all do
    let expectedScope :=
      if processWideOps.contains op then
        WorkspaceScope.none
      else if optionallyScopedOps.contains op then
        .optional
      else
        .required
    require s!"{op.key} has the wrong workspace scope"
      (op.workspaceScope == expectedScope)
    let expectedTracking := op != .cancel && op != .shutdown
    require s!"{op.key} has the wrong active-request tracking policy"
      (op.tracksActiveRequest == expectedTracking)
    let request : Request := { op }
    let decoded ← expectOk s!"minimal {op.key} request round trip" <|
      fromJson? (α := Request) (toJson request)
    require s!"minimal {op.key} request lost its operation" (decoded.op == op)

  let unscopedReq : Request := { op := .stats }
  require "missing workspace id remains unscoped" unscopedReq.resolvedWorkspaceId?.isNone
  requireFieldAbsent "stats request serialization" "backend" (toJson unscopedReq)

  let leanReq : Request := { op := .ensure }
  requireJsonString "backend-scoped request serialization" "backend" "lean" (toJson leanReq)

  let explicitReq : Request := {
    op := .stats
    workspaceId? := some "fixture"
  }
  require "explicit workspace id wins" (explicitReq.resolvedWorkspaceId? == some "fixture")

  let handle : Handle := {
    workspaceId := "handle-workspace"
    backend := .lean
    epoch := 1
    session := "session"
    raw := Json.mkObj [("value", toJson ("raw" : String))]
  }
  let handleReq : Request := {
    op := .runWith
    handle? := some handle
  }
  require "handle workspace id routes omitted request workspace"
    (handleReq.resolvedWorkspaceId? == some "handle-workspace")

  let explicitHandleReq : Request := {
    op := .runWith
    workspaceId? := some "explicit"
    handle? := some handle
  }
  require "explicit workspace id overrides handle for validation"
    (explicitHandleReq.resolvedWorkspaceId? == some "explicit")

  let unrelatedStats : Request := {
    op := .stats
    query? := some "ignored-before-strict-validation"
  }
  match unrelatedStats.validateFields with
  | .ok _ => throw <| IO.userError "stats accepted an unrelated query field"
  | .error err =>
      require "broker request field validation identifies the operation and field"
        (err.contains "stats" && err.contains "query")

  let rootOnlyStats : Request := {
    op := .stats
    root? := some "/workspace"
  }
  match rootOnlyStats.validateFields with
  | .ok _ => throw <| IO.userError "stats accepted a root without a workspace id"
  | .error err =>
      require "scoped stats requires an explicit workspace id"
        (err.contains "workspaceId" && err.contains "root")

  for (label, json, field) in #[
      ("unknown broker field", Json.mkObj [
        ("op", toJson "stats"),
        ("mystery", toJson true)
      ], "mystery"),
      ("known field owned by another operation", Json.mkObj [
        ("op", toJson "stats"),
        ("query", toJson "ignored-before-strict-validation")
      ], "query"),
      ("backend on process operation", Json.mkObj [
        ("op", toJson "stats"),
        ("backend", toJson "lean")
      ], "backend")
    ] do
    match fromJson? (α := Request) json with
    | .ok _ => throw <| IO.userError s!"{label} decoded unexpectedly"
    | .error err =>
        require s!"{label} error should identify '{field}'"
          (err.contains field || (field == "backend" && err.contains "does not select a backend"))

  for obsoleteField in #["fullDiagnostics", "includeDiagnostics"] do
    let json := Json.mkObj [
      ("op", toJson "sync_file"),
      ("backend", toJson "lean"),
      ("workspaceId", toJson "fixture"),
      ("path", toJson "Demo.lean"),
      (obsoleteField, toJson true)
    ]
    match fromJson? (α := Request) json with
    | .ok _ => throw <| IO.userError s!"broker accepted obsolete field {obsoleteField}"
    | .error err =>
        require s!"obsolete broker field error should identify {obsoleteField}"
          (err.contains obsoleteField)

  match fromJson? (α := Request) <| Json.mkObj [
      ("op", toJson "sync_file"),
      ("backend", toJson "lean"),
      ("workspaceId", toJson "fixture"),
      ("path", toJson "Demo.lean"),
      ("diagnosticScope", toJson true)
    ] with
  | .ok _ => throw <| IO.userError "broker accepted boolean diagnosticScope"
  | .error err =>
      require "invalid diagnosticScope error should name the enum values"
        (err.contains "errors" && err.contains "all")

  match fromJson? (α := Request) <| Json.mkObj [
      ("op", toJson "init_workspace"),
      ("workspaceMode", toJson "unsupported")
    ] with
  | .ok _ => throw <| IO.userError "unsupported typed workspace mode decoded unexpectedly"
  | .error err =>
      require "unsupported workspace mode error should name accepted values"
        (err.contains "'set', 'verify', or 'reset'")

private def checkProjectRequestBoundary : IO Unit := do
  let semanticJson := Json.mkObj [
    ("op", toJson Op.runAt),
    ("backend", toJson Backend.lean),
    ("clientRequestId", toJson "project-request"),
    ("path", toJson "Demo.lean"),
    ("version", toJson (1 : Nat)),
    ("line", toJson (0 : Nat)),
    ("character", toJson (0 : Nat)),
    ("text", toJson "exact rfl")
  ]
  let projectRequest ← expectOk "semantic project request" <|
    fromJson? (α := ProjectRequest) semanticJson
  let attached := projectRequest.attach "workspace-a" "/workspace/a" "session-capability"
  require "project request attachment injects the selected workspace"
    (attached.workspaceId? == some "workspace-a")
  require "project request attachment injects the owner-side root"
    (attached.root? == some "/workspace/a")
  require "project request attachment injects session authority"
    (attached.daemonCapability? == some "session-capability")
  match fromJson? (α := ProjectRequest) <| Json.mkObj [("op", toJson Op.stats)] with
  | .ok _ => throw <| IO.userError "project request unexpectedly accepted a missing request id"
  | .error err =>
      require "project request id rejection should explain the machine identity requirement"
        (err.contains "non-empty clientRequestId")
  let cancelRequest ← expectOk "semantic cancellation request" <|
    fromJson? (α := ProjectRequest) <| Json.mkObj [
      ("op", toJson Op.cancel),
      ("clientRequestId", toJson "cancel-command"),
      ("cancelRequestId", toJson "project-request")
    ]
  let attachedCancel := cancelRequest.attach "workspace-a" "/workspace/a" "session-capability"
  require "project cancellation is workspace-scoped"
    (attachedCancel.workspaceId? == some "workspace-a")
  require "project cancellation does not invent an unsupported root field"
    attachedCancel.root?.isNone
  for field in ["workspaceId", "root", "daemonCapability", "leanCmd"] do
    match fromJson? (α := ProjectRequest) (semanticJson.setObjVal! field (toJson "forbidden")) with
    | .ok _ => throw <| IO.userError s!"project request unexpectedly accepted session field '{field}'"
    | .error _ => pure ()
  for op in [Op.initWorkspace, .listWorkspaces, .dropWorkspace] do
    match fromJson? (α := ProjectRequest) <| Json.mkObj [
      ("op", toJson op),
      ("clientRequestId", toJson "admin-request")
    ] with
    | .ok _ => throw <| IO.userError s!"project request unexpectedly accepted admin op '{op.key}'"
    | .error _ => pure ()

private def checkWorkspaceLifecycleProtocol : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  let previous := System.FilePath.mk "/previous-workspace"
  let emptyRuntimeIdRejected ←
    try
      discard <| Beam.Broker.ServerRuntime.create ({ root } : Beam.Broker.BrokerConfig) ""
      pure false
    catch err =>
      pure <| err.toString.contains "workspace id must be non-empty"
  require "broker runtime constructor should reject an empty workspace id" emptyRuntimeIdRejected

  let runtime ← Beam.Broker.ServerRuntime.create
    ({ root } : Beam.Broker.BrokerConfig) "fixture"
  require "broker workspace query should expose the constructor workspace"
    ((← runtime.workspaceRoot? "fixture") == some root)
  require "broker workspace query should reject an unknown workspace"
    ((← runtime.workspaceRoot? "unknown") == none)
  for op in #[Op.ensure, .initWorkspace, .dropWorkspace] do
    let missingWorkspaceResp ← runtime.dispatchRequest { op }
    require s!"{op.key} should reject omitted workspace identity"
      (missingWorkspaceResp.error?.any fun err =>
        err.code == "invalidParams" && err.message.contains "workspaceId is required")
  let processStatsResp ← runtime.dispatchRequest { op := .stats }
  let some processStats := processStatsResp.result?
    | throw <| IO.userError s!"process-wide stats failed: {(toJson processStatsResp).compress}"
  requireFieldAbsent "process-wide stats" "root" processStats
  requireFieldAbsent "process-wide stats" "sessions" processStats
  requireFieldAbsent "process-wide stats" "byBackend" processStats
  discard <| IO.ofExcept <| processStats.getObjVal? "workspaces"

  let resetResult : Beam.Workspace.InitResult := {
    workspaceId := "fixture"
    root
    mode := .reset
    runtimeReused := false
    previousRoot? := some previous
    invalidatedHandles := true
  }
  let resetJson := toJson resetResult
  requireJsonString "reset result json" "workspace_id" "fixture" resetJson
  requireJsonString "reset result json" "root" root.toString resetJson
  requireFieldAbsent "reset result json" "active_root" resetJson
  requireJsonString "reset result json" "previous_root" previous.toString resetJson
  requireJsonBool "reset result json" "invalidated_handles" true resetJson
  requireJsonBool "reset result json" "runtime_reused" false resetJson
  let decodedReset ← expectOk "decode typed workspace initialization result" <|
    fromJson? (α := Beam.Workspace.InitResult) resetJson
  require "typed workspace initialization result preserves lifecycle state"
    (decodedReset.workspaceId == "fixture" && decodedReset.root == root &&
      decodedReset.previousRoot? == some previous && decodedReset.invalidatedHandles)

  let setResultJson := toJson ({
    workspaceId := "fixture"
    root
    mode := .set
    runtimeReused := false
    invalidatedHandles := false
  } : Beam.Workspace.InitResult)
  requireJsonString "set result json" "workspace_id" "fixture" setResultJson
  requireJsonBool "set result json" "invalidated_handles" false setResultJson
  requireFieldAbsent "set result json" "previous_root" setResultJson

  let listJson := toJson ({ workspaces := #[{
    workspaceId := "fixture"
    root
    leanActive := true
    rocqActive := false
  }] } : Beam.Workspace.ListResult)
  let decodedList ← expectOk "decode typed workspace list" <|
    fromJson? (α := Beam.Workspace.ListResult) listJson
  let some decodedEntry := decodedList.workspaces[0]?
    | throw <| IO.userError "typed workspace list lost its entry"
  require "typed workspace list preserves workspace id" (decodedEntry.workspaceId == "fixture")
  require "typed workspace list preserves root" (decodedEntry.root == root)
  require "typed workspace list preserves backend activity"
    (decodedEntry.leanActive && !decodedEntry.rocqActive)

  let dropJson := toJson ({
    workspaceId := "fixture"
    dropped := true
    invalidatedHandles := true
  } : Beam.Workspace.DropResult)
  let decodedDrop ← expectOk "decode typed workspace drop result" <|
    fromJson? (α := Beam.Workspace.DropResult) dropJson
  require "typed workspace drop preserves lifecycle state"
    (decodedDrop.workspaceId == "fixture" && decodedDrop.dropped && decodedDrop.invalidatedHandles)
  let dropResult ← runtime.dropWorkspace "fixture"
  match dropResult with
  | .error failure =>
      throw <| IO.userError s!"broker workspace drop failed: {failure.error.message}"
  | .ok dropped =>
      require "broker workspace drop should succeed" dropped.dropped
      require "broker workspace drop should invalidate handles" dropped.invalidatedHandles
  require "broker workspace query should observe a dropped workspace"
    ((← runtime.workspaceRoot? "fixture") == none)

  match ← runtime.initWorkspaceWithConfig "fixture" ({ root } : Beam.Broker.BrokerConfig) with
  | .error failure =>
      throw <| IO.userError s!"typed broker workspace initialization failed: {failure.error.message}"
  | .ok initialized =>
      require "typed broker workspace initialization should return its workspace"
        (initialized.workspaceId == "fixture" && initialized.root == root)
      require "typed broker workspace initialization should report a new runtime"
        (!initialized.runtimeReused && !initialized.invalidatedHandles)

private inductive LifecycleTeardown where
  | reset
  | drop

private def LifecycleTeardown.label : LifecycleTeardown → String
  | .reset => "reset"
  | .drop => "drop"

private partial def waitForPath
    (path : System.FilePath)
    (tries : Nat := 200) : IO Bool := do
  if ← path.pathExists then
    pure true
  else if tries == 0 then
    pure false
  else
    IO.sleep 10
    waitForPath path (tries - 1)

private partial def waitForTaskBefore
    (task : Task α)
    (blockedBy : Task β)
    (tries : Nat := 300) : IO (Option α) := do
  if ← IO.hasFinished blockedBy then
    pure none
  else if ← IO.hasFinished task then
    pure <| some (← IO.wait task)
  else if tries == 0 then
    pure none
  else
    IO.sleep 10
    waitForTaskBefore task blockedBy (tries - 1)

private def stubbornSession
    (workspaceId : WorkspaceId)
    (root sentinel : System.FilePath) : IO Session := do
  let proc ← IO.Process.spawn {
    toStdioConfig := brokerStdio
    cmd := "python3"
    args := #[
      "-c",
      "import pathlib, sys, time; sys.stdin.buffer.readline(); pathlib.Path(sys.argv[1]).write_text('shutdown'); time.sleep(30)",
      sentinel.toString
    ]
  }
  let pending ← Std.Mutex.new ({} : Std.TreeMap Lean.JsonRpc.RequestID PendingRequest)
  pure {
    workspaceId
    backend := .lean
    root
    epoch := 1
    sessionToken := s!"stubborn-{workspaceId}"
    proc
    stdin := IO.FS.Stream.ofHandle proc.stdin
    stdout := IO.FS.Stream.ofHandle proc.stdout
    pending
  }

private def runLifecycleTeardown
    (kind : LifecycleTeardown)
    (runtime : ServerRuntime)
    (workspaceId : WorkspaceId)
    (replacement : BrokerConfig) : IO (Except ResponseFailure Bool) := do
  match kind with
  | .reset =>
      match ← runtime.initWorkspaceWithConfig workspaceId replacement (some .reset) with
      | .ok result => pure <| .ok result.invalidatedHandles
      | .error failure => pure <| .error failure
  | .drop =>
      match ← runtime.dropWorkspace workspaceId with
      | .ok result => pure <| .ok result.invalidatedHandles
      | .error failure => pure <| .error failure

private def checkLifecycleTeardownReleasesStateMutex
    (kind : LifecycleTeardown) : IO Unit := do
  let nonce ← IO.monoNanosNow
  let targetId := "teardown-target"
  let observerId := "teardown-observer"
  let targetRoot := System.FilePath.mk s!"/tmp/beam-{kind.label}-target-{nonce}"
  let replacementRoot := System.FilePath.mk s!"/tmp/beam-{kind.label}-replacement-{nonce}"
  let observerRoot := System.FilePath.mk s!"/tmp/beam-{kind.label}-observer-{nonce}"
  let sentinel := System.FilePath.mk s!"/tmp/beam-{kind.label}-shutdown-{nonce}"
  let targetConfig : BrokerConfig := { root := targetRoot }
  let replacementConfig : BrokerConfig := { root := replacementRoot }
  let observerConfig : BrokerConfig := { root := observerRoot }
  let runtime ← ServerRuntime.create targetConfig targetId
  let session ← stubbornSession targetId targetRoot sentinel
  runtime.state.atomically do
    let state ← get
    let targetWorkspace : WorkspaceState := {
      config := targetConfig
      lean := { nextEpoch := 2, session? := some session }
    }
    let observerWorkspace : WorkspaceState := { config := observerConfig }
    let workspaces := state.workspaces.insert targetId targetWorkspace
    let workspaces := workspaces.insert observerId observerWorkspace
    set { state with workspaces }
  let teardownTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    runLifecycleTeardown kind runtime targetId replacementConfig
  try
    unless ← waitForPath sentinel do
      throw <| IO.userError s!"{kind.label}: backend did not enter shutdown"
    require s!"{kind.label}: teardown fixture should still be waiting for the backend"
      (!(← IO.hasFinished teardownTask))

    let queryTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      runtime.workspaceRoot? observerId
    let some queryOutcome ← waitForTaskBefore queryTask teardownTask
      | throw <| IO.userError s!"{kind.label}: unrelated workspace query blocked on teardown"
    let queryRoot ←
      match queryOutcome with
      | .ok queryRoot => pure queryRoot
      | .error err => throw err
    require s!"{kind.label}: unrelated workspace query should retain its root"
      (queryRoot == some observerRoot)
    require s!"{kind.label}: unrelated workspace query should finish before teardown"
      (!(← IO.hasFinished teardownTask))

    let teardownOutcome ← IO.wait teardownTask
    let teardownResult ←
      match teardownOutcome with
      | .ok result => pure result
      | .error err => throw err
    match teardownResult with
    | .error failure =>
        throw <| IO.userError s!"{kind.label}: lifecycle transition failed: {failure.error.message}"
    | .ok invalidatedHandles =>
        require s!"{kind.label}: lifecycle transition should invalidate handles" invalidatedHandles
  finally
    try
      session.proc.kill
    catch _ =>
      pure ()
    if ← sentinel.pathExists then
      IO.FS.removeFile sentinel

private def checkLifecycleTeardownConcurrency : IO Unit := do
  checkLifecycleTeardownReleasesStateMutex .reset
  checkLifecycleTeardownReleasesStateMutex .drop

private partial def waitForCancellation
    (cancelRef : IO.Ref Bool)
    (tries : Nat := 100) : IO Unit := do
  if ← cancelRef.get then
    pure ()
  else if tries == 0 then
    throw <| IO.userError "timed out waiting for runtime close cancellation"
  else
    IO.sleep 10
    waitForCancellation cancelRef (tries - 1)

private def checkSessionCloseAdmission : IO Unit := do
  let root := System.FilePath.mk "/tmp/beam-session-close-admission"
  let runtime ← Beam.Broker.ServerRuntime.create
    ({ root } : Beam.Broker.BrokerConfig) "fixture"
  let beforeClose ← runtime.dispatchRequest { op := .stats }
  require "stats should be admitted before session close" beforeClose.ok
  let active ←
    match ← ActiveRequestRegistry.register runtime.activeRequests none (some "close-drain") with
    | .ok active => pure active
    | .error failure => throw <| IO.userError failure.message
  let closeTask ← IO.asTask (prio := Task.Priority.dedicated) runtime.close
  waitForCancellation active.cancelRef
  let concurrentCloseTask ← IO.asTask (prio := Task.Priority.dedicated) runtime.close
  IO.sleep 10
  require "runtime close should wait for admitted dispatch scopes"
    (!(← IO.hasFinished closeTask))
  require "concurrent runtime close should share the same drain"
    (!(← IO.hasFinished concurrentCloseTask))
  ActiveRequestRegistry.unregister runtime.activeRequests (some active)
  match ← IO.wait closeTask with
  | .ok () => pure ()
  | .error err => throw err
  match ← IO.wait concurrentCloseTask with
  | .ok () => pure ()
  | .error err => throw err
  runtime.close
  let afterClose ← runtime.dispatchRequest { op := .stats }
  require "ordinary requests should be rejected after session close"
    (afterClose.error?.any fun err => err.code == "requestCancelled")
  let shutdown ← runtime.dispatchRequest { op := .shutdown }
  require "shutdown remains idempotent after admission closes" shutdown.ok
  require "closed admission should leave no active request"
    ((← ActiveRequestRegistry.count runtime.activeRequests) == 0)

private def checkWrapperDaemonAuthorization : IO Unit := do
  let root := System.FilePath.mk "/tmp/beam-wrapper-daemon-authorization"
  let capability := "generation-secret"
  let runtime ← Beam.Broker.ServerRuntime.create
    ({ root } : Beam.Broker.BrokerConfig) "fixture"
    (some { daemonId := "generation-a", configHash := "config-a" })
    (some capability)
  try
    for (label, capability?) in [
        ("missing", none),
        ("wrong", some "another-generation-secret")
      ] do
      let response ← runtime.dispatchRequest {
        op := .stats
        daemonCapability? := capability?
      }
      require s!"wrapper daemon should reject {label} capability"
        (response.error?.any fun err =>
          err.code == "invalidParams" && err.message.contains "invalid Beam daemon capability")

    let stats ← runtime.dispatchRequest {
      op := .stats
      daemonCapability? := some capability
    }
    require "wrapper daemon should admit the exact generation capability" stats.ok

    for op in [Op.initWorkspace, .listWorkspaces, .dropWorkspace] do
      let response ← runtime.dispatchRequest {
        op
        workspaceId? := some "fixture"
        daemonCapability? := some capability
      }
      require s!"wrapper daemon should disable dynamic {op.key}"
        (response.error?.any fun err =>
          err.code == "invalidParams" && err.message.contains "wrapper-owned daemon mode")
  finally
    runtime.close

def main : IO Unit := do
  checkResponseJsonShape
  checkStreamMessageDecode
  checkResponseJsonDecode
  checkSaveResultJsonDecode
  checkOrderedJsonPretty
  checkSyncFileResultDecode
  checkFailureResponseConversions
  checkDocumentVersionMismatchErrorData
  checkReadinessBoundary
  checkStaleDirectDepHints
  checkRequestArgsBoundary
  checkWorkspaceRoutingFields
  checkProjectRequestBoundary
  checkWorkspaceLifecycleProtocol
  checkLifecycleTeardownConcurrency
  checkSessionCloseAdmission
  checkWrapperDaemonAuthorization

end BeamTest.Broker.ProtocolTest

def main := BeamTest.Broker.ProtocolTest.main
