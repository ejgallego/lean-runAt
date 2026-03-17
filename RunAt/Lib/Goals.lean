/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Lean.Meta.PPGoal
import RunAt.ProofSnapshot
import RunAt.Protocol

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM

namespace RunAt.Lib

def ppExprString (e : Expr) : MetaM String := do
  let e ← if getPPInstantiateMVars (← getOptions) then instantiateMVars e else pure e
  return (← Meta.ppExpr e).pretty

def ppLetValueString? (tactic : Bool) (value : Expr) : MetaM (Option String) := do
  if ← Lean.Meta.ppGoal.shouldShowLetValue tactic value then
    some <$> ppExprString value
  else
    pure none

def withGoalCtx (goal : MVarId) (action : LocalContext → MetavarDecl → MetaM α) : MetaM α := do
  let mctx ← getMCtx
  let some mvarDecl := mctx.findDecl? goal
    | throwError "unknown goal {goal.name}"
  let lctx := mvarDecl.lctx |>.sanitizeNames.run' { options := (← getOptions) }
  Meta.withLCtx lctx mvarDecl.localInstances (action lctx mvarDecl)

def addGoalHypBundle
    (hyps : Array GoalHyp)
    (names : Array String)
    (type : Expr)
    (value? : Option Expr := none)
    (tactic : Bool := false) : MetaM (Array GoalHyp) := do
  if names.isEmpty then
    pure hyps
  else
    let renderedValue? ←
      match value? with
      | some value => ppLetValueString? tactic value
      | none => pure none
    return hyps.push {
      names
      type := ← ppExprString type
      value? := renderedValue?
    }

def goalOfMVarId (mvarId : MVarId) : MetaM Goal := do
  let ppAuxDecls := (← getOptions).getBool `pp.auxDecls false
  let ppImplDetailHyps := (← getOptions).getBool `pp.implementationDetailHyps false
  withGoalCtx mvarId fun lctx mvarDecl => do
    let tactic := mvarDecl.kind.isSyntheticOpaque
    let pushPending
        (names : Array String)
        (type? : Option Expr)
        (hyps : Array GoalHyp) : MetaM (Array GoalHyp) :=
      if names.isEmpty then
        pure hyps
      else
        match type? with
        | none => pure hyps
        | some type => addGoalHypBundle hyps names type (tactic := tactic)
    let mut pendingNames : Array String := #[]
    let mut prevType? : Option Expr := none
    let mut hyps : Array GoalHyp := #[]
    for localDecl in lctx do
      if !ppAuxDecls && localDecl.isAuxDecl || !ppImplDetailHyps && localDecl.isImplementationDetail then
        continue
      else
        match localDecl with
        | LocalDecl.cdecl _index _fvarId varName type ..
        | LocalDecl.ldecl _index _fvarId varName type (nondep := true) .. =>
            let varName := toString varName
            let type ← instantiateMVars type
            if prevType? == none || prevType? == some type then
              pendingNames := pendingNames.push varName
            else
              hyps ← pushPending pendingNames prevType? hyps
              pendingNames := #[varName]
            prevType? := some type
        | LocalDecl.ldecl _index _fvarId varName type val (nondep := false) .. => do
            let varName := toString varName
            hyps ← pushPending pendingNames prevType? hyps
            let type ← instantiateMVars type
            let val ← instantiateMVars val
            hyps ← addGoalHypBundle hyps #[varName] type (value? := some val) (tactic := tactic)
            pendingNames := #[]
            prevType? := none
    hyps ← pushPending pendingNames prevType? hyps
    let userName? := match mvarDecl.userName with
      | Name.anonymous => none
      | name => some <| toString name.eraseMacroScopes
    return {
      userName?
      goalPrefix := Lean.Meta.getGoalPrefix mvarDecl
      target := ← ppExprString (← instantiateMVars mvarDecl.type)
      hyps
    }

def proofStateOfGoalList (goals : List MVarId) : MetaM ProofState := do
  let goals ← goals.mapM goalOfMVarId
  return { goals := goals.toArray }

def proofStateOfGoals (goals : List MVarId) (ctxInfo : ContextInfo) : RequestM ProofState := do
  ctxInfo.runMetaM {} <| proofStateOfGoalList goals

def mkBasisCtxInfo (result : GoalsAtResult) (useAfter : Bool := result.useAfter) : ContextInfo :=
  if useAfter then
    { result.ctxInfo with mctx := result.tacticInfo.mctxAfter }
  else
    { result.ctxInfo with mctx := result.tacticInfo.mctxBefore }

def basisGoals (result : GoalsAtResult) (useAfter : Bool := result.useAfter) : List MVarId :=
  if useAfter then result.tacticInfo.goalsAfter else result.tacticInfo.goalsBefore

def basisProofState (result : GoalsAtResult) (useAfter : Bool := result.useAfter) :
    RequestM ProofState := do
  proofStateOfGoals (basisGoals result useAfter) (mkBasisCtxInfo result useAfter)

def findProofBasisAt (position : Lean.Lsp.Position) : RequestM (RequestTask (Option GoalsAtResult)) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.mapTaskCostly (Lean.Server.FileWorker.findGoalsAt? doc pos) fun
    | some (result :: _) => return some result
    | _ => return none

def noProofBasisFoundMessage (position : Lean.Lsp.Position) : String :=
  s!"position {position} is inside the document, but Lean has no proof goals there; try a position inside a tactic or proof body"

end RunAt.Lib
