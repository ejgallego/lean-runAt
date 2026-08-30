/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Args
import Beam.Cli.RuntimeBundle
import Beam.JsonPretty
import Beam.Broker.Client
import Beam.LSP.RunAt

open Lean

namespace Beam.Cli

open Beam.Broker

def printJsonLine (json : Json) : IO Unit := do
  IO.println <| Beam.orderedJsonPretty json

def envClientRequestId? : IO (Option String) := do
  match ← IO.getEnv "BEAM_REQUEST_ID" with
  | some raw =>
      let trimmed := raw.trimAscii.toString
      pure <| if trimmed.isEmpty then none else some trimmed
  | none =>
      pure none

def withEnvClientRequestId (req : Request) : IO Request := do
  pure { req with clientRequestId? := req.clientRequestId? <|> (← envClientRequestId?) }

def annotateRunatMessage (clientRequestId? : Option String) (msg : String) : String :=
  match clientRequestId? with
  | some clientRequestId =>
      if msg.startsWith "beam:" then
        s!"beam[{clientRequestId}]:" ++ (msg.drop 6).toString
      else
        s!"beam[{clientRequestId}]: {msg}"
  | none =>
      msg

private def debugTextEnabled : IO Bool := do
  pure <| (← envFlag? "BEAM_DEBUG_TEXT").getD false

def maybeEmitTextDebug
    (clientRequestId? : Option String)
    (action source text : String) : IO Unit := do
  if !(← debugTextEnabled) then
    pure ()
  else
    let bytes := text.toUTF8
    let containsLiteralBackslashN := hasSubstring text "\\n"
    IO.eprintln <| annotateRunatMessage clientRequestId?
      s!"beam: debug text for {action}: source={source} utf8Bytes={bytes.size} containsNewline={boolText (text.contains '\n')} containsLiteralBackslashN={boolText containsLiteralBackslashN}"
    IO.eprintln <| annotateRunatMessage clientRequestId?
      s!"beam: debug text escaped={(Json.str text).compress}"
    IO.eprintln <| annotateRunatMessage clientRequestId?
      s!"beam: debug text utf8Hex={utf8Hex bytes}"

def decodeRunAtResult? (resp : Response) : Option Beam.LSP.RunAt.Result :=
  match resp.result? with
  | none => none
  | some result =>
      match fromJson? result with
      | .ok payload => some payload
      | .error _ => none

def responseErrorSummary? (action failureBoundary : String) (resp : Response) : Option String :=
  resp.error?.map fun err =>
    s!"beam: {action} request failed {failureBoundary} ({err.code}): {err.message}"

private def jsonStringField? (json : Json) (field : String) : Option String := do
  match json.getObjVal? field with
  | .ok (.str value) => some value
  | _ => none

private def jsonStringArrayField? (json : Json) (field : String) : Option (Array String) := do
  let .ok (.arr values) := json.getObjVal? field
    | none
  values.foldlM (init := #[]) fun acc value =>
    match value with
    | .str text => some (acc.push text)
    | _ => none

private def recoveryPlanText? (steps : Array String) : Option String :=
  if steps.isEmpty then
    none
  else
    let quotedSteps := steps.map fun step => s!"`{step}`"
    some <| "try " ++ String.intercalate "; then " quotedSteps.toList

private def syncBarrierFallbackRecovery? (data? : Option Json) : Option String :=
  match data?.bind (jsonStringField? · "targetPath") with
  | some targetPath =>
      some <|
        s!"run `lean-beam refresh \"{targetPath}\"` after saving changed dependencies; " ++
        "if that still fails, run `lake build` or fix the upstream module first"
  | none =>
      some "run `lake build` or fix the upstream module first"

def responseRecoveryHint? (resp : Response) : Option String := do
  let err ← resp.error?
  if err.code == syncBarrierIncompleteCode then
    let recoveryText? :=
      match err.data?.bind (jsonStringArrayField? · "recoveryPlan") with
      | some steps => recoveryPlanText? steps
      | none => syncBarrierFallbackRecovery? err.data?
    recoveryText?.map fun recoveryText => s!"beam: recovery: {recoveryText}"
  else
    none

def runAtPayloadSummary? (action noun : String) (resp : Response) : Option String :=
  match decodeRunAtResult? resp with
  | some result =>
      if result.success then
        none
      else
        some s!"beam: {action} {noun} failed inside Lean; the request completed and returned result.success=false"
  | none =>
      none

def maybeEmitLiteralBackslashNewlineHint
    (clientRequestId? : Option String)
    (req : Request)
    (resp : Response) : IO Unit := do
  match req.op with
  | .runAt | .runWith =>
      match req.text?, decodeRunAtResult? resp with
      | some text, some result =>
          if !result.success && hasSubstring text "\\n" && !text.contains '\n' then
            IO.eprintln <| annotateRunatMessage clientRequestId?
              "beam: hint: the probe text contains the literal characters '\\n'; if you meant a real newline, use --stdin or --text-file."
          else
            pure ()
      | _, _ =>
          pure ()
  | _ =>
      pure ()

def decodeSyncFileResult? (resp : Response) : Option SyncFileResult := do
  let result ← resp.result?
  fromJson? result |>.toOption

def decodeUpdateFileResult? (resp : Response) : Option UpdateFileResult := do
  let result ← resp.result?
  fromJson? result |>.toOption

def responseFileProgress? (resp : Response) : Option SyncFileProgress :=
  resp.fileProgress?

def syncFileProgressSuffix (progress? : Option SyncFileProgress) : String :=
  match progress? with
  | none => ""
  | some progress =>
      s!", fp {SyncFileProgress.displayDetails progress (includeDoneTrue := false)}"

end Beam.Cli
