/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import RunAt.Protocol

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM

namespace RunAt.Lib

def mkMessage (severity : MessageSeverity) (text : String) : RunAt.Message :=
  { severity, text }

def trimOutput (text : String) : String :=
  text.trimAscii.toString

def outputMessage? (output : String) : Option RunAt.Message :=
  let output := trimOutput output
  if output.isEmpty then none else some <| mkMessage .information output

def errorResult (message : String) (proofState? : Option ProofState := none) : Result :=
  {
    success := false
    messages := #[mkMessage .error message]
    proofState?
  }

def messagesToProtocol (messages : List Lean.Message) : IO (Array RunAt.Message) := do
  messages.toArray.mapM fun message => do
    return mkMessage message.severity (← message.data.toString)

def tracesToStrings (traces : List TraceElem) : IO (Array String) := do
  traces.toArray.mapM fun trace => do
    return (← trace.msg.toString)

structure ExecutionArtifacts where
  messages : Array RunAt.Message
  traces : Array String
  hasErrors : Bool

def mkExecutionArtifacts
    (output : String)
    (messages : List Lean.Message)
    (traces : List TraceElem) : RequestM ExecutionArtifacts := do
  let mut protocolMessages ← messagesToProtocol messages
  if let some outputMessage := outputMessage? output then
    protocolMessages := protocolMessages.push outputMessage
  let protocolTraces ← tracesToStrings traces
  return {
    messages := protocolMessages
    traces := protocolTraces
    hasErrors := protocolMessages.any (fun message => message.severity == .error)
  }

def mkExecutionResult
    (error? : Option String)
    (artifacts : ExecutionArtifacts)
    (proofState? : Option ProofState := none) : Result :=
  match error? with
  | some error =>
      if artifacts.hasErrors then
        { success := false, messages := artifacts.messages, traces := artifacts.traces, proofState? }
      else
        {
          success := false
          messages := artifacts.messages.push (mkMessage .error error)
          traces := artifacts.traces
          proofState?
        }
  | none =>
      {
        success := !artifacts.hasErrors
        messages := artifacts.messages
        traces := artifacts.traces
        proofState?
      }

def checkRequestCancelled : RequestM Unit := do
  let rc ← readThe RequestContext
  if ← rc.cancelTk.wasCancelledByEdit then
    throw RequestError.fileChanged
  if ← rc.cancelTk.wasCancelledByCancelRequest then
    throw RequestError.requestCancelled

def withInnerCancelToken (k : IO.CancelToken → RequestM α) : RequestM α := do
  let rc ← readThe RequestContext
  let innerCancelTk ← IO.CancelToken.new
  let finished ← IO.Promise.new
  let finishedTask : ServerTask Bool :=
    finished.resultD () |>.asServerTask |>.mapCheap (fun _ => false)
  let cancelTasks :=
    rc.cancelTk.cancellationTasks.map (·.mapCheap (fun _ => true)) ++ [finishedTask]
  discard <| ServerTask.BaseIO.asTask do
    if ← ServerTask.waitAny cancelTasks then
      innerCancelTk.set
  try
    k innerCancelTk
  finally
    finished.resolve ()

def runCommandElabMWithCancel
    (snap : Snapshots.Snapshot)
    (doc : DocumentMeta)
    (cancelTk? : Option IO.CancelToken)
    (c : Elab.Command.CommandElabM α) : EIO Exception α := do
  let ctx : Command.Context := {
    cmdPos := snap.stx.getPos? |>.getD 0
    fileName := doc.uri
    fileMap := doc.text
    snap? := none
    cancelTk?
  }
  c.run ctx |>.run' snap.cmdState

def lineUtf16Length (text : FileMap) (line : Nat) : Nat :=
  let start := text.lineStart (line + 1)
  let stop :=
    if line + 1 < text.getLastLine then
      text.lineStart (line + 2)
    else
      text.source.rawEndPos
  let lineText := String.Pos.Raw.extract text.source start stop
  let lineText :=
    if lineText.endsWith "\n" then
      (lineText.dropEnd 1).copy
    else
      lineText
  lineText.utf16Length

def validatePosition (position : Lean.Lsp.Position) : RequestM Unit := do
  let doc ← RequestM.readDoc
  let text := doc.meta.text
  let eof := text.utf8PosToLspPos text.source.rawEndPos
  let lineTooLarge := position.line > eof.line
  let maxCharacter :=
    if position.line > eof.line then
      0
    else
      lineUtf16Length text position.line
  let charTooLarge :=
    if position.line > eof.line then
      false
    else
      position.character > maxCharacter
  if lineTooLarge then
    throw <| RequestError.invalidParams
      s!"position {position} is outside the document: line {position.line} is beyond the last line {eof.line}"
  if charTooLarge then
    throw <| RequestError.invalidParams
      s!"position {position} is outside the document: character {position.character} is beyond max character {maxCharacter} for line {position.line}"

def noSnapshotFoundMessage (position : Lean.Lsp.Position) : String :=
  s!"position {position} is inside the document, but Lean has no command or tactic snapshot there; try a position inside a command or proof body, not a standalone comment, blank line, or declaration header"

def withRunAtSnapAtPos
    (position : Lean.Lsp.Position)
    (f : Snapshots.Snapshot → RequestM α) : RequestM (RequestTask α) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.withWaitFindSnap doc (fun snap => snap.endPos >= pos)
    (notFoundX := throw <| RequestError.invalidParams (noSnapshotFoundMessage position))
    (x := f)

end RunAt.Lib
