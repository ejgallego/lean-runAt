/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import RunAt.Lib.Goals
import RunAt.Lib.Handles
import RunAt.Lib.Support

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open RunAt.Lib

namespace RunAt.Requests

def runCommandText (snap : Snapshots.Snapshot) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let rc ← readThe RequestContext
    let stx ←
      match Parser.runParserCategory snap.env `command text "<runAt>" with
      | .ok stx => pure stx
      | .error err => return (errorResult err, none)
    let (output, response) ← IO.FS.withIsolatedStreams do
      EIO.toBaseIO do
        runCommandElabMWithCancel snap rc.doc.meta (some innerCancelTk) do
          let initialMsgCount := (← get).messages.toList.length
          let initialTraceCount := (← getTraces).size
          let error? ← try
            Elab.Command.elabCommandTopLevel stx
            pure none
          catch ex =>
            if ex.isInterrupt then
              throw ex
            pure (some (← ex.toMessageData.toString))
          let state ← get
          let messages := state.messages.toList.drop initialMsgCount
          let traces := (← getTraces).toList.drop initialTraceCount
          return (error?, messages, traces, state)
    let (error?, newMessages, newTraces, newState) ←
      match response with
      | .ok response => pure response
      | .error ex =>
          checkRequestCancelled
          throw <| RequestError.internalError (← ex.toMessageData.toString)
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let result := mkExecutionResult error? artifacts
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.command { snap with cmdState := newState }
      else
        none
    return (result, nextHandle?)

def proofStateOfSnapshot (snapshot : ProofSnapshot) : RequestM ProofState := do
  let (proofState, _) ← snapshot.runMetaM <| proofStateOfGoalList snapshot.tacticState.goals
  return proofState

def runTacticText (snapshot : ProofSnapshot) (initialProofState : ProofState) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let snapshot := snapshot.withCancelToken (some innerCancelTk)
    let stx ←
      match Parser.runParserCategory snapshot.coreState.env `tactic text "<runAt>" with
      | .ok stx => pure stx
      | .error err => return (errorResult err (some initialProofState), none)
    let (output, ((error?, newMessages, newTraces), proofSnapshot')) ←
      try
        IO.FS.withIsolatedStreams do
          let run := snapshot.runTacticM do
            let saved ← Elab.Tactic.saveState
            let initialMsgCount := (← Core.getMessageLog).toList.length
            let initialTraceCount := (← getTraces).size
            let error? ← try
              Elab.Tactic.evalTactic stx
              pure none
            catch ex =>
              if ex.isInterrupt then
                throw ex
              saved.restore (restoreInfo := true)
              pure (some (← ex.toMessageData.toString))
            let messages := (← Core.getMessageLog).toList.drop initialMsgCount
            let traces := (← getTraces).toList.drop initialTraceCount
            return ((error?, messages, traces))
          run
      catch ex =>
        checkRequestCancelled
        throw ex
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let proofState ←
      if error?.isSome then
        pure initialProofState
      else
        proofStateOfSnapshot proofSnapshot'
    let result := mkExecutionResult error? artifacts (proofState? := some proofState)
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.proof proofSnapshot'
      else
        none
    return (result, nextHandle?)

def runTacticAtBasis (basis : GoalsAtResult) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  let ctxInfo := mkBasisCtxInfo basis
  let initialProofState ← basisProofState basis
  let proofSnapshot ← ProofSnapshot.create ctxInfo (basisGoals basis)
  runTacticText proofSnapshot initialProofState text

def handleRunAt (p : Params) : RequestM (RequestTask Result) := do
  syncHandleStoreForCurrentDoc
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasisAt p.position
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis => do
        checkRequestCancelled
        let (result, state?) ← runTacticAtBasis basis p.text
        return RequestTask.pure (← maybeAttachHandle result (p.storeHandle?.getD false) state?)
    | none =>
        withRunAtSnapAtPos p.position fun snap => do
          checkRequestCancelled
          let (result, state?) ← runCommandText snap p.text
          maybeAttachHandle result (p.storeHandle?.getD false) state?

def handleRunWith (p : RunWithParams) : RequestM (RequestTask Result) := do
  syncHandleStoreForCurrentDoc
  checkRequestCancelled
  withStoredHandle p.handle (p.linear?.getD false) fun stored => do
    RequestM.asTask do
      checkRequestCancelled
      let (result, state?) ←
        match stored.state with
        | .command snapshot =>
            runCommandText snapshot p.text
        | .proof snapshot =>
            let initialProofState ← proofStateOfSnapshot snapshot
            runTacticText snapshot initialProofState p.text
      maybeAttachHandle result (p.storeHandle?.getD false) state?

def handleReleaseHandle (p : ReleaseHandleParams) : RequestM (RequestTask Json) := do
  syncHandleStoreForCurrentDoc
  releaseStoredHandle p.handle
  return RequestTask.pure Json.null

end RunAt.Requests
