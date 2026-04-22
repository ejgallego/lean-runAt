#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

project_root="$(beam_wrapper_prepare_project_root probe)"
deps_root="$(beam_wrapper_prepare_project_root probe-deps)"

(
  cd "$project_root"
  "$beam_script" ensure lean > /dev/null
)

registry_path="$(beam_wrapper_registry_path "$project_root")"
beam_wrapper_expect_file "$registry_path"

pid1="$(read_json_field "$registry_path" pid)"
port1="$(read_json_field "$registry_path" port)"
root1="$(read_json_field "$registry_path" root)"
client1="$(read_json_field "$registry_path" clientBin 2>/dev/null || true)"
if [ -z "$client1" ]; then
  client1="$client"
fi
if [ "$root1" != "$(beam_wrapper_realpath "$project_root")" ]; then
  echo "wrapper registry root mismatch: expected $project_root, got $root1" >&2
  exit 1
fi
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be alive" >&2
  exit 1
fi

(
  cd "$project_root"
  "$beam_script" ensure lean > /dev/null

  cmd_err="$(beam_wrapper_mktemp_file progress)"
  cmd_out="$(BEAM_PROGRESS=1 "$beam_script" lean-run-at CommandA.lean 0 2 "#check answerA" 2>"$cmd_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$cmd_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-run-at to succeed" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$cmd_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper lean-run-at payload success" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  run_at_progress_done="$(RUNAT_JSON_PAYLOAD="$cmd_out" read_json_text_field fileProgress.done)"
  if [ "$run_at_progress_done" != "true" ] && [ "$run_at_progress_done" != "false" ]; then
    echo "expected wrapper lean-run-at to expose top-level fileProgress" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if ! grep -q 'waiting for a ready Lean snapshot' "$cmd_err"; then
    echo "expected wrapper lean-run-at progress stderr output" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if ! grep -q 'snapshot progress' "$cmd_err"; then
    echo "expected wrapper lean-run-at forwarded Beam daemon progress stderr output" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if ! grep -q 'lean-run-at complete' "$cmd_err"; then
    echo "expected wrapper lean-run-at completion stderr output" >&2
    cat "$cmd_err" >&2
    exit 1
  fi

  multiline_stdin_out="$(printf 'def stdinProbe : Nat :=\n  42' | "$beam_script" lean-run-at PositionEmptyLine.lean 1 0 --stdin)"
  if [ "$(RUNAT_JSON_PAYLOAD="$multiline_stdin_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-run-at --stdin probe to succeed" >&2
    printf '%s\n' "$multiline_stdin_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$multiline_stdin_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper lean-run-at --stdin payload success" >&2
    printf '%s\n' "$multiline_stdin_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$multiline_stdin_out" read_json_array_len result.messages)" != "0" ]; then
    echo "expected wrapper lean-run-at --stdin multiline declaration to produce no messages" >&2
    printf '%s\n' "$multiline_stdin_out" >&2
    exit 1
  fi

  probe_text_file="multiline-probe.lean"
  printf 'def fileProbe : Nat :=\n  42' > "$probe_text_file"
  multiline_file_out="$("$beam_script" lean-run-at PositionEmptyLine.lean 1 0 --text-file "$probe_text_file")"
  if [ "$(RUNAT_JSON_PAYLOAD="$multiline_file_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-run-at --text-file probe to succeed" >&2
    printf '%s\n' "$multiline_file_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$multiline_file_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper lean-run-at --text-file payload success" >&2
    printf '%s\n' "$multiline_file_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$multiline_file_out" read_json_array_len result.messages)" != "0" ]; then
    echo "expected wrapper lean-run-at --text-file multiline declaration to produce no messages" >&2
    printf '%s\n' "$multiline_file_out" >&2
    exit 1
  fi

  delimiter_out="$("$beam_script" lean-run-at PositionEmptyLine.lean 1 0 -- $'--stdin\n#check answer')"
  if [ "$(RUNAT_JSON_PAYLOAD="$delimiter_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-run-at -- delimiter path to treat leading --stdin as text" >&2
    printf '%s\n' "$delimiter_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$delimiter_out" | grep -q 'answer : Nat'; then
    echo "expected wrapper lean-run-at -- delimiter path to keep the leading --stdin text as a comment" >&2
    printf '%s\n' "$delimiter_out" >&2
    exit 1
  fi

  debug_text_err="$(beam_wrapper_mktemp_file debug-text)"
  debug_text_out="$(printf 'def debugProbe : Nat :=\n  42' | BEAM_DEBUG_TEXT=1 "$beam_script" lean-run-at PositionEmptyLine.lean 1 0 --stdin 2>"$debug_text_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$debug_text_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper debug-text probe to succeed" >&2
    printf '%s\n' "$debug_text_out" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'debug text for lean-run-at: source=stdin' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to report stdin as the text source" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'containsNewline=true' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to report a real newline" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'containsLiteralBackslashN=false' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to distinguish literal backslash-n from a real newline" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'escaped="def debugProbe : Nat :=\\n  42"' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to print the escaped probe text" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'utf8Hex=' "$debug_text_err" || ! grep -q '0a' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to print UTF-8 bytes including the newline byte" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi

  literal_newline_err="$(beam_wrapper_mktemp_file literal-newline)"
  literal_newline_out="$("$beam_script" lean-run-at PositionEmptyLine.lean 1 0 'def _probe_tmp : Nat := 0\n' 2>"$literal_newline_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$literal_newline_out" read_json_text_field ok)" != "true" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to stay a payload failure, not a transport error" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$literal_newline_out" read_json_text_field result.success)" != "false" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to fail in the run-at payload" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if ! grep -q "literal characters '\\\\n'" "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n probe to print a newline hint" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if ! grep -q 'probe failed inside Lean; the request completed and returned result.success=false' "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n probe to distinguish a probe failure from a request failure" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi

  blank_ok_out="$("$beam_script" lean-run-at PositionEmptyLine.lean 1 0 "#check answer")"
  if [ "$(RUNAT_JSON_PAYLOAD="$blank_ok_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper blank-line probe at character 0 to succeed" >&2
    printf '%s\n' "$blank_ok_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$blank_ok_out" | grep -q 'answer : Nat'; then
    echo "expected wrapper blank-line probe at character 0 to expose answer type information" >&2
    printf '%s\n' "$blank_ok_out" >&2
    exit 1
  fi

  blank_err="$(beam_wrapper_mktemp_file empty-line)"
  if "$beam_script" lean-run-at PositionEmptyLine.lean 1 1 "#check answer" >"$blank_err" 2>&1; then
    echo "expected wrapper blank-line probe at character 1 to be rejected" >&2
    cat "$blank_err" >&2
    exit 1
  fi
  if ! grep -q 'character 1 is beyond max character 0 for line 1' "$blank_err"; then
    echo "expected wrapper blank-line invalid position error message" >&2
    cat "$blank_err" >&2
    exit 1
  fi
  if ! grep -q 'lean-run-at request failed before probe execution (invalidParams)' "$blank_err"; then
    echo "expected wrapper blank-line invalid position path to distinguish request failure from probe failure" >&2
    cat "$blank_err" >&2
    exit 1
  fi

  utf16_ok_out="$("$beam_script" lean-run-at PositionUtf16.lean 1 5 "#check Nat")"
  if [ "$(RUNAT_JSON_PAYLOAD="$utf16_ok_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper UTF-16 boundary probe to succeed" >&2
    printf '%s\n' "$utf16_ok_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$utf16_ok_out" | grep -q 'Nat : Type'; then
    echo "expected wrapper UTF-16 boundary probe to expose Nat type information" >&2
    printf '%s\n' "$utf16_ok_out" >&2
    exit 1
  fi

  utf16_err="$(beam_wrapper_mktemp_file utf16)"
  if "$beam_script" lean-run-at PositionUtf16.lean 1 6 "#check Nat" >"$utf16_err" 2>&1; then
    echo "expected wrapper UTF-16 out-of-range probe to be rejected" >&2
    cat "$utf16_err" >&2
    exit 1
  fi
  if ! grep -q 'character 6 is beyond max character 5 for line 1' "$utf16_err"; then
    echo "expected wrapper UTF-16 invalid position error message" >&2
    cat "$utf16_err" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper stats to succeed" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  run_at_count="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.run_at.count)"
  if [ "${run_at_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one run_at request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  hover_out="$("$beam_script" lean-hover CommandA.lean 0 4)"
  if [ "$(RUNAT_JSON_PAYLOAD="$hover_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-hover probe to succeed" >&2
    printf '%s\n' "$hover_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$hover_out" | grep -q 'answerA : Nat'; then
    echo "expected wrapper lean-hover probe to expose answerA type information" >&2
    printf '%s\n' "$hover_out" >&2
    exit 1
  fi

  goals_prev_out="$("$beam_script" lean-goals-prev GoalSmoke.lean 1 2)"
  if [ "$(RUNAT_JSON_PAYLOAD="$goals_prev_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-goals-prev probe to succeed" >&2
    printf '%s\n' "$goals_prev_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$goals_prev_out" read_json_text_field result.goals.0.target)" != "True" ]; then
    echo "expected wrapper lean-goals-prev probe to expose the open True goal" >&2
    printf '%s\n' "$goals_prev_out" >&2
    exit 1
  fi

  goals_after_out="$("$beam_script" lean-goals-after GoalSmoke.lean 1 2)"
  if [ "$(RUNAT_JSON_PAYLOAD="$goals_after_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-goals-after probe to succeed" >&2
    printf '%s\n' "$goals_after_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$goals_after_out" read_json_array_len result.goals)" != "0" ]; then
    echo "expected wrapper lean-goals-after probe to expose no remaining goals" >&2
    printf '%s\n' "$goals_after_out" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  request_at_count="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.request_at.count)"
  if [ "${request_at_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one request_at-backed hover request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  goals_count="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.goals.count)"
  if [ "${goals_count:-0}" -lt 2 ]; then
    echo "expected wrapper stats to record at least two goals requests" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  references_out="$(printf '%s\n' '{"context":{"includeDeclaration":true}}' | "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/references -)"
  if [ "$(RUNAT_JSON_PAYLOAD="$references_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-request-at references probe from stdin json to succeed" >&2
    printf '%s\n' "$references_out" >&2
    exit 1
  fi

  unsupported_err="$(beam_wrapper_mktemp_file request-at-unsupported)"
  if "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/completion '{}' >"$unsupported_err" 2>&1; then
    echo "expected wrapper lean-request-at to reject unsupported methods" >&2
    cat "$unsupported_err" >&2
    exit 1
  fi
  if ! grep -q "does not support 'textDocument/completion'" "$unsupported_err"; then
    echo "expected unsupported request_at method error message" >&2
    cat "$unsupported_err" >&2
    exit 1
  fi

  params_doc_err="$(beam_wrapper_mktemp_file request-at-textDocument)"
  if "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/hover '{"textDocument":{"uri":"file:///tmp/nope.lean"}}' >"$params_doc_err" 2>&1; then
    echo "expected wrapper lean-request-at to reject user-supplied textDocument" >&2
    cat "$params_doc_err" >&2
    exit 1
  fi
  if ! grep -q "'params' must not include 'textDocument'" "$params_doc_err"; then
    echo "expected request_at textDocument override rejection message" >&2
    cat "$params_doc_err" >&2
    exit 1
  fi

  params_pos_err="$(beam_wrapper_mktemp_file request-at-position)"
  if "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/hover '{"position":{"line":99,"character":0}}' >"$params_pos_err" 2>&1; then
    echo "expected wrapper lean-request-at to reject user-supplied position" >&2
    cat "$params_pos_err" >&2
    exit 1
  fi
  if ! grep -q "'params' must not include 'position'" "$params_pos_err"; then
    echo "expected request_at position override rejection message" >&2
    cat "$params_pos_err" >&2
    exit 1
  fi
)

pid1_repeat="$(read_json_field "$registry_path" pid)"
port1_repeat="$(read_json_field "$registry_path" port)"
if [ "$pid1" != "$pid1_repeat" ] || [ "$port1" != "$port1_repeat" ]; then
  echo "wrapper unexpectedly restarted the Beam daemon for the same project" >&2
  exit 1
fi

cat >"$deps_root/BrokenHeader.lean" <<'EOF'
import SaveSmoke.
EOF

(
  cd "$deps_root"
  deps_out="$("$beam_script" lean-deps SaveSmoke/A.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$deps_out" read_json_text_field ok)" != "true" ]; then
    echo "expected hidden lean-deps compatibility alias to succeed despite unrelated broken files" >&2
    printf '%s\n' "$deps_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$deps_out" | grep -q '"name": "SaveSmoke.B"'; then
    echo "expected hidden lean-deps compatibility alias imports to include SaveSmoke.B" >&2
    printf '%s\n' "$deps_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$deps_out" | grep -q '"name": "SaveSmoke"'; then
    echo "expected hidden lean-deps compatibility alias importedBy to include SaveSmoke" >&2
    printf '%s\n' "$deps_out" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.active)" != "false" ]; then
    echo "expected hidden lean-deps compatibility alias not to start a live Lean session" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  session_starts="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.sessionStarts)"
  if [ "${session_starts:-0}" -ne 0 ]; then
    echo "expected hidden lean-deps compatibility alias not to start any Lean sessions" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  deps_count="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.deps.count)"
  if [ "${deps_count:-0}" -lt 1 ]; then
    echo "expected hidden lean-deps compatibility alias stats to record at least one deps request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
)
