#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

beam_script="$PWD/scripts/lean-beam"
search_helper="$PWD/scripts/lean-beam-search"
client="$PWD/.lake/build/bin/beam-client"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi

if [ ! -x "$search_helper" ]; then
  echo "missing beam search helper at $search_helper" >&2
  exit 1
fi

if [ ! -x "$client" ]; then
  echo "missing CLI client at $client" >&2
  exit 1
fi

read_json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
value = data
for part in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

read_json_text_field() {
  python3 - "$1" <<'PY'
import json, os, sys
payload = json.loads(os.environ["RUNAT_JSON_PAYLOAD"])
path = sys.argv[1]
if path == "ok" and "ok" not in payload:
    print("false" if payload.get("error") is not None else "true")
    raise SystemExit(0)
value = payload
try:
    for part in path.split("."):
        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value[part]
except (KeyError, IndexError, ValueError, TypeError):
    print("")
    raise SystemExit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

read_json_array_len() {
  python3 - "$1" <<'PY'
import json, os, sys
payload = json.loads(os.environ["RUNAT_JSON_PAYLOAD"])
value = payload
for part in sys.argv[1].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
print(len(value))
PY
}

expect_file() {
  if [ ! -f "$1" ]; then
    echo "missing expected file: $1" >&2
    exit 1
  fi
}

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-wrapper-*|/tmp/runat-validate-*/tmp/beam-wrapper-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

expect_path_within_tmp_dir() {
  local path="$1"
  local root="$2"
  expect_owned_tmp_dir "$root"
  case "$path" in
    "$root"|"$root"/*)
      ;;
    *)
      echo "refusing to touch path outside temp root $root: $path" >&2
      exit 1
      ;;
  esac
}

remove_owned_tmp_tree() {
  local path="$1"
  expect_owned_tmp_dir "$path"
  rm -rf -- "$path"
}

remove_tmp_tree_within() {
  local path="$1"
  local root="$2"
  expect_path_within_tmp_dir "$path" "$root"
  rm -rf -- "$path"
}

wait_for_exit() {
  local pid="$1"
  local label="$2"
  local tries="${3:-40}"
  local delay="${4:-0.5}"
  local remaining="$tries"
  while [ "$remaining" -gt 0 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep "$delay"
    remaining=$((remaining - 1))
  done
  echo "timed out waiting for $label (pid $pid) to exit" >&2
  return 1
}

tmp1="$(mktemp -d /tmp/beam-wrapper-a-XXXXXX)"
tmp2="$(mktemp -d /tmp/beam-wrapper-b-XXXXXX)"
tmp3="$(mktemp -d /tmp/beam-wrapper-c-XXXXXX)"
tmp4="$(mktemp -d /tmp/beam-wrapper-d-XXXXXX)"
tmp5="$(mktemp -d /tmp/beam-wrapper-e-XXXXXX)"
tmp6="$(mktemp -d /tmp/beam-wrapper-f-XXXXXX)"
tmp7="$(mktemp -d /tmp/beam-wrapper-g-XXXXXX)"
tmp8="$(mktemp -d /tmp/beam-wrapper-h-XXXXXX)"
tmp9="$(mktemp -d /tmp/beam-wrapper-i-XXXXXX)"
tmp10="$(mktemp -d /tmp/beam-wrapper-j-XXXXXX)"
busy_pid=""

cleanup() {
  if [ -n "$busy_pid" ]; then
    kill "$busy_pid" > /dev/null 2>&1 || true
    wait "$busy_pid" 2>/dev/null || true
  fi
  "$beam_script" --root "$tmp1" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp2" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp3" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp4" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp5" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp6" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp7" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp8" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp9" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp10" shutdown > /dev/null 2>&1 || true
  remove_owned_tmp_tree "$tmp1"
  remove_owned_tmp_tree "$tmp2"
  remove_owned_tmp_tree "$tmp3"
  remove_owned_tmp_tree "$tmp4"
  remove_owned_tmp_tree "$tmp5"
  remove_owned_tmp_tree "$tmp6"
  remove_owned_tmp_tree "$tmp7"
  remove_owned_tmp_tree "$tmp8"
  remove_owned_tmp_tree "$tmp9"
  remove_owned_tmp_tree "$tmp10"
}
trap cleanup EXIT

for tmp in "$tmp1" "$tmp2" "$tmp3" "$tmp4" "$tmp5" "$tmp6" "$tmp7" "$tmp8" "$tmp9"; do
  expect_owned_tmp_dir "$tmp"
  rsync -a tests/save_olean_project/ "$tmp"/
  remove_tmp_tree_within "$tmp/.beam" "$tmp"
  mkdir -p "$tmp/.beam"
done

expect_owned_tmp_dir "$tmp10"
rsync -a tests/save_olean_project/ "$tmp10"/
mkdir -p "$tmp10/tests/scenario/docs"
cp tests/scenario/docs/CommandA.lean "$tmp10/tests/scenario/docs/CommandA.lean"
cp tests/scenario/docs/SlowPoll.lean "$tmp10/tests/scenario/docs/SlowPoll.lean"
mkdir -p "$tmp10/.beam"

(
  cd "$tmp1"
  "$beam_script" ensure lean > /dev/null
)

reg1="$tmp1/.beam/beam-daemon.json"
expect_file "$reg1"

pid1="$(read_json_field "$reg1" pid)"
port1="$(read_json_field "$reg1" port)"
root1="$(read_json_field "$reg1" root)"
client1="$(read_json_field "$reg1" clientBin 2>/dev/null || true)"
if [ -z "$client1" ]; then
  client1="$client"
fi
if [ "$root1" != "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$tmp1")" ]; then
  echo "wrapper registry root mismatch: expected $tmp1, got $root1" >&2
  exit 1
fi
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be alive" >&2
  exit 1
fi

(
  cd "$tmp1"
  "$beam_script" ensure lean > /dev/null
  cmd_err="$(mktemp /tmp/beam-wrapper-progress-XXXXXX)"
  cmd_out="$(BEAM_PROGRESS=1 "$beam_script" lean-run-at CommandA.lean 0 2 "#check answerA" 2>"$cmd_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$cmd_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-run-at to succeed" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    rm -f "$cmd_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$cmd_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper lean-run-at payload success" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    rm -f "$cmd_err"
    exit 1
  fi
  run_at_progress_done="$(RUNAT_JSON_PAYLOAD="$cmd_out" read_json_text_field fileProgress.done)"
  if [ "$run_at_progress_done" != "true" ] && [ "$run_at_progress_done" != "false" ]; then
    echo "expected wrapper lean-run-at to expose top-level fileProgress" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    rm -f "$cmd_err"
    exit 1
  fi
  if ! grep -q 'waiting for a ready Lean snapshot' "$cmd_err"; then
    echo "expected wrapper lean-run-at progress stderr output" >&2
    cat "$cmd_err" >&2
    rm -f "$cmd_err"
    exit 1
  fi
  if ! grep -q 'snapshot progress' "$cmd_err"; then
    echo "expected wrapper lean-run-at forwarded Beam daemon progress stderr output" >&2
    cat "$cmd_err" >&2
    rm -f "$cmd_err"
    exit 1
  fi
  if ! grep -q 'lean-run-at complete' "$cmd_err"; then
    echo "expected wrapper lean-run-at completion stderr output" >&2
    cat "$cmd_err" >&2
    rm -f "$cmd_err"
    exit 1
  fi
  rm -f "$cmd_err"
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
  debug_text_err="$(mktemp /tmp/beam-wrapper-debug-text-XXXXXX)"
  debug_text_out="$(printf 'def debugProbe : Nat :=\n  42' | BEAM_DEBUG_TEXT=1 "$beam_script" lean-run-at PositionEmptyLine.lean 1 0 --stdin 2>"$debug_text_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$debug_text_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper debug-text probe to succeed" >&2
    printf '%s\n' "$debug_text_out" >&2
    cat "$debug_text_err" >&2
    rm -f "$debug_text_err"
    exit 1
  fi
  if ! grep -q 'debug text for lean-run-at: source=stdin' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to report stdin as the text source" >&2
    cat "$debug_text_err" >&2
    rm -f "$debug_text_err"
    exit 1
  fi
  if ! grep -q 'containsNewline=true' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to report a real newline" >&2
    cat "$debug_text_err" >&2
    rm -f "$debug_text_err"
    exit 1
  fi
  if ! grep -q 'containsLiteralBackslashN=false' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to distinguish literal backslash-n from a real newline" >&2
    cat "$debug_text_err" >&2
    rm -f "$debug_text_err"
    exit 1
  fi
  if ! grep -q 'escaped="def debugProbe : Nat :=\\n  42"' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to print the escaped probe text" >&2
    cat "$debug_text_err" >&2
    rm -f "$debug_text_err"
    exit 1
  fi
  if ! grep -q 'utf8Hex=' "$debug_text_err" || ! grep -q '0a' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to print UTF-8 bytes including the newline byte" >&2
    cat "$debug_text_err" >&2
    rm -f "$debug_text_err"
    exit 1
  fi
  rm -f "$debug_text_err"
  literal_newline_err="$(mktemp /tmp/beam-wrapper-literal-newline-XXXXXX)"
  literal_newline_out="$("$beam_script" lean-run-at PositionEmptyLine.lean 1 0 'def _probe_tmp : Nat := 0\n' 2>"$literal_newline_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$literal_newline_out" read_json_text_field ok)" != "true" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to stay a payload failure, not a transport error" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    rm -f "$literal_newline_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$literal_newline_out" read_json_text_field result.success)" != "false" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to fail in the run-at payload" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    rm -f "$literal_newline_err"
    exit 1
  fi
  if ! grep -q "literal characters '\\\\n'" "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n probe to print a newline hint" >&2
    cat "$literal_newline_err" >&2
    rm -f "$literal_newline_err"
    exit 1
  fi
  if ! grep -q 'probe failed inside Lean; the request completed and returned result.success=false' "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n probe to distinguish a probe failure from a request failure" >&2
    cat "$literal_newline_err" >&2
    rm -f "$literal_newline_err"
    exit 1
  fi
  rm -f "$literal_newline_err"
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
  blank_err="$(mktemp /tmp/beam-wrapper-empty-line-XXXXXX)"
  if "$beam_script" lean-run-at PositionEmptyLine.lean 1 1 "#check answer" >"$blank_err" 2>&1; then
    echo "expected wrapper blank-line probe at character 1 to be rejected" >&2
    cat "$blank_err" >&2
    rm -f "$blank_err"
    exit 1
  fi
  if ! grep -q 'character 1 is beyond max character 0 for line 1' "$blank_err"; then
    echo "expected wrapper blank-line invalid position error message" >&2
    cat "$blank_err" >&2
    rm -f "$blank_err"
    exit 1
  fi
  if ! grep -q 'lean-run-at request failed before probe execution (invalidParams)' "$blank_err"; then
    echo "expected wrapper blank-line invalid position path to distinguish request failure from probe failure" >&2
    cat "$blank_err" >&2
    rm -f "$blank_err"
    exit 1
  fi
  rm -f "$blank_err"
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
  utf16_err="$(mktemp /tmp/beam-wrapper-utf16-XXXXXX)"
  if "$beam_script" lean-run-at PositionUtf16.lean 1 6 "#check Nat" >"$utf16_err" 2>&1; then
    echo "expected wrapper UTF-16 out-of-range probe to be rejected" >&2
    cat "$utf16_err" >&2
    rm -f "$utf16_err"
    exit 1
  fi
  if ! grep -q 'character 6 is beyond max character 5 for line 1' "$utf16_err"; then
    echo "expected wrapper UTF-16 invalid position error message" >&2
    cat "$utf16_err" >&2
    rm -f "$utf16_err"
    exit 1
  fi
  rm -f "$utf16_err"
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
  unsupported_err="$(mktemp /tmp/beam-wrapper-request-at-unsupported-XXXXXX)"
  if "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/completion '{}' >"$unsupported_err" 2>&1; then
    echo "expected wrapper lean-request-at to reject unsupported methods" >&2
    cat "$unsupported_err" >&2
    rm -f "$unsupported_err"
    exit 1
  fi
  if ! grep -q "does not support 'textDocument/completion'" "$unsupported_err"; then
    echo "expected unsupported request_at method error message" >&2
    cat "$unsupported_err" >&2
    rm -f "$unsupported_err"
    exit 1
  fi
  rm -f "$unsupported_err"
  params_doc_err="$(mktemp /tmp/beam-wrapper-request-at-textDocument-XXXXXX)"
  if "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/hover '{"textDocument":{"uri":"file:///tmp/nope.lean"}}' >"$params_doc_err" 2>&1; then
    echo "expected wrapper lean-request-at to reject user-supplied textDocument" >&2
    cat "$params_doc_err" >&2
    rm -f "$params_doc_err"
    exit 1
  fi
  if ! grep -q "'params' must not include 'textDocument'" "$params_doc_err"; then
    echo "expected request_at textDocument override rejection message" >&2
    cat "$params_doc_err" >&2
    rm -f "$params_doc_err"
    exit 1
  fi
  rm -f "$params_doc_err"
  params_pos_err="$(mktemp /tmp/beam-wrapper-request-at-position-XXXXXX)"
  if "$beam_script" lean-request-at CommandA.lean 0 4 textDocument/hover '{"position":{"line":99,"character":0}}' >"$params_pos_err" 2>&1; then
    echo "expected wrapper lean-request-at to reject user-supplied position" >&2
    cat "$params_pos_err" >&2
    rm -f "$params_pos_err"
    exit 1
  fi
  if ! grep -q "'params' must not include 'position'" "$params_pos_err"; then
    echo "expected request_at position override rejection message" >&2
    cat "$params_pos_err" >&2
    rm -f "$params_pos_err"
    exit 1
  fi
  rm -f "$params_pos_err"
)

pid1_repeat="$(read_json_field "$reg1" pid)"
port1_repeat="$(read_json_field "$reg1" port)"
if [ "$pid1" != "$pid1_repeat" ] || [ "$port1" != "$port1_repeat" ]; then
  echo "wrapper unexpectedly restarted the Beam daemon for the same project" >&2
  exit 1
fi

(
  cd "$tmp10"
  "$beam_script" --root "$tmp10" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp10" ensure lean > /dev/null
  interrupt_out="$(mktemp /tmp/beam-wrapper-interrupt-out-XXXXXX)"
  interrupt_err="$(mktemp /tmp/beam-wrapper-interrupt-err-XXXXXX)"
  interrupt_status="$(python3 - "$beam_script" "$tmp10" "$interrupt_out" "$interrupt_err" <<'PY'
import os
import signal
import subprocess
import sys
import time

beam_script, project_root, out_path, err_path = sys.argv[1:]
env = os.environ.copy()
env["BEAM_PROGRESS"] = "1"
env["BEAM_REQUEST_ID"] = "wrapper-sigint"

with open(out_path, "wb") as out, open(err_path, "wb") as err:
    proc = subprocess.Popen(
        [
            beam_script,
            "--root",
            project_root,
            "lean-run-at",
            "tests/scenario/docs/SlowPoll.lean",
            "25",
            "2",
            "poll_sleep_cmd",
        ],
        stdout=out,
        stderr=err,
        env=env,
    )
    time.sleep(1.0)
    proc.send_signal(signal.SIGINT)
    try:
        rc = proc.wait(timeout=15.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        print("timeout")
        raise SystemExit(2)

print(rc)
PY
)"
  if [ "$interrupt_status" = "timeout" ]; then
    cat "$interrupt_out" >&2
    cat "$interrupt_err" >&2
    rm -f "$interrupt_out" "$interrupt_err"
    exit 1
  fi
  if [ "$interrupt_status" = "0" ]; then
    echo "expected wrapper lean-run-at SIGINT path to exit non-zero after broker cancellation" >&2
    cat "$interrupt_out" >&2
    cat "$interrupt_err" >&2
    rm -f "$interrupt_out" "$interrupt_err"
    exit 1
  fi
  interrupt_json="$(cat "$interrupt_out")"
  if [ "$(RUNAT_JSON_PAYLOAD="$interrupt_json" read_json_text_field error.code)" != "requestCancelled" ]; then
    echo "expected wrapper SIGINT path to report requestCancelled" >&2
    printf '%s\n' "$interrupt_json" >&2
    cat "$interrupt_err" >&2
    rm -f "$interrupt_out" "$interrupt_err"
    exit 1
  fi
  if ! grep -q 'requesting broker cancellation' "$interrupt_err"; then
    echo "expected wrapper SIGINT path to log broker cancellation on stderr" >&2
    cat "$interrupt_err" >&2
    rm -f "$interrupt_out" "$interrupt_err"
    exit 1
  fi
  post_interrupt_hover="$("$beam_script" --root "$tmp10" lean-hover tests/scenario/docs/CommandA.lean 0 4)"
  if [ "$(RUNAT_JSON_PAYLOAD="$post_interrupt_hover" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper SIGINT cancellation to preserve the isolated Beam daemon session" >&2
    printf '%s\n' "$post_interrupt_hover" >&2
    rm -f "$interrupt_out" "$interrupt_err"
    exit 1
  fi
  rm -f "$interrupt_out" "$interrupt_err"
  "$beam_script" --root "$tmp10" shutdown > /dev/null 2>&1 || true
)

(
  cd "$tmp10"
  "$beam_script" --root "$tmp10" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp10" ensure lean > /dev/null
  duplicate_slow_out="$(mktemp /tmp/beam-wrapper-duplicate-slow-out-XXXXXX)"
  duplicate_slow_err="$(mktemp /tmp/beam-wrapper-duplicate-slow-err-XXXXXX)"
  duplicate_out="$(mktemp /tmp/beam-wrapper-duplicate-out-XXXXXX)"
  duplicate_err="$(mktemp /tmp/beam-wrapper-duplicate-err-XXXXXX)"
  BEAM_PROGRESS=1 BEAM_REQUEST_ID=wrapper-duplicate-active \
    "$beam_script" --root "$tmp10" lean-run-at tests/scenario/docs/SlowPoll.lean 25 2 "poll_sleep_cmd" \
    >"$duplicate_slow_out" 2>"$duplicate_slow_err" &
  duplicate_slow_pid=$!
  sleep 1
  if BEAM_REQUEST_ID=wrapper-duplicate-active \
      "$beam_script" --root "$tmp10" lean-hover tests/scenario/docs/CommandA.lean 0 4 \
      >"$duplicate_out" 2>"$duplicate_err"; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to fail" >&2
    cat "$duplicate_out" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  duplicate_json="$(cat "$duplicate_out")"
  if [ "$(RUNAT_JSON_PAYLOAD="$duplicate_json" read_json_text_field error.code)" != "invalidParams" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to report invalidParams" >&2
    printf '%s\n' "$duplicate_json" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$duplicate_json" read_json_text_field clientRequestId)" != "wrapper-duplicate-active" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper response to echo clientRequestId" >&2
    printf '%s\n' "$duplicate_json" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  if ! grep -q "already active" "$duplicate_out"; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to explain the conflict" >&2
    cat "$duplicate_out" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  cancel_json="$("$beam_script" --root "$tmp10" cancel wrapper-duplicate-active)"
  if [ "$(RUNAT_JSON_PAYLOAD="$cancel_json" read_json_text_field result.cancelled)" != "true" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID cancel to report cancelled=true" >&2
    printf '%s\n' "$cancel_json" >&2
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  if ! wait_for_exit "$duplicate_slow_pid" "duplicate active slow wrapper request"; then
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  if wait "$duplicate_slow_pid"; then
    echo "expected duplicate active slow wrapper request to exit non-zero after cancellation" >&2
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  duplicate_slow_json="$(cat "$duplicate_slow_out")"
  if [ "$(RUNAT_JSON_PAYLOAD="$duplicate_slow_json" read_json_text_field error.code)" != "requestCancelled" ]; then
    echo "expected cancelled duplicate active slow wrapper request to report requestCancelled" >&2
    printf '%s\n' "$duplicate_slow_json" >&2
    cat "$duplicate_slow_err" >&2
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  stats_out="$("$beam_script" --root "$tmp10" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.invalidParamsCount)" -lt 1 ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper conflict to increment invalidParamsCount" >&2
    printf '%s\n' "$stats_out" >&2
    rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
    exit 1
  fi
  rm -f "$duplicate_slow_out" "$duplicate_slow_err" "$duplicate_out" "$duplicate_err"
  "$beam_script" --root "$tmp10" shutdown > /dev/null 2>&1 || true
)

cat >"$tmp3/BrokenHeader.lean" <<'EOF'
import SaveSmoke.
EOF

(
  cd "$tmp3"
  deps_out="$("$beam_script" lean-deps SaveSmoke/A.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$deps_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper lean-deps to succeed despite unrelated broken files" >&2
    printf '%s\n' "$deps_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$deps_out" | grep -q '"name": "SaveSmoke.B"'; then
    echo "expected lean-deps imports to include SaveSmoke.B" >&2
    printf '%s\n' "$deps_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$deps_out" | grep -q '"name": "SaveSmoke"'; then
    echo "expected lean-deps importedBy to include SaveSmoke" >&2
    printf '%s\n' "$deps_out" >&2
    exit 1
  fi
  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.sessions.lean.active)" != "false" ]; then
    echo "expected lean-deps not to start a live Lean session" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  session_starts="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.sessionStarts)"
  if [ "${session_starts:-0}" -ne 0 ]; then
    echo "expected lean-deps not to start any Lean sessions" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  deps_count="$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.deps.count)"
  if [ "${deps_count:-0}" -lt 1 ]; then
    echo "expected lean-deps stats to record at least one deps request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
)

(
  cd "$tmp4"
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

  sed -i 's/1/2/' SaveSmoke/B.lean
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

  sed -i 's/2/3/' SaveSmoke/B.lean
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

  cat > HandleSmoke.lean <<'EOF'
example : True ∧ True := by
EOF

  mint_handle_stdin="$(printf 'constructor' | "$beam_script" lean-run-at-handle HandleSmoke.lean 0 27 --stdin)"
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_handle_stdin" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle mint via --stdin to succeed" >&2
    printf '%s\n' "$mint_handle_stdin" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_handle_stdin" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper handle mint via --stdin to return a lean handle" >&2
    printf '%s\n' "$mint_handle_stdin" >&2
    exit 1
  fi

  handle_mint_file="handle-mint.txt"
  printf 'constructor' > "$handle_mint_file"
  mint_handle_file="$("$beam_script" lean-run-at-handle HandleSmoke.lean 0 27 --text-file "$handle_mint_file")"
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_handle_file" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle mint via --text-file to succeed" >&2
    printf '%s\n' "$mint_handle_file" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_handle_file" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper handle mint via --text-file to return a lean handle" >&2
    printf '%s\n' "$mint_handle_file" >&2
    exit 1
  fi
  branch_handle_file="branch-handle.json"
  printf '%s\n' "$mint_handle_file" > "$branch_handle_file"

  mint_handle="$("$beam_script" lean-run-at-handle HandleSmoke.lean 0 27 "constructor")"
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_handle" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle mint to succeed" >&2
    printf '%s\n' "$mint_handle" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_handle" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper handle mint to return a lean handle" >&2
    printf '%s\n' "$mint_handle" >&2
    exit 1
  fi

  branch_step_stdin_err="$(mktemp /tmp/beam-wrapper-run-with-stdin-XXXXXX)"
  branch_step_stdin="$(printf 'exact trivial' | BEAM_DEBUG_TEXT=1 "$beam_script" lean-run-with HandleSmoke.lean "$mint_handle_stdin" --stdin 2>"$branch_step_stdin_err")"
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_step_stdin" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper non-linear handle continuation via --stdin to succeed" >&2
    printf '%s\n' "$branch_step_stdin" >&2
    cat "$branch_step_stdin_err" >&2
    rm -f "$branch_step_stdin_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_step_stdin" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper non-linear handle continuation via --stdin to return a successor handle" >&2
    printf '%s\n' "$branch_step_stdin" >&2
    cat "$branch_step_stdin_err" >&2
    rm -f "$branch_step_stdin_err"
    exit 1
  fi
  if ! grep -q 'debug text for lean-run-with: source=stdin' "$branch_step_stdin_err"; then
    echo "expected wrapper run-with debug-text mode to report stdin as the continuation text source" >&2
    cat "$branch_step_stdin_err" >&2
    rm -f "$branch_step_stdin_err"
    exit 1
  fi
  rm -f "$branch_step_stdin_err"

  branch_step_file="$(printf 'exact trivial' | "$beam_script" lean-run-with HandleSmoke.lean --handle-file "$branch_handle_file" --stdin)"
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_step_file" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper non-linear handle continuation via --handle-file to succeed" >&2
    printf '%s\n' "$branch_step_file" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_step_file" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper non-linear handle continuation via --handle-file to return a successor handle" >&2
    printf '%s\n' "$branch_step_file" >&2
    exit 1
  fi

  stdin_conflict_err="$(mktemp /tmp/beam-wrapper-run-with-stdin-conflict-XXXXXX)"
  if printf '%s\n' "$mint_handle" | "$beam_script" lean-run-with HandleSmoke.lean - --stdin >"$stdin_conflict_err" 2>&1; then
    echo "expected wrapper run-with to reject reading both handle json and text from stdin" >&2
    cat "$stdin_conflict_err" >&2
    rm -f "$stdin_conflict_err"
    exit 1
  fi
  if ! grep -q 'cannot read both handle json and continuation text from stdin' "$stdin_conflict_err"; then
    echo "expected wrapper run-with stdin conflict to explain the single-stdin limitation" >&2
    cat "$stdin_conflict_err" >&2
    rm -f "$stdin_conflict_err"
    exit 1
  fi
  rm -f "$stdin_conflict_err"

  branch_step="$(printf '%s\n' "$mint_handle" | "$beam_script" lean-run-with HandleSmoke.lean - "exact trivial")"
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_step" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper non-linear handle continuation to succeed" >&2
    printf '%s\n' "$branch_step" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_step" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper non-linear handle continuation to return a successor handle" >&2
    printf '%s\n' "$branch_step" >&2
    exit 1
  fi

  branch_done="$(printf '%s\n' "$branch_step" | "$beam_script" lean-run-with HandleSmoke.lean - "exact trivial")"
  if [ "$(RUNAT_JSON_PAYLOAD="$branch_done" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper second non-linear handle continuation to succeed" >&2
    printf '%s\n' "$branch_done" >&2
    exit 1
  fi
  if ! printf '%s\n' "$branch_done" | grep -q '"goals": \[\]'; then
    echo "expected wrapper non-linear handle chain to solve the proof" >&2
    printf '%s\n' "$branch_done" >&2
    exit 1
  fi

  mint_linear="$("$beam_script" lean-run-at-handle HandleSmoke.lean 0 27 "constructor")"
  if [ "$(RUNAT_JSON_PAYLOAD="$mint_linear" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper linear handle mint to succeed" >&2
    printf '%s\n' "$mint_linear" >&2
    exit 1
  fi

  linear_text_file="linear-continuation.txt"
  printf 'exact trivial' > "$linear_text_file"
  linear_handle_file="linear-handle.json"
  printf '%s\n' "$mint_linear" > "$linear_handle_file"
  linear_step="$("$beam_script" lean-run-with-linear HandleSmoke.lean --handle-file "$linear_handle_file" --text-file "$linear_text_file")"
  if [ "$(RUNAT_JSON_PAYLOAD="$linear_step" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper linear handle continuation via --handle-file and --text-file to succeed" >&2
    printf '%s\n' "$linear_step" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$linear_step" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper linear handle continuation via --handle-file and --text-file to return a successor handle" >&2
    printf '%s\n' "$linear_step" >&2
    exit 1
  fi

  linear_reuse_err="$(mktemp /tmp/beam-wrapper-linear-reuse-XXXXXX)"
  if printf '%s\n' "$mint_linear" | "$beam_script" lean-run-with HandleSmoke.lean - "exact trivial" >"$linear_reuse_err" 2>&1; then
    echo "expected consumed linear handle to fail when reused" >&2
    cat "$linear_reuse_err" >&2
    rm -f "$linear_reuse_err"
    exit 1
  fi
  if ! grep -q 'invalidParams' "$linear_reuse_err"; then
    echo "expected consumed linear handle reuse to report invalidParams" >&2
    cat "$linear_reuse_err" >&2
    rm -f "$linear_reuse_err"
    exit 1
  fi
  rm -f "$linear_reuse_err"

  release_handle_file="release-handle.json"
  printf '%s\n' "$linear_step" > "$release_handle_file"
  release_out="$("$beam_script" lean-release HandleSmoke.lean --handle-file "$release_handle_file")"
  if [ "$(RUNAT_JSON_PAYLOAD="$release_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle release via --handle-file to succeed" >&2
    printf '%s\n' "$release_out" >&2
    exit 1
  fi

  release_reuse_err="$(mktemp /tmp/beam-wrapper-release-reuse-XXXXXX)"
  if printf '%s\n' "$linear_step" | "$beam_script" lean-run-with HandleSmoke.lean - "exact trivial" >"$release_reuse_err" 2>&1; then
    echo "expected released handle to fail when reused" >&2
    cat "$release_reuse_err" >&2
    rm -f "$release_reuse_err"
    exit 1
  fi
  if ! grep -q 'invalidParams' "$release_reuse_err"; then
    echo "expected released handle reuse to report invalidParams" >&2
    cat "$release_reuse_err" >&2
    rm -f "$release_reuse_err"
    exit 1
  fi
  rm -f "$release_reuse_err"
  close_handle_out="$("$beam_script" lean-close HandleSmoke.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$close_handle_out" read_json_text_field ok)" != "true" ]; then
    echo "expected handle smoke file close to succeed" >&2
    printf '%s\n' "$close_handle_out" >&2
    exit 1
  fi

  portable_wrapper_bin="$tmp1/portable-wrapper-bin"
  system_readlink="$(command -v readlink)"
  mkdir -p "$portable_wrapper_bin"
  ln -sf "$beam_script" "$portable_wrapper_bin/lean-beam"
  ln -sf "$search_helper" "$portable_wrapper_bin/lean-beam-search"
  cat > "$portable_wrapper_bin/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\${1:-}" = "-f" ]; then
  echo "unexpected readlink -f in portability test" >&2
  exit 64
fi

exec "$system_readlink" "\$@"
EOF
  chmod +x "$portable_wrapper_bin/readlink"

  portable_stats_out="$(PATH="$portable_wrapper_bin:$PATH" "$portable_wrapper_bin/lean-beam" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$portable_stats_out" read_json_text_field ok)" != "true" ]; then
    echo "expected symlinked wrapper to work when readlink -f is unavailable" >&2
    printf '%s\n' "$portable_stats_out" >&2
    exit 1
  fi

  portable_helper_root="$(PATH="$portable_wrapper_bin:$PATH" "$portable_wrapper_bin/lean-beam-search" mint HandleSmoke.lean 0 27 "constructor")"
  if [ "$(RUNAT_JSON_PAYLOAD="$portable_helper_root" read_json_text_field ok)" != "true" ]; then
    echo "expected symlinked helper to work when readlink -f is unavailable" >&2
    printf '%s\n' "$portable_helper_root" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$portable_helper_root" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected symlinked helper mint to return a lean handle" >&2
    printf '%s\n' "$portable_helper_root" >&2
    exit 1
  fi

  wrapper_shadow_root="$tmp1/wrapper-shadow-root"
  mkdir -p "$wrapper_shadow_root/scripts" "$wrapper_shadow_root/.lake/build/bin" "$wrapper_shadow_root/libexec"
  cp "$beam_script" "$wrapper_shadow_root/scripts/lean-beam"
  cat > "$wrapper_shadow_root/.lake/build/bin/beam-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'checkout\n'
EOF
  cat > "$wrapper_shadow_root/libexec/beam-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'installed\n'
EOF
  chmod +x "$wrapper_shadow_root/.lake/build/bin/beam-cli" "$wrapper_shadow_root/libexec/beam-cli"

  wrapper_shadow_out="$("$wrapper_shadow_root/scripts/lean-beam" stats)"
  if [ "$wrapper_shadow_out" != "checkout" ]; then
    echo "expected checkout wrapper to prefer .lake/build over sibling libexec when BEAM_HOME is unset" >&2
    printf '%s\n' "$wrapper_shadow_out" >&2
    exit 1
  fi

  wrapper_override_out="$(BEAM_HOME="$wrapper_shadow_root" "$wrapper_shadow_root/scripts/lean-beam" stats)"
  if [ "$wrapper_override_out" != "installed" ]; then
    echo "expected explicit BEAM_HOME to prefer libexec in the overridden runtime" >&2
    printf '%s\n' "$wrapper_override_out" >&2
    exit 1
  fi

  helper_root="$("$search_helper" mint HandleSmoke.lean 0 27 "constructor")"
  if [ "$(RUNAT_JSON_PAYLOAD="$helper_root" read_json_text_field ok)" != "true" ]; then
    echo "expected helper mint to succeed" >&2
    printf '%s\n' "$helper_root" >&2
    exit 1
  fi
  helper_branch="$(printf '%s\n' "$helper_root" | "$search_helper" branch HandleSmoke.lean "exact trivial")"
  if [ "$(RUNAT_JSON_PAYLOAD="$helper_branch" read_json_text_field ok)" != "true" ]; then
    echo "expected helper branch to succeed" >&2
    printf '%s\n' "$helper_branch" >&2
    exit 1
  fi
  helper_playout="$(printf '%s\n' "$helper_branch" | "$search_helper" playout HandleSmoke.lean "exact trivial")"
  if [ "$(RUNAT_JSON_PAYLOAD="$helper_playout" read_json_text_field ok)" != "true" ]; then
    echo "expected helper playout to succeed" >&2
    printf '%s\n' "$helper_playout" >&2
    exit 1
  fi
  if ! printf '%s\n' "$helper_playout" | grep -q '"goals": \[\]'; then
    echo "expected helper playout to solve the proof" >&2
    printf '%s\n' "$helper_playout" >&2
    exit 1
  fi
  helper_release="$(printf '%s\n' "$helper_root" | "$search_helper" release HandleSmoke.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$helper_release" read_json_text_field ok)" != "true" ]; then
    echo "expected helper release to succeed" >&2
    printf '%s\n' "$helper_release" >&2
    exit 1
  fi
  helper_release_reuse_err="$(mktemp /tmp/beam-helper-release-reuse-XXXXXX)"
  if printf '%s\n' "$helper_root" | "$search_helper" branch HandleSmoke.lean "exact trivial" >"$helper_release_reuse_err" 2>&1; then
    echo "expected released helper root to fail when reused" >&2
    cat "$helper_release_reuse_err" >&2
    rm -f "$helper_release_reuse_err"
    exit 1
  fi
  if ! grep -q 'invalidParams' "$helper_release_reuse_err"; then
    echo "expected released helper root reuse to report invalidParams" >&2
    cat "$helper_release_reuse_err" >&2
    rm -f "$helper_release_reuse_err"
    exit 1
  fi
  rm -f "$helper_release_reuse_err"
  close_helper_handle_out="$("$beam_script" lean-close HandleSmoke.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$close_helper_handle_out" read_json_text_field ok)" != "true" ]; then
    echo "expected helper handle smoke file close to succeed" >&2
    printf '%s\n' "$close_helper_handle_out" >&2
    exit 1
  fi

  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
  broken_sync_json="$(mktemp /tmp/beam-wrapper-broken-sync-json-XXXXXX)"
  broken_sync_err="$(mktemp /tmp/beam-wrapper-broken-sync-err-XXXXXX)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$broken_sync_json" 2>"$broken_sync_err"
  broken_sync="$(cat "$broken_sync_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync to succeed even when Lean reports diagnostics" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field fileProgress.done)" != "true" ]; then
    echo "expected broken lean-sync to report completed top-level fileProgress" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.errorCount)" -lt 1 ]; then
    echo "expected broken lean-sync final json to report at least one error diagnostic" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.warningCount)" != "0" ]; then
    echo "expected broken lean-sync final json to report zero warnings" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.saveReady)" != "false" ]; then
    echo "expected broken lean-sync final json to report saveReady = false" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.stateErrorCount)" -lt 1 ]; then
    echo "expected broken lean-sync final json to report stateErrorCount >= 1" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$broken_sync" read_json_text_field result.saveReadyReason)" != "documentErrors" ]; then
    echo "expected broken lean-sync final json to report saveReadyReason = documentErrors" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if printf '%s\n' "$broken_sync" | grep -q '"diagnostics"'; then
    echo "expected broken lean-sync final json to omit replayed diagnostics" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  if ! grep -Eq '^beam: diagnostic error SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$broken_sync_err"; then
    echo "expected broken lean-sync to stream an error diagnostic on stderr" >&2
    printf '%s\n' "$broken_sync" >&2
    cat "$broken_sync_err" >&2
    rm -f "$broken_sync_json" "$broken_sync_err"
    exit 1
  fi
  rm -f "$broken_sync_json" "$broken_sync_err"

  close_save_err="$(mktemp /tmp/beam-wrapper-close-save-XXXXXX)"
  if "$beam_script" lean-close-save SaveSmoke/B.lean >"$close_save_err" 2>&1; then
    echo "expected lean-close-save to fail on a file with Lean errors" >&2
    cat "$close_save_err" >&2
    rm -f "$close_save_err"
    exit 1
  fi
  rm -f "$close_save_err"

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
  cd "$tmp8"
  "$beam_script" ensure lean > /dev/null
  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial
EOF

  warn_sync_json="$(mktemp /tmp/beam-wrapper-warn-sync-json-XXXXXX)"
  warn_sync_err="$(mktemp /tmp/beam-wrapper-warn-sync-err-XXXXXX)"
  "$beam_script" lean-sync SaveSmoke/B.lean >"$warn_sync_json" 2>"$warn_sync_err"
  warn_sync="$(cat "$warn_sync_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-sync to succeed" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync" read_json_text_field result.errorCount)" != "0" ]; then
    echo "expected warning-only lean-sync final json to report zero errors" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync" read_json_text_field result.warningCount)" -lt 1 ]; then
    echo "expected warning-only lean-sync final json to report at least one warning" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err"
    exit 1
  fi
  if printf '%s\n' "$warn_sync" | grep -q '"diagnostics"'; then
    echo "expected warning-only lean-sync final json to omit replayed diagnostics" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err"
    exit 1
  fi
  if grep -Eq '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_sync_err"; then
    echo "expected warning-only lean-sync without +full to suppress warning diagnostics" >&2
    printf '%s\n' "$warn_sync" >&2
    cat "$warn_sync_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err"
    exit 1
  fi
  warn_save_json="$(mktemp /tmp/beam-wrapper-warn-save-json-XXXXXX)"
  warn_save_err="$(mktemp /tmp/beam-wrapper-warn-save-err-XXXXXX)"
  "$beam_script" lean-save SaveSmoke/B.lean >"$warn_save_json" 2>"$warn_save_err"
  warn_save="$(cat "$warn_save_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_save" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-save to succeed" >&2
    printf '%s\n' "$warn_save" >&2
    cat "$warn_save_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err" "$warn_save_json" "$warn_save_err"
    exit 1
  fi
  if grep -Eq '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_save_err"; then
    echo "expected warning-only lean-save without +full to suppress warning diagnostics" >&2
    printf '%s\n' "$warn_save" >&2
    cat "$warn_save_err" >&2
    rm -f "$warn_sync_json" "$warn_sync_err" "$warn_save_json" "$warn_save_err"
    exit 1
  fi
  rm -f "$warn_save_json" "$warn_save_err"
  rm -f "$warn_sync_json" "$warn_sync_err"

)

(
  cd "$tmp9"
  "$beam_script" ensure lean > /dev/null
  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial
EOF
  warn_sync_full_json="$(mktemp /tmp/beam-wrapper-warn-sync-full-json-XXXXXX)"
  warn_sync_full_err="$(mktemp /tmp/beam-wrapper-warn-sync-full-err-XXXXXX)"
  "$beam_script" lean-sync SaveSmoke/B.lean +full >"$warn_sync_full_json" 2>"$warn_sync_full_err"
  warn_sync_full="$(cat "$warn_sync_full_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync_full" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-sync +full to succeed" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync_full" read_json_text_field result.errorCount)" != "0" ]; then
    echo "expected warning-only lean-sync +full final json to report zero errors" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_sync_full" read_json_text_field result.warningCount)" -lt 1 ]; then
    echo "expected warning-only lean-sync +full final json to report at least one warning" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err"
    exit 1
  fi
  if printf '%s\n' "$warn_sync_full" | grep -q '"diagnostics"'; then
    echo "expected warning-only lean-sync +full final json to omit replayed diagnostics" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err"
    exit 1
  fi
  warn_count="$(grep -Ec '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_sync_full_err" || true)"
  if [ "$warn_count" -eq 0 ]; then
    echo "expected warning-only lean-sync +full to stream warning diagnostics" >&2
    printf '%s\n' "$warn_sync_full" >&2
    cat "$warn_sync_full_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err"
    exit 1
  fi
  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial

-- close-save fresh version
EOF
  reg9="$PWD/.beam/beam-daemon.json"
  expect_file "$reg9"
  port9="$(read_json_field "$reg9" port)"
  client9="$(read_json_field "$reg9" clientBin 2>/dev/null || true)"
  if [ -z "$client9" ]; then
    client9="$client"
  fi
  stream_req="$(printf '{"op":"sync_file","root":"%s","path":"SaveSmoke/B.lean","fullDiagnostics":true}' "$PWD")"
  stream_out="$(mktemp /tmp/beam-wrapper-stream-out-XXXXXX)"
  stream_err="$(mktemp /tmp/beam-wrapper-stream-err-XXXXXX)"
  "$client9" --port "$port9" request-stream "$stream_req" >"$stream_out" 2>"$stream_err"
  if [ -s "$stream_err" ]; then
    echo "expected request-stream to keep machine-readable output on stdout only" >&2
    cat "$stream_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err" "$stream_out" "$stream_err"
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
  rm -f "$stream_out" "$stream_err"
  cat > SaveSmoke/B.lean <<'EOF'
def bVal : Nat := 1

set_option linter.unusedVariables true in
theorem warnOnly (n : Nat) : True := by
  trivial

EOF
  warn_close_save_json="$(mktemp /tmp/beam-wrapper-warn-close-save-json-XXXXXX)"
  warn_close_save_err="$(mktemp /tmp/beam-wrapper-warn-close-save-err-XXXXXX)"
  "$beam_script" lean-close-save SaveSmoke/B.lean +full >"$warn_close_save_json" 2>"$warn_close_save_err"
  warn_close_save="$(cat "$warn_close_save_json")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warn_close_save" read_json_text_field ok)" != "true" ]; then
    echo "expected warning-only lean-close-save +full to succeed" >&2
    printf '%s\n' "$warn_close_save" >&2
    cat "$warn_close_save_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err" "$warn_close_save_json" "$warn_close_save_err"
    exit 1
  fi
  warn_close_count="$(grep -Ec '^beam: diagnostic warning SaveSmoke/B\.lean:[0-9]+:[0-9]+: ' "$warn_close_save_err" || true)"
  if [ "$warn_close_count" -eq 0 ]; then
    echo "expected warning-only lean-close-save +full to stream warning diagnostics" >&2
    printf '%s\n' "$warn_close_save" >&2
    cat "$warn_close_save_err" >&2
    rm -f "$warn_sync_full_json" "$warn_sync_full_err" "$warn_close_save_json" "$warn_close_save_err"
    exit 1
  fi
  rm -f "$warn_close_save_json" "$warn_close_save_err"
  rm -f "$warn_sync_full_json" "$warn_sync_full_err"
)

(
  cd "$tmp2"
  "$beam_script" ensure lean > /dev/null
)

reg2="$tmp2/.beam/beam-daemon.json"
expect_file "$reg2"

pid2="$(read_json_field "$reg2" pid)"
port2="$(read_json_field "$reg2" port)"
if [ "$pid1" = "$pid2" ]; then
  echo "expected distinct Beam daemon processes per project" >&2
  exit 1
fi
if [ "$port1" = "$port2" ]; then
  echo "expected distinct Beam daemon ports per project" >&2
  exit 1
fi

cross_err="$(mktemp /tmp/beam-wrapper-cross-XXXXXX)"
cross_req="$(mktemp /tmp/beam-wrapper-cross-req-XXXXXX)"
printf '{"op":"ensure","root":"%s"}\n' "$tmp2" > "$cross_req"
if "$client1" --port "$port1" request - <"$cross_req" >"$cross_err" 2>&1; then
  echo "expected single-root Beam daemon to reject another project root" >&2
  cat "$cross_err" >&2
  rm -f "$cross_req"
  rm -f "$cross_err"
  exit 1
fi
if ! grep -q "invalidParams" "$cross_err"; then
    echo "expected cross-root Beam daemon request to fail with invalidParams" >&2
  cat "$cross_err" >&2
  rm -f "$cross_req"
  rm -f "$cross_err"
  exit 1
fi
rm -f "$cross_req"
rm -f "$cross_err"

(
  cd "$tmp5"
  "$beam_script" ensure lean > /dev/null
  warm_out="$("$beam_script" lean-run-at SaveSmoke/B.lean 0 2 "#eval bVal")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warm_out" read_json_text_field ok)" != "true" ]; then
    echo "expected tmp5 warmup probe to succeed before busy-port reuse check" >&2
    printf '%s\n' "$warm_out" >&2
    exit 1
  fi
)

reg5="$tmp5/.beam/beam-daemon.json"
expect_file "$reg5"

pid5="$(read_json_field "$reg5" pid)"
port5="$(read_json_field "$reg5" port)"
busy_port=43123
if [ "$busy_port" = "$port5" ]; then
  busy_port=43124
fi

python3 -m http.server "$busy_port" >/dev/null 2>&1 &
busy_pid=$!
sleep 1

(
  cd "$tmp5"
  doctor_out="$("$beam_script" doctor lean)"
  if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
    echo "expected doctor lean to report a live Beam daemon before requested-port reuse check" >&2
    printf '%s\n' "$doctor_out" >&2
    exit 1
  fi
  sed -i 's/1/2/' SaveSmoke/B.lean
  sync_out="$("$beam_script" --port "$busy_port" lean-sync SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field ok)" != "true" ]; then
    echo "expected lean-sync with a busy requested port to reuse the live Beam daemon" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$sync_out" read_json_text_field result.version)" != "2" ]; then
    echo "expected busy-port lean-sync reuse path to report version 2" >&2
    printf '%s\n' "$sync_out" >&2
    exit 1
  fi
  stats_out="$("$beam_script" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field ok)" != "true" ]; then
    echo "expected stats to keep working after busy-port lean-sync reuse" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
)

kill "$busy_pid" > /dev/null 2>&1 || true
wait "$busy_pid" 2>/dev/null || true
busy_pid=""

pid5_after="$(read_json_field "$reg5" pid)"
port5_after="$(read_json_field "$reg5" port)"
if [ "$pid5" != "$pid5_after" ] || [ "$port5" != "$port5_after" ]; then
  echo "expected requested-port lean-sync reuse to preserve the original registry entry" >&2
  exit 1
fi
if ! kill -0 "$pid5" 2>/dev/null; then
  echo "expected original Beam daemon pid $pid5 to remain alive after busy-port lean-sync reuse" >&2
  exit 1
fi

(
  cd "$tmp6"
  lake build SaveSmoke/A.lean > /dev/null
  "$beam_script" ensure lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean

  stale_sync_json="$(mktemp /tmp/beam-wrapper-stale-sync-json-XXXXXX)"
  stale_sync_err="$(mktemp /tmp/beam-wrapper-stale-sync-XXXXXX)"
  if "$beam_script" lean-sync SaveSmoke/A.lean >"$stale_sync_json" 2>"$stale_sync_err"; then
    echo "expected lean-sync to fail when an imported target is stale and rebuild cannot complete" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    rm -f "$stale_sync_json"
    rm -f "$stale_sync_err"
    exit 1
  fi
  if ! grep -q 'Lean diagnostics barrier did not complete' "$stale_sync_err"; then
    echo "expected stale-import lean-sync failure to explain the incomplete diagnostics barrier" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    rm -f "$stale_sync_json"
    rm -f "$stale_sync_err"
    exit 1
  fi
  if ! grep -q 'lean-sync request failed before a complete diagnostics barrier was available (syncBarrierIncomplete)' "$stale_sync_err"; then
    echo "expected stale-import lean-sync failure to distinguish request failure from ordinary sync diagnostics" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    rm -f "$stale_sync_json"
    rm -f "$stale_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_sync_json")" read_json_text_field error.code)" != "syncBarrierIncomplete" ]; then
    echo "expected stale-import lean-sync failure to expose syncBarrierIncomplete" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    rm -f "$stale_sync_json"
    rm -f "$stale_sync_err"
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$stale_sync_err"; then
    echo "expected stale-import lean-sync failure to stay structured instead of reporting a dropped daemon connection" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    rm -f "$stale_sync_json"
    rm -f "$stale_sync_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_sync_json")" read_json_text_field error.data.recoveryPlan.1)" != "lake build" ]; then
    echo "expected stale-import lean-sync failure to include a lake build fallback plan" >&2
    cat "$stale_sync_json" >&2
    cat "$stale_sync_err" >&2
    rm -f "$stale_sync_json"
    rm -f "$stale_sync_err"
    exit 1
  fi
  rm -f "$stale_sync_json"
  rm -f "$stale_sync_err"

  stale_save_err="$(mktemp /tmp/beam-wrapper-stale-save-XXXXXX)"
  if "$beam_script" lean-save SaveSmoke/A.lean >"$stale_save_err" 2>&1; then
    echo "expected lean-save to reject an importer whose sync barrier cannot complete" >&2
    cat "$stale_save_err" >&2
    rm -f "$stale_save_err"
    exit 1
  fi
  if ! grep -q 'Lean diagnostics barrier did not complete' "$stale_save_err"; then
    echo "expected stale-import lean-save failure to explain the incomplete diagnostics barrier" >&2
    cat "$stale_save_err" >&2
    rm -f "$stale_save_err"
    exit 1
  fi
  if ! grep -q '"code": "syncBarrierIncomplete"' "$stale_save_err"; then
    echo "expected stale-import lean-save failure to expose syncBarrierIncomplete" >&2
    cat "$stale_save_err" >&2
    rm -f "$stale_save_err"
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$stale_save_err"; then
    echo "expected stale-import lean-save failure to stay structured instead of reporting a dropped daemon connection" >&2
    cat "$stale_save_err" >&2
    rm -f "$stale_save_err"
    exit 1
  fi
  rm -f "$stale_save_err"

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
  stale_after_save_json="$(mktemp /tmp/beam-wrapper-stale-after-save-json-XXXXXX)"
  stale_after_save_err="$(mktemp /tmp/beam-wrapper-stale-after-save-XXXXXX)"
  if "$beam_script" lean-sync SaveSmoke/A.lean >"$stale_after_save_json" 2>"$stale_after_save_err"; then
    echo "expected lean-sync on the stale importer to keep failing until refresh" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    rm -f "$stale_after_save_json"
    rm -f "$stale_after_save_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.staleDirectDeps.0.path)" != "SaveSmoke/B.lean" ]; then
    echo "expected stale-import hint to name the direct dependency path" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    rm -f "$stale_after_save_json"
    rm -f "$stale_after_save_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.staleDirectDeps.0.needsSave)" != "false" ]; then
    echo "expected stale-import hint to mark the saved dependency as not needing save" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    rm -f "$stale_after_save_json"
    rm -f "$stale_after_save_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_array_len error.data.saveDeps)" != "0" ]; then
    echo "expected stale-import hint to avoid recommending save for an already saved dependency" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    rm -f "$stale_after_save_json"
    rm -f "$stale_after_save_err"
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$(cat "$stale_after_save_json")" read_json_text_field error.data.recoveryPlan.0)" != "lean-beam refresh \"SaveSmoke/A.lean\"" ]; then
    echo "expected stale-import hint to recommend lean-refresh first after a saved dependency change" >&2
    cat "$stale_after_save_json" >&2
    cat "$stale_after_save_err" >&2
    rm -f "$stale_after_save_json"
    rm -f "$stale_after_save_err"
    exit 1
  fi
  rm -f "$stale_after_save_json"
  rm -f "$stale_after_save_err"
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

(
  cd "$tmp7"
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

  standalone_save_err="$(mktemp /tmp/beam-wrapper-standalone-save-XXXXXX)"
  if "$beam_script" lean-save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
    echo "expected lean-save to reject a standalone file outside the Lake module graph" >&2
    cat "$standalone_save_err" >&2
    rm -f "$standalone_save_err"
    exit 1
  fi
  if ! grep -q '"code": "saveTargetNotModule"' "$standalone_save_err"; then
    echo "expected standalone lean-save failure to expose saveTargetNotModule" >&2
    cat "$standalone_save_err" >&2
    rm -f "$standalone_save_err"
    exit 1
  fi
  if ! grep -q 'lean-save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
    echo "expected standalone lean-save failure to explain the Lake module requirement" >&2
    cat "$standalone_save_err" >&2
    rm -f "$standalone_save_err"
    exit 1
  fi
  rm -f "$standalone_save_err"
)

(
  cd "$tmp1"
  "$beam_script" shutdown > /dev/null
)
if [ -f "$reg1" ]; then
  echo "expected shutdown to remove the project Beam daemon registry" >&2
  exit 1
fi
if kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be gone after shutdown" >&2
  exit 1
fi
