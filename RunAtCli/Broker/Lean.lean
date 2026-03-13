/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Communication
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Lean.Data.Lsp.Internal
import Lean.Server.Requests
import RunAt.Protocol
import RunAt.Internal.SaveArtifacts
import RunAtCli.Broker.Config
import RunAtCli.Broker.Protocol

open Lean
open Lean.JsonRpc
open Lean.Lsp

namespace RunAtCli.Broker

private def leanPluginPath (config : BrokerConfig) : IO System.FilePath := do
  match config.leanPlugin? with
  | some path => IO.FS.realPath path
  | none => throw <| IO.userError "missing CLI daemon --lean-plugin configuration"

private def rocqLspPath (config : BrokerConfig) : IO String := do
  match config.rocqCmd? with
  | some path => pure path
  | none => throw <| IO.userError "missing CLI daemon --rocq-cmd configuration"

def backendCommand (config : BrokerConfig) (backend : Backend) : IO (String × Array String) := do
  match backend with
  | .lean =>
      let some cmd := config.leanCmd?
        | throw <| IO.userError "missing CLI daemon --lean-cmd configuration"
      let pluginPath := ← leanPluginPath config
      pure (cmd, #["--server", s!"--plugin={pluginPath}", "-DstderrAsMessages=false", "-Dexperimental.module=true"])
  | .rocq =>
      pure ((← rocqLspPath config), #[])

def initializeParams (backend : Backend) (root : System.FilePath) : Json := Id.run do
  let rootUri := System.Uri.pathToUri root
  match backend with
  | .lean =>
      return toJson ({
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
  | .rocq =>
      return toJson ({
        rootUri? := some rootUri
        workspaceFolders? := some #[{ uri := rootUri, name := root.fileName.getD root.toString }]
        capabilities := {}
        : InitializeParams
      })

def runAtMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok RunAt.method
  | .rocq => .error "rocq backend does not support run_at yet"

def requestAtMethod (backend : Backend) (method : String) : Except String String :=
  match backend with
  | .lean =>
      match method with
      | "textDocument/definition"
      | "textDocument/hover"
      | "textDocument/references" => .ok method
      | _ => .error s!"lean backend experimental request_at does not support '{method}'"
  | .rocq => .error "rocq backend does not support request_at yet"

def runWithMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok RunAt.runWithMethod
  | .rocq => .error "rocq backend does not support run_with yet"

def releaseMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok RunAt.releaseHandleMethod
  | .rocq => .error "rocq backend does not support release yet"

def saveArtifactsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok RunAt.Internal.saveArtifactsMethod
  | .rocq => .error "rocq backend does not support artifact save yet"

def goalsMethod (backend : Backend) (mode? : Option GoalMode := none) : Except String String :=
  match backend with
  | .lean =>
      match mode?.getD .after with
      | .after => .ok RunAt.goalsAfterMethod
      | .prev => .ok RunAt.goalsPrevMethod
  | .rocq => .ok "proof/goals"

def goalModeValue (mode? : Option GoalMode) : String :=
  match mode? with
  | some mode => mode.key
  | none => GoalMode.after.key

def goalPpFormatValue (ppFormat? : Option GoalPpFormat) : String :=
  match ppFormat? with
  | some format => format.key
  | none => GoalPpFormat.str.key

end RunAtCli.Broker
