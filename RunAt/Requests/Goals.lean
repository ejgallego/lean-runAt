/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.Requests
import RunAt.Lib.Goals
import RunAt.Lib.Handles
import RunAt.Lib.Support

open Lean
open Lean.Server
open Lean.Server.RequestM
open RunAt.Lib

namespace RunAt.Requests

def handleGoalsAt (p : GoalsParams) (useAfter : Bool) : RequestM (RequestTask ProofState) := do
  syncHandleStoreForCurrentDoc
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasisAt p.position
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis => do
        checkRequestCancelled
        return RequestTask.pure (← basisProofState basis useAfter)
    | none =>
        throw <| RequestError.invalidParams (noProofBasisFoundMessage p.position)

end RunAt.Requests
