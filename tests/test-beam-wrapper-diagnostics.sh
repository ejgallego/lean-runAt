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
guard_msgs_io_stderr_root="$(beam_wrapper_prepare_project_root diagnostics-guard-msgs-io-stderr)"
warn_root="$(beam_wrapper_prepare_project_root diagnostics-warn)"
warn_full_root="$(beam_wrapper_prepare_project_root diagnostics-warn-full)"
stale_root="$(beam_wrapper_prepare_project_root diagnostics-stale)"
renamed_stale_root="$(beam_wrapper_prepare_project_root diagnostics-renamed-stale)"

fail_json() {
  local message="$1"
  local json_payload="$2"
  local err_file="${3:-}"
  echo "$message" >&2
  printf '%s\n' "$json_payload" >&2
  if [ -n "$err_file" ]; then
    cat "$err_file" >&2
  fi
  exit 1
}

expect_json_field_absent() {
  local json_payload="$1"
  local field="$2"
  local label="$3"
  local err_file="${4:-}"
  if BEAM_JSON_PAYLOAD="$json_payload" json_text_has_field "$field"; then
    fail_json "expected $label to omit $field" "$json_payload" "$err_file"
  fi
}

expect_json_field_present() {
  local json_payload="$1"
  local field="$2"
  local label="$3"
  local err_file="${4:-}"
  if ! BEAM_JSON_PAYLOAD="$json_payload" json_text_has_field "$field"; then
    fail_json "expected $label to include $field" "$json_payload" "$err_file"
  fi
}

expect_json_text_eq() {
  local json_payload="$1"
  local field="$2"
  local expected="$3"
  local label="$4"
  local err_file="${5:-}"
  local actual
  actual="$(BEAM_JSON_PAYLOAD="$json_payload" read_json_text_field "$field")"
  if [ "$actual" != "$expected" ]; then
    fail_json "expected $label $field = $expected, got $actual" "$json_payload" "$err_file"
  fi
}

expect_json_int_at_least() {
  local json_payload="$1"
  local field="$2"
  local minimum="$3"
  local label="$4"
  local err_file="${5:-}"
  local actual
  actual="$(BEAM_JSON_PAYLOAD="$json_payload" read_json_text_field "$field")"
  if [ "$actual" -lt "$minimum" ]; then
    fail_json "expected $label $field >= $minimum, got $actual" "$json_payload" "$err_file"
  fi
}

expect_no_top_level_readiness_fields() {
  local json_payload="$1"
  local prefix="$2"
  local label="$3"
  local err_file="${4:-}"
  expect_json_field_absent "$json_payload" "$prefix.errorCount" "$label sync verdict" "$err_file"
  expect_json_field_absent "$json_payload" "$prefix.warningCount" "$label sync verdict" "$err_file"
  expect_json_field_absent "$json_payload" "$prefix.saveReady" "$label sync verdict" "$err_file"
  expect_json_field_absent "$json_payload" "$prefix.saveReadyReason" "$label sync verdict" "$err_file"
}

expect_sync_result_shape() {
  local json_payload="$1"
  local prefix="$2"
  local label="$3"
  local err_file="${4:-}"
  expect_json_text_eq "$json_payload" "$prefix.path" "SaveSmoke/B.lean" "$label sync path" "$err_file"
  expect_json_field_present "$json_payload" "$prefix.diagnostics.counts" "$label diagnostic counts" "$err_file"
  expect_json_field_present "$json_payload" "$prefix.readiness" "$label readiness" "$err_file"
}

(
  cd "$broken_root"

  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
  broken_sync_json="$(beam_wrapper_mktemp_file broken-sync-json)"
  broken_sync_err="$(beam_wrapper_mktemp_file broken-sync-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$broken_sync_json" 2>"$broken_sync_err"
  broken_sync="$(cat "$broken_sync_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$broken_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync to succeed even when Lean reports diagnostics" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi
  assert_json_completed_file_progress "broken lean-sync" "$broken_sync" fileProgress "$broken_sync_err"
  expect_sync_result_shape "$broken_sync" result "broken lean-sync" "$broken_sync_err"
  expect_no_top_level_readiness_fields "$broken_sync" result "broken lean-sync" "$broken_sync_err"
  expect_json_text_eq "$broken_sync" result.diagnostics.counts.warning 0 \
    "broken lean-sync diagnostic counts" "$broken_sync_err"
  expect_json_text_eq "$broken_sync" result.readiness.saveReady false \
    "broken lean-sync readiness" "$broken_sync_err"
  expect_json_int_at_least "$broken_sync" result.readiness.blockingErrorCount 1 \
    "broken lean-sync readiness" "$broken_sync_err"
  expect_json_text_eq "$broken_sync" result.readiness.reason documentErrors \
    "broken lean-sync readiness" "$broken_sync_err"
  expect_json_field_absent "$broken_sync" result.diagnostics.items "broken lean-sync final json" "$broken_sync_err"
  if ! grep -Eq '^beam: diagnostic error SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$broken_sync_err"; then
    echo "expected broken lean-sync to stream an error diagnostic on stderr" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    exit 1
  fi

  broken_resync_json="$(beam_wrapper_mktemp_file broken-resync-json)"
  broken_resync_err="$(beam_wrapper_mktemp_file broken-resync-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$broken_resync_json" 2>"$broken_resync_err"
  broken_resync="$(cat "$broken_resync_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$broken_resync" read_json_text_field ok)" != "true" ]; then
    echo "expected unchanged broken lean-sync to succeed even when Lean reports diagnostics" >&2
    printf '%s\n' "$broken_resync" >&2
    cat "$broken_resync_err" >&2
    exit 1
  fi
  expect_no_top_level_readiness_fields "$broken_resync" result "unchanged broken lean-sync" "$broken_resync_err"
  expect_json_int_at_least "$broken_resync" result.readiness.blockingErrorCount 1 \
    "unchanged broken lean-sync readiness" "$broken_resync_err"

  close_save_json="$(beam_wrapper_mktemp_file close-save-json)"
  close_save_err="$(beam_wrapper_mktemp_file close-save-err)"
  if "$beam_script" lean-close-save SaveSmoke/B.lean >"$close_save_json" 2>"$close_save_err"; then
    echo "expected lean-close-save to fail on a file with Lean errors" >&2
    cat "$close_save_json" >&2
    cat "$close_save_err" >&2
    exit 1
  fi
  close_save_failed="$(cat "$close_save_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$close_save_failed" read_json_text_field error.data.sync.readiness.saveReady)" != "false" ]; then
    echo "expected failed lean-close-save to include blocking sync verdict" >&2
    cat "$close_save_json" >&2
    cat "$close_save_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$close_save_failed" read_json_text_field error.data.sync.readiness.blockingErrorCount)" -lt 1 ]; then
    echo "expected failed lean-close-save sync verdict to report save-blocking errors" >&2
    cat "$close_save_json" >&2
    cat "$close_save_err" >&2
    exit 1
  fi
  expect_json_text_eq "$close_save_failed" error.data.sync.path SaveSmoke/B.lean \
    "failed lean-close-save sync path" "$close_save_err"
  close_out="$("$beam_script" lean-close SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$close_out" read_json_text_field ok)" != "true" ]; then
    echo "expected plain lean-close to succeed after a broken speculative session" >&2
    printf '%s\n' "$close_out" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.openDocCount)" != "0" ]; then
    echo "expected final lean-close to leave zero open Beam daemon documents" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
)

(
  cd "$guard_msgs_io_stderr_root"

  cat > SaveSmoke/B.lean <<'EOF'
/--
info: stderr from IO.eprintln
---
info: true
-/
#guard_msgs in
#eval do
  IO.eprintln "stderr from IO.eprintln"
  pure true
EOF

  guard_sync_json="$(beam_wrapper_mktemp_file guard-msgs-io-stderr-sync-json)"
  guard_sync_err="$(beam_wrapper_mktemp_file guard-msgs-io-stderr-sync-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean +all-diagnostics >"$guard_sync_json" 2>"$guard_sync_err"
  guard_sync="$(cat "$guard_sync_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$guard_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected IO.eprintln guard_msgs lean-sync to succeed" >&2
    printf '%s\n' "$guard_sync" >&2
    cat "$guard_sync_err" >&2
    exit 1
  fi
  assert_json_completed_file_progress "IO.eprintln guard_msgs lean-sync" "$guard_sync" fileProgress \
    "$guard_sync_err"
  expect_sync_result_shape "$guard_sync" result "IO.eprintln guard_msgs lean-sync" \
    "$guard_sync_err"
  expect_json_text_eq "$guard_sync" result.readiness.saveReady true \
    "IO.eprintln guard_msgs lean-sync readiness" "$guard_sync_err"
  expect_json_text_eq "$guard_sync" result.readiness.blockingErrorCount 0 \
    "IO.eprintln guard_msgs lean-sync readiness" "$guard_sync_err"
  expect_json_text_eq "$guard_sync" result.diagnostics.counts.total 0 \
    "IO.eprintln guard_msgs lean-sync diagnostic counts" "$guard_sync_err"
  if grep -Fq "Docstring on \`#guard_msgs\` does not match generated message" "$guard_sync_err"; then
    echo "expected IO.eprintln guard_msgs sync to accept stderr output as a generated message" >&2
    printf '%s\n' "$guard_sync" >&2
    cat "$guard_sync_err" >&2
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
  if [ "$(BEAM_JSON_PAYLOAD="$warn_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-sync to succeed" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi
  assert_json_completed_file_progress "warning-only lean-sync" "$warn_sync" fileProgress \
    "$warn_sync_err"
  expect_no_top_level_readiness_fields "$warn_sync" result "warning-only lean-sync" "$warn_sync_err"
  expect_json_int_at_least "$warn_sync" result.diagnostics.counts.warning 1 \
    "warning-only lean-sync diagnostic counts" "$warn_sync_err"
  expect_json_field_absent "$warn_sync" result.diagnostics.items "warning-only lean-sync final json" "$warn_sync_err"
  if grep -Eq '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_sync_err"; then
    echo "expected warning-only lean-sync without +all-diagnostics to suppress warning diagnostics" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    exit 1
  fi

  warn_save_json="$(beam_wrapper_mktemp_file warn-save-json)"
  warn_save_err="$(beam_wrapper_mktemp_file warn-save-err)"
  "$beam_script" lean-save SaveSmoke/B.lean >"$warn_save_json" 2>"$warn_save_err"
  warn_save="$(cat "$warn_save_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$warn_save" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-save to succeed" >&2
    printf '%s\n' "$warn_save" >&2
    cat "$warn_save_err" >&2
    exit 1
  fi
  assert_json_completed_file_progress "warning-only lean-save" "$warn_save" fileProgress \
    "$warn_save_err"
  expect_no_top_level_readiness_fields "$warn_save" result.sync "warning-only lean-save" "$warn_save_err"
  expect_json_int_at_least "$warn_save" result.sync.diagnostics.counts.warning 1 \
    "warning-only lean-save diagnostic counts" "$warn_save_err"
  expect_sync_result_shape "$warn_save" result.sync "warning-only lean-save" "$warn_save_err"
  expect_json_text_eq "$warn_save" result.sync.readiness.saveReady true \
    "warning-only lean-save readiness" "$warn_save_err"
  if grep -Eq '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_save_err"; then
    echo "expected warning-only lean-save without +all-diagnostics to suppress warning diagnostics" >&2
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
  "$beam_script" lean-sync SaveSmoke/B.lean +all-diagnostics >"$warn_sync_full_json" 2>"$warn_sync_full_err"
  warn_sync_full="$(cat "$warn_sync_full_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$warn_sync_full" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-sync +all-diagnostics to succeed" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    exit 1
  fi
  assert_json_completed_file_progress "warning-only lean-sync +all-diagnostics" "$warn_sync_full" \
    fileProgress "$warn_sync_full_err"
  expect_no_top_level_readiness_fields "$warn_sync_full" result "warning-only lean-sync +all-diagnostics" "$warn_sync_full_err"
  expect_json_int_at_least "$warn_sync_full" result.diagnostics.counts.warning 1 \
    "warning-only lean-sync +all-diagnostics diagnostic counts" "$warn_sync_full_err"
  expect_json_field_absent "$warn_sync_full" result.diagnostics.items \
    "warning-only lean-sync +all-diagnostics final json" "$warn_sync_full_err"
  warn_count="$(grep -Ec '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_sync_full_err" || true)"
  if [ "$warn_count" -eq 0 ]; then
    echo "expected warning-only lean-sync +all-diagnostics to stream warning diagnostics" >&2
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

  stream_req="$(printf '{"op":"sync_file","workspaceId":"beam-cli-project","root":"%s","path":"SaveSmoke/B.lean","diagnosticScope":"all"}' "$warn_full_root")"
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
diag = next(row["payload"] for row in rows if row.get("kind") == "diagnostic")
if diag.get("path") != "SaveSmoke/B.lean":
    raise SystemExit(f"expected diagnostic path SaveSmoke/B.lean, got {diag.get('path')!r}")
response = rows[-1]["payload"]
result = response.get("result", {})
if "errorCount" in result:
    raise SystemExit(f"expected streamed sync response to omit top-level errorCount, got {result.get('errorCount')!r}")
if "warningCount" in result:
    raise SystemExit(f"expected streamed sync response to omit top-level warningCount, got {result.get('warningCount')!r}")
if "saveReady" in result:
    raise SystemExit(f"expected streamed sync response to omit top-level saveReady, got {result.get('saveReady')!r}")
readiness = result.get("readiness", {})
if readiness.get("saveReady") is not True:
    raise SystemExit(
        f"expected streamed sync response readiness saveReady true, got {readiness.get('saveReady')!r}"
    )
if readiness.get("blockingErrorCount") != 0:
    raise SystemExit(
        "expected streamed sync response readiness blockingErrorCount 0, "
        f"got {readiness.get('blockingErrorCount')!r}"
    )
counts = result.get("diagnostics", {}).get("counts", {})
if not isinstance(counts.get("warning"), int) or counts["warning"] < 1:
    raise SystemExit(
        f"expected streamed sync diagnostic warning count >= 1, got {counts.get('warning')!r}"
    )
if "items" in result.get("diagnostics", {}):
    raise SystemExit("expected streamed sync final response to omit replayed diagnostic items")
PY

  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial

EOF

  warn_close_save_json="$(beam_wrapper_mktemp_file warn-close-save-json)"
  warn_close_save_err="$(beam_wrapper_mktemp_file warn-close-save-err)"
  "$beam_script" lean-close-save SaveSmoke/B.lean +all-diagnostics >"$warn_close_save_json" 2>"$warn_close_save_err"
  warn_close_save="$(cat "$warn_close_save_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$warn_close_save" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-close-save +all-diagnostics to succeed" >&2
    printf '%s\n' "$warn_close_save" >&2
    cat "$warn_close_save_err" >&2
    exit 1
  fi
  assert_json_completed_file_progress "warning-only lean-close-save +all-diagnostics" "$warn_close_save" \
    fileProgress "$warn_close_save_err"
  expect_no_top_level_readiness_fields "$warn_close_save" result.saved.sync \
    "warning-only lean-close-save" "$warn_close_save_err"
  expect_json_int_at_least "$warn_close_save" \
    result.saved.sync.diagnostics.counts.warning 1 \
    "warning-only lean-close-save diagnostic counts" "$warn_close_save_err"
  expect_sync_result_shape "$warn_close_save" result.saved.sync \
    "warning-only lean-close-save" "$warn_close_save_err"
  expect_json_text_eq "$warn_close_save" result.saved.sync.readiness.saveReady true \
    "warning-only lean-close-save readiness" "$warn_close_save_err"
  warn_close_count="$(grep -Ec '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_close_save_err" || true)"
  if [ "$warn_close_count" -eq 0 ]; then
    echo "expected warning-only lean-close-save +all-diagnostics to stream warning diagnostics" >&2
    printf '%s\n' "$warn_close_save" >&2
    cat "$warn_close_save_err" >&2
    exit 1
  fi
)


(
  cd "$renamed_stale_root"

  cat > SaveSmoke/B.lean <<'EOF'
def old : Nat := 1
EOF
  cat > SaveSmoke/A.lean <<'EOF'
import SaveSmoke.B

def aVal : Nat := old
EOF

  lake build SaveSmoke/A.lean > /dev/null

  renamed_initial_dep_sync_json="$(beam_wrapper_mktemp_file renamed-initial-dep-sync-json)"
  renamed_initial_dep_sync_err="$(beam_wrapper_mktemp_file renamed-initial-dep-sync-err)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$renamed_initial_dep_sync_json" 2>"$renamed_initial_dep_sync_err"
  renamed_initial_dep_sync="$(cat "$renamed_initial_dep_sync_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_initial_dep_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected initial renamed dependency lean-sync to succeed" >&2
    cat "$renamed_initial_dep_sync_json" >&2
    cat "$renamed_initial_dep_sync_err" >&2
    exit 1
  fi

  renamed_initial_sync_json="$(beam_wrapper_mktemp_file renamed-initial-sync-json)"
  renamed_initial_sync_err="$(beam_wrapper_mktemp_file renamed-initial-sync-err)"
  "$beam_script" lean-sync SaveSmoke/A.lean >"$renamed_initial_sync_json" 2>"$renamed_initial_sync_err"
  renamed_initial_sync="$(cat "$renamed_initial_sync_json")"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_initial_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected initial renamed-importer lean-sync to succeed" >&2
    cat "$renamed_initial_sync_json" >&2
    cat "$renamed_initial_sync_err" >&2
    exit 1
  fi

  cat > SaveSmoke/B.lean <<'EOF'
def old : Nat := 2
EOF

  renamed_presave_dep_sync="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_presave_dep_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected pre-save stale dependency lean-sync to succeed" >&2
    printf '%s\n' "$renamed_presave_dep_sync" >&2
    exit 1
  fi

  renamed_presave_stale_json="$(beam_wrapper_mktemp_file renamed-presave-stale-json)"
  renamed_presave_stale_err="$(beam_wrapper_mktemp_file renamed-presave-stale-err)"
  if "$beam_script" lean-sync SaveSmoke/A.lean >"$renamed_presave_stale_json" 2>"$renamed_presave_stale_err"; then
    echo "expected importer lean-sync to fail after unsaved dependency change" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.code)" != "syncBarrierIncomplete" ]; then
    echo "expected pre-save stale failure to expose syncBarrierIncomplete" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.data.staleDirectDeps.0.path)" != "SaveSmoke/B.lean" ]; then
    echo "expected pre-save stale hint to name the direct dependency path" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.data.staleDirectDeps.0.needsSave)" != "true" ]; then
    echo "expected pre-save stale hint to mark the dependency as needing save" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.data.saveDeps.0)" != "SaveSmoke/B.lean" ]; then
    echo "expected pre-save stale hint to recommend saving the dependency" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.data.recoveryPlan.0)" != "lean-beam save \"SaveSmoke/B.lean\"" ]; then
    echo "expected pre-save stale recovery to save the dependency first" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.data.recoveryPlan.1)" != "lean-beam refresh \"SaveSmoke/A.lean\"" ]; then
    echo "expected pre-save stale recovery to refresh the importer after save" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_presave_stale_json")" read_json_text_field error.data.recoveryPlan.2)" != "lake build" ]; then
    echo "expected pre-save stale recovery to keep a lake build fallback" >&2
    cat "$renamed_presave_stale_json" >&2
    cat "$renamed_presave_stale_err" >&2
    exit 1
  fi

  renamed_presave_dep_save="$("$beam_script" lean-save SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_presave_dep_save" read_json_text_field ok)" != "true" ]; then
    echo "expected pre-save stale dependency lean-save to succeed" >&2
    printf '%s\n' "$renamed_presave_dep_save" >&2
    exit 1
  fi
  renamed_presave_refreshed_a="$("$beam_script" lean-refresh SaveSmoke/A.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_presave_refreshed_a" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-refresh to recover the importer after saving the pre-save dependency" >&2
    printf '%s\n' "$renamed_presave_refreshed_a" >&2
    exit 1
  fi

  cat > SaveSmoke/B.lean <<'EOF'
def new : Nat := 2
EOF
  cat > SaveSmoke/A.lean <<'EOF'
import SaveSmoke.B

def aVal : Nat := new
EOF

  renamed_dep_sync="$("$beam_script" lean-sync SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_dep_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected renamed dependency lean-sync to succeed" >&2
    printf '%s\n' "$renamed_dep_sync" >&2
    exit 1
  fi
  renamed_dep_save="$("$beam_script" lean-save SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_dep_save" read_json_text_field ok)" != "true" ]; then
    echo "expected renamed dependency lean-save to succeed" >&2
    printf '%s\n' "$renamed_dep_save" >&2
    exit 1
  fi
  lake build SaveSmoke/A.lean > /dev/null

  renamed_stale_json="$(beam_wrapper_mktemp_file renamed-stale-json)"
  renamed_stale_err="$(beam_wrapper_mktemp_file renamed-stale-err)"
  if "$beam_script" lean-sync SaveSmoke/A.lean >"$renamed_stale_json" 2>"$renamed_stale_err"; then
    echo "expected renamed importer lean-sync to fail until refresh" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_stale_json")" read_json_text_field error.code)" != "syncBarrierIncomplete" ]; then
    echo "expected renamed importer stale failure to expose syncBarrierIncomplete" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_stale_json")" read_json_text_field error.data.completionBlockingDiagnostics.0.message)" != 'Imports are out of date and should be rebuilt; use the "Restart File" command in your editor.' ]; then
    echo "expected renamed importer stale failure to carry Lean's stale-dependency diagnostic" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_stale_json")" read_json_text_field error.data.staleDirectDeps.0.path)" != "SaveSmoke/B.lean" ]; then
    echo "expected renamed importer stale hint to name the direct dependency path" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_stale_json")" read_json_text_field error.data.staleDirectDeps.0.needsSave)" != "false" ]; then
    echo "expected renamed importer stale hint to mark the dependency as already saved" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_stale_json")" read_json_array_len error.data.saveDeps)" != "0" ]; then
    echo "expected renamed importer stale hint not to recommend saving an already saved dependency" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$renamed_stale_json")" read_json_text_field error.data.recoveryPlan.0)" != "lean-beam refresh \"SaveSmoke/A.lean\"" ]; then
    echo "expected renamed importer stale hint to recommend lean-refresh first" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi
  if grep -F -q "Unknown identifier \`new\`" "$renamed_stale_err"; then
    echo "expected renamed importer stale failure not to report stale unknown-name diagnostics" >&2
    cat "$renamed_stale_json" >&2
    cat "$renamed_stale_err" >&2
    exit 1
  fi

  renamed_refreshed_a="$("$beam_script" lean-refresh SaveSmoke/A.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_refreshed_a" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-refresh to recover the renamed stale importer" >&2
    printf '%s\n' "$renamed_refreshed_a" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$renamed_refreshed_a" read_json_text_field result.readiness.saveReady)" != "true" ]; then
    echo "expected recovered renamed lean-refresh to report saveReady = true" >&2
    printf '%s\n' "$renamed_refreshed_a" >&2
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
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$stale_sync_json")" read_json_text_field error.code)" != "syncBarrierIncomplete" ]; then
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
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$stale_sync_json")" read_json_text_field error.data.recoveryPlan.1)" != "lake build" ]; then
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
  if [ "$(BEAM_JSON_PAYLOAD="$recovered_b_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync on the recovered dependency to succeed" >&2
    printf '%s\n' "$recovered_b_sync" >&2
    exit 1
  fi
  recovered_b_save="$("$beam_script" lean-save SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$recovered_b_save" read_json_text_field ok)" != "true" ]; then
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
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.staleDirectDeps.0.path)" != "SaveSmoke/B.lean" ]; then
    echo "expected stale-import hint to name the direct dependency path" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.staleDirectDeps.0.needsSave)" != "false" ]; then
    echo "expected stale-import hint to mark the saved dependency as not needing save" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_array_len error.data.saveDeps)" != "0" ]; then
    echo "expected stale-import hint to avoid recommending save for an already saved dependency" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.recoveryPlan.0)" != "lean-beam refresh \"SaveSmoke/A.lean\"" ]; then
    echo "expected stale-import hint to recommend lean-refresh first after a saved dependency change" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    exit 1
  fi

  refreshed_a="$("$beam_script" lean-refresh SaveSmoke/A.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$refreshed_a" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-refresh to recover a stale target after saving the dependency" >&2
    printf '%s\n' "$refreshed_a" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$refreshed_a" read_json_text_field result.readiness.saveReady)" != "true" ]; then
    echo "expected recovered lean-refresh to report saveReady = true" >&2
    printf '%s\n' "$refreshed_a" >&2
    exit 1
  fi
  assert_json_completed_file_progress "recovered lean-refresh" "$refreshed_a" fileProgress
)
