/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Feedback

def responsePayloadOrWarning
    (label : String)
    (resp : Beam.Broker.Response)
    (warnings : Array String) : Json × Array String :=
  match resp with
  | .successResult result _ => (result, warnings)
  | .errorResult failure =>
      let error := failure.error
      (Json.null, warnings.push s!"{label} failed: {error.code}: {error.message}")

end Beam.Feedback
