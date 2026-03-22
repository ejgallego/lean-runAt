/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake

open Lake DSL
open System

package "runAt" where

def runatUnixOTarget (pkg : Package) : FetchM (Job FilePath) := do
  let oFile := pkg.buildDir / "ffi" / "runat_unix.o"
  let srcTarget ← inputTextFile <| pkg.dir / "ffi" / "runat_unix.c"
  buildFileAfterDep oFile srcTarget fun srcFile => do
    let flags := #["-I", (← getLeanIncludeDir).toString, "-fPIC"]
    compileO oFile srcFile flags

extern_lib runat_unix (pkg) := do
  let name := nameToStaticLib "runat_unix"
  let ffiO ← runatUnixOTarget pkg
  buildStaticLib (pkg.staticLibDir / name) #[ffiO]

lean_lib RunAt where
  defaultFacets := #[`shared]

lean_lib Beam where
  defaultFacets := #[`shared]

lean_lib RunAtTest where

lean_exe "runAt-test" where
  root := `RunAtTest.TestRunner

lean_exe "runAt-scenario-test" where
  root := `RunAtTest.ScenarioRunner

lean_exe "runAt-scenario-api-test" where
  root := `RunAtTest.Scenario.ApiTest

lean_exe "runAt-scenario-stress-test" where
  root := `RunAtTest.Scenario.StressTest

lean_exe "runAt-handle-api-test" where
  root := `RunAtTest.Handle.ApiTest

lean_exe "runAt-handle-restart-test" where
  root := `RunAtTest.Handle.RestartTest

lean_exe "runAt-handle-lifecycle-test" where
  root := `RunAtTest.Handle.LifecycleTest

lean_exe "runAt-mcts-proof-search-test" where
  root := `RunAtTest.Scenario.MctsProofSearchTest

lean_exe "runAt-nested-handle-failure-test" where
  root := `RunAtTest.Handle.NestedHandleFailureTest

lean_exe "runAt-request-surface-test" where
  root := `RunAtTest.RequestSurfaceTest

lean_exe "runAt-search-workload-report" where
  root := `RunAtTest.Scenario.SearchWorkloadReport

lean_exe "beam-daemon" where
  root := `Beam.Broker.Server
  supportInterpreter := true

lean_exe "beam-client" where
  root := `Beam.BrokerClient

@[default_target]
lean_exe "beam-cli" where
  root := `Beam.Cli

lean_exe "beam-daemon-smoke-test" where
  root := `RunAtTest.Broker.SmokeTestMain

lean_exe "beam-daemon-save-stream-test" where
  root := `RunAtTest.Broker.SaveStreamTestMain

lean_exe "beam-daemon-request-stream-test" where
  root := `RunAtTest.Broker.RequestStreamContractTestMain

lean_exe "beam-daemon-startup-handshake-test" where
  root := `RunAtTest.Broker.StartupHandshakeTestMain

lean_exe "beam-daemon-rocq-smoke-test" where
  root := `RunAtTest.Broker.RocqSmokeTest
