 /-
 Copyright (c) 2026 Lean FRO LLC. All rights reserved.
 Released under Apache 2.0 license as described in the file LICENSE.
 Author: Emilio J. Gallego Arias
 -/

 import Lean

 open Lean

 namespace RunAt.Internal

 /--
 Internal broker-only request for parsing the current document header and returning its direct imports
 from the current tracked text snapshot.

 This supports broker-side stale dependency hints and compatibility-only tooling. It is not part of
 the supported public `runAt` API.
 -/
 def directImportsMethod : String := "$/lean/runAt/directImports"

 /-- Internal request payload for direct-import queries from the current tracked text snapshot. -/
 structure DirectImportsParams where
   textDocument : Lean.Lsp.TextDocumentIdentifier
   deriving FromJson, ToJson

 instance : Lean.Lsp.FileSource DirectImportsParams where
   fileSource p := p.textDocument.uri

 /-- Internal success payload for direct-import queries from the current tracked text snapshot. -/
 structure DirectImportsResult where
   version : Nat
   imports : Array String := #[]
   deriving FromJson, ToJson

 end RunAt.Internal
