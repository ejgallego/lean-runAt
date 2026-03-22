/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import RunAt.Protocol
import RunAt.Internal.DirectImports
import RunAt.Internal.SaveSupport
import Beam.Broker.Config
import Beam.Broker.Protocol

open Lean
open Lean.Lsp

namespace Beam.Broker.Backend.Lean

private def pluginPath (config : BrokerConfig) : IO System.FilePath := do
  match config.leanPlugin? with
  | some path => IO.FS.realPath path
  | none => throw <| IO.userError "missing Beam daemon --lean-plugin configuration"

def command (config : BrokerConfig) : IO (String × Array String) := do
  let some cmd := config.leanCmd?
    | throw <| IO.userError "missing Beam daemon --lean-cmd configuration"
  let plugin := ← pluginPath config
  pure (cmd, #["--server", s!"--plugin={plugin}", "-DstderrAsMessages=false", "-Dexperimental.module=true"])

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
      lean? := some { silentDiagnosticSupport? := some true }
    }
    : InitializeParams
  })

def runAtMethod : String :=
  RunAt.method

def requestAtMethod (method : String) : Except String String :=
  match method with
  | "textDocument/definition"
  | "textDocument/hover"
  | "textDocument/references" => .ok method
  | _ => .error s!"lean backend experimental request_at does not support '{method}'"

def runWithMethod : String :=
  RunAt.runWithMethod

def releaseMethod : String :=
  RunAt.releaseHandleMethod

def saveArtifactsMethod : String :=
  RunAt.Internal.saveArtifactsMethod

def saveReadinessMethod : String :=
  RunAt.Internal.saveReadinessMethod

def directImportsMethod : String :=
  RunAt.Internal.directImportsMethod

def goalsMethod (mode? : Option GoalMode := none) : String :=
  match mode?.getD .after with
  | .after => RunAt.goalsAfterMethod
  | .prev => RunAt.goalsPrevMethod

end Beam.Broker.Backend.Lean
