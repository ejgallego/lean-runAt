/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace RunAtCli.Broker

structure BrokerConfig where
  root : System.FilePath
  leanCmd? : Option String := none
  leanPlugin? : Option System.FilePath := none
  rocqCmd? : Option String := none
  deriving Inhabited, Repr

end RunAtCli.Broker
