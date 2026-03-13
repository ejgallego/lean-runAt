/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace RunAt

structure ProofSnapshot where
  coreState : Core.State
  coreContext : Core.Context
  metaState : Meta.State
  metaContext : Meta.Context
  termState : Elab.Term.State
  termContext : Elab.Term.Context
  tacticState : Elab.Tactic.State
  tacticContext : Elab.Tactic.Context

namespace ProofSnapshot

open Elab
open Elab.Tactic

def withCancelToken (p : ProofSnapshot) (cancelTk? : Option IO.CancelToken) : ProofSnapshot :=
  { p with coreContext := { p.coreContext with cancelTk? } }

def runCoreM (p : ProofSnapshot) (t : CoreM α) : IO (α × ProofSnapshot) := do
  let (a, coreState) ← (Core.CoreM.toIO · p.coreContext p.coreState) do
    t
  return (a, { p with coreState })

def runMetaM (p : ProofSnapshot) (t : MetaM α) : IO (α × ProofSnapshot) := do
  let ((a, metaState), p') ←
    p.runCoreM (Meta.MetaM.run (ctx := p.metaContext) (s := p.metaState) do t)
  return (a, { p' with metaState })

def runTermElabM (p : ProofSnapshot) (t : TermElabM α) : IO (α × ProofSnapshot) := do
  let ((a, termState), p') ←
    p.runMetaM (Term.TermElabM.run (s := p.termState) do
      let r ← t
      Term.synthesizeSyntheticMVarsNoPostponing
      pure r)
  return (a, { p' with termState })

def runTacticM (p : ProofSnapshot) (t : TacticM α) : IO (α × ProofSnapshot) := do
  let ((a, tacticState), p') ← p.runTermElabM (t p.tacticContext |>.run p.tacticState)
  return (a, { p' with tacticState })

def create (ctx : Elab.ContextInfo) (goals : List MVarId) (types : List Expr := []) :
    IO ProofSnapshot := do
  ctx.runMetaM {} do
    let goals := goals ++ (← types.mapM fun t => Expr.mvarId! <$> Meta.mkFreshExprMVar (some t))
    pure {
      coreState := ← getThe Core.State
      coreContext := ← readThe Core.Context
      metaState := ← getThe Meta.State
      metaContext := ← readThe Meta.Context
      termState := {}
      termContext := {}
      tacticState := { goals }
      tacticContext := { elaborator := .anonymous }
    }

def ppGoals (p : ProofSnapshot) : IO (List Format) :=
  Prod.fst <$> p.runMetaM do
    p.tacticState.goals.mapM Meta.ppGoal

end ProofSnapshot
end RunAt
