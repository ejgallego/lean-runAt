/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import RunAt.Protocol
import RunAt.Requests.DirectImports
import RunAt.Requests.Goals
import RunAt.Requests.RunAt
import RunAt.Requests.Save

open Lean
open Lean.Server

namespace RunAt

/--
Root plugin module for the standalone `$/lean/runAt` extension.

This module keeps request registration thin. Request implementations live in
`RunAt.Requests.*`.
-/
def pluginMethod : String := method

initialize
  registerLspRequestHandler method Params Result RunAt.Requests.handleRunAt
  registerLspRequestHandler goalsAfterMethod GoalsParams ProofState
    (fun p => RunAt.Requests.handleGoalsAt p true)
  registerLspRequestHandler goalsPrevMethod GoalsParams ProofState
    (fun p => RunAt.Requests.handleGoalsAt p false)
  registerLspRequestHandler runWithMethod RunWithParams Result RunAt.Requests.handleRunWith
  registerLspRequestHandler releaseHandleMethod ReleaseHandleParams Json
    RunAt.Requests.handleReleaseHandle
  registerLspRequestHandler RunAt.Internal.saveArtifactsMethod
    RunAt.Internal.SaveArtifactsParams
    RunAt.Internal.SaveArtifactsResult
    RunAt.Requests.handleSaveArtifacts
  registerLspRequestHandler RunAt.Internal.saveReadinessMethod
    RunAt.Internal.SaveReadinessParams
    RunAt.Internal.SaveReadinessResult
    RunAt.Requests.handleSaveReadiness
  registerLspRequestHandler RunAt.Internal.directImportsMethod
    RunAt.Internal.DirectImportsParams
    RunAt.Internal.DirectImportsResult
    RunAt.Requests.handleDirectImports

end RunAt
