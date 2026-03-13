/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean

namespace RunAtTest.ScenarioRunner

open RunAtTest.Scenario

private structure OpenSpec where
  path : String
  deriving FromJson

private structure WatchSpec where
  path : String
  type? : Option Nat := none
  deriving FromJson

private inductive Step where
  | openDoc (docName : String) (spec : OpenSpec)
  | changeDoc (docName : String) (spec : ChangeSpec)
  | syncDoc (docName : String)
  | closeDoc (docName : String)
  | watchChange (spec : WatchSpec)
  | sendRunAt (reqName : String) (docName : String) (spec : SendRunAtSpec)
  | sendRunWith (reqName : String) (docName : String) (handleName : String) (spec : RunWithSpec)
  | awaitHandle (handleName : String) (reqName : String)
  | releaseHandle (docName : String) (handleName : String)
  | cancelReq (reqName : String)
  | awaitReq (reqName : String)
  | expectResponse (reqName : String) (expected : Json)
  | expectError (reqName : String) (expected : Json)

private structure ScriptStep where
  lineNo : Nat
  step : Step

private structure FrontState where
  scenarioDir : System.FilePath
  docs : Std.TreeMap String DocHandle := {}
  requests : Std.TreeMap String ReqHandle := {}
  handles : Std.TreeMap String RunAt.Handle := {}

private abbrev FrontM := StateT FrontState ScenarioM

private def takeWord? (s : String.Slice) : Option (String × String.Slice) :=
  let s := s.trimAsciiStart
  if s.isEmpty then
    none
  else
    let head := s.takeWhile (fun c => !c.isWhitespace)
    let tail := (s.dropWhile (fun c => !c.isWhitespace)).trimAsciiStart
    some (head.copy, tail)

private def ensureNoRemainder (s : String.Slice) : Except String Unit :=
  if s.trimAsciiStart.isEmpty then
    pure ()
  else
    throw s!"unexpected trailing input: {s.trimAsciiStart.copy}"

private def parseJsonTail (s : String.Slice) : Except String Json := do
  let text := s.trimAsciiStart.copy
  if text.isEmpty then
    throw "expected JSON payload"
  match Json.parse text with
  | .ok j => pure j
  | .error err => throw s!"invalid JSON payload: {err}"

private def parseJsonAs [FromJson α] (s : String.Slice) : Except String α := do
  let j ← parseJsonTail s
  match fromJson? j with
  | .ok a => pure a
  | .error err => throw s!"invalid JSON payload: {err}"

private def parseLine (lineNo : Nat) (line : String) : Except String (Option ScriptStep) := do
  let trimmed := line.toSlice.trimAsciiStart
  if trimmed.isEmpty then
    return none
  let text := trimmed.copy
  if text.startsWith "#" || text.startsWith "--" then
    return none
  let some (cmd, rest) := takeWord? trimmed
    | throw "expected command"
  let mkStep (step : Step) : ScriptStep := { lineNo, step }
  match cmd with
  | "open" =>
      let some (docName, tail) := takeWord? rest
        | throw "expected document name"
      return some <| mkStep <| .openDoc docName (← parseJsonAs tail)
  | "change" =>
      let some (docName, tail) := takeWord? rest
        | throw "expected document name"
      return some <| mkStep <| .changeDoc docName (← parseJsonAs tail)
  | "sync" =>
      let some (docName, tail) := takeWord? rest
        | throw "expected document name"
      ensureNoRemainder tail
      return some <| mkStep <| .syncDoc docName
  | "close" =>
      let some (docName, tail) := takeWord? rest
        | throw "expected document name"
      ensureNoRemainder tail
      return some <| mkStep <| .closeDoc docName
  | "watch_change" =>
      return some <| mkStep <| .watchChange (← parseJsonAs rest)
  | "send" =>
      let some (reqName, rest) := takeWord? rest
        | throw "expected request name"
      let some (methodName, rest) := takeWord? rest
        | throw "expected method name"
      let some (docName, tail) := takeWord? rest
        | throw "expected document name"
      if methodName == "runAt" then
        return some <| mkStep <| .sendRunAt reqName docName (← parseJsonAs tail)
      else if methodName == "runWith" then
        let some (handleName, tail) := takeWord? tail
          | throw "expected handle name"
        return some <| mkStep <| .sendRunWith reqName docName handleName (← parseJsonAs tail)
      else
        throw s!"unsupported method '{methodName}'"
  | "await_handle" =>
      let some (handleName, tail) := takeWord? rest
        | throw "expected handle name"
      let some (reqName, tail) := takeWord? tail
        | throw "expected request name"
      ensureNoRemainder tail
      return some <| mkStep <| .awaitHandle handleName reqName
  | "release_handle" =>
      let some (docName, tail) := takeWord? rest
        | throw "expected document name"
      let some (handleName, tail) := takeWord? tail
        | throw "expected handle name"
      ensureNoRemainder tail
      return some <| mkStep <| .releaseHandle docName handleName
  | "await" =>
      let some (reqName, tail) := takeWord? rest
        | throw "expected request name"
      ensureNoRemainder tail
      return some <| mkStep <| .awaitReq reqName
  | "cancel" =>
      let some (reqName, tail) := takeWord? rest
        | throw "expected request name"
      ensureNoRemainder tail
      return some <| mkStep <| .cancelReq reqName
  | "expect_response" =>
      let some (reqName, tail) := takeWord? rest
        | throw "expected request name"
      return some <| mkStep <| .expectResponse reqName (← parseJsonTail tail)
  | "expect_error" =>
      let some (reqName, tail) := takeWord? rest
        | throw "expected request name"
      return some <| mkStep <| .expectError reqName (← parseJsonTail tail)
  | _ =>
      throw s!"unknown command '{cmd}'"

private def parseScript (path : System.FilePath) : IO (Array ScriptStep) := do
  let text ← IO.FS.readFile path
  let lines := text.splitOn "\n"
  let mut steps := #[]
  let mut lineNo := 1
  for line in lines do
    match parseLine lineNo line with
    | .ok (some step) => steps := steps.push step
    | .ok none => pure ()
    | .error err => throw <| IO.userError s!"{path}:{lineNo}: {err}"
    lineNo := lineNo + 1
  pure steps

private def resolvePath (baseDir : System.FilePath) (path : String) : IO System.FilePath := do
  let path := System.FilePath.mk path
  let path := if path.isAbsolute then path else baseDir / path
  IO.FS.realPath path

private def getDocHandle (docName : String) : FrontM DocHandle := do
  let some doc := (← get).docs.get? docName
    | throw <| IO.userError s!"unknown document '{docName}'"
  pure doc

private def getReqHandle (reqName : String) : FrontM ReqHandle := do
  let some req := (← get).requests.get? reqName
    | throw <| IO.userError s!"unknown request '{reqName}'"
  pure req

private def getStoredHandle (handleName : String) : FrontM RunAt.Handle := do
  let some handle := (← get).handles.get? handleName
    | throw <| IO.userError s!"unknown handle '{handleName}'"
  pure handle

private def decodeWatchChangeType (type? : Option Nat) : IO Lean.Lsp.FileChangeType := do
  match type? with
  | none | some 2 => pure Lsp.FileChangeType.Changed
  | some 1 => pure Lsp.FileChangeType.Created
  | some 3 => pure Lsp.FileChangeType.Deleted
  | some n => throw <| IO.userError s!"invalid watch change type {n}; expected 1, 2, or 3"

private def executeStep (scriptStep : ScriptStep) : FrontM Unit := do
  try
    match scriptStep.step with
    | .openDoc docName spec =>
        if (← get).docs.contains docName then
          throw <| IO.userError s!"document '{docName}' is already open"
        let path ← resolvePath (← get).scenarioDir spec.path
        let doc ← RunAtTest.Scenario.openDoc path
        modify fun s => { s with docs := s.docs.insert docName doc }
    | .changeDoc docName spec =>
        RunAtTest.Scenario.changeDoc (← getDocHandle docName) spec
    | .syncDoc docName =>
        RunAtTest.Scenario.syncDoc (← getDocHandle docName)
    | .closeDoc docName =>
        let doc ← getDocHandle docName
        RunAtTest.Scenario.closeDoc doc
        modify fun s => { s with docs := s.docs.erase docName }
    | .watchChange spec =>
        let path ← resolvePath (← get).scenarioDir spec.path
        let changeType ← decodeWatchChangeType spec.type?
        RunAtTest.Scenario.notifyWatchedFileChanged path changeType
    | .sendRunAt reqName docName spec =>
        if (← get).requests.contains reqName then
          throw <| IO.userError s!"request '{reqName}' already exists"
        let req ← RunAtTest.Scenario.sendRunAt (← getDocHandle docName) spec
        modify fun s => { s with requests := s.requests.insert reqName req }
    | .sendRunWith reqName docName handleName spec =>
        if (← get).requests.contains reqName then
          throw <| IO.userError s!"request '{reqName}' already exists"
        let req ← RunAtTest.Scenario.runWithHandle (← getDocHandle docName) (← getStoredHandle handleName) spec
        modify fun s => { s with requests := s.requests.insert reqName req }
    | .awaitHandle handleName reqName =>
        if (← get).handles.contains handleName then
          throw <| IO.userError s!"handle '{handleName}' already exists"
        let result : RunAt.Result ← RunAtTest.Scenario.awaitResponseAs (α := RunAt.Result) (← getReqHandle reqName)
        let some handle := result.handle?
          | throw <| IO.userError s!"request '{reqName}' did not return a handle"
        modify fun s => { s with handles := s.handles.insert handleName handle }
    | .releaseHandle docName handleName =>
        RunAtTest.Scenario.releaseHandle (← getDocHandle docName) (← getStoredHandle handleName)
    | .cancelReq reqName =>
        RunAtTest.Scenario.cancelReq (← getReqHandle reqName)
    | .awaitReq reqName =>
        discard <| RunAtTest.Scenario.awaitReq (← getReqHandle reqName)
    | .expectResponse reqName expected =>
        RunAtTest.Scenario.expectResponseContains (← getReqHandle reqName) expected
    | .expectError reqName expected =>
        RunAtTest.Scenario.expectErrorContains (← getReqHandle reqName) expected
  catch e =>
    throw <| IO.userError s!"scenario line {scriptStep.lineNo}: {e}"

partial def main (args : List String) : IO Unit := do
  let args := args.toArray
  let some (path : String) := args[0]?
    | throw <| IO.userError "usage: lake exe runAt-scenario-test <file>"
  let scriptPath := System.FilePath.mk path
  let scenarioDir := scriptPath.parent.getD (System.FilePath.mk ".")
  let steps ← parseScript scriptPath
  discard <| RunAtTest.Scenario.run do
    let init : FrontState := { scenarioDir }
    discard <| StateT.run (m := ScenarioM) (s := init) (do
      for step in steps do
        executeStep step
      : FrontM Unit)

end RunAtTest.ScenarioRunner

def main := RunAtTest.ScenarioRunner.main
