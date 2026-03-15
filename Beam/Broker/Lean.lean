/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Backend.Lean
import Beam.Broker.Backend.Rocq
import Beam.Broker.Backend.Shared

namespace Beam.Broker

def backendCommand (config : BrokerConfig) (backend : Backend) : IO (String × Array String) := do
  match backend with
  | .lean => Backend.Lean.command config
  | .rocq => Backend.Rocq.command config

def initializeParams (backend : Backend) (root : System.FilePath) : Lean.Json :=
  match backend with
  | .lean => Backend.Lean.initializeParams root
  | .rocq => Backend.Rocq.initializeParams root

def runAtMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.runAtMethod
  | .rocq => Backend.Rocq.runAtMethod

def requestAtMethod (backend : Backend) (method : String) : Except String String :=
  match backend with
  | .lean => Backend.Lean.requestAtMethod method
  | .rocq => Backend.Rocq.requestAtMethod

def runWithMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.runWithMethod
  | .rocq => Backend.Rocq.runWithMethod

def releaseMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.releaseMethod
  | .rocq => Backend.Rocq.releaseMethod

def saveArtifactsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.saveArtifactsMethod
  | .rocq => Backend.Rocq.saveArtifactsMethod

def saveReadinessMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.saveReadinessMethod
  | .rocq => Backend.Rocq.saveReadinessMethod

def goalsMethod (backend : Backend) (mode? : Option GoalMode := none) : Except String String :=
  match backend with
  | .lean => .ok (Backend.Lean.goalsMethod mode?)
  | .rocq => .ok Backend.Rocq.goalsMethod

def goalModeValue (mode? : Option GoalMode) : String :=
  Backend.Shared.goalModeValue mode?

def goalPpFormatValue (ppFormat? : Option GoalPpFormat) : String :=
  Backend.Shared.goalPpFormatValue ppFormat?

end Beam.Broker
