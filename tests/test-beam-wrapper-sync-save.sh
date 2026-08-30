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
beam_wrapper_start_owner "$lifecycle_root"
beam_wrapper_start_owner "$standalone_root"

(
  cd "$lifecycle_root"
  "$beam_script" stats > /dev/null

  stats_out="$("$beam_script" stats)"
  if [ "$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "0" ]; then
    echo "expected a newly served Lean session to start with zero open documents" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  probe_before_version="$(beam_wrapper_update_version "initial SaveSmoke/B.lean" "$beam_script" lean-update SaveSmoke/B.lean)"
  probe_before="$("$beam_script" lean-run-at SaveSmoke/B.lean "$probe_before_version" 0 2 "#eval bVal")"
  if [ "$(BEAM_JSON_PAYLOAD="$probe_before" read_json_text_field ok)" != "true" ]; then
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
  if [ "$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "1" ]; then
    echo "expected initial wrapper sync/probe to open exactly one Beam daemon document" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  open_files_initial="$("$beam_script" open-files)"
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_initial" read_json_text_field ok)" != "true" ]; then
    echo "expected open-files after initial probe to succeed" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_initial" read_json_text_field result.sessions.lean.files.0.diskStatus)" != "matchesTracked" ]; then
    echo "expected open-files after initial probe to report SaveSmoke/B.lean as matching tracked text" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_initial" read_json_text_field result.sessions.lean.files.0.checkpointed)" != "false" ]; then
    echo "expected open-files after initial probe to report checkpointed = false" >&2
    printf '%s\n' "$open_files_initial" >&2
    exit 1
  fi
  sed_in_place_portable 's/1/2/' SaveSmoke/B.lean
  sync_out="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$sync_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync after first edit to succeed" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$sync_out" read_json_text_field result.version)" != "2" ]; then
    echo "expected lean-sync after first edit to report version 2" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  assert_json_completed_file_progress "lean-sync after first edit" "$sync_out" fileProgress
  if [ "$(BEAM_JSON_PAYLOAD="$sync_out" read_json_text_field result.readiness.saveReady)" != "true" ]; then
    echo "expected lean-sync after first edit to report saveReady = true" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$sync_out" read_json_text_field result.readiness.blockingErrorCount)" != "0" ]; then
    echo "expected lean-sync after first edit to report readiness blockingErrorCount = 0" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  open_files_synced="$("$beam_script" open-files)"
  assert_json_completed_file_progress "open-files after lean-sync" "$open_files_synced" \
    result.sessions.lean.files.0.fileProgress
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_synced" read_json_text_field result.sessions.lean.files.0.checkpointed)" != "false" ]; then
    echo "expected open-files after lean-sync to keep checkpointed = false before lean-save" >&2
    printf '%s\n' "$open_files_synced" >&2
    exit 1
  fi

  probe_after_version="$(json_text_field "$sync_out" result.version)"
  probe_after="$("$beam_script" lean-run-at SaveSmoke/B.lean "$probe_after_version" 0 2 "#eval bVal")"
  if [ "$(BEAM_JSON_PAYLOAD="$probe_after" read_json_text_field ok)" != "true" ]; then
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
  if [ "$(BEAM_JSON_PAYLOAD="$save_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-save to succeed after a synced good edit" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  assert_json_completed_file_progress "lean-save after synced edit" "$save_out" fileProgress
  if [ "$(BEAM_JSON_PAYLOAD="$save_out" read_json_text_field result.version)" != "2" ]; then
    echo "expected lean-save to report saved version 2" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$save_out" read_json_text_field result.sync.version)" != "2" ]; then
    echo "expected lean-save to include a sync verdict for version 2" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$save_out" read_json_text_field result.sync.readiness.saveReady)" != "true" ]; then
    echo "expected lean-save sync verdict to report saveReady = true" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi
  if [ -z "$(BEAM_JSON_PAYLOAD="$save_out" read_json_text_field result.sourceHash)" ]; then
    echo "expected lean-save to report a non-empty sourceHash" >&2
    printf '%s\n' "$save_out" >&2
    exit 1
  fi

  open_files_saved="$("$beam_script" open-files)"
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_saved" read_json_text_field result.sessions.lean.files.0.checkpointed)" != "true" ]; then
    echo "expected open-files after lean-save to report checkpointed = true" >&2
    printf '%s\n' "$open_files_saved" >&2
    exit 1
  fi

  sed_in_place_portable 's/2/3/' SaveSmoke/B.lean
  open_files_dirty="$("$beam_script" open-files)"
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_dirty" read_json_text_field result.sessions.lean.files.0.diskStatus)" != "differsFromTracked" ]; then
    echo "expected open-files to detect an on-disk edit for an already known file incrementally" >&2
    printf '%s\n' "$open_files_dirty" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_dirty" read_json_text_field result.sessions.lean.files.0.checkpointed)" != "false" ]; then
    echo "expected open-files to clear checkpointed once the on-disk file diverges" >&2
    printf '%s\n' "$open_files_dirty" >&2
    exit 1
  fi

  sync_second="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$sync_second" read_json_text_field ok)" != "true" ]; then
    echo "expected second lean-sync to succeed" >&2
    printf '%s\n' "$sync_second" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$sync_second" read_json_text_field result.version)" != "3" ]; then
    echo "expected second lean-sync to report version 3" >&2
    printf '%s\n' "$sync_second" >&2
    exit 1
  fi
  assert_json_completed_file_progress "second lean-sync" "$sync_second" fileProgress

  open_files_second="$("$beam_script" open-files)"
  if [ "$(BEAM_JSON_PAYLOAD="$open_files_second" read_json_text_field result.sessions.lean.files.0.diskStatus)" != "matchesTracked" ]; then
    echo "expected open-files after second lean-sync to report the disk and tracked text as matching again" >&2
    printf '%s\n' "$open_files_second" >&2
    exit 1
  fi
  assert_json_completed_file_progress "open-files after second lean-sync" "$open_files_second" \
    result.sessions.lean.files.0.fileProgress

  sync_third="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$sync_third" read_json_text_field ok)" != "true" ]; then
    echo "expected unchanged third lean-sync to succeed" >&2
    printf '%s\n' "$sync_third" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$sync_third" read_json_text_field result.version)" != "3" ]; then
    echo "expected unchanged third lean-sync to preserve version 3" >&2
    printf '%s\n' "$sync_third" >&2
    exit 1
  fi
  assert_json_completed_file_progress "unchanged third lean-sync" "$sync_third" fileProgress

  refresh_out="$("$beam_script" lean-refresh SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$refresh_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-refresh to succeed for a tracked Lean file" >&2
    printf '%s\n' "$refresh_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$refresh_out" read_json_text_field result.readiness.saveReady)" != "true" ]; then
    echo "expected lean-refresh to report saveReady = true for an unchanged file" >&2
    printf '%s\n' "$refresh_out" >&2
    exit 1
  fi
  assert_json_completed_file_progress "lean-refresh" "$refresh_out" fileProgress

  sleep 1
  doctor_out="$("$beam_script" doctor lean)"
  if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
    echo "expected doctor lean to report a live Beam daemon after lean-sync and a short idle wait" >&2
    printf '%s\n' "$doctor_out" >&2
    exit 1
  fi

  probe_second_version="$(json_text_field "$refresh_out" result.version)"
  probe_second="$("$beam_script" lean-run-at SaveSmoke/B.lean "$probe_second_version" 0 2 "#eval bVal")"
  if [ "$(BEAM_JSON_PAYLOAD="$probe_second" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper probe after lean-refresh to succeed" >&2
    printf '%s\n' "$probe_second" >&2
    exit 1
  fi
  if ! printf '%s\n' "$probe_second" | grep -q '"text": "3"'; then
    echo "expected wrapper probe after lean-refresh to observe bVal = 3" >&2
    printf '%s\n' "$probe_second" >&2
    exit 1
  fi

  close_good_out="$("$beam_script" lean-close SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$close_good_out" read_json_text_field ok)" != "true" ]; then
    echo "expected plain lean-close to succeed after a synced good edit" >&2
    printf '%s\n' "$close_good_out" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "0" ]; then
    echo "expected lean-close to leave zero open Beam daemon documents" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  probe_reopen_version="$(beam_wrapper_update_version "reopened SaveSmoke/B.lean" "$beam_script" lean-update SaveSmoke/B.lean)"
  probe_reopen="$("$beam_script" lean-run-at SaveSmoke/B.lean "$probe_reopen_version" 0 2 "#eval bVal")"
  if [ "$(BEAM_JSON_PAYLOAD="$probe_reopen" read_json_text_field ok)" != "true" ]; then
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
  "$beam_script" stats > /dev/null

  cat > StandaloneSaveSmoke.lean <<'EOF'
import SaveSmoke.B

#check bVal
EOF

  standalone_sync="$("$beam_script" lean-sync StandaloneSaveSmoke.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$standalone_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync to succeed on a standalone file the daemon can open" >&2
    printf '%s\n' "$standalone_sync" >&2
    exit 1
  fi
  assert_json_completed_file_progress "standalone lean-sync" "$standalone_sync" fileProgress

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
  if ! grep -q 'lean-beam save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
    echo "expected standalone lean-save failure to explain the Lake module requirement" >&2
    cat "$standalone_save_err" >&2
    exit 1
  fi
)
