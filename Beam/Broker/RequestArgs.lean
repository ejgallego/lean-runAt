/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Lean

namespace Beam.Broker

def invalidParamsFailure (message : String) : ResponseFailure :=
  responseFailure "invalidParams" message

private def asInvalidParams (arg : Except String α) : Except ResponseFailure α :=
  arg.mapError invalidParamsFailure

def Request.rootArg (req : Request) : Except ResponseFailure System.FilePath :=
  asInvalidParams req.requireRoot

def Request.pathArg (req : Request) : Except ResponseFailure System.FilePath :=
  asInvalidParams req.requirePath

def Request.cancelRequestIdArg (req : Request) : Except ResponseFailure String :=
  asInvalidParams req.requireCancelRequestId

structure PositionArgs where
  path : System.FilePath
  version : Nat
  line : Nat
  character : Nat

def Request.positionArgs (req : Request) : Except ResponseFailure PositionArgs := do
  let path ← asInvalidParams req.requirePath
  let version ← asInvalidParams req.requireVersion
  let line ← asInvalidParams req.requireLine
  let character ← asInvalidParams req.requireCharacter
  pure { path, version, line, character }

structure RunAtArgs extends PositionArgs where
  text : String
  method : String

def Request.runAtArgs (req : Request) : Except ResponseFailure RunAtArgs := do
  let position ← req.positionArgs
  let text ← asInvalidParams req.requireText
  let method ← asInvalidParams (runAtMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    text
    method
  }

structure HoverArgs extends PositionArgs where
  method : String

def Request.hoverArgs (req : Request) : Except ResponseFailure HoverArgs := do
  let position ← req.positionArgs
  let method ← asInvalidParams (hoverMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
  }

structure SignatureHelpArgs extends PositionArgs where
  method : String

def Request.signatureHelpArgs (req : Request) : Except ResponseFailure SignatureHelpArgs := do
  let position ← req.positionArgs
  let method ← asInvalidParams (signatureHelpMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
  }

structure DefinitionArgs extends PositionArgs where
  method : String

def Request.definitionArgs (req : Request) : Except ResponseFailure DefinitionArgs := do
  let position ← req.positionArgs
  let method ← asInvalidParams (definitionMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
  }

structure ReferencesArgs extends PositionArgs where
  method : String
  includeDeclaration : Bool

def Request.referencesArgs (req : Request) : Except ResponseFailure ReferencesArgs := do
  let position ← req.positionArgs
  let method ← asInvalidParams (referencesMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
    includeDeclaration := req.includeDeclaration?.getD true
  }

structure DocumentSymbolsArgs where
  path : System.FilePath
  version : Nat
  method : String

def Request.documentSymbolsArgs (req : Request) : Except ResponseFailure DocumentSymbolsArgs := do
  let path ← asInvalidParams req.requirePath
  let version ← asInvalidParams req.requireVersion
  let method ← asInvalidParams (documentSymbolsMethod req.backend)
  pure { path, version, method }

structure WorkspaceSymbolsArgs where
  query : String
  method : String

def Request.workspaceSymbolsArgs (req : Request) : Except ResponseFailure WorkspaceSymbolsArgs := do
  let query ← asInvalidParams req.requireQuery
  let method ← asInvalidParams (workspaceSymbolsMethod req.backend)
  pure { query, method }

structure CodeActionResolveArgs where
  path : System.FilePath
  version : Nat
  codeAction : Lean.Lsp.CodeAction
  method : String

def Request.codeActionResolveArgs (req : Request) : Except ResponseFailure CodeActionResolveArgs := do
  let path ← asInvalidParams req.requirePath
  let version ← asInvalidParams req.requireVersion
  let codeAction ← asInvalidParams req.requireCodeAction
  let method ← asInvalidParams (codeActionResolveMethod req.backend)
  pure { path, version, codeAction, method }

structure GoalsArgs extends PositionArgs where
  method : String

def Request.goalsArgs (req : Request) : Except ResponseFailure GoalsArgs := do
  let position ← req.positionArgs
  let method ← asInvalidParams (goalsMethod req.backend req.mode?)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
  }

structure TodoArgs extends PositionArgs where
  endLine : Nat
  endCharacter : Nat
  method : String

def Request.todoArgs (req : Request) : Except ResponseFailure TodoArgs := do
  let position ← req.positionArgs
  let endLine ← asInvalidParams req.requireEndLine
  let endCharacter ← asInvalidParams req.requireEndCharacter
  let method ← asInvalidParams (todoMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    endLine
    endCharacter
    method
  }

structure RunWithArgs where
  path : System.FilePath
  handle : Handle
  text : String
  method : String

def Request.runWithArgs (req : Request) : Except ResponseFailure RunWithArgs := do
  let path ← asInvalidParams req.requirePath
  let handle ← asInvalidParams req.requireHandle
  let text ← asInvalidParams req.requireText
  let method ← asInvalidParams (runWithMethod req.backend)
  pure { path, handle, text, method }

structure ReleaseArgs where
  path : System.FilePath
  handle : Handle
  method : String

def Request.releaseArgs (req : Request) : Except ResponseFailure ReleaseArgs := do
  let path ← asInvalidParams req.requirePath
  let handle ← asInvalidParams req.requireHandle
  let method ← asInvalidParams (releaseMethod req.backend)
  pure { path, handle, method }

end Beam.Broker
