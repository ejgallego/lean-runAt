#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

broken_root="$(beam_wrapper_prepare_project_root diagnostics-broken)"
warn_root="$(beam_wrapper_prepare_project_root diagnostics-warn)"
warn_full_root="$(beam_wrapper_prepare_project_root diagnostics-warn-full)"
stale_root="$(beam_wrapper_prepare_project_root diagnostics-stale)"

(
  cd "$broken_root"

  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
  broken_sync_json="$(beam_wrapper_mktemp_file broken-sync-json)"
  broken_sync_err="$(beam_wrapper_mktemp_file broken-sync-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$broken_sync_json" 2>"$broken_sync_err"
  broken_sync="$(cat "$broken_sync_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync to succeed even when Lean reports diagnostics" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected broken lean-sync to report completed top-level fileProgress" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.errorCount)" -lt 1 ]; then
    echo "expected broken lean-sync final json to report at least one error diagnostic" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.warningCount)" != "0" ]; then
    echo "expected broken lean-sync final json to report zero warnings" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.saveReady)" != "false" ]; then
    echo "expected broken lean-sync final json to report saveReady = false" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.stateErrorCount)" -lt 1 ]; then
    echo "expected broken lean-sync final json to report stateErrorCount >= 1" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.saveReadyReason)" != "documentErrors" ]; then
    echo "expected broken lean-sync final json to report saveReadyReason = documentErrors" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if printf '%s\n' "$broken_sync" | grep -q '"diagnostics"'; then
    echo "expected broken lean-sync final json to omit replayed diagnostics" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  if ! grep -Eq '^beam: diagnostic error SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$broken_sync_err"; then
    echo "expected broken lean-sync to stream an error diagnostic on stderr" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi

  close_save_err="$(beam_wrapper_mktemp_file close-save)"
  if "$beam_script" lean-close-save SaveSmoke/B.lean >"$close_save_err" 2>&1; then
    echo "expected lean-close-save to fail on a file with Lean errors" >&2
    cat "$close_save_err" >&2
    exit 1
  fi

  close_out="$("$beam_script" lean-close SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$close_out" read_json_text_field ok)" != "true" ]; then
    echo "expected plain lean-close to succeed after a broken speculative session" >&2
    printf '%s\n' "$close_out" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "0" ]; then
    echo "expected final lean-close to leave zero open Beam daemon documents" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
)

(
  cd "$warn_root"
  "$beam_script" ensure lean > /dev/null

  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial
EOF

  warn_sync_json="$(beam_wrapper_mktemp_file warn-sync-json)"
  warn_sync_err="$(beam_wrapper_mktemp_file warn-sync-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$warn_sync_json" 2>"$warn_sync_err"
  warn_sync="$(cat "$warn_sync_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-sync to succeed" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync" read_json_text_field result.errorCount)" != "0" ]; then
    echo "expected warning-only lean-sync final json to report zero errors" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync" read_json_text_field result.warningCount)" -lt 1 ]; then
    echo "expected warning-only lean-sync final json to report at least one warning" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi
  if printf '%s\n' "$warn_sync" | grep -q '"diagnostics"'; then
    echo "expected warning-only lean-sync final json to omit replayed diagnostics" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi
  if grep -Eq '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_sync_err"; then
    echo "expected warning-only lean-sync without +full to suppress warning diagnostics" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi

  warn_save_json="$(beam_wrapper_mktemp_file warn-save-json)"
  warn_save_err="$(beam_wrapper_mktemp_file warn-save-err)"
  "$beam_script" lean-save SaveSmoke/B.lean >"$warn_save_json" 2>"$warn_save_err"
  warn_save="$(cat "$warn_save_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_save" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-save to succeed" >&2
    printf '%s\n' "$warn_save" >&2
    cat "$warn_save_err" >&2
    exit 1
  fi
  if grep -Eq '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_save_err"; then
    echo "expected warning-only lean-save without +full to suppress warning diagnostics" >&2
    printf '%s\n' "$warn_save" >&2
    cat "$warn_save_err" >&2
    exit 1
  fi
)

(
  cd "$warn_full_root"
  "$beam_script" ensure lean > /dev/null

  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial
EOF

  warn_sync_full_json="$(beam_wrapper_mktemp_file warn-sync-full-json)"
  warn_sync_full_err="$(beam_wrapper_mktemp_file warn-sync-full-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean +full >"$warn_sync_full_json" 2>"$warn_sync_full_err"
  warn_sync_full="$(cat "$warn_sync_full_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync_full" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-sync +full to succeed" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync_full" read_json_text_field result.errorCount)" != "0" ]; then
    echo "expected warning-only lean-sync +full final json to report zero errors" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync_full" read_json_text_field result.warningCount)" -lt 1 ]; then
    echo "expected warning-only lean-sync +full final json to report at least one warning" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    exit 1
  fi
  if printf '%s\n' "$warn_sync_full" | grep -q '"diagnostics"'; then
    echo "expected warning-only lean-sync +full final json to omit replayed diagnostics" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    exit 1
  fi
  warn_count="$(grep -Ec '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_sync_full_err" || true)"
  if [ "$warn_count" -eq 0 ]; then
    echo "expected warning-only lean-sync +full to stream warning diagnostics" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    exit 1
  fi

  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial

-- close-save fresh version
EOF

  warn_full_registry="$(beam_wrapper_registry_path "$warn_full_root")"
  beam_wrapper_expect_file "$warn_full_registry"
  port9="$(read_json_field "$warn_full_registry" port)"
  client9="$(read_json_field "$warn_full_registry" clientBin 2>/dev/null || true)"
  if [ -z "$client9" ]; then
    client9="$client"
  fi

  stream_req="$(printf '{"op":"sync_file","root":"%s","path":"SaveSmoke/B.lean","fullDiagnostics":true}' "$warn_full_root")"
  stream_out="$(beam_wrapper_mktemp_file stream-out)"
  stream_err="$(beam_wrapper_mktemp_file stream-err)"
  "$client9" --port "$port9" request-stream "$stream_req" >"$stream_out" 2>"$stream_err"
  if [ -s "$stream_err" ]; then
    echo "expected request-stream to keep machine-readable output on stdout only" >&2
    cat "$stream_err" >&2
    exit 1
  fi
  python3 - "$stream_out" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    rows = [json.loads(line) for line in f if line.strip()]
if not rows:
    raise SystemExit("expected request-stream output")
kinds = [row.get("kind") for row in rows]
if "diagnostic" not in kinds:
    raise SystemExit(f"expected diagnostic stream message, got {kinds}")
if kinds[-1] != "response":
    raise SystemExit(f"expected final stream message to be response, got {kinds[-1]!r}")
diag = next(row["diagnostic"] for row in rows if row.get("kind") == "diagnostic")
if diag.get("path") != "SaveSmoke/B.lean":
    raise SystemExit(f"expected diagnostic path SaveSmoke/B.lean, got {diag.get('path')!r}")
response = rows[-1]["response"]
result = response.get("result", {})
if result.get("errorCount") != 0:
    raise SystemExit(f"expected streamed sync response errorCount 0, got {result.get('errorCount')!r}")
if not isinstance(result.get("warningCount"), int) or result["warningCount"] < 1:
    raise SystemExit(f"expected streamed sync response warningCount >= 1, got {result.get('warningCount')!r}")
if result.get("saveReady") is not True:
    raise SystemExit(f"expected streamed sync response saveReady true, got {result.get('saveReady')!r}")
if result.get("stateErrorCount") != 0:
    raise SystemExit(f"expected streamed sync response stateErrorCount 0, got {result.get('stateErrorCount')!r}")
if result.get("stateCommandErrorCount") != 0:
    raise SystemExit(
        f"expected streamed sync response stateCommandErrorCount 0, got {result.get('stateCommandErrorCount')!r}"
    )
if "diagnostics" in result:
    raise SystemExit("expected streamed sync final response to omit replayed diagnostics")
PY

  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial

EOF

  warn_close_save_json="$(beam_wrapper_mktemp_file warn-close-save-json)"
  warn_close_save_err="$(beam_wrapper_mktemp_file warn-close-save-err)"
  "$beam_script" lean-close-save SaveSmoke/B.lean +full >"$warn_close_save_json" 2>"$warn_close_save_err"
  warn_close_save="$(cat "$warn_close_save_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_close_save" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-close-save +full to succeed" >&2
    printf '%s\n' "$warn_close_save" >&2
    cat "$warn_close_save_err" >&2
    exit 1
  fi
  warn_close_count="$(grep -Ec '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_close_save_err" || true)"
  if [ "$warn_close_count" -eq 0 ]; then
    echo "expected warning-only lean-close-save +full to stream warning diagnostics" >&2
    printf '%s\n' "$warn_close_save" >&2
    cat "$warn_close_save_err" >&2
    exit 1
  fi
)

(
  cd "$stale_root"
  lake build SaveSmoke/A.lean > /dev/null
  "$beam_script" ensure lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean

  stale_sync_json="$(beam_wrapper_mktemp_file stale-sync-json)"
  stale_sync_err="$(beam_wrapper_mktemp_file stale-sync-err)"
  if "$beam_script" lean-sync SaveSmoke/A.lean >"$stale_sync_json" 2>"$stale_sync_err"; then
    echo "expected lean-sync to fail when an imported target is stale and rebuild cannot complete" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    exit 1
  fi
  if ! grep -q 'Lean diagnostics barrier did not complete' "$stale_sync_err"; then
    echo "expected stale-import lean-sync failure to explain the incomplete diagnostics barrier" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    exit 1
  fi
  if ! grep -q 'lean-sync request failed before a complete diagnostics barrier was available (syncBarrierIncomplete)' "$stale_sync_err"; then
    echo "expected stale-import lean-sync failure to distinguish request failure from ordinary sync diagnostics" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_sync_json")" read_json_text_field error.code)" != "syncBarrierIncomplete" ]; then
    echo "expected stale-import lean-sync failure to expose syncBarrierIncomplete" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$stale_sync_err"; then
    echo "expected stale-import lean-sync failure to stay structured instead of reporting a dropped daemon connection" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_sync_json")" read_json_text_field error.data.recoveryPlan.1)" != "lake build" ]; then
    echo "expected stale-import lean-sync failure to include a lake build fallback plan" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    exit 1
  fi

  stale_save_err="$(beam_wrapper_mktemp_file stale-save)"
  if "$beam_script" lean-save SaveSmoke/A.lean >"$stale_save_err" 2>&1; then
    echo "expected lean-save to reject an importer whose sync barrier cannot complete" >&2
    cat "$stale_save_err" >&2
    exit 1
  fi
  if ! grep -q 'Lean diagnostics barrier did not complete' "$stale_save_err"; then
    echo "expected stale-import lean-save failure to explain the incomplete diagnostics barrier" >&2
    cat "$stale_save_err" >&2
    exit 1
  fi
  if ! grep -q '"code": "syncBarrierIncomplete"' "$stale_save_err"; then
    echo "expected stale-import lean-save failure to expose syncBarrierIncomplete" >&2
    cat "$stale_save_err" >&2
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$stale_save_err"; then
    echo "expected stale-import lean-save failure to stay structured instead of reporting a dropped daemon connection" >&2
    cat "$stale_save_err" >&2
    exit 1
  fi

  printf 'def bVal : Nat := 2\n' > SaveSmoke/B.lean
  recovered_b_sync="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$recovered_b_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync on the recovered dependency to succeed" >&2
    printf '%s\n' "$recovered_b_sync" >&2
    exit 1
  fi
  recovered_b_save="$("$beam_script" lean-save SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$recovered_b_save" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-save on the recovered dependency to succeed" >&2
    printf '%s\n' "$recovered_b_save" >&2
    exit 1
  fi

  stale_after_save_json="$(beam_wrapper_mktemp_file stale-after-save-json)"
  stale_after_save_err="$(beam_wrapper_mktemp_file stale-after-save-err)"
  if "$beam_script" lean-sync SaveSmoke/A.lean >"$stale_after_save_json" 2>"$stale_after_save_err"; then
    echo "expected lean-sync on the stale importer to keep failing until refresh" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.staleDirectDeps.0.path)" != "SaveSmoke/B.lean" ]; then
    echo "expected stale-import hint to name the direct dependency path" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.staleDirectDeps.0.needsSave)" != "false" ]; then
    echo "expected stale-import hint to mark the saved dependency as not needing save" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_array_len error.data.saveDeps)" != "0" ]; then
    echo "expected stale-import hint to avoid recommending save for an already saved dependency" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.recoveryPlan.0)" != "lean-beam refresh \"SaveSmoke/A.lean\"" ]; then
    echo "expected stale-import hint to recommend lean-refresh first after a saved dependency change" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi

  refreshed_a="$("$beam_script" lean-refresh SaveSmoke/A.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$refreshed_a" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-refresh to recover a stale target after saving the dependency" >&2
    printf '%s\n' "$refreshed_a" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$refreshed_a" read_json_text_field result.saveReady)" != "true" ]; then
    echo "expected recovered lean-refresh to report saveReady = true" >&2
    printf '%s\n' "$refreshed_a" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$refreshed_a" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected recovered lean-refresh to expose completed top-level fileProgress" >&2
    printf '%s\n' "$refreshed_a" >&2
    exit 1
  fi
)
