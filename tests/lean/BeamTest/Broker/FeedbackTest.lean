/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Feedback
import Beam.Version
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.FeedbackTest

private def homeFixture : IO String := do
  let home? ← IO.getEnv "HOME"
  pure <| home?.getD "/tmp/beam-feedback-home"

private def localPathFromResult (home path : String) : System.FilePath :=
  if path.startsWith "~/" then
    System.FilePath.mk <| home ++ (path.drop 1).toString
  else
    System.FilePath.mk path

private def removeTempDir (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    IO.FS.removeDirAll path

private def withTempPath
    (stem : String)
    (action : System.FilePath → IO α) : IO α := do
  let scratchRoot := (← IO.currentDir) / ".lake" / "build" / "beam-feedback-test-scratch"
  IO.FS.createDirAll scratchRoot
  let path := scratchRoot / s!"{stem}-{← IO.monoNanosNow}"
  try
    action path
  finally
    removeTempDir path

private def withTempDir
    (stem : String)
    (action : System.FilePath → IO α) : IO α :=
  withTempPath stem fun path => do
    IO.FS.createDirAll path
    action path

private def inspectZipArchive (path : System.FilePath) : IO Json := do
  let script := String.intercalate "\n" [
    "import json, sys, zipfile",
    "with zipfile.ZipFile(sys.argv[1]) as archive:",
    "    names = archive.namelist()",
    "    reports = [name for name in names if name.endswith('/report.json')]",
    "    if len(reports) != 1:",
    "        raise RuntimeError(f'expected one report.json, got {reports}')",
    "    report = json.loads(archive.read(reports[0]).decode('utf-8'))",
    "    print(json.dumps({'names': names, 'report': report}))"
  ]
  let out ← IO.Process.output {
    cmd := "python3"
    args := #["-c", script, path.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to inspect confidential feedback ZIP\n{out.stderr}"
  expectOk "parse confidential feedback ZIP inspection" <| Json.parse out.stdout

private def expectFailureContaining
    (label expected : String)
    (action : IO α) : IO Unit := do
  let failure? ←
    try
      discard <| action
      pure none
    catch e =>
      pure (some e.toString)
  let some failure := failure?
    | throw <| IO.userError s!"{label}: expected failure"
  require s!"{label}: expected error to contain '{expected}', got '{failure}'"
    (failure.contains expected)

private def sampleInput (home : String) : Beam.Feedback.Input := {
  title := "Daemon startup failure"
  summary := s!"Beam failed while reading {home}/project/Demo.lean"
  reproduction := s!"cd {home}/project && lean-beam run-at Demo.lean 1 0"
  expected := "The request should return a structured Beam response."
  actual := "The daemon connection closed before a response was returned."
  kind? := some .bug
  severity? := some .high
  tags := #["daemon", "feedback"]
  clientRequestId? := some "req-123"
  request? := some <| Json.mkObj [("path", toJson s!"{home}/project/Demo.lean")]
  response? := some <| Json.mkObj [("ok", toJson false)]
}

private def sampleCollection (home : String) : Beam.Feedback.Collection := {
  generatedAt := "2026-07-06T10:11:12Z"
  activeRoot? := some s!"{home}/project"
  data := Json.mkObj [
    ("identity", Json.mkObj [
      ("name", toJson "lean-beam-mcp"),
      ("version", toJson "0.2.0-beta"),
      ("mcp_protocol", toJson Beam.Version.mcpProtocolVersion),
      ("beam_cli", toJson s!"{home}/beam-cli"),
      ("source_commit", toJson "0123456789abcdef"),
      ("source_branch", toJson "feedback"),
      ("source_dirty", toJson true),
      ("runtime_active", toJson true),
      ("runtime_current", toJson false),
      ("runtime_error", toJson "invalid install manifest")
    ]),
    ("stats", Json.mkObj [("requests", toJson (3 : Nat))]),
    ("openFiles", Json.arr #[Json.mkObj [("path", toJson s!"{home}/project/Demo.lean")]]),
    ("daemon", Json.mkObj [
      ("registryEndpoint", toJson "127.0.0.1:1234"),
      ("recentDaemonIncidents", Json.arr #[])
    ])
  ]
  warnings := #["fixture warning"]
}

private def minimalInputJson
    (title : String)
    (fields : List (String × Json) := []) : Json :=
  Json.mkObj <| [
    ("title", toJson title),
    ("summary", toJson "Report."),
    ("reproduction", toJson "Call feedback."),
    ("expected", toJson "A report."),
    ("actual", toJson "An error.")
  ] ++ fields

private def checkRenderAndRedaction : IO Unit := do
  let home ← homeFixture
  let result ← Beam.Feedback.buildResult (sampleInput home) (sampleCollection home)
  require "report card title" (result.markdown.contains "# Daemon startup failure")
  require "non-confidential report card carries a public-sharing warning"
    (result.markdown.contains "Review before posting publicly")
  require "report card explains that feedback is not submitted automatically"
    (result.markdown.contains "Beam does not submit feedback automatically")
  require "report card summary section" (result.markdown.contains "## Summary")
  require "report card summary includes kind" (result.markdown.contains "- Kind: `bug`")
  require "report card summary includes severity" (result.markdown.contains "- Severity: `high`")
  require "report card runtime section" (result.markdown.contains "## Beam Runtime")
  require "report card runtime section includes stale installed runtime"
    (result.markdown.contains "- runtime current: `false`")
  require "report card runtime section includes installed runtime error"
    (result.markdown.contains "- runtime error: `invalid install manifest`")
  require "report card runtime section includes source" (result.markdown.contains "commit 0123456789ab")
  require "report card debug context section" (result.markdown.contains "## Beam Debug Context")
  require "report card should render each collection warning once"
    (result.markdown.contains "Collection warnings:" &&
      (result.markdown.splitOn "fixture warning").length == 2)
  requireJsonString "feedback metadata" "schema" "beam.feedback.report-card.v1" result.metadata
  requireJsonString "feedback metadata" "kind" "bug" result.metadata
  requireJsonString "feedback metadata" "severity" "high" result.metadata
  requireJsonString "feedback metadata" "client_request_id" "req-123" result.metadata
  let compact ← Beam.Feedback.renderMcpMarkdown (sampleInput home) (sampleCollection home) false
  require "compact MCP markdown keeps title" (compact.contains "# Daemon startup failure")
  require "compact MCP markdown keeps runtime summary" (compact.contains "## Beam Runtime")
  require "compact MCP markdown omits full debug context" (!compact.contains "## Beam Debug Context")
  require "compact MCP markdown omits collected JSON keys" (!compact.contains "\"openFiles\"")
  let full ← Beam.Feedback.renderMcpMarkdown (sampleInput home) (sampleCollection home) true
  require "full MCP markdown keeps full debug context" (full.contains "## Beam Debug Context")
  if !home.isEmpty then
    require "markdown should redact HOME" (!result.markdown.contains home)
    require "collected debug data should redact HOME" (!result.collected.compress.contains home)
    require "compact MCP markdown should redact HOME" (!compact.contains home)
    require "redacted report should still show a readable placeholder" (result.markdown.contains "~/project")

private def checkInputRoundTrip : IO Unit := do
  let home ← homeFixture
  let input : Beam.Feedback.Input := {
    sampleInput home with
      impact? := some "Blocks local proof repair."
      workaround? := some "Restart the daemon."
      evidence := #[
        { name := "trace.json", content? := some <| Json.mkObj [("path", toJson s!"{home}/trace")] },
        { name := "stderr.log", path? := some "stderr.log" }
      ]
      bundle := .zip
      redact := false
  }
  let json := toJson input
  requireJsonString "feedback input json" "client_request_id" "req-123" json
  requireJsonString "feedback input json" "kind" "bug" json
  requireJsonString "feedback input json" "severity" "high" json
  requireJsonString "feedback input json" "bundle" "zip" json
  requireJsonBool "feedback input json" "redact" false json
  requireFieldAbsent "feedback input json" "clientRequestId" json
  let decoded ← expectOk "feedback input round-trip" <| fromJson? (α := Beam.Feedback.Input) json
  require "decoded feedback client request id" (decoded.clientRequestId? == some "req-123")
  require "decoded feedback kind" (decoded.kind? == some .bug)
  require "decoded feedback severity" (decoded.severity? == some .high)
  require "decoded feedback evidence count" (decoded.evidence.size == 2)
  require "decoded feedback bundle" (decoded.bundle == .zip)
  require "decoded feedback redact" (!decoded.redact)
  let some firstEvidence := input.evidence[0]?
    | throw <| IO.userError "feedback input fixture missing first evidence"
  let evidenceJson := toJson firstEvidence
  requireJsonString "feedback evidence json" "name" "trace.json" evidenceJson
  requireFieldAbsent "feedback evidence json" "content?" evidenceJson

private def checkConfidentialOutput : IO Unit := do
  let home ← homeFixture
  let secretCode := "PRIVATE_LEAN_CODE_7f9d"
  let narrativeMarker := "CALLER_NARRATIVE_RETAINED_7f9d"
  let privateRoot := "/srv/private/customer-project"
  let input : Beam.Feedback.Input := {
    sampleInput home with
      summary := s!"{narrativeMarker}: Beam failed while reading {home}/project/Demo.lean"
      confidential := true
      clientRequestId? := some s!"request-{secretCode}"
      request? := some <| Json.mkObj [("source", toJson secretCode)]
      response? := some <| Json.mkObj [("diagnostic", toJson secretCode)]
      evidence := #[{ name := "private.lean", content? := some <| toJson secretCode }]
  }
  let collection : Beam.Feedback.Collection := {
    sampleCollection home with
      activeRoot? := some privateRoot
      data := Json.mkObj [
        ("identity", Json.mkObj [
          ("name", toJson "lean-beam-mcp"),
          ("version", toJson "0.2.0-beta"),
          ("mcp_protocol", toJson "2025-11-25"),
          ("runtime_active", toJson true),
          ("source_branch", toJson secretCode)
        ]),
        ("stats", Json.mkObj [("source", toJson secretCode)]),
        ("openFiles", Json.arr #[Json.mkObj [("path", toJson s!"{privateRoot}/Secret.lean")]]),
        ("daemon", Json.mkObj [("startupLogTail", toJson secretCode)])
      ]
      warnings := #[s!"private warning: {secretCode}"]
  }
  let result ← Beam.Feedback.buildResult input collection
  let output := result.toJson.compress
  require "confidential report is visibly marked"
    (result.markdown.contains "Confidential report: do not post this report publicly")
  require "confidential report does not render the non-confidential sharing warning"
    (!result.markdown.contains "This non-confidential report may include")
  require "confidential report explains retained caller narrative"
    (result.markdown.contains
      "Caller-authored narrative is retained except for HOME-path redaction")
  require "confidential output retains caller-authored narrative"
    (result.markdown.contains narrativeMarker)
  if !home.isEmpty then
    require "confidential caller narrative still redacts HOME paths"
      (result.markdown.contains "~/project/Demo.lean" && !result.markdown.contains home)
  require "confidential output omits caller-supplied request, response, evidence, and ids"
    (!output.contains secretCode)
  require "confidential output omits the active project root" (!output.contains privateRoot)
  require "confidential output omits collected project context"
    (!output.contains "openFiles" && !output.contains "startupLogTail")
  require "confidential output retains safe runtime identity"
    (output.contains "lean-beam-mcp" && output.contains "0.2.0-beta")
  requireJsonBool "confidential feedback metadata" "confidential" true result.metadata
  requireJsonBool "confidential feedback metadata" "redacted" true result.metadata
  requireJsonNull "confidential feedback metadata" "active_root" result.metadata
  requireJsonNull "confidential feedback metadata" "client_request_id" result.metadata
  require "confidential output does not misuse collection warnings for policy notices"
    result.collectionWarnings.isEmpty
  let full ← Beam.Feedback.renderMcpMarkdown input collection true
  require "confidential MCP include_collected cannot restore project context"
    (!full.contains secretCode && !full.contains privateRoot && !full.contains "openFiles")

  let json := toJson input
  requireJsonBool "confidential feedback input json" "confidential" true json
  let decoded ← expectOk "confidential feedback input round-trip" <|
    fromJson? (α := Beam.Feedback.Input) json
  require "decoded feedback confidential flag" decoded.confidential
  let normalizedJson := toJson { input with redact := false }
  requireFieldAbsent "confidential feedback normalized input json" "redact" normalizedJson
  let normalized ← expectOk "confidential feedback normalized input round-trip" <|
    fromJson? (α := Beam.Feedback.Input) normalizedJson
  require "confidential feedback serialization should restore required redaction"
    (normalized.confidential && normalized.redact)

private def checkInputErrorMessages : IO Unit := do
  match fromJson? (α := Beam.Feedback.Input) Json.null with
  | .ok _ =>
      throw <| IO.userError "non-object feedback input decoded unexpectedly"
  | .error err =>
      require "non-object feedback input error should name JSON object requirement"
        (err.contains "feedback input must be a JSON object")

  match fromJson? (α := Beam.Feedback.Input) (Json.mkObj []) with
  | .ok _ =>
      throw <| IO.userError "empty feedback input decoded unexpectedly"
  | .error err =>
      require "empty feedback input error should name missing title"
        (err.contains "missing required string field 'title'")

  match fromJson? (α := Beam.Feedback.Input) <| Json.mkObj [
    ("title", toJson (3 : Nat))
  ] with
  | .ok _ =>
      throw <| IO.userError "wrong-type feedback title decoded unexpectedly"
  | .error err =>
      require "wrong-type feedback title error should name the field"
        (err.contains "field 'title' must be a string")

  match fromJson? (α := Beam.Feedback.Input) <| minimalInputJson "Bad kind" [
    ("kind", toJson "incident")
  ] with
  | .ok _ =>
      throw <| IO.userError "invalid feedback kind decoded unexpectedly"
  | .error err =>
      require "invalid feedback kind error should name allowed values"
        (err.contains "expected feedback kind")

  match fromJson? (α := Beam.Feedback.Input) <| minimalInputJson "Conflicting privacy options" [
    ("confidential", toJson true),
    ("redact", toJson false)
  ] with
  | .ok _ =>
      throw <| IO.userError "confidential feedback with disabled redaction decoded unexpectedly"
  | .error err =>
      require "confidential feedback should require redaction"
        (err.contains "'confidential' requires redaction")

  match fromJson? (α := Beam.Feedback.Input) <| minimalInputJson "Misspelled confidentiality" [
    ("confidental", toJson true)
  ] with
  | .ok _ =>
      throw <| IO.userError "unknown feedback input field decoded unexpectedly"
  | .error err =>
      require "unknown feedback input fields should fail closed"
        (err.contains "feedback input accepts no undeclared fields: confidental")

  match fromJson? (α := Beam.Feedback.EvidenceInput) <| Json.mkObj [
    ("name", toJson "trace.log"),
    ("path", toJson "trace.log"),
    ("confidential", toJson true)
  ] with
  | .ok _ =>
      throw <| IO.userError "unknown feedback evidence field decoded unexpectedly"
  | .error err =>
      require "unknown feedback evidence fields should be rejected"
        (err.contains "feedback evidence entry accepts no undeclared fields: confidential")

  match fromJson? (α := Beam.Feedback.Input) <| minimalInputJson "Invalid request payload" [
    ("request", toJson "not-an-object")
  ] with
  | .ok _ =>
      throw <| IO.userError "non-object feedback request decoded unexpectedly"
  | .error err =>
      require "feedback request should require a JSON object"
        (err.contains "invalid 'request': expected a JSON object")

  match fromJson? (α := Beam.Feedback.Input) <| minimalInputJson "Invalid response payload" [
    ("response", Json.arr #[])
  ] with
  | .ok _ =>
      throw <| IO.userError "non-object feedback response decoded unexpectedly"
  | .error err =>
      require "feedback response should require a JSON object"
        (err.contains "invalid 'response': expected a JSON object")

private def checkBundleWrite : IO Unit := do
  let home ← homeFixture
  withTempDir "beam-feedback-test" fun root => do
    IO.FS.writeFile (root / "trace.log") s!"raw trace from {home}/project\n"
    let input : Beam.Feedback.Input := {
      sampleInput home with
        bundle := .dir
        evidence := #[
          { name := "trace.log", path? := some "trace.log" },
          { name := "inline.json", content? := some <| Json.mkObj [("root", toJson s!"{home}/project")] }
        ]
    }
    let result ← Beam.Feedback.buildResult input (sampleCollection home) {
      root? := some root
      allowedRoots := #[root]
    }
    let some bundleDirText := result.bundleDir?
      | throw <| IO.userError "feedback bundle did not report bundle_dir"
    let bundleDir := localPathFromResult home bundleDirText
    require "feedback bundle directory exists" (← bundleDir.pathExists)
    let card ← IO.FS.readFile (bundleDir / "card.md")
    require "bundle card contains report title" (card.contains "# Daemon startup failure")
    let metadataText ← IO.FS.readFile (bundleDir / "metadata.json")
    let metadata ← expectOk "parse feedback metadata bundle json" <| Json.parse metadataText
    requireJsonString "feedback bundle metadata" "schema" "beam.feedback.report-card.v1" metadata
    let collectedText ← IO.FS.readFile (bundleDir / "collected.json")
    let collected ← expectOk "parse feedback collected bundle json" <| Json.parse collectedText
    discard <| requireObjVal "feedback bundle collected" "daemon" collected
    let reportText ← IO.FS.readFile (bundleDir / "report.json")
    let report ← expectOk "parse feedback report bundle json" <| Json.parse reportText
    discard <| requireObjVal "feedback bundle report" "collected" report
    discard <| requireObjVal "feedback bundle report" "collection_warnings" report
    let trace ← IO.FS.readFile (bundleDir / "evidence" / "trace.log")
    if !home.isEmpty then
      require "file evidence should be redacted" (!trace.contains home)
    let inline ← IO.FS.readFile (bundleDir / "evidence" / "inline.json")
    require "inline evidence is written" (inline.contains "project")

    let repeatedResult ← Beam.Feedback.buildResult input (sampleCollection home) {
      root? := some root
      allowedRoots := #[root]
    }
    let some repeatedBundleDirText := repeatedResult.bundleDir?
      | throw <| IO.userError "repeated feedback bundle did not report bundle_dir"
    let repeatedBundleDir := localPathFromResult home repeatedBundleDirText
    require "sequential feedback bundles should use distinct paths"
      (repeatedBundleDir.toString != bundleDir.toString)
    require "repeated feedback bundle directory exists" (← repeatedBundleDir.pathExists)
    let originalCard ← IO.FS.readFile (bundleDir / "card.md")
    require "sequential feedback bundle should not overwrite the original bundle"
      (originalCard == card)

private def checkEvidencePathBoundary : IO Unit := do
  let home ← homeFixture
  withTempDir "beam-feedback-allowed-root" fun root =>
    withTempDir "beam-feedback-outside-root" fun outsideRoot => do
      let invalidNameInput : Beam.Feedback.Input := {
        sampleInput home with
          bundle := .dir
          evidence := #[{ name := "../private.txt", content? := some <| toJson "private" }]
      }
      expectFailureContaining "path-like evidence name rejection"
          "use a simple filename without path separators" <|
        Beam.Feedback.buildResult invalidNameInput (sampleCollection home) {
            root? := some root
            allowedRoots := #[root]
          }

      let outsidePath := outsideRoot / "private.txt"
      IO.FS.writeFile outsidePath "outside allowed feedback roots\n"
      let input : Beam.Feedback.Input := {
        sampleInput home with
          bundle := .dir
          evidence := #[{ name := "private.txt", path? := some outsidePath.toString }]
      }
      expectFailureContaining "outside evidence rejection"
          "feedback evidence path is outside the allowed roots" <|
        Beam.Feedback.buildResult input (sampleCollection home) {
            root? := some root
            allowedRoots := #[root]
          }

private def checkConfidentialBundleWrite (mode : Beam.Feedback.BundleMode) : IO Unit := do
  let home ← homeFixture
  let privatePath := "private-customer-project-4a2c"
  withTempDir s!"beam-feedback-confidential-{mode.key}-test-{privatePath}" fun root => do
    let secretCode := "PRIVATE_BUNDLE_CODE_4a2c"
    let input : Beam.Feedback.Input := {
      sampleInput home with
        confidential := true
        bundle := mode
        request? := some <| Json.mkObj [("source", toJson secretCode)]
        evidence := #[
          { name := "private.lean", content? := some <| toJson secretCode },
          { name := "outside.txt", path? := some "/etc/passwd" }
        ]
    }
    let result ← Beam.Feedback.buildResult input (sampleCollection home) {
      root? := some root
      allowedRoots := #[root]
    }
    let some bundleDirText := result.bundleDir?
      | throw <| IO.userError "confidential feedback bundle did not report bundle_dir"
    require "confidential local result retains its operational bundle path"
      (bundleDirText.contains privatePath)
    let bundleDir := localPathFromResult home bundleDirText
    require "confidential bundle does not write caller-supplied evidence"
      (!(← (bundleDir / "evidence").pathExists))
    for name in #["card.md", "metadata.json", "collected.json", "report.json"] do
      let text ← IO.FS.readFile (bundleDir / name)
      require s!"confidential bundle {name} should omit private source" (!text.contains secretCode)
      require s!"confidential bundle {name} should omit project debug context"
        (!text.contains "openFiles")
      require s!"confidential bundle {name} should omit its private project path"
        (!text.contains privatePath)
    let reportText ← IO.FS.readFile (bundleDir / "report.json")
    let report ← expectOk "parse confidential feedback bundle report" <| Json.parse reportText
    requireFieldAbsent "confidential feedback bundle report" "bundle_dir" report
    requireFieldAbsent "confidential feedback bundle report" "zip_path" report
    match mode, result.zipPath? with
    | .zip, some zipPathText =>
        let archive ← inspectZipArchive (localPathFromResult home zipPathText)
        let names ← expectOk "decode confidential feedback ZIP members" <|
          archive.getObjValAs? (Array String) "names"
        require "confidential feedback ZIP should omit caller-supplied evidence"
          (!names.any (·.contains "/evidence/"))
        let archivedReport ← requireObjVal "confidential feedback ZIP inspection" "report" archive
        let archivedOutput := archivedReport.compress
        require "confidential feedback ZIP report should omit private source"
          (!archivedOutput.contains secretCode)
        require "confidential feedback ZIP report should omit project debug context"
          (!archivedOutput.contains "openFiles")
        require "confidential feedback ZIP report should omit its private project path"
          (!archivedOutput.contains privatePath)
        requireFieldAbsent "confidential feedback ZIP report" "bundle_dir" archivedReport
        requireFieldAbsent "confidential feedback ZIP report" "zip_path" archivedReport
    | .zip, none =>
        require "confidential feedback ZIP failure should be reported as a warning"
          (result.collectionWarnings.any (·.contains "zip"))
    | _, _ => pure ()

private def checkZipBundleReportRoundTrip : IO Unit := do
  let home ← homeFixture
  withTempDir "beam-feedback-zip-test" fun root => do
    let input : Beam.Feedback.Input := {
      sampleInput home with
        bundle := .zip
    }
    let result ← Beam.Feedback.buildResult input (sampleCollection home) {
      root? := some root
      allowedRoots := #[root]
    }
    let some bundleDirText := result.bundleDir?
      | throw <| IO.userError "feedback zip bundle did not report bundle_dir"
    let bundleDir := localPathFromResult home bundleDirText
    let reportText ← IO.FS.readFile (bundleDir / "report.json")
    let report ← expectOk "parse feedback zip report bundle json" <| Json.parse reportText
    match result.zipPath? with
    | some zipPath =>
        requireJsonString "feedback zip bundle report" "zip_path" zipPath report
        require "feedback zip archive exists" (← (localPathFromResult home zipPath).pathExists)
    | none =>
        requireFieldAbsent "feedback zip bundle report" "zip_path" report
        let warnings ← requireObjVal "feedback zip bundle report" "collection_warnings" report
        require "feedback zip warning is recorded in report"
          (warnings.compress.contains "zip")

private def checkUnredactedBundlePaths : IO Unit := do
  let home ← homeFixture
  withTempDir "beam-feedback-unredacted-root" fun root =>
    withTempPath "beam-feedback-unredacted-output" fun outputDir => do
      let input : Beam.Feedback.Input := {
        sampleInput home with
          bundle := .dir
          redact := false
      }
      let result ← Beam.Feedback.buildResult input (sampleCollection home) {
        root? := some root
        outputDir? := some outputDir
        allowedRoots := #[root]
      }
      let some bundleDirText := result.bundleDir?
        | throw <| IO.userError "unredacted feedback bundle did not report bundle_dir"
      require "unredacted bundle_dir should be the local output path"
        (bundleDirText == outputDir.toString)
      require "unredacted bundle_dir should not use home placeholder" (!bundleDirText.contains "~")
      let reportText ← IO.FS.readFile (System.FilePath.mk bundleDirText / "report.json")
      let report ← expectOk "parse unredacted feedback report bundle json" <| Json.parse reportText
      requireJsonString "unredacted feedback bundle report" "bundle_dir" bundleDirText report

def main : IO Unit := do
  checkRenderAndRedaction
  checkInputRoundTrip
  checkConfidentialOutput
  checkInputErrorMessages
  checkBundleWrite
  checkEvidencePathBoundary
  checkConfidentialBundleWrite .dir
  checkConfidentialBundleWrite .zip
  checkZipBundleReportRoundTrip
  checkUnredactedBundlePaths

end BeamTest.Broker.FeedbackTest

def main := BeamTest.Broker.FeedbackTest.main
