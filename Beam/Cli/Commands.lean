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
import Std.Internal.UV.Signal

open Lean

namespace Beam.Cli

open Beam.Broker

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
    workspaceId? := some projectDaemonWorkspaceId
    root? := some root.toString
    path? := some path
  }
  failOnError resp
  let some result := decodeUpdateFileResult? resp
    | throw <| IO.userError "update_file returned an invalid response while obtaining document version"
  pure result.version

private def runLeanRunAt
    (home : System.FilePath)
    (opts : CliOptions)
    (action path versionText lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let root ← projectRoot opts .lean
  let version ← parseNatArg "version" versionText
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let parsedText ← parseTextArg s!"{action} <path> <version> <line> <character>" textArgs
  withProjectDaemon home root .lean opts fun client => do
    let req ← withEnvClientRequestId <|
      leanRunAtRequest root path version line character parsedText.text? (storeHandle := storeHandle)
    maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
    callBrokerWithProgress root client req (leanRunAtWaitSpec action path line character)

private def runLeanRunWith
    (home : System.FilePath)
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
  let root ← projectRoot opts .lean
  let (handle, textArgs) ← parseHandleInput s!"{action} <path>" args
  let parsedText ← parseTextArg s!"{action} <path> <handle-json|-|--handle-file <path>>" textArgs
  let req ← withEnvClientRequestId <|
    leanRunWithRequest root path handle parsedText.text? (linear := linear)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
  withProjectDaemon home root .lean opts fun client =>
    callBrokerWithProgress root client req (leanRunWithWaitSpec path (linear := linear))

private def runLeanRelease
    (home : System.FilePath)
    (opts : CliOptions)
    (action : String)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts .lean
  let (handle, extra) ← parseHandleInput s!"{action} <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage s!"{action} <path>")
  withProjectDaemon home root .lean opts fun client =>
    callBroker root client <| leanReleaseRequest root path handle

private def shutdownProjectDaemon (opts : CliOptions) : IO Unit := do
  let root ← projectRootAny opts
  withProjectControlLock root do
    match ← registryLiveFor root with
    | some entry =>
        if let some endpoint := Beam.Daemon.registryEndpoint? entry then
          let resp ← sendRequest endpoint { op := .shutdown }
          printResponse resp
          finishRegistryDaemonShutdown entry
          removeRegistry root
        else
          stopRegisteredDaemon root
          printJsonLine <| Json.mkObj [
            ("result", Json.mkObj [("shutdown", toJson false), ("reason", toJson ("notFound" : String))])
          ]
    | none =>
        stopRegisteredDaemon root
        printJsonLine <| Json.mkObj [
          ("result", Json.mkObj [("shutdown", toJson false), ("reason", toJson ("notFound" : String))])
        ]

private def backendOfName (name : String) : Backend :=
  if name == "rocq" then .rocq else .lean

private def runThenHoldUntilInterrupted (act : IO Unit) : IO Unit := do
  let signal ← Std.Internal.UV.Signal.mk 2 false
  let promise ← Std.Internal.UV.Signal.next signal
  let task ← IO.asTask (prio := Task.Priority.dedicated) do
    let some _ ← IO.wait promise.result?
      | throw <| IO.userError "SIGINT watcher promise dropped"
    pure ()
  try
    act
    while !(← IO.hasFinished task) && !(← IO.checkCanceled) do
      IO.sleep 50
    if ← IO.hasFinished task then
      match ← IO.wait task with
      | .ok () => pure ()
      | .error err => throw err
  finally
    Std.Internal.UV.Signal.stop signal

private def ensureBackend
    (home : System.FilePath)
    (opts : CliOptions)
    (backend : Backend)
    (hold : Bool := false) : IO Unit := do
  let root ← projectRoot opts backend
  withProjectDaemon home root backend opts fun client =>
    if hold then
      runThenHoldUntilInterrupted do
        callBroker root client {
          op := .ensure, backend := backend, root? := some root.toString
        }
        (← IO.getStdout).flush
        IO.eprintln "beam: holding ensured daemon; interrupt this wrapper process when finished"
    else
      callBroker root client { op := .ensure, backend := backend, root? := some root.toString }

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
  | "install-runtime-validate" :: path :: [] =>
      validateInstalledRuntimeForReuse (System.FilePath.mk path)
  | "mcp-config" :: [] =>
      printMcpConfig home opts
  | "feedback-report" :: args =>
      Beam.Cli.Feedback.run home opts args
  | "ensure" :: [] =>
      ensureBackend home opts .lean
  | "ensure" :: "--hold" :: [] =>
      ensureBackend home opts .lean (hold := true)
  | "ensure" :: backend :: [] =>
      ensureBackend home opts (backendOfName backend)
  | "ensure" :: backend :: "--hold" :: [] =>
      ensureBackend home opts (backendOfName backend) (hold := true)
  | "lean-run-at" :: path :: version :: line :: character :: text =>
      runLeanRunAt home opts (← wrapperDisplayAction "lean-run-at") path version line character text
  | "lean-run-at-handle" :: path :: version :: line :: character :: text =>
      runLeanRunAt home opts (← wrapperDisplayAction "lean-run-at-handle") path version line character text
        (storeHandle := true)
  | "lean-hover" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-hover"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanHoverRequest root path version line character)
          (leanHoverWaitSpec path line character action)
  | "lean-signature-help" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-signature-help"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanSignatureHelpRequest root path version line character)
          (leanSignatureHelpWaitSpec path line character action)
  | "lean-definition" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-definition"
      withProjectDaemon home root .lean opts fun client =>
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
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanReferencesRequest root path version line character includeDeclaration)
          (leanReferencesWaitSpec path line character action)
  | "lean-document-symbols" :: path :: versionText :: [] =>
      let root ← projectRoot opts .lean
      let version ← parseNatArg "version" versionText
      let action ← wrapperDisplayAction "lean-document-symbols"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanDocumentSymbolsRequest root path version)
          (leanDocumentSymbolsWaitSpec path action)
  | "lean-workspace-symbols" :: queryParts =>
      let root ← projectRoot opts .lean
      let query ←
        match joinTextArgs queryParts with
        | some query => pure query
        | none => throw <| IO.userError "usage: beam [--root PATH] [--port N] lean-workspace-symbols <query...>"
      let action ← wrapperDisplayAction "lean-workspace-symbols"
      withProjectDaemon home root .lean opts fun client =>
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
      withProjectDaemon home root .lean opts fun client =>
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
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanTodoRequest root path version startLine startCharacter endLine endCharacter kinds? suggest?)
          (leanTodoWaitSpec path startLine startCharacter endLine endCharacter action)
  | "lean-run-with" :: path :: args =>
      runLeanRunWith home opts (← wrapperDisplayAction "lean-run-with") path args
  | "lean-run-with-linear" :: path :: args =>
      runLeanRunWith home opts (← wrapperDisplayAction "lean-run-with-linear") path args
        (linear := true)
  | "lean-release" :: path :: args =>
      runLeanRelease home opts (← wrapperDisplayAction "lean-release") path args
  | "lean-save" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanSaveArgs extra
      let action ← wrapperDisplayAction "lean-save"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanSaveRequest root path diagnosticScope)
          (leanSaveWaitSpec path (action? := some action))
  | "lean-update" :: path :: [] =>
      let root ← projectRoot opts .lean
      withProjectDaemon home root .lean opts fun client =>
        callBroker root client <| leanUpdateRequest root path
  | "lean-sync" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanSyncArgs extra
      let action ← wrapperDisplayAction "lean-sync"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanSyncRequest root path diagnosticScope)
          (syncWaitSpec path action)
  | "lean-refresh" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanRefreshArgs extra
      let action ← wrapperDisplayAction "lean-refresh"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanRefreshRequest root path diagnosticScope)
          (refreshWaitSpec path action)
  | "lean-close" :: path :: [] =>
      let root ← projectRoot opts .lean
      withProjectDaemon home root .lean opts fun client =>
        callBroker root client <| leanCloseRequest root path
  | "lean-close-save" :: path :: extra =>
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanCloseSaveArgs extra
      let action ← wrapperDisplayAction "lean-close-save"
      withProjectDaemon home root .lean opts fun client =>
        callBrokerWithProgress root client
          (leanCloseSaveRequest root path diagnosticScope)
          (leanSaveWaitSpec path (closeAfter := true) (action? := some action))
  | "rocq-goals-after" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      withProjectDaemon home root .rocq opts fun client => do
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
      withProjectDaemon home root .rocq opts fun client => do
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
      doctor home opts (if backend == "rocq" then .rocq else .lean)
  | "open-files" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root fun client =>
        callBroker root client {
          op := .openDocs
          root? := some root.toString
        }
  | "cancel" :: requestId :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root fun client =>
        callBroker root client {
          op := .cancel
          cancelRequestId? := some requestId
        }
  | "stats" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root fun client =>
        callBroker root client { op := .stats }
  | "reset-stats" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root fun client =>
        callBroker root client { op := .resetStats }
  | "shutdown" :: [] =>
      shutdownProjectDaemon opts
  | _ =>
      throw <| IO.userError usage

end Beam.Cli
