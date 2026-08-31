/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Beam.Broker.Config
import Beam.Broker.LakeEnv
import Beam.Broker.Protocol
import Beam.LSP.Goals
import Beam.LSP.RunAt
import Beam.LSP.Save
import Beam.LSP.Todo
import Beam.Path

open Lean
open Lean.Lsp

namespace Beam.Broker.Backend.Lean

private def pluginPath (config : BrokerConfig) : IO System.FilePath := do
  match config.leanPlugin? with
  | some path => Beam.resolveExistingPath path
  | none => throw <| IO.userError "missing Beam daemon --lean-plugin configuration"

def command (config : BrokerConfig) : IO (String × Array String × Array (String × Option String)) := do
  let some cmd := config.leanCmd?
    | throw <| IO.userError "missing Beam daemon --lean-cmd configuration"
  let plugin := ← pluginPath config
  let lakeEnv ← leanServerLakeEnv config.root config.leanCmd? config.leanLakeHelper?
  pure (
    cmd,
    #["--server"] ++ lakeEnv.moreServerArgs ++
      #[s!"--plugin={plugin}", "-Dexperimental.module=true"],
    lakeEnv.env)

def initializeParams (root : System.FilePath) : Json :=
  let rootUri := System.Uri.pathToUri root
  toJson ({
    processId? := some 0
    rootUri? := some rootUri
    workspaceFolders? := some #[{ uri := rootUri, name := root.fileName.getD root.toString }]
    initializationOptions? := some { hasWidgets? := some true, logCfg? := none }
    capabilities := {
      textDocument? := some {
        completion? := some {
          completionItem? := some { insertReplaceSupport? := true }
        }
      }
    }
    : InitializeParams
  })

def runAtMethod : String :=
  Beam.LSP.RunAt.method

def hoverMethod : String :=
  "textDocument/hover"

def signatureHelpMethod : String :=
  "textDocument/signatureHelp"

def definitionMethod : String :=
  "textDocument/definition"

def referencesMethod : String :=
  "textDocument/references"

def documentSymbolsMethod : String :=
  "textDocument/documentSymbol"

def workspaceSymbolsMethod : String :=
  "workspace/symbol"

def codeActionResolveMethod : String :=
  "codeAction/resolve"

def runWithMethod : String :=
  Beam.LSP.RunAt.runWithMethod

def releaseMethod : String :=
  Beam.LSP.RunAt.releaseHandleMethod

def saveArtifactsMethod : String :=
  Beam.LSP.Save.saveArtifactsMethod

def diagnosticsBarrierMethod : String :=
  "$/beam/waitForDiagnostics"

def goalsMethod (mode? : Option GoalMode := none) : String :=
  match mode?.getD .after with
  | .before => Beam.LSP.Goals.prevMethod
  | .after => Beam.LSP.Goals.afterMethod

def todoMethod : String :=
  Beam.LSP.Todo.method

end Beam.Broker.Backend.Lean
