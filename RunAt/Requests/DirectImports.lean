/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.Requests
import RunAt.Internal.DirectImports
import RunAt.Lib.Handles
import RunAt.Lib.Support

open Lean
open Lean.Server
open Lean.Server.RequestM
open RunAt.Lib

namespace RunAt.Requests

def handleDirectImports
    (_p : RunAt.Internal.DirectImportsParams) :
    RequestM (RequestTask RunAt.Internal.DirectImportsResult) := do
  syncHandleStoreForCurrentDoc
  let doc ← RequestM.readDoc
  checkRequestCancelled
  let inputCtx := Lean.Parser.mkInputContext doc.meta.text.source doc.meta.uri
  let (header, _, _) ← Lean.Parser.parseHeader inputCtx
  let imports :=
    (Lean.Server.collectImports header).foldl (init := #[]) fun acc info =>
      if acc.contains info.module then
        acc
      else
        acc.push info.module
  return RequestTask.pure {
    version := doc.meta.version
    imports
  }

end RunAt.Requests
