#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

lifecycle_root="$(beam_wrapper_prepare_project_root sync-save)"
standalone_root="$(beam_wrapper_prepare_project_root standalone-save)"

(
  cd "$lifecycle_root"
  "$beam_script" ensure lean > /dev/null

  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "0" ]; then
    echo "expected ensure lean to start with zero open Beam daemon documents" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  probe_before="$("$beam_script" lean-run-at SaveSmoke/B.lean 0 2 "#eval bVal")"
  if [ "$(RUNAT_JSON_PAYLOAD="$probe_before" read_json_text_field ok)" != "true" ]; then
    echo "expected initial wrapper probe to succeed" >&2
    printf '%s\n' "$probe_before" >&2
    exit 1
  fi
  if ! printf '%s\n' "$probe_before" | grep -q '"text": "1"'; then
    echo "expected initial wrapper probe to observe bVal = 1" >&2
    printf '%s\n' "$probe_before" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "1" ]; then
    echo "expected initial wrapper probe to open exactly one Beam daemon document" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  open_files_initial="$("$beam_script" open-files)"
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_initial" read_json_text_field ok)" != "true" ]; then
    echo "expected open-files after initial probe to succeed" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_initial" read_json_text_field result.sessions.lean.files.0.status)" != "saved" ]; then
    echo "expected open-files after initial probe to report SaveSmoke/B.lean as saved" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_initial" read_json_text_field result.sessions.lean.files.0.savedOlean)" != "false" ]; then
    echo "expected open-files after initial probe to report savedOlean = false" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_initial" read_json_text_field result.sessions.lean.files.0.saveEligible)" != "true" ]; then
    echo "expected open-files after initial probe to report saveEligible = true for SaveSmoke/B.lean" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_initial" read_json_text_field result.sessions.lean.files.0.saveReason)" != "ok" ]; then
    echo "expected open-files after initial probe to report saveReason = ok for SaveSmoke/B.lean" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi

  sed_in_place_portable 's/1/2/' SaveSmoke/B.lean
  sync_out="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync after first edit to succeed" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field result.version)" != "2" ]; then
    echo "expected lean-sync after first edit to report version 2" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected lean-sync after first edit to expose completed top-level fileProgress" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field result.saveReady)" != "true" ]; then
    echo "expected lean-sync after first edit to report saveReady = true" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field result.stateErrorCount)" != "0" ]; then
    echo "expected lean-sync after first edit to report stateErrorCount = 0" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field result.stateCommandErrorCount)" != "0" ]; then
    echo "expected lean-sync after first edit to report stateCommandErrorCount = 0" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if printf '%s\n' "$sync_out" | grep -q '"ok"[[:space:]]*:'; then
    echo "expected lean-sync output to omit the legacy ok field" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi

  open_files_synced="$("$beam_script" open-files)"
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_synced" read_json_text_field result.sessions.lean.files.0.fileProgress.done)" != "true" ]; then
    echo "expected open-files after lean-sync to retain completed fileProgress" >&2
    printf '%s\n' "$open_files_synced" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_synced" read_json_text_field result.sessions.lean.files.0.savedOlean)" != "false" ]; then
    echo "expected open-files after lean-sync to keep savedOlean = false before lean-save" >&2
    printf '%s\n' "$open_files_synced" >&2
    exit 1
  fi

  probe_after="$("$beam_script" lean-run-at SaveSmoke/B.lean 0 2 "#eval bVal")"
  if [ "$(RUNAT_JSON_PAYLOAD="$probe_after" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper probe after lean-sync to succeed" >&2
    printf '%s\n' "$probe_after" >&2
    exit 1
  fi
  if ! printf '%s\n' "$probe_after" | grep -q '"text": "2"'; then
    echo "expected wrapper probe after lean-sync to observe bVal = 2" >&2
    printf '%s\n' "$probe_after" >&2
    exit 1
  fi

  save_out="$("$beam_script" lean-save SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$save_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-save to succeed after a synced good edit" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$save_out" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected lean-save to expose completed top-level fileProgress" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$save_out" read_json_text_field result.version)" != "2" ]; then
    echo "expected lean-save to report saved version 2" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  if [ -z "$(RUNAT_JSON_PAYLOAD="$save_out" read_json_text_field result.sourceHash)" ]; then
    echo "expected lean-save to report a non-empty sourceHash" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi

  open_files_saved="$("$beam_script" open-files)"
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_saved" read_json_text_field result.sessions.lean.files.0.savedOlean)" != "true" ]; then
    echo "expected open-files after lean-save to report savedOlean = true" >&2
    printf '%s\n' "$open_files_saved" >&2
    exit 1
  fi

  sed_in_place_portable 's/2/3/' SaveSmoke/B.lean
  open_files_dirty="$("$beam_script" open-files)"
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_dirty" read_json_text_field result.sessions.lean.files.0.status)" != "notSaved" ]; then
    echo "expected open-files to detect an on-disk edit for an already known file incrementally" >&2
    printf '%s\n' "$open_files_dirty" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_dirty" read_json_text_field result.sessions.lean.files.0.savedOlean)" != "false" ]; then
    echo "expected open-files to clear savedOlean once the on-disk file diverges" >&2
    printf '%s\n' "$open_files_dirty" >&2
    exit 1
  fi

  sync_second="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_second" read_json_text_field ok)" != "true" ]; then
    echo "expected second lean-sync to succeed" >&2
    printf '%s\n' "$sync_second" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_second" read_json_text_field result.version)" != "3" ]; then
    echo "expected second lean-sync to report version 3" >&2
    printf '%s\n' "$sync_second" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_second" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected second lean-sync to expose completed top-level fileProgress" >&2
    printf '%s\n' "$sync_second" >&2
    exit 1
  fi

  open_files_second="$("$beam_script" open-files)"
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_second" read_json_text_field result.sessions.lean.files.0.status)" != "saved" ]; then
    echo "expected open-files after second lean-sync to report the file as saved again" >&2
    printf '%s\n' "$open_files_second" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$open_files_second" read_json_text_field result.sessions.lean.files.0.fileProgress.done)" != "true" ]; then
    echo "expected open-files after second lean-sync to retain completed fileProgress" >&2
    printf '%s\n' "$open_files_second" >&2
    exit 1
  fi

  sync_third="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_third" read_json_text_field ok)" != "true" ]; then
    echo "expected unchanged third lean-sync to succeed" >&2
    printf '%s\n' "$sync_third" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_third" read_json_text_field result.version)" != "3" ]; then
    echo "expected unchanged third lean-sync to preserve version 3" >&2
    printf '%s\n' "$sync_third" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_third" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected unchanged third lean-sync to expose completed top-level fileProgress" >&2
    printf '%s\n' "$sync_third" >&2
    exit 1
  fi

  refresh_out="$("$beam_script" lean-refresh SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$refresh_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-refresh to succeed for a tracked Lean file" >&2
    printf '%s\n' "$refresh_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$refresh_out" read_json_text_field result.saveReady)" != "true" ]; then
    echo "expected lean-refresh to report saveReady = true for an unchanged file" >&2
    printf '%s\n' "$refresh_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$refresh_out" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected lean-refresh to expose completed top-level fileProgress" >&2
    printf '%s\n' "$refresh_out" >&2
    exit 1
  fi

  sleep 1
  doctor_out="$("$beam_script" doctor lean)"
  if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
    echo "expected doctor lean to report a live Beam daemon after lean-sync and a short idle wait" >&2
    printf '%s\n' "$doctor_out" >&2
    exit 1
  fi

  probe_second="$("$beam_script" lean-run-at SaveSmoke/B.lean 0 2 "#eval bVal")"
  if [ "$(RUNAT_JSON_PAYLOAD="$probe_second" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper probe after a second lean-sync to succeed" >&2
    printf '%s\n' "$probe_second" >&2
    exit 1
  fi
  if ! printf '%s\n' "$probe_second" | grep -q '"text": "3"'; then
    echo "expected wrapper probe after a second lean-sync to observe bVal = 3" >&2
    printf '%s\n' "$probe_second" >&2
    exit 1
  fi

  close_good_out="$("$beam_script" lean-close SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$close_good_out" read_json_text_field ok)" != "true" ]; then
    echo "expected plain lean-close to succeed after a synced good edit" >&2
    printf '%s\n' "$close_good_out" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "0" ]; then
    echo "expected lean-close to leave zero open Beam daemon documents" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  probe_reopen="$("$beam_script" lean-run-at SaveSmoke/B.lean 0 2 "#eval bVal")"
  if [ "$(RUNAT_JSON_PAYLOAD="$probe_reopen" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper probe after lean-close to reopen the document successfully" >&2
    printf '%s\n' "$probe_reopen" >&2
    exit 1
  fi
  if ! printf '%s\n' "$probe_reopen" | grep -q '"text": "3"'; then
    echo "expected wrapper probe after lean-close to observe bVal = 3" >&2
    printf '%s\n' "$probe_reopen" >&2
    exit 1
  fi
)

(
  cd "$standalone_root"
  "$beam_script" ensure lean > /dev/null

  cat > StandaloneSaveSmoke.lean <<'EOF'
import SaveSmoke.B

#check bVal
EOF

  standalone_sync="$("$beam_script" lean-sync StandaloneSaveSmoke.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$standalone_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync to succeed on a standalone file the daemon can open" >&2
    printf '%s\n' "$standalone_sync" >&2
    exit 1
  fi

  standalone_open="$("$beam_script" open-files)"
  if [ "$(RUNAT_JSON_PAYLOAD="$standalone_open" read_json_text_field result.sessions.lean.files.0.saveEligible)" != "false" ]; then
    echo "expected open-files to report saveEligible = false for a standalone save target" >&2
    printf '%s\n' "$standalone_open" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$standalone_open" read_json_text_field result.sessions.lean.files.0.saveReason)" != "saveTargetNotModule" ]; then
    echo "expected open-files to report saveReason = saveTargetNotModule for a standalone save target" >&2
    printf '%s\n' "$standalone_open" >&2
    exit 1
  fi

  standalone_save_err="$(beam_wrapper_mktemp_file standalone-save)"
  if "$beam_script" lean-save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
    echo "expected lean-save to reject a standalone file outside the Lake module graph" >&2
    cat "$standalone_save_err" >&2
    exit 1
  fi
  if ! grep -q '"code": "saveTargetNotModule"' "$standalone_save_err"; then
    echo "expected standalone lean-save failure to expose saveTargetNotModule" >&2
    cat "$standalone_save_err" >&2
    exit 1
  fi
  if ! grep -q 'lean-save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
    echo "expected standalone lean-save failure to explain the Lake module requirement" >&2
    cat "$standalone_save_err" >&2
    exit 1
  fi
)
