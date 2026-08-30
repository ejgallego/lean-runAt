/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Args
import Beam.Cli.Broker
import Beam.Cli.DaemonManager
import Beam.Cli.Feedback
import Beam.Cli.Info
import Beam.Cli.InstallPrune
import Beam.Cli.LeanOperation
import Beam.Cli.Project
import Beam.Cli.RuntimeBundle
import Beam.Cli.Usage

open Lean

namespace Beam.Cli

open Beam.Broker

private inductive SessionState where
  | absent
  | running
  | stopping
  | recoveryRequired
  deriving BEq, Repr

private instance : ToJson SessionState where
  toJson
    | .absent => "absent"
    | .running => "running"
    | .stopping => "stopping"
    | .recoveryRequired => "recoveryRequired"

private structure SessionStatus where
  state : SessionState
  workspace : String
  sessionDir : String
  generation? : Option String := none
  detail? : Option String := none
  deriving ToJson

private structure SessionTransitionWarning where
  code : String
  message : String
  deriving ToJson

private structure SessionTransitionResult where
  state : SessionState
  changed : Bool
  warning? : Option SessionTransitionWarning := none
  deriving ToJson

private structure SessionRecoveryResult where
  state : SessionState
  changed : Bool
  generation? : Option String := none
  quarantinedPath? : Option String := none
  reason? : Option String := none
  deriving ToJson

private def mkSessionStatus
    (state : SessionState)
    (workspace sessionDir : System.FilePath)
    (generation? detail? : Option String := none) : SessionStatus := {
  state
  workspace := workspace.toString
  sessionDir := sessionDir.toString
  generation?
  detail?
}

private def wrapperDisplayAction (fallback : String) : IO String := do
  match ← IO.getEnv "BEAM_WRAPPER_COMMAND" with
  | some action => pure action
  | none => pure fallback

private def updateVersionForRocqGoals
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (path : String) : IO Nat := do
  let resp ← requestBroker root client {
    op := .updateFile
    backend := .rocq
    workspaceId? := some client.workspaceId
    root? := some root.toString
    path? := some path
  }
  failOnError resp
  let some result := decodeUpdateFileResult? resp
    | throw <| IO.userError "update_file returned an invalid response while obtaining document version"
  pure result.version

private def runLeanRunAt
    (opts : CliOptions)
    (action path versionText lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let version ← parseNatArg "version" versionText
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let parsedText ← parseTextArg s!"{action} <path> <version> <line> <character>" textArgs
  let root ← projectRoot opts .lean
  withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client => do
    let req ← withEnvClientRequestId <|
      leanRunAtRequest root path version line character parsedText.text (storeHandle := storeHandle)
    maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
    callBrokerWithProgress root client req (leanRunAtWaitSpec action path line character)

private def runLeanRunWith
    (opts : CliOptions)
    (action path : String)
    (args : List String)
    (linear : Bool := false) : IO Unit := do
  let textArgs :=
    match args with
    | [] => []
    | "--handle-file" :: _ :: rest => rest
    | _ :: rest => rest
  if handleArgReadsStdin args && textArgReadsStdin textArgs then
    throw <| IO.userError <| String.intercalate "\n" [
      textArgUsage s!"{action} <path> <handle-json|-|--handle-file <path>>",
      "cannot read both handle json and continuation text from stdin; pass the handle inline, use --handle-file, or use --text-file for the text"
    ]
  let (handle, textArgs) ← parseHandleInput s!"{action} <path>" args
  let parsedText ← parseTextArg s!"{action} <path> <handle-json|-|--handle-file <path>>" textArgs
  let root ← projectRoot opts .lean
  let req ← withEnvClientRequestId <|
    leanRunWithRequest root path handle parsedText.text (linear := linear)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
  withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBrokerWithProgress root client req (leanRunWithWaitSpec path (linear := linear))

private def runLeanRelease
    (opts : CliOptions)
    (action : String)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts .lean
  let (handle, extra) ← parseHandleInput s!"{action} <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage s!"{action} <path>")
  withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBroker root client <| leanReleaseRequest root path handle

private def stopProjectSession (opts : CliOptions) : IO Unit := do
  let root ← explicitProjectRoot opts "stop"
  match ← shutdownRegisteredProjectDaemon root opts.explicitControlDir? with
  | .absent =>
      printResponse <| Response.success <|
        toJson ({ state := .absent, changed := false } : SessionTransitionResult)
  | .alreadyStopping =>
      printResponse <| Response.success <| toJson ({
        state := .stopping
        changed := false
      } : SessionTransitionResult)
  | .stopping delivery =>
      let warning? ←
        match delivery with
        | .acknowledged => pure none
        | .rejected failure =>
            pure <| some ({
              code := "shutdownRejected"
              message := failure.error.message
            } : SessionTransitionWarning)
        | .failed failure =>
            pure <| some ({
              code := "shutdownDeliveryFailed"
              message := ← daemonFailureMessage root failure opts.explicitControlDir?
            } : SessionTransitionWarning)
      printResponse <| Response.success <| toJson ({
        state := .stopping
        changed := true
        warning?
      } : SessionTransitionResult)

private def recoverProjectSession (opts : CliOptions) (args : List String) : IO Unit := do
  let root ← explicitProjectRoot opts "recover"
  let (generation?, forceOpaque) ←
    match args with
    | ["--generation", generation] => pure (some generation, false)
    | ["--force"] => pure (none, true)
    | _ =>
        throw <| IO.userError
          "usage: beam --root PATH [--session-dir DIR] recover --generation ID | --force"
  let result ← recoverProjectDaemon root generation? forceOpaque opts.explicitControlDir?
  printResponse <| Response.success <| toJson ({
    state := .absent
    changed := result.recovered
    generation? := result.generation?
    quarantinedPath? := result.quarantinedPath?
    reason? := result.reason?
  } : SessionRecoveryResult)

private def parseBackendName (name : String) : IO Backend := do
  match fromJson? (Json.str name) with
  | .ok backend => pure backend
  | .error err => throw <| IO.userError err

private def runThenHoldUntilInterrupted
    (owner : ProjectDaemonOwner)
    (act : IO Unit) : IO Unit :=
  withInterruptWatcher fun watcher => do
    act
    while !(← watcher.interrupted) && (← owner.exitCode?).isNone &&
        (← owner.registered) && !(← IO.checkCanceled) do
      IO.sleep 50
    if ← watcher.interrupted then
      watcher.awaitInterrupt
    else if let some exitCode ← owner.exitCode? then
      unless exitCode == 0 do
        throw <| IO.userError s!"owned Beam daemon exited with status {exitCode}"

private def serveBackend
    (home : System.FilePath)
    (opts : CliOptions)
    (backend : Backend) : IO Unit := do
  let root ← projectRoot opts backend
  withProjectDaemonOwner home root backend opts fun owner =>
    runThenHoldUntilInterrupted owner do
      callBrokerQuiet root owner.client {
        op := .ensure, backend := backend, root? := some root.toString
      }
      printResponse <| Response.success <| toJson <|
        mkSessionStatus .running root owner.client.controlDir (some owner.generation)
      (← IO.getStdout).flush
      IO.eprintln <|
        "beam: serving Beam session; interrupt this process or run when finished:\n" ++
        wrapperSessionCommand root owner.client.controlDir .stop

private def sessionStatus (opts : CliOptions) : IO Unit := do
  let root ← projectRootAny opts
  let sessionDir ← Beam.Daemon.controlDirFor root opts.explicitControlDir?
  let result : SessionStatus ←
    match ← observeProjectRegistry root opts.explicitControlDir? with
    | .absent => pure <| mkSessionStatus .absent root sessionDir
    | .live entry => pure <| mkSessionStatus .running root sessionDir (some entry.daemonId)
    | .draining entry => pure <| mkSessionStatus .stopping root sessionDir (some entry.daemonId)
    | .legacy =>
        pure <| mkSessionStatus .recoveryRequired root sessionDir none
          (some "legacy session descriptor")
    | .unsupported schemaVersion =>
        pure <| mkSessionStatus .recoveryRequired root sessionDir none
          (some s!"unsupported session descriptor schema {schemaVersion}")
    | .malformed detail =>
        pure <| mkSessionStatus .recoveryRequired root sessionDir none (some detail)
    | .selectorMismatch entry =>
        throw <| IO.userError <|
          sessionSelectorMismatchMessage root sessionDir entry
    | .unusable entry reason =>
        pure <| mkSessionStatus .recoveryRequired root sessionDir
          (some entry.daemonId) (some reason.message)
  printResponse <| Response.success (toJson result)

def runCommand (home : System.FilePath) (opts : CliOptions) : IO Unit := do
  match opts.args with
  | [] =>
      throw <| IO.userError usage
  | "version" :: [] | "--version" :: [] =>
      printVersion home
  | "bundle-install" :: toolchain :: [] =>
      let cacheRoot ←
        match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
        | some path => pure <| System.FilePath.mk path
        | none =>
            let roots ← installBundleCacheRoots
            pure <| roots.headD (beamStateDir home / installBundlesDirName)
      let _ ← ensureToolchainBundleIn cacheRoot home toolchain
      pure ()
  | "install-prune" :: args =>
      runInstallPrune home args
  | "validated-toolchains" :: backend :: [] =>
      printValidatedToolchains home backend
  | "compatible-release-lines" :: [] =>
      printCompatibleReleaseLines home
  | "install-layout" :: [] =>
      printInstallLayout
  | "install-manifest" :: payloadHash :: sourceCommitArg :: createdWithToolchains =>
      printInstallManifest payloadHash sourceCommitArg createdWithToolchains
  | "install-manifest-with-source-commit" :: manifestPath :: sourceCommitArg :: [] =>
      printInstallManifestWithSourceCommit (System.FilePath.mk manifestPath) sourceCommitArg
  | "install-runtime-validate" :: path :: [] =>
      validateInstalledRuntimeForReuse (System.FilePath.mk path)
  | "mcp-config" :: [] =>
      printMcpConfig home opts
  | "feedback-report" :: args =>
      Beam.Cli.Feedback.run home opts args
  | "serve" :: [] =>
      serveBackend home opts .lean
  | "serve" :: backend :: [] =>
      serveBackend home opts (← parseBackendName backend)
  | "lean-run-at" :: path :: version :: line :: character :: text =>
      runLeanRunAt opts (← wrapperDisplayAction "lean-run-at") path version line character text
  | "lean-run-at-handle" :: path :: version :: line :: character :: text =>
      runLeanRunAt opts (← wrapperDisplayAction "lean-run-at-handle") path version line character text
        (storeHandle := true)
  | "lean-hover" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-hover"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanHoverRequest root path version line character)
          (leanHoverWaitSpec path line character action)
  | "lean-signature-help" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-signature-help"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSignatureHelpRequest root path version line character)
          (leanSignatureHelpWaitSpec path line character action)
  | "lean-definition" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-definition"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDefinitionRequest root path version line character)
          (leanDefinitionWaitSpec path line character action)
  | "lean-references" :: path :: versionText :: line :: character :: extra =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let includeDeclaration ← parseLeanReferencesArgs extra
      let action ← wrapperDisplayAction "lean-references"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanReferencesRequest root path version line character includeDeclaration)
          (leanReferencesWaitSpec path line character action)
  | "lean-document-symbols" :: path :: versionText :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let action ← wrapperDisplayAction "lean-document-symbols"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDocumentSymbolsRequest root path version)
          (leanDocumentSymbolsWaitSpec path action)
  | "lean-workspace-symbols" :: queryParts =>
      let root ← projectRoot opts .lean
      let query ←
        match joinTextArgs queryParts with
        | some query => pure query
        | none => throw <| IO.userError "usage: beam [--root PATH] lean-workspace-symbols <query...>"
      let action ← wrapperDisplayAction "lean-workspace-symbols"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanWorkspaceSymbolsRequest root query)
          (leanWorkspaceSymbolsWaitSpec query action)
  | "lean-goals" :: modeText :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let mode ← parseLeanGoalsModeArg modeText
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-goals"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanGoalsRequest root path version line character mode)
          (leanGoalsWaitSpec path line character mode (some action))
  | "lean-todo" :: path :: versionText :: startLine :: startCharacter :: endLine :: endCharacter :: extra => do
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let startLine ← parseNatArg "startLine" startLine
      let startCharacter ← parseNatArg "startCharacter" startCharacter
      let endLine ← parseNatArg "endLine" endLine
      let endCharacter ← parseNatArg "endCharacter" endCharacter
      let (kinds?, suggest?) ← parseLeanTodoArgs extra
      let action ← wrapperDisplayAction "lean-todo"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanTodoRequest root path version startLine startCharacter endLine endCharacter kinds? suggest?)
          (leanTodoWaitSpec path startLine startCharacter endLine endCharacter action)
  | "lean-run-with" :: path :: args =>
      runLeanRunWith opts (← wrapperDisplayAction "lean-run-with") path args
  | "lean-run-with-linear" :: path :: args =>
      runLeanRunWith opts (← wrapperDisplayAction "lean-run-with-linear") path args
        (linear := true)
  | "lean-release" :: path :: args =>
      runLeanRelease opts (← wrapperDisplayAction "lean-release") path args
  | "lean-save" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanSaveArgs extra
      let action ← wrapperDisplayAction "lean-save"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSaveRequest root path diagnosticScope)
          (leanSaveWaitSpec path (action? := some action))
  | "lean-update" :: path :: [] =>
      let root ← projectRoot opts .lean
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| leanUpdateRequest root path
  | "lean-sync" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanSyncArgs extra
      let action ← wrapperDisplayAction "lean-sync"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSyncRequest root path diagnosticScope)
          (syncWaitSpec path action)
  | "lean-refresh" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanRefreshArgs extra
      let action ← wrapperDisplayAction "lean-refresh"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanRefreshRequest root path diagnosticScope)
          (refreshWaitSpec path action)
  | "lean-close" :: path :: [] =>
      let root ← projectRoot opts .lean
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| leanCloseRequest root path
  | "lean-close-save" :: path :: extra =>
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanCloseSaveArgs extra
      let action ← wrapperDisplayAction "lean-close-save"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanCloseSaveRequest root path diagnosticScope)
          (leanSaveWaitSpec path (closeAfter := true) (action? := some action))
  | "rocq-goals-after" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      withProjectDaemon root .rocq (explicitControlDir? := opts.explicitControlDir?) fun client => do
        let version ← updateVersionForRocqGoals root client path
        callBroker root client {
          op := .goals
          backend := .rocq
          root? := some root.toString
          path? := some path
          version? := some version
          line? := some (← parseNatArg "line" line)
          character? := some (← parseNatArg "character" character)
          mode? := some .after
          compact? := some false
          ppFormat? := some .str
          text? := joinTextArgs text
        }
  | "rocq-goals-prev" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      withProjectDaemon root .rocq (explicitControlDir? := opts.explicitControlDir?) fun client => do
        let version ← updateVersionForRocqGoals root client path
        callBroker root client {
          op := .goals
          backend := .rocq
          root? := some root.toString
          path? := some path
          version? := some version
          line? := some (← parseNatArg "line" line)
          character? := some (← parseNatArg "character" character)
          mode? := some .before
          compact? := some false
          ppFormat? := some .str
          text? := joinTextArgs text
        }
  | "doctor" :: backend :: [] =>
      doctor home opts (← parseBackendName backend)
  | "open-files" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client {
          op := .openDocs
          root? := some root.toString
        }
  | "cancel" :: requestId :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client {
          op := .cancel
          cancelRequestId? := some requestId
        }
  | "stats" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client { op := .stats }
  | "reset-stats" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client { op := .resetStats }
  | "status" :: [] =>
      sessionStatus opts
  | "stop" :: [] =>
      stopProjectSession opts
  | "recover" :: args =>
      recoverProjectSession opts args
  | _ =>
      throw <| IO.userError usage

end Beam.Cli
