/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Broker.LakeHelperMain

def main (args : List String) : IO Unit :=
  match args with
  | "lake-helper" :: helperArgs => Beam.Broker.LakeHelperMain.main helperArgs
  | _ => Beam.Broker.main args
