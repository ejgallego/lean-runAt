/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.JsonPretty
import Beam.Path

open Lean

namespace Beam.Feedback

inductive BundleMode where
  | none
  | dir
  | zip
  deriving BEq, Repr

def BundleMode.key : BundleMode → String
  | .none => "none"
  | .dir => "dir"
  | .zip => "zip"

instance : ToJson BundleMode where
  toJson mode := toJson mode.key

instance : FromJson BundleMode where
  fromJson?
    | .str "none" => .ok .none
    | .str "dir" => .ok .dir
    | .str "zip" => .ok .zip
    | j => .error s!"expected feedback bundle mode 'none', 'dir', or 'zip', got {j.compress}"

def bundleModeKeys : Array String :=
  #["none", "dir", "zip"]

inductive ReportKind where
  | bug
  | ux
  | perf
  | docs
  | question
  deriving BEq, Repr

def ReportKind.key : ReportKind → String
  | .bug => "bug"
  | .ux => "ux"
  | .perf => "perf"
  | .docs => "docs"
  | .question => "question"

instance : ToJson ReportKind where
  toJson kind := toJson kind.key

instance : FromJson ReportKind where
  fromJson?
    | .str "bug" => .ok .bug
    | .str "ux" => .ok .ux
    | .str "perf" => .ok .perf
    | .str "docs" => .ok .docs
    | .str "question" => .ok .question
    | j => .error s!"expected feedback kind 'bug', 'ux', 'perf', 'docs', or 'question', got {j.compress}"

def reportKindKeys : Array String :=
  #["bug", "ux", "perf", "docs", "question"]

inductive ReportSeverity where
  | low
  | medium
  | high
  | critical
  deriving BEq, Repr

def ReportSeverity.key : ReportSeverity → String
  | .low => "low"
  | .medium => "medium"
  | .high => "high"
  | .critical => "critical"

instance : ToJson ReportSeverity where
  toJson severity := toJson severity.key

instance : FromJson ReportSeverity where
  fromJson?
    | .str "low" => .ok .low
    | .str "medium" => .ok .medium
    | .str "high" => .ok .high
    | .str "critical" => .ok .critical
    | j => .error s!"expected feedback severity 'low', 'medium', 'high', or 'critical', got {j.compress}"

def reportSeverityKeys : Array String :=
  #["low", "medium", "high", "critical"]

def requiredInputFields : Array String :=
  #["title", "summary", "reproduction", "expected", "actual"]

def optionalInputFields : Array String :=
  #[
    "kind", "severity", "impact", "workaround", "tags", "client_request_id", "request",
    "response", "evidence", "bundle", "redact", "confidential"
  ]

def inputFields : Array String :=
  requiredInputFields ++ optionalInputFields

def requiredInputFieldsText : String :=
  String.intercalate ", " requiredInputFields.toList

private def requireObject (label : String) : Json → Except String Unit
  | Json.obj _ => pure ()
  | other => throw s!"{label}, got {other.compress}"

private def requireOnlyFields
    (label : String)
    (allowed : Array String) : Json → Except String Unit
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"{label} accepts no undeclared fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"{label} must be a JSON object, got {other.compress}"

private def optionalField? [FromJson α] (json : Json) (field : String) : Except String (Option α) := do
  match json.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

private def optionalObjectField? (json : Json) (field : String) : Except String (Option Json) := do
  match json.getObjVal? field with
  | .ok value@(.obj _) => pure (some value)
  | .ok other => throw s!"invalid '{field}': expected a JSON object, got {other.compress}"
  | .error _ => pure none

private def requiredString (json : Json) (field : String) : Except String String := do
  match json.getObjVal? field with
  | .error _ =>
      throw s!"missing required string field '{field}'"
  | .ok (.str value) =>
      if value.trimAscii.isEmpty then
        throw s!"'{field}' must not be empty"
      pure value
  | .ok other =>
      throw s!"field '{field}' must be a string, got {other.compress}"

structure EvidenceInput where
  name : String
  content? : Option Json := none
  path? : Option String := none

instance : FromJson EvidenceInput where
  fromJson? json := do
    requireOnlyFields "feedback evidence entry" #["name", "content", "path"] json
    let name ← requiredString json "name"
    let content? ← optionalField? (α := Json) json "content"
    let path? ← optionalField? (α := String) json "path"
    if content?.isSome && path?.isSome then
      throw "feedback evidence accepts either 'content' or 'path', not both"
    if content?.isNone && path?.isNone then
      throw "feedback evidence requires 'content' or 'path'"
    pure { name, content?, path? }

instance : ToJson EvidenceInput where
  toJson evidence :=
    Json.mkObj <|
      [("name", toJson evidence.name)] ++
      (match evidence.content? with
      | some content => [("content", content)]
      | none => []) ++
      match evidence.path? with
      | some path => [("path", toJson path)]
      | none => []

structure Input where
  title : String
  summary : String
  reproduction : String
  expected : String
  actual : String
  kind? : Option ReportKind := none
  severity? : Option ReportSeverity := none
  impact? : Option String := none
  workaround? : Option String := none
  tags : Array String := #[]
  clientRequestId? : Option String := none
  request? : Option Json := none
  response? : Option Json := none
  evidence : Array EvidenceInput := #[]
  bundle : BundleMode := .none
  redact : Bool := true
  confidential : Bool := false

instance : FromJson Input where
  fromJson? json := do
    requireObject
      s!"feedback input must be a JSON object with required string fields: {requiredInputFieldsText}"
      json
    requireOnlyFields "feedback input" inputFields json
    let title ← requiredString json "title"
    let summary ← requiredString json "summary"
    let reproduction ← requiredString json "reproduction"
    let expected ← requiredString json "expected"
    let actual ← requiredString json "actual"
    let kind? ← optionalField? (α := ReportKind) json "kind"
    let severity? ← optionalField? (α := ReportSeverity) json "severity"
    let impact? ← optionalField? (α := String) json "impact"
    let workaround? ← optionalField? (α := String) json "workaround"
    let tags? ← optionalField? (α := Array String) json "tags"
    let tags := tags?.map (·.filter (fun tag => !tag.trimAscii.isEmpty)) |>.getD #[]
    let clientRequestId? ← optionalField? (α := String) json "client_request_id"
    let request? ← optionalObjectField? json "request"
    let response? ← optionalObjectField? json "response"
    let evidence? ← optionalField? (α := Array EvidenceInput) json "evidence"
    let evidence := evidence?.getD #[]
    let bundle? ← optionalField? (α := BundleMode) json "bundle"
    let bundle := bundle?.getD .none
    let redact? ← optionalField? (α := Bool) json "redact"
    let redact := redact?.getD true
    let confidential? ← optionalField? (α := Bool) json "confidential"
    let confidential := confidential?.getD false
    if confidential && !redact then
      throw "'confidential' requires redaction; remove 'redact': false"
    pure {
      title, summary, reproduction, expected, actual,
      kind?, severity?, impact?, workaround?, tags, clientRequestId?, request?, response?,
      evidence, bundle, redact, confidential
    }

instance : ToJson Input where
  toJson input :=
    Json.mkObj <|
      [
        ("title", toJson input.title),
        ("summary", toJson input.summary),
        ("reproduction", toJson input.reproduction),
        ("expected", toJson input.expected),
        ("actual", toJson input.actual)
      ] ++
      (match input.kind? with
      | some kind => [("kind", toJson kind)]
      | none => []) ++
      (match input.severity? with
      | some severity => [("severity", toJson severity)]
      | none => []) ++
      (match input.impact? with
      | some impact => [("impact", toJson impact)]
      | none => []) ++
      (match input.workaround? with
      | some workaround => [("workaround", toJson workaround)]
      | none => []) ++
      (if input.tags.isEmpty then [] else [("tags", toJson input.tags)]) ++
      (match input.clientRequestId? with
      | some clientRequestId => [("client_request_id", toJson clientRequestId)]
      | none => []) ++
      (match input.request? with
      | some request => [("request", request)]
      | none => []) ++
      (match input.response? with
      | some response => [("response", response)]
      | none => []) ++
      (if input.evidence.isEmpty then [] else [("evidence", toJson input.evidence)]) ++
      (if input.bundle == .none then [] else [("bundle", toJson input.bundle)]) ++
      (if input.redact || input.confidential then [] else [("redact", toJson false)]) ++
      if input.confidential then [("confidential", toJson true)] else []

private def Input.forConfidentialOutput (input : Input) : Input :=
  if input.confidential then
    {
      input with
        clientRequestId? := none
        request? := none
        response? := none
        evidence := #[]
        redact := true
    }
  else
    input

/-- Whether bundle construction needs caller-approved roots for path-backed evidence. -/
def Internal.needsEvidenceRoots (input : Input) : Bool :=
  input.bundle != .none && !input.confidential &&
    input.evidence.any fun evidence => evidence.content?.isNone && evidence.path?.isSome

structure Collection where
  generatedAt : String
  activeRoot? : Option String := none
  data : Json := Json.mkObj []
  warnings : Array String := #[]

private def confidentialJsonField (json : Json) (field : String) : Json :=
  match json.getObjVal? field with
  | .ok value => value
  | .error _ => Json.null

private def confidentialIdentity (data : Json) : Json :=
  let identity := confidentialJsonField data "identity"
  Json.mkObj [
    ("name", confidentialJsonField identity "name"),
    ("version", confidentialJsonField identity "version"),
    ("mcp_protocol", confidentialJsonField identity "mcp_protocol"),
    ("runtime_active", confidentialJsonField identity "runtime_active")
  ]

private def Collection.forConfidential (collection : Collection) : Collection :=
  {
    generatedAt := collection.generatedAt
    data := Json.mkObj [("identity", confidentialIdentity collection.data)]
    warnings := #[]
  }

private def Collection.forInput (collection : Collection) (input : Input) : Collection :=
  if input.confidential then collection.forConfidential else collection

private def prepareOutput (input : Input) (collection : Collection) : Input × Collection :=
  let input := input.forConfidentialOutput
  (input, collection.forInput input)

structure BundleWriteOptions where
  root? : Option System.FilePath := none
  outputDir? : Option System.FilePath := none
  allowedRoots : Array System.FilePath := #[]

structure Result where
  markdown : String
  metadata : Json
  collected : Json
  collectionWarnings : Array String := #[]
  bundleDir? : Option String := none
  zipPath? : Option String := none

private def nonemptyLines (text : String) : String :=
  let trimmed := text.trimAscii.toString
  if trimmed.isEmpty then "_Not supplied._" else trimmed

private def mdSection (title body : String) : String :=
  s!"## {title}\n\n{nonemptyLines body}\n"

private def optSection (title : String) : Option String → String
  | some body =>
      if body.trimAscii.isEmpty then "" else "\n" ++ mdSection title body
  | none => ""

private def jsonBlock (json : Json) : String :=
  "```json\n" ++ Beam.orderedJsonPretty json ++ "\n```"

private def requestResponseSection (input : Input) : String :=
  let requestPart :=
    match input.request? with
    | some request => "\n### Request\n\n" ++ jsonBlock request ++ "\n"
    | none => ""
  let responsePart :=
    match input.response? with
    | some response => "\n### Response\n\n" ++ jsonBlock response ++ "\n"
    | none => ""
  if requestPart.isEmpty && responsePart.isEmpty then
    ""
  else
    "\n## Request And Response\n" ++ requestPart ++ responsePart

private def evidenceLine (evidence : EvidenceInput) : String :=
  match evidence.content?, evidence.path? with
  | some _, _ => s!"- `{evidence.name}`: inline evidence supplied by caller."
  | none, some path => s!"- `{evidence.name}`: file evidence from `{path}`."
  | none, none => s!"- `{evidence.name}`"

private def evidenceSection (input : Input) : String :=
  let lines := input.evidence.map evidenceLine
  let lines :=
    match input.clientRequestId? with
    | some id => #["- client request id: `" ++ id ++ "`"] ++ lines
    | none => lines
  if lines.isEmpty then
    ""
  else
    "\n" ++ mdSection "Evidence" (String.intercalate "\n" lines.toList)

private def code (value : String) : String :=
  "`" ++ value ++ "`"

private def optionalLine (label : String) (value? : Option String) : List String :=
  match value? with
  | some value => [s!"- {label}: {code value}"]
  | none => []

private def boolText (value : Bool) : String :=
  if value then "true" else "false"

private def shortCommit (commit : String) : String :=
  String.ofList <| commit.toList.take 12

private def jsonField? (json : Json) (field : String) : Option Json :=
  match json.getObjVal? field with
  | .ok value => some value
  | .error _ => none

private def jsonStringField? (json : Json) (field : String) : Option String :=
  match json.getObjValAs? String field with
  | .ok value => some value
  | .error _ => none

private def jsonBoolField? (json : Json) (field : String) : Option Bool :=
  match json.getObjValAs? Bool field with
  | .ok value => some value
  | .error _ => none

private def reportRoutingText (input : Input) : String :=
  let lines :=
    optionalLine "Kind" (input.kind?.map ReportKind.key) ++
    optionalLine "Severity" (input.severity?.map ReportSeverity.key) ++
    if input.tags.isEmpty then
      []
    else
      ["- Tags: " ++ String.intercalate ", " (input.tags.toList.map code)]
  if lines.isEmpty then
    ""
  else
    "\n\n" ++ String.intercalate "\n" lines

private def runtimeSummarySection (collection : Collection) : String :=
  let identity := (jsonField? collection.data "identity").getD Json.null
  let daemon := (jsonField? collection.data "daemon").getD Json.null
  let name? := jsonStringField? identity "name"
  let version? := jsonStringField? identity "version"
  let server? :=
    match name?, version? with
    | some name, some version => some s!"{name} {version}"
    | some name, none => some name
    | none, some version => some version
    | none, none => none
  let source? :=
    match jsonStringField? identity "source_branch", jsonStringField? identity "source_commit",
      jsonBoolField? identity "source_dirty" with
    | none, none, none => none
    | branch?, commit?, dirty? =>
        let parts :=
          (branch?.map (fun branch => s!"branch {branch}")).toList ++
          (commit?.map (fun commit => s!"commit {shortCommit commit}")).toList ++
          (dirty?.map (fun dirty => s!"dirty {boolText dirty}")).toList
        some <| String.intercalate ", " parts
  let activeRoot? :=
    match collection.activeRoot? with
    | some root => some root
    | none => jsonStringField? identity "active_root"
  let warningLines :=
    if collection.warnings.isEmpty then
      []
    else
      ["", "Collection warnings:"] ++ collection.warnings.toList.map (fun warning => "- " ++ warning)
  let lines :=
    ["- generated at: " ++ code collection.generatedAt] ++
    optionalLine "server" server? ++
    optionalLine "MCP protocol" (jsonStringField? identity "mcp_protocol") ++
    optionalLine "active root" activeRoot? ++
    optionalLine "runtime active" ((jsonBoolField? identity "runtime_active").map boolText) ++
    optionalLine "runtime current" ((jsonBoolField? identity "runtime_current").map boolText) ++
    optionalLine "runtime error" (jsonStringField? identity "runtime_error") ++
    optionalLine "source" source? ++
    optionalLine "daemon endpoint" (jsonStringField? daemon "registryEndpoint") ++
    warningLines
  mdSection "Beam Runtime" (String.intercalate "\n" lines)

private def environmentSection (collection : Collection) : String :=
  mdSection "Beam Debug Context" (jsonBlock collection.data)

private def sharingNotice (input : Input) : String :=
  if input.confidential then
    String.intercalate "\n" [
      "> [!IMPORTANT]",
      "> Confidential report: do not post this report publicly.",
      "> Project-derived debug context, request/response payloads, and evidence were omitted.",
      "> Caller-authored narrative is retained except for HOME-path redaction; review it for secrets",
      "> before sharing privately.",
      "",
      ""
    ]
  else
    String.intercalate "\n" [
      "> [!WARNING]",
      "> Review before posting publicly. This non-confidential report may include caller-authored",
      "> narrative, request/response payloads, local paths, Beam stats, open-file data, daemon",
      "> logs or incidents, and bundle evidence. Beam does not submit feedback automatically.",
      "",
      ""
    ]

private def renderMarkdownWithDebugContext
    (input : Input)
    (collection : Collection)
    (includeDebugContext : Bool) : String :=
  let debugContext :=
    if includeDebugContext then
      "\n" ++ environmentSection collection
    else
      ""
  "# " ++ input.title ++ "\n\n" ++
    sharingNotice input ++
    mdSection "Summary" (input.summary ++ reportRoutingText input) ++ "\n" ++
    runtimeSummarySection collection ++ "\n" ++
    mdSection "Reproduction" input.reproduction ++ "\n" ++
    mdSection "Expected Behavior" input.expected ++ "\n" ++
    mdSection "Actual Behavior" input.actual ++ "\n" ++
    optSection "Impact" input.impact? ++
    debugContext ++
    requestResponseSection input ++
    evidenceSection input ++
    optSection "Workaround" input.workaround?

private def metadataJsonPrepared (input : Input) (collection : Collection) : Json :=
  Json.mkObj [
    ("schema", toJson ("beam.feedback.report-card.v1" : String)),
    ("title", toJson input.title),
    ("kind", match input.kind? with | some kind => toJson kind | none => Json.null),
    ("severity", match input.severity? with | some severity => toJson severity | none => Json.null),
    ("generated_at", toJson collection.generatedAt),
    ("active_root", match collection.activeRoot? with | some root => toJson root | none => Json.null),
    ("tags", toJson input.tags),
    ("bundle", toJson input.bundle),
    ("redacted", toJson input.redact),
    ("confidential", toJson input.confidential),
    ("client_request_id", match input.clientRequestId? with | some id => toJson id | none => Json.null)
  ]

private def redactString (home? : Option String) (text : String) : String :=
  match home? with
  | some home =>
      if home.isEmpty then text else text.replace home "~"
  | none => text

private partial def redactJson (home? : Option String) : Json → Json
  | .str text => .str (redactString home? text)
  | .arr values => .arr (values.map (redactJson home?))
  | .obj fields =>
      Json.mkObj <| (Std.TreeMap.Raw.toList fields).map fun (key, value) =>
        (key, redactJson home? value)
  | other => other

private def redactResult (home? : Option String) (result : Result) : Result :=
  {
    result with
      markdown := redactString home? result.markdown
      metadata := redactJson home? result.metadata
      collected := redactJson home? result.collected
      collectionWarnings := result.collectionWarnings.map (redactString home?)
      bundleDir? := result.bundleDir?.map (redactString home?)
      zipPath? := result.zipPath?.map (redactString home?)
  }

def renderMcpMarkdown
    (input : Input)
    (collection : Collection)
    (includeCollected : Bool) : IO String := do
  let (input, collection) := prepareOutput input collection
  let markdown := renderMarkdownWithDebugContext input collection includeCollected
  if input.redact then
    let home? ← IO.getEnv "HOME"
    pure <| redactString home? markdown
  else
    pure markdown

private def renderPreparedResult (input : Input) (collection : Collection) : IO Result := do
  let result : Result := {
    markdown := renderMarkdownWithDebugContext input collection true
    metadata := metadataJsonPrepared input collection
    collected := collection.data
    collectionWarnings := collection.warnings
  }
  if input.redact then
    let home? ← IO.getEnv "HOME"
    pure <| redactResult home? result
  else
    pure result

private def resultPathFields (result : Result) : List (String × Json) :=
  (match result.bundleDir? with
  | some path => [("bundle_dir", toJson path)]
  | none => []) ++
  match result.zipPath? with
  | some path => [("zip_path", toJson path)]
  | none => []

private def jsonResultFields (result : Result) : List (String × Json) :=
  [
    ("markdown", toJson result.markdown),
    ("metadata", result.metadata),
    ("collected", result.collected),
    ("collection_warnings", toJson result.collectionWarnings)
  ] ++ resultPathFields result

def Result.toJson (result : Result) : Json :=
  Json.mkObj (jsonResultFields result)

def resultMcpJson
    (result : Result)
    (markdown : String)
    (includeCollected : Bool) : Json :=
  Json.mkObj <|
    [
      ("markdown", toJson markdown),
      ("metadata", result.metadata)
    ] ++
    (if includeCollected then [("collected", result.collected)] else []) ++
    [
      ("collection_warnings", toJson result.collectionWarnings)
    ] ++ resultPathFields result

private def validateEvidenceName (name : String) : Except String Unit := do
  if name.trimAscii.isEmpty then
    throw "evidence name must not be empty"
  if name.contains '/' || name.contains '\\' || (name.splitOn "..").length > 1 then
    throw s!"invalid evidence name '{name}': use a simple filename without path separators"

private def textForEvidenceContent (home? : Option String) (redact : Bool) (content : Json) : String :=
  let content :=
    if redact then
      redactJson home? content
    else
      content
  match content with
  | .str text => text
  | other => Beam.orderedJsonPretty other ++ "\n"

private def slugChar (c : Char) : Option Char :=
  let c := c.toLower
  if c.isAlphanum then
    some c
  else if c == '-' || c == '_' then
    some '-'
  else if c.isWhitespace then
    some '-'
  else
    none

private def collapseDashes (chars : List Char) : List Char :=
  let rec loop : List Char → Bool → List Char
    | [], _ => []
    | '-' :: rest, true => loop rest true
    | '-' :: rest, false => '-' :: loop rest true
    | c :: rest, _ => c :: loop rest false
  loop chars false

private def trimDashes (text : String) : String :=
  let chars := text.toList
  let chars := chars.dropWhile (· == '-')
  let chars := chars.reverse.dropWhile (· == '-')
  String.ofList chars.reverse

private def slugify (title : String) : String :=
  let chars := title.toList.filterMap slugChar |> collapseDashes
  let slug := trimDashes <| String.ofList chars
  if slug.isEmpty then "feedback" else String.ofList <| slug.toList.take 60

private partial def uniqueDir (base : System.FilePath) (n : Nat := 0) : IO System.FilePath := do
  let candidate :=
    if n == 0 then
      base
    else
      System.FilePath.mk s!"{base.toString}-{n}"
  if ← candidate.pathExists then
    uniqueDir base (n + 1)
  else
    pure candidate

private def defaultBundleBase (root : System.FilePath) (generatedAt title : String) : System.FilePath :=
  let stamp := (generatedAt.replace "-" "").replace ":" "" |>.replace "T" "-" |>.replace "Z" ""
  root / ".beam" / "feedback" / s!"{stamp}-{slugify title}"

private def resolveBundleDir
    (input : Input)
    (collection : Collection)
    (opts : BundleWriteOptions) : IO System.FilePath := do
  match opts.outputDir? with
  | some outputDir => uniqueDir outputDir
  | none =>
      match opts.root? with
      | some root => uniqueDir <| defaultBundleBase root collection.generatedAt input.title
      | none => throw <| IO.userError "feedback bundle output requires a project root or --output-dir"

private def resolveAllowedRoots (roots : Array System.FilePath) : IO (Array System.FilePath) := do
  let mut resolved := #[]
  for root in roots do
    try
      resolved := resolved.push (← IO.FS.realPath root)
    catch _ =>
      pure ()
  pure resolved

private def evidencePathAllowed (resolvedRoots : Array System.FilePath) (path : System.FilePath) :
    IO Bool := do
  let resolved ← IO.FS.realPath path
  for root in resolvedRoots do
    if (Beam.pathRelativeToRoot? root resolved).isSome then
      return true
  pure false

private def resolveEvidencePath
    (root? : Option System.FilePath)
    (pathText : String) : System.FilePath :=
  let path := System.FilePath.mk pathText
  if path.isAbsolute then
    path
  else
    match root? with
    | some root => root / path
    | none => path

private def writeEvidence
    (input : Input)
    (opts : BundleWriteOptions)
    (bundleDir : System.FilePath)
    (home? : Option String)
    (warnings : Array String) :
    IO (Array String) := do
  let evidenceDir := bundleDir / "evidence"
  let mut warnings := warnings
  if !input.evidence.isEmpty then
    IO.FS.createDirAll evidenceDir
  let allowedRoots ←
    if Internal.needsEvidenceRoots input then
      resolveAllowedRoots (opts.allowedRoots ++ #[bundleDir])
    else
      pure #[]
  for evidence in input.evidence do
    match validateEvidenceName evidence.name with
    | .error err => throw <| IO.userError err
    | .ok () => pure ()
    let target := evidenceDir / evidence.name
    match evidence.content?, evidence.path? with
    | some content, _ =>
        IO.FS.writeFile target <| textForEvidenceContent home? input.redact content
    | none, some pathText =>
        let source := resolveEvidencePath opts.root? pathText
        if ← evidencePathAllowed allowedRoots source then
          let text ← IO.FS.readFile source
          let text := if input.redact then redactString home? text else text
          IO.FS.writeFile target text
        else
          throw <| IO.userError s!"feedback evidence path is outside the allowed roots: {pathText}"
    | none, none =>
        warnings := warnings.push s!"evidence '{evidence.name}' had no content or path"
  pure warnings

private def expectedZipPath? (bundleDir : System.FilePath) : Option System.FilePath := do
  match bundleDir.parent, bundleDir.fileName with
  | some _, some _ => some <| System.FilePath.mk s!"{bundleDir.toString}.zip"
  | _, _ => none

private def zipBundle? (bundleDir : System.FilePath) : IO (Option System.FilePath × Option String) := do
  let some parent := bundleDir.parent
    | pure (none, some "could not zip feedback bundle without a parent directory")
  let some dirName := bundleDir.fileName
    | pure (none, some "could not zip feedback bundle without a directory name")
  let some zipPath := expectedZipPath? bundleDir
    | pure (none, some "could not derive feedback zip filename")
  let some zipName := zipPath.fileName
    | pure (none, some "could not derive feedback zip filename")
  try
    let out ← IO.Process.output {
      cmd := "zip"
      args := #["-rq", zipName, dirName]
      cwd := some parent.toString
    }
    if out.exitCode == 0 then
      pure (some zipPath, none)
    else
      pure (none, some s!"zip failed: {out.stderr.trimAscii.toString}")
  catch e =>
    pure (none, some s!"zip unavailable or failed: {e.toString}")

private def writePrettyJsonFile (path : System.FilePath) (json : Json) : IO Unit :=
  IO.FS.writeFile path (Beam.orderedJsonPretty json ++ "\n")

private def Result.withoutLocalPaths (result : Result) : Result :=
  { result with bundleDir? := none, zipPath? := none }

private def writeBundleFiles
    (bundleDir : System.FilePath)
    (result : Result)
    (confidential : Bool) : IO Unit := do
  IO.FS.writeFile (bundleDir / "card.md") result.markdown
  writePrettyJsonFile (bundleDir / "metadata.json") result.metadata
  writePrettyJsonFile (bundleDir / "collected.json") result.collected
  let report := if confidential then result.withoutLocalPaths else result
  writePrettyJsonFile (bundleDir / "report.json") (Result.toJson report)

private def writePreparedBundle
    (input : Input)
    (collection : Collection)
    (result : Result)
    (opts : BundleWriteOptions) : IO Result := do
  let confidential := input.confidential
  if input.bundle == .none then
    pure result
  else
    let bundleDir ← resolveBundleDir input collection opts
    IO.FS.createDirAll bundleDir
    let home? ← if input.redact then IO.getEnv "HOME" else pure none
    let warnings ← writeEvidence input opts bundleDir home? result.collectionWarnings
    let mut result := { result with
      collectionWarnings := warnings
      bundleDir? := some bundleDir.toString
    }
    if input.bundle == .zip then
      let resultForZip :=
        { result with zipPath? := (expectedZipPath? bundleDir).map (·.toString) }
      writeBundleFiles bundleDir
        (if input.redact then redactResult home? resultForZip else resultForZip)
        confidential
      let (zipPath?, warning?) ← zipBundle? bundleDir
      let updatedWarnings :=
        match warning? with
        | some warning => result.collectionWarnings.push warning
        | none => result.collectionWarnings
      result := { result with
        zipPath? := zipPath?.map (·.toString)
        collectionWarnings := updatedWarnings
      }
    writeBundleFiles bundleDir
      (if input.redact then redactResult home? result else result)
      confidential
    if input.redact then
      pure <| redactResult home? result
    else
      pure result

def buildResult
    (input : Input)
    (collection : Collection)
    (opts : BundleWriteOptions := {}) : IO Result := do
  let (input, collection) := prepareOutput input collection
  let result ← renderPreparedResult input collection
  writePreparedBundle input collection result opts

end Beam.Feedback
