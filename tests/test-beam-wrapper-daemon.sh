#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_script="$PWD/scripts/lean-beam"
beam_cli="$PWD/.lake/build/bin/beam-cli"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi
if [ ! -x "$beam_cli" ]; then
  echo "missing beam-cli at $beam_cli" >&2
  exit 1
fi

tmp1="$(mktemp -d /tmp/beam-wrapper-daemon-owner-a-XXXXXX)"
tmp2="$(mktemp -d /tmp/beam-wrapper-daemon-owner-b-XXXXXX)"
owned_bundle_dir=""
if [ -z "${BEAM_INSTALL_BUNDLE_DIR:-}" ]; then
  owned_bundle_dir="$(mktemp -d /tmp/beam-wrapper-daemon-owner-bundles-XXXXXX)"
  export BEAM_INSTALL_BUNDLE_DIR="$owned_bundle_dir"
fi
hold_pid=""
root_removed="false"
active_request_pid=""

start_slow_request() {
  local root="$1"
  local label="$2"
  local request_id="$3"
  local version
  version="$(beam_wrapper_update_version "$label SlowPoll" \
    "$beam_script" --root "$root" lean-update tests/scenario/docs/SlowPoll.lean)"
  BEAM_PROGRESS=1 BEAM_REQUEST_ID="$request_id" "$beam_script" --root "$root" \
    lean-run-at tests/scenario/docs/SlowPoll.lean "$version" 25 2 poll_sleep_cmd \
    >"$root/$label.out" 2>"$root/$label.err" &
  active_request_pid="$!"
  if ! wait_for_file_text "$root/$label.err" "running lean-run-at" \
      "$label request progress" 150 0.1; then
    cat "$root/$label.out" >&2
    cat "$root/$label.err" >&2
    exit 1
  fi
  if ! kill -0 "$active_request_pid" 2>/dev/null; then
    echo "expected $label request to remain active before session close" >&2
    cat "$root/$label.out" >&2
    cat "$root/$label.err" >&2
    exit 1
  fi
}

expect_slow_request_cancelled() {
  local root="$1"
  local label="$2"
  local request_id="$3"
  local status=0
  set +e
  wait "$active_request_pid"
  status="$?"
  set -e
  active_request_pid=""
  if [ "$status" -eq 0 ]; then
    echo "expected $label request to exit non-zero after session close" >&2
    cat "$root/$label.out" >&2
    exit 1
  fi
  assert_json_file_field_equals "$label cancellation code" "$root/$label.out" \
    error.code requestCancelled "$root/$label.err"
  assert_json_file_field_equals "$label request id" "$root/$label.out" \
    clientRequestId "$request_id" "$root/$label.err"
}

stop_hold_process() {
  local require_clean_exit="${1:-false}"
  if [ -z "$hold_pid" ]; then
    return
  fi
  kill -INT "$hold_pid" > /dev/null 2>&1 || true
  if ! wait_for_exit "$hold_pid" "ensure --hold owner" 200 0.05; then
    kill "$hold_pid" > /dev/null 2>&1 || true
    wait "$hold_pid" 2>/dev/null || true
    hold_pid=""
    if [ "$require_clean_exit" = "true" ]; then
      echo "expected ensure --hold owner to exit promptly after SIGINT" >&2
      return 1
    fi
    return
  fi
  local status=0
  set +e
  wait "$hold_pid"
  status="$?"
  set -e
  hold_pid=""
  if [ "$require_clean_exit" = "true" ] && [ "$status" -ne 0 ]; then
    echo "expected ensure --hold owner to exit cleanly, got $status" >&2
    return 1
  fi
}

cleanup() {
  if [ -n "$active_request_pid" ]; then
    kill "$active_request_pid" > /dev/null 2>&1 || true
    wait "$active_request_pid" 2>/dev/null || true
    active_request_pid=""
  fi
  stop_hold_process
  if [ "$root_removed" != "true" ]; then
    "$beam_script" --root "$tmp1" shutdown > /dev/null 2>&1 || true
    remove_owned_tmp_tree "$tmp1"
  fi
  "$beam_script" --root "$tmp2" shutdown > /dev/null 2>&1 || true
  remove_owned_tmp_tree "$tmp2"
  if [ -n "$owned_bundle_dir" ]; then
    remove_owned_tmp_tree "$owned_bundle_dir"
  fi
}
trap cleanup EXIT

if [ -n "$owned_bundle_dir" ]; then
  expect_owned_tmp_dir "$owned_bundle_dir"
fi
for tmp in "$tmp1" "$tmp2"; do
  expect_owned_tmp_dir "$tmp"
  rsync -a --exclude='.beam/' tests/save_olean_project/ "$tmp"/
  remove_tmp_tree_within "$tmp/.beam" "$tmp"
  mkdir -p "$tmp/.beam"
  mkdir -p "$tmp/tests/scenario/docs"
  cp tests/scenario/docs/SlowPoll.lean "$tmp/tests/scenario/docs/SlowPoll.lean"
done

fixture_toolchain="$(awk 'NR==1 {print $1}' tests/save_olean_project/lean-toolchain)"
"$beam_cli" bundle-install "$fixture_toolchain"

invalid_backend_out="$tmp1/invalid-backend.out"
invalid_backend_err="$tmp1/invalid-backend.err"
if "$beam_script" --root "$tmp1" ensure typo --hold > "$invalid_backend_out" 2> "$invalid_backend_err"; then
  echo "expected an unknown owner backend to be rejected" >&2
  cat "$invalid_backend_out" >&2
  exit 1
fi
if ! grep -Fq "expected backend 'lean' or 'rocq'" "$invalid_backend_err"; then
  echo "expected unknown-backend diagnostics to list the valid backend names" >&2
  cat "$invalid_backend_err" >&2
  exit 1
fi

missing_owner_out="$tmp1/missing-owner.out"
missing_owner_err="$tmp1/missing-owner.err"
if "$beam_script" --root "$tmp1" ensure > "$missing_owner_out" 2> "$missing_owner_err"; then
  echo "expected an ordinary wrapper command to require a session owner" >&2
  cat "$missing_owner_out" >&2
  exit 1
fi
if ! grep -Fq "lean-beam ensure --hold" "$missing_owner_err"; then
  echo "expected missing-owner error to name the recovery command" >&2
  cat "$missing_owner_err" >&2
  exit 1
fi

start_owner() {
  local root="$1"
  local label="$2"
  local out="$root/$label.out"
  local err="$root/$label.err"
  "$beam_script" --root "$root" ensure --hold > "$out" 2> "$err" &
  hold_pid="$!"
  local registry="$root/.beam/beam-daemon.json"
  local attempts="${BEAM_TEST_HOLD_READY_ATTEMPTS:-1800}"
  case "$attempts" in
    ''|*[!0-9]*|0)
      echo "BEAM_TEST_HOLD_READY_ATTEMPTS must be a positive integer" >&2
      exit 1
      ;;
  esac
  for _ in $(seq 1 "$attempts"); do
    if [ -s "$out" ] && [ -f "$registry" ]; then
      break
    fi
    if ! kill -0 "$hold_pid" 2>/dev/null; then
      echo "session owner exited before becoming ready" >&2
      cat "$err" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [ ! -s "$out" ] || [ ! -f "$registry" ]; then
    echo "expected ensure --hold to publish its response and registry" >&2
    cat "$err" >&2
    exit 1
  fi
  assert_json_field_equals "ensure --hold response" "$(cat "$out")" ok true "$err"
}

registry="$tmp1/.beam/beam-daemon.json"
start_owner "$tmp1" "owner-1"
owner1_pid="$hold_pid"
daemon1_pid="$(read_json_field "$registry" pid)"
daemon1_id="$(read_json_field "$registry" daemonId)"
recorded_owner_pid="$(read_json_field "$registry" ownerPid)"
owner_domain="$(read_json_field "$registry" ownerPidDomain)"
case "$recorded_owner_pid" in
  ''|*[!0-9]*|0)
    echo "expected registry to record a positive session-owner PID" >&2
    cat "$registry" >&2
    exit 1
    ;;
esac
if [ -z "$owner_domain" ]; then
  echo "expected registry to record the session owner's PID domain" >&2
  cat "$registry" >&2
  exit 1
fi
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "expected both the wrapper owner and daemon to remain alive" >&2
  exit 1
fi

ensure_json="$("$beam_script" --root "$tmp1" ensure)"
assert_json_field_equals "owned ensure response" "$ensure_json" ok true
stats_json="$("$beam_script" --root "$tmp1" stats)"
assert_json_field_equals "owned stats response" "$stats_json" ok true

start_slow_request "$tmp1" "shutdown-active" "shutdown-active"

second_owner_out="$tmp1/second-owner.out"
second_owner_err="$tmp1/second-owner.err"
if "$beam_script" --root "$tmp1" ensure --hold > "$second_owner_out" 2> "$second_owner_err"; then
  echo "expected a second foreground owner to be rejected" >&2
  cat "$second_owner_out" >&2
  exit 1
fi
if ! grep -Fq "already owned" "$second_owner_err"; then
  echo "expected duplicate-owner failure to identify the active owner" >&2
  cat "$second_owner_err" >&2
  exit 1
fi

port1="$(read_json_field "$registry" port)"
collision_out="$tmp2/collision.out"
collision_err="$tmp2/collision.err"
if "$beam_script" --root "$tmp2" --port "$port1" ensure --hold > "$collision_out" 2> "$collision_err"; then
  echo "expected an owner not to claim another project's endpoint" >&2
  cat "$collision_out" >&2
  exit 1
fi
if ! grep -Fq "already serves Beam root" "$collision_err"; then
  echo "expected endpoint collision to identify the served project root" >&2
  cat "$collision_err" >&2
  exit 1
fi
if [ -e "$tmp2/.beam/beam-daemon.json" ]; then
  echo "expected endpoint collision not to publish a registry" >&2
  cat "$tmp2/.beam/beam-daemon.json" >&2
  exit 1
fi

shutdown_json="$("$beam_script" --root "$tmp1" shutdown)"
assert_json_field_equals "explicit session shutdown" "$shutdown_json" ok true
expect_slow_request_cancelled "$tmp1" "shutdown-active" "shutdown-active"
if ! wait_for_exit "$hold_pid" "owner after explicit shutdown" 200 0.05; then
  cat "$tmp1/owner-1.err" >&2
  exit 1
fi
set +e
wait "$hold_pid"
owner_status="$?"
set -e
hold_pid=""
if [ "$owner_status" -ne 0 ]; then
  echo "expected owner to exit cleanly after explicit shutdown, got $owner_status" >&2
  cat "$tmp1/owner-1.err" >&2
  exit 1
fi
if ! wait_for_exit "$daemon1_pid" "daemon after explicit session shutdown" 200 0.05; then
  exit 1
fi
if [ -e "$registry" ]; then
  echo "expected owner shutdown to remove its registry" >&2
  cat "$registry" >&2
  exit 1
fi

start_owner "$tmp1" "owner-2"
daemon2_pid="$(read_json_field "$registry" pid)"
daemon2_id="$(read_json_field "$registry" daemonId)"
if [ "$daemon2_id" = "$daemon1_id" ]; then
  echo "expected a new owner to publish a new daemon generation" >&2
  exit 1
fi

kill -KILL "$daemon2_pid"
if ! wait_for_exit "$hold_pid" "owner after unexpected daemon crash" 200 0.05; then
  cat "$tmp1/owner-2.err" >&2
  exit 1
fi
set +e
wait "$hold_pid"
crashed_owner_status="$?"
set -e
hold_pid=""
if [ "$crashed_owner_status" -eq 0 ]; then
  echo "expected the owner to report an unexpected daemon crash" >&2
  exit 1
fi
if ! grep -Fq "owned Beam daemon exited with status" "$tmp1/owner-2.err"; then
  echo "expected the owner crash report to include the daemon exit status" >&2
  cat "$tmp1/owner-2.err" >&2
  exit 1
fi
if [ -e "$registry" ]; then
  echo "expected a crashed daemon's owner to remove its exact registry generation" >&2
  cat "$registry" >&2
  exit 1
fi

start_owner "$tmp1" "owner-3"
daemon3_pid="$(read_json_field "$registry" pid)"
start_slow_request "$tmp1" "owner-loss-active" "owner-loss-active"
kill -KILL "$hold_pid"
set +e
wait "$hold_pid"
set -e
hold_pid=""
if ! wait_for_exit "$daemon3_pid" "daemon after owner death" 200 0.05; then
  echo "expected owner-pipe EOF to stop the daemon" >&2
  exit 1
fi
expect_slow_request_cancelled "$tmp1" "owner-loss-active" "owner-loss-active"
owner_loss_out="$tmp1/owner-loss.out"
owner_loss_err="$tmp1/owner-loss.err"
if "$beam_script" --root "$tmp1" ensure > "$owner_loss_out" 2> "$owner_loss_err"; then
  echo "expected a command after owner loss to require a replacement owner" >&2
  cat "$owner_loss_out" >&2
  exit 1
fi
if ! grep -Fq "lean-beam ensure --hold" "$owner_loss_err"; then
  echo "expected owner-loss recovery to name ensure --hold" >&2
  cat "$owner_loss_err" >&2
  exit 1
fi
if [ -e "$registry" ]; then
  echo "expected owner-loss recovery to remove the stale registry" >&2
  cat "$registry" >&2
  exit 1
fi

generation_registry="$tmp2/.beam/beam-daemon.json"
start_owner "$tmp2" "owner-generation"
generation_daemon_pid="$(read_json_field "$generation_registry" pid)"
generation_id="$(read_json_field "$generation_registry" daemonId)"
replacement_generation_id="$generation_id-replacement"
python3 - "$generation_registry" "$replacement_generation_id" <<'PY'
import json
import os
import sys

path, replacement_id = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    entry = json.load(stream)
entry["daemonId"] = replacement_id
replacement = path + ".replacement"
with open(replacement, "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
os.replace(replacement, path)
PY
if ! wait_for_exit "$hold_pid" "owner after generation replacement" 200 0.05; then
  cat "$tmp2/owner-generation.err" >&2
  exit 1
fi
wait "$hold_pid"
hold_pid=""
if ! wait_for_exit "$generation_daemon_pid" "daemon after generation replacement" 200 0.05; then
  exit 1
fi
if [ "$(read_json_field "$generation_registry" daemonId)" != "$replacement_generation_id" ]; then
  echo "expected old-owner cleanup to preserve the replacement registry generation" >&2
  cat "$generation_registry" >&2
  exit 1
fi
rm -f -- "$generation_registry"

start_owner "$tmp1" "owner-4"
daemon4_pid="$(read_json_field "$registry" pid)"
remove_owned_tmp_tree "$tmp1"
root_removed="true"
if ! wait_for_exit "$daemon4_pid" "daemon whose project root disappeared" 200 0.05; then
  echo "expected root disappearance to stop the owned daemon" >&2
  exit 1
fi
if ! wait_for_exit "$hold_pid" "owner whose project root disappeared" 200 0.05; then
  echo "expected root disappearance to release the foreground owner" >&2
  exit 1
fi
set +e
wait "$hold_pid"
root_owner_status="$?"
set -e
hold_pid=""
if [ "$root_owner_status" -ne 0 ]; then
  echo "expected root-disappearance owner to exit cleanly, got $root_owner_status" >&2
  exit 1
fi
