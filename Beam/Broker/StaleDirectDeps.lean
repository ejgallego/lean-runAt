 /-
 Copyright (c) 2026 Lean FRO LLC. All rights reserved.
 Released under Apache 2.0 license as described in the file LICENSE.
 Author: Emilio J. Gallego Arias
 -/

 import Lean

 open Lean

 namespace Beam.Broker

 /--
 Data used by the supported sync/readiness path to explain stale direct dependencies after a failed
 diagnostics barrier.

 This is intentionally separate from the stopgap `lean-deps` workspace scanner so the real sync
 recovery path does not conceptually depend on the experimental dependency-inspection surface.
 -/

 structure DirectImportsQueryResult where
   version : Nat
   imports : Array String := #[]
   deriving Inhabited

 structure ModuleHistorySnapshot where
   path : String
   lastSyncSeq : Nat := 0
   lastSaveSeq : Nat := 0
   deriving Inhabited

 structure StaleDirectDepHint where
   module : String
   path : String
   needsSave : Bool
   lastSyncSeq : Nat
   lastSaveSeq : Nat
   deriving Inhabited

 def staleDirectDepHintJson (hint : StaleDirectDepHint) : Json :=
   Json.mkObj [
     ("module", toJson hint.module),
     ("path", toJson hint.path),
     ("needsSave", toJson hint.needsSave),
     ("lastSyncSeq", toJson hint.lastSyncSeq),
     ("lastSaveSeq", toJson hint.lastSaveSeq)
   ]

 def staleSyncErrorData
     (targetPath : String)
     (hints : Array StaleDirectDepHint) : Json :=
   let saveHints := hints.filter (·.needsSave)
   let recoveryPlan :=
     (saveHints.map fun hint => s!"lean-beam save \"{hint.path}\"") ++
     #[s!"lean-beam refresh \"{targetPath}\"", "lake build"]
   Json.mkObj [
     ("targetPath", toJson targetPath),
     ("staleDirectDeps", Json.arr <| hints.map staleDirectDepHintJson),
     ("saveDeps", Json.arr <| saveHints.map (fun hint => toJson hint.path)),
     ("recoveryPlan", Json.arr <| recoveryPlan.map toJson)
   ]

 def collectStaleDirectDepHints
     (importsResult : DirectImportsQueryResult)
     (version : Nat)
     (targetLastSyncSeq : Nat)
     (history : Std.TreeMap String ModuleHistorySnapshot)
     : Array StaleDirectDepHint :=
   if importsResult.version != version then
     #[]
   else
     importsResult.imports.foldl (init := #[]) fun hints moduleName =>
       match history.get? moduleName with
       | some moduleHistory =>
           if moduleHistory.lastSaveSeq > targetLastSyncSeq then
             hints.push {
               module := moduleName
               path := moduleHistory.path
               needsSave := moduleHistory.lastSaveSeq < moduleHistory.lastSyncSeq
               lastSyncSeq := moduleHistory.lastSyncSeq
               lastSaveSeq := moduleHistory.lastSaveSeq
             }
           else
             hints
       | none =>
           hints

 end Beam.Broker
