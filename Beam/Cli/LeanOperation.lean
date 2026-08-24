/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation

open Lean

namespace Beam.Cli

open Beam.Broker

private def rootText (root : System.FilePath) : String :=
  root.toString

private def storeHandleFlag (storeHandle : Bool) : Option Bool :=
  if storeHandle then some true else none

def leanRunAtRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (line character : Nat)
    (text? : Option String)
    (storeHandle : Bool := false) : Request :=
  match text? with
  | some text =>
      ({ path, version, line, character, text } : Beam.Lean.RunAtInput).toBrokerRequest
        (rootText root) (storeHandle := storeHandle)
  | none =>
      {
        op := .runAt
        backend := .lean
        root? := some (rootText root)
        path? := some path
        version? := some version
        line? := some line
        character? := some character
        storeHandle? := storeHandleFlag storeHandle
      }

def leanRunWithRequest
    (root : System.FilePath)
    (path : String)
    (handle : Handle)
    (text? : Option String)
    (linear : Bool := false) : Request :=
  match text? with
  | some text =>
      ({ path, handle, text } : Beam.Lean.RunWithInput).toBrokerRequest
        (rootText root) (linear := linear)
  | none =>
      {
        op := .runWith
        backend := .lean
        root? := some (rootText root)
        path? := some path
        handle? := some handle
        storeHandle? := some true
        linear? := some linear
      }

def leanReleaseRequest (root : System.FilePath) (path : String) (handle : Handle) : Request :=
  ({ path, handle } : Beam.Lean.ReleaseInput).toBrokerRequest (rootText root)

def leanHoverRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (line character : Nat) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toHoverBrokerRequest (rootText root)

def leanSignatureHelpRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (line character : Nat) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toSignatureHelpBrokerRequest
    (rootText root)

def leanDefinitionRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (line character : Nat) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toDefinitionBrokerRequest
    (rootText root)

def leanReferencesRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (line character : Nat)
    (includeDeclaration : Bool := true) : Request :=
  ({
    path
    version
    line
    character
    includeDeclaration? := some includeDeclaration
  } : Beam.Lean.ReferencesInput).toBrokerRequest (rootText root)

def leanDocumentSymbolsRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat) : Request :=
  ({ path, version } : Beam.Lean.DocumentSymbolsInput).toBrokerRequest (rootText root)

def leanWorkspaceSymbolsRequest
    (root : System.FilePath)
    (query : String) : Request :=
  ({ query } : Beam.Lean.WorkspaceSymbolsInput).toBrokerRequest (rootText root)

def leanGoalsRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (line character : Nat)
    (mode : GoalMode) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toGoalsBrokerRequest (rootText root) mode

def leanTodoRequest
    (root : System.FilePath)
    (path : String)
    (version : Nat)
    (startLine startCharacter endLine endCharacter : Nat)
    (kinds? : Option (Array Beam.LSP.Todo.TodoKind))
    (suggest? : Option Beam.LSP.Todo.TodoSuggestMode) : Request :=
  ({
    path
    version
    startLine
    startCharacter
    endLine
    endCharacter
    kinds?
    suggest?
  } : Beam.Lean.TodoInput).toBrokerRequest (rootText root)

def leanCloseRequest (root : System.FilePath) (path : String) : Request :=
  ({ path } : Beam.Lean.PathInput).toCloseBrokerRequest (rootText root)

def leanUpdateRequest (root : System.FilePath) (path : String) : Request :=
  ({ path } : Beam.Lean.PathInput).toUpdateBrokerRequest (rootText root)

def leanSyncRequest
    (root : System.FilePath)
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SyncInput).toSyncBrokerRequest
    (rootText root)

def leanRefreshRequest
    (root : System.FilePath)
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SyncInput).toRefreshBrokerRequest
    (rootText root)

def leanSaveRequest
    (root : System.FilePath)
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SaveInput).toSaveBrokerRequest
    (rootText root)

def leanCloseSaveRequest
    (root : System.FilePath)
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SaveInput).toCloseSaveBrokerRequest
    (rootText root)

end Beam.Cli
