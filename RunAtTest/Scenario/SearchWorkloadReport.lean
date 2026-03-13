/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Scenario.SearchWorkloadReport

private structure SearchHandle where
  handle : RunAt.Handle
  goalCount : Nat

private inductive StepOutcome where
  | ongoing (next : SearchHandle)
  | solved (extraHandle? : Option RunAt.Handle)

private inductive OpKind where
  | mint
  | branchSuccess
  | linearSuccess
  | failureProbe
  | release
  deriving Inhabited

private structure OpStats where
  count : Nat := 0
  totalLatencyUs : Nat := 0
  maxLatencyUs : Nat := 0
  minLatencyUs? : Option Nat := none

private structure ReportState where
  playouts : Nat := 0
  solvedPlayouts : Nat := 0
  totalSteps : Nat := 0
  maxSteps : Nat := 0
  rootGoalCount : Nat := 0
  goalHistogram : Std.TreeMap Nat Nat := {}
  mintStats : OpStats := {}
  branchStats : OpStats := {}
  linearStats : OpStats := {}
  failureStats : OpStats := {}
  releaseStats : OpStats := {}

private abbrev ReportM := StateT ReportState ScenarioM

private def liftScenario (act : ScenarioM α) : ReportM α :=
  StateT.lift act

private def searchPath : System.FilePath :=
  System.FilePath.mk "tests/scenario/docs/MctsProof.lean"

private def successTactic : String :=
  "first | constructor | exact trivial"

private def badTactic : String :=
  "exact MissingSearchReportWitness"

private def defaultPlayouts : Nat := 24

private def defaultBaseSeed : Nat := 20260311

private def OpStats.record (stats : OpStats) (latencyUs : Nat) : OpStats :=
  {
    count := stats.count + 1
    totalLatencyUs := stats.totalLatencyUs + latencyUs
    maxLatencyUs := max stats.maxLatencyUs latencyUs
    minLatencyUs? := some <| match stats.minLatencyUs? with
      | some current => min current latencyUs
      | none => latencyUs
  }

private def avgLatencyUs (stats : OpStats) : Nat :=
  if stats.count == 0 then 0 else stats.totalLatencyUs / stats.count

private def opStatsJson (stats : OpStats) : Json :=
  Json.mkObj <|
    [
      ("count", toJson stats.count),
      ("avgLatencyUs", toJson (avgLatencyUs stats)),
      ("maxLatencyUs", toJson stats.maxLatencyUs),
      ("totalLatencyUs", toJson stats.totalLatencyUs)
    ] ++
    match stats.minLatencyUs? with
    | some latency => [("minLatencyUs", toJson latency)]
    | none => []

private def recordOp (kind : OpKind) (latencyUs : Nat) : ReportM Unit := do
  modify fun state =>
    match kind with
    | .mint => { state with mintStats := state.mintStats.record latencyUs }
    | .branchSuccess => { state with branchStats := state.branchStats.record latencyUs }
    | .linearSuccess => { state with linearStats := state.linearStats.record latencyUs }
    | .failureProbe => { state with failureStats := state.failureStats.record latencyUs }
    | .release => { state with releaseStats := state.releaseStats.record latencyUs }

private def recordGoalCount (goalCount : Nat) : ReportM Unit := do
  modify fun state =>
    let seen := (state.goalHistogram.get? goalCount).getD 0
    { state with goalHistogram := state.goalHistogram.insert goalCount (seen + 1) }

private def recordPlayoutSolved (steps : Nat) : ReportM Unit := do
  modify fun state => {
    state with
    playouts := state.playouts + 1
    solvedPlayouts := state.solvedPlayouts + 1
    totalSteps := state.totalSteps + steps
    maxSteps := max state.maxSteps steps
  }

private def timed (kind : OpKind) (act : ReportM α) : ReportM α := do
  let startedAt ← IO.monoNanosNow
  let result ← act
  let finishedAt ← IO.monoNanosNow
  recordOp kind ((finishedAt - startedAt) / 1000)
  pure result

private def startPos : IO Lean.Lsp.Position := do
  let text ← IO.FS.readFile searchPath
  let some line := text.splitOn "\n" |>.head?
    | throw <| IO.userError s!"could not read first line of {searchPath}"
  pure { line := 0, character := line.length }

private def goalCountOf (label : String) (result : RunAt.Result) : ReportM Nat := do
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState payload"
  let goalCount := proofState.goals.size
  recordGoalCount goalCount
  pure goalCount

private def awaitResult (label : String) (req : ReqHandle) : ReportM RunAt.Result := do
  let outcome : RunAtTest.TestHarness.RequestOutcome ← liftScenario <| awaitReq req
  let some actual := outcome.result?
    | throw <| IO.userError
        s!"{label}: unexpected transport error {outcome.errorCode?.getD "unknown"}"
  match fromJson? actual with
  | .ok result => pure result
  | .error err =>
      throw <| IO.userError s!"{label}: failed to decode RunAt result: {err}"

private def releaseHandleTimed (doc : DocHandle) (handle : RunAt.Handle) : ReportM Unit :=
  timed .release <| liftScenario <| releaseHandle doc handle

private def runAtTimed (doc : DocHandle) (spec : SendRunAtSpec) : ReportM RunAt.Result :=
  timed .mint do
    let req ← liftScenario <| sendRunAt doc spec
    awaitResult "root mint" req

private def runWithTimed (kind : OpKind) (label : String) (doc : DocHandle) (handle : RunAt.Handle)
    (spec : RunWithSpec) : ReportM RunAt.Result :=
  timed kind do
    let req ← liftScenario <| runWithHandle doc handle spec
    awaitResult label req

private def awaitBranchSuccess (doc : DocHandle) (current : SearchHandle) : ReportM StepOutcome := do
  let result ← runWithTimed .branchSuccess
    s!"branch success from {current.goalCount} goals"
    doc current.handle { text := successTactic, storeHandle := true, linear := false }
  if !result.success then
    throw <| IO.userError "expected successful non-linear search step"
  let goalCount ← goalCountOf "branch success" result
  match result.handle? with
  | some handle =>
      if goalCount == 0 then
        pure (.solved (some handle))
      else
        pure (.ongoing { handle, goalCount })
  | none =>
      if goalCount == 0 then
        pure (.solved none)
      else
        throw <| IO.userError "unfinished branch success did not return a successor handle"

private def awaitLinearSuccess (doc : DocHandle) (current : SearchHandle) : ReportM StepOutcome := do
  let result ← runWithTimed .linearSuccess
    s!"linear success from {current.goalCount} goals"
    doc current.handle { text := successTactic, storeHandle := true, linear := true }
  if !result.success then
    throw <| IO.userError "expected successful linear playout step"
  let goalCount ← goalCountOf "linear success" result
  match result.handle? with
  | some handle =>
      if goalCount == 0 then
        pure (.solved (some handle))
      else
        pure (.ongoing { handle, goalCount })
  | none =>
      if goalCount == 0 then
        pure (.solved none)
      else
        throw <| IO.userError "unfinished linear step did not return a successor handle"

private def awaitFailureStep (doc : DocHandle) (current : SearchHandle) : ReportM Unit := do
  let result ← runWithTimed .failureProbe
    s!"failure probe from {current.goalCount} goals"
    doc current.handle { text := badTactic, storeHandle := true, linear := false }
  if result.success then
    throw <| IO.userError "expected semantic failure from bad search probe"
  let _ ← goalCountOf "failure probe" result
  if result.handle?.isSome then
    throw <| IO.userError "failed search probe unexpectedly returned a successor handle"

private def disposeSolvedHandle? (doc : DocHandle) : Option RunAt.Handle → ReportM Unit
  | some handle =>
      releaseHandleTimed doc handle
  | none =>
      pure ()

private def mintRootHandle (doc : DocHandle) : ReportM SearchHandle := do
  let pos ← startPos
  let result ← runAtTimed doc {
    line := pos.line
    character := pos.character
    text := "constructor"
    storeHandle := true
  }
  if !result.success then
    throw <| IO.userError "expected successful root search handle mint"
  let goalCount ← goalCountOf "root mint" result
  if goalCount == 0 then
    throw <| IO.userError "root mint unexpectedly solved the search proof"
  let some handle := result.handle?
    | throw <| IO.userError "expected root search handle"
  modify fun state => { state with rootGoalCount := goalCount }
  pure { handle, goalCount }

private def runPlayout (doc : DocHandle) (root : SearchHandle) (seed : Nat) : ReportM Unit := do
  let mut gen := mkStdGen seed
  let branch ← awaitBranchSuccess doc root
  let current ←
    match branch with
    | .ongoing next => pure next
    | .solved handle? =>
        disposeSolvedHandle? doc handle?
        throw <| IO.userError "playout branch unexpectedly solved on its first move"
  let mut current := current
  let mut steps := 1
  for _ in List.range 16 do
    let (probeRoll, gen') := randNat gen 0 3
    gen := gen'
    if probeRoll == 0 then
      awaitFailureStep doc current
    let (sideRoll, gen') := randNat gen 0 4
    gen := gen'
    if sideRoll == 0 then
      match ← awaitBranchSuccess doc current with
      | .ongoing side =>
          steps := steps + 1
          awaitFailureStep doc side
          releaseHandleTimed doc side.handle
      | .solved handle? =>
          steps := steps + 1
          disposeSolvedHandle? doc handle?
    match ← awaitLinearSuccess doc current with
    | .ongoing next =>
        steps := steps + 1
        current := next
    | .solved handle? =>
        steps := steps + 1
        disposeSolvedHandle? doc handle?
        recordPlayoutSolved steps
        return
  throw <| IO.userError "search workload exceeded the step budget without solving the proof"

private def goalHistogramJson (hist : Std.TreeMap Nat Nat) : Json :=
  Json.arr <| (hist.toList.map fun (goals, count) =>
    Json.mkObj [("goals", toJson goals), ("count", toJson count)]
  ).toArray

private def reportJson (playouts : Nat) (baseSeed totalWallTimeUs : Nat) (state : ReportState) : Json :=
  Json.mkObj [
    ("kind", toJson ("searchWorkloadReport" : String)),
    ("fixture", toJson searchPath.toString),
    ("notes", toJson #[
      "Lightweight seeded workload report; useful for regression visibility, not a benchmark.",
      "Latencies are end-to-end request timings inside the local scenario harness."
    ]),
    ("playoutsRequested", toJson playouts),
    ("baseSeed", toJson baseSeed),
    ("playoutsCompleted", toJson state.playouts),
    ("solvedPlayouts", toJson state.solvedPlayouts),
    ("totalWallTimeUs", toJson totalWallTimeUs),
    ("rootGoalCount", toJson state.rootGoalCount),
    ("avgStepsPerPlayout", toJson (if state.playouts == 0 then 0 else state.totalSteps / state.playouts)),
    ("maxStepsPerPlayout", toJson state.maxSteps),
    ("goalHistogram", goalHistogramJson state.goalHistogram),
    ("ops", Json.mkObj [
      ("mint", opStatsJson state.mintStats),
      ("branchSuccess", opStatsJson state.branchStats),
      ("linearSuccess", opStatsJson state.linearStats),
      ("failureProbe", opStatsJson state.failureStats),
      ("release", opStatsJson state.releaseStats)
    ])
  ]

private def parseNatArg (name : String) (arg : Option String) (fallback : Nat) : IO Nat := do
  match arg with
  | none => pure fallback
  | some text =>
      let some n := text.toNat?
        | throw <| IO.userError s!"invalid {name} '{text}'"
      pure n

def main (args : List String) : IO Unit := do
  let args := args.toArray
  let playouts ← parseNatArg "playouts" args[0]? defaultPlayouts
  let baseSeed ← parseNatArg "base seed" args[1]? defaultBaseSeed
  let startedAt ← IO.monoNanosNow
  let report ← RunAtTest.Scenario.run do
    let doc ← openDoc searchPath
    let (root, state) ← StateT.run (m := ScenarioM) (do
      let root ← mintRootHandle doc
      for i in List.range playouts do
        runPlayout doc root (baseSeed + i)
      releaseHandleTimed doc root.handle
      let state ← get
      pure (root, state)
    ) {}
    let _ := root
    closeDoc doc
    let finishedAt ← IO.monoNanosNow
    pure <| reportJson playouts baseSeed ((finishedAt - startedAt) / 1000) state
  IO.println report.pretty

end RunAtTest.Scenario.SearchWorkloadReport

def main := RunAtTest.Scenario.SearchWorkloadReport.main
