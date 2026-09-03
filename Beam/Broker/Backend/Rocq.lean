/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Beam.Broker.Config
import Beam.Broker.Protocol

open Lean
open Lean.Lsp

namespace Beam.Broker.Backend.Rocq

def command (config : BrokerConfig) : IO (String × Array String) := do
  let some rocqConfig := config.rocq?
    | throw <| IO.userError "Rocq backend is not configured"
  pure (rocqConfig.command, #[])

def initializeParams (root : System.FilePath) : Json :=
  let rootUri := System.Uri.pathToUri root
  toJson ({
    rootUri? := some rootUri
    workspaceFolders? := some #[{ uri := rootUri, name := root.fileName.getD root.toString }]
    capabilities := {}
    : InitializeParams
  })

def runAtMethod : Except String String :=
  .error "rocq backend does not support run_at yet"

def runWithMethod : Except String String :=
  .error "rocq backend does not support run_with yet"

def releaseMethod : Except String String :=
  .error "rocq backend does not support release yet"

def saveArtifactsMethod : Except String String :=
  .error "rocq backend does not support artifact save yet"

def goalsMethod : String :=
  "proof/goals"

def goalModeValue (mode? : Option GoalMode) : String :=
  match mode?.getD .after with
  | .before => "Prev"
  | .after => "After"

end Beam.Broker.Backend.Rocq
