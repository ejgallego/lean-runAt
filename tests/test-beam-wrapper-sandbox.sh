#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

platform_system="$(uname -s)"
if [ "$platform_system" != "Linux" ]; then
  echo "skipping sandbox wrapper regression on unsupported platform: $platform_system" >&2
  exit 0
fi

beam_script="$PWD/scripts/lean-beam"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi

if ! command -v bwrap >/dev/null 2>&1; then
  echo "missing bwrap; cannot run sandbox wrapper regression" >&2
  exit 1
fi

if ! bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    -- /bin/sh -c 'exit 0' >/dev/null 2>&1; then
  echo "skipping sandbox wrapper regression because pid-isolated bwrap is unavailable on this runner" >&2
  exit 0
fi

read_json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
value = data
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

tmp_root="$(mktemp -d /tmp/beam-wrapper-sandbox-XXXXXX)"
project_root="$tmp_root/project"
control_root="$tmp_root/control"
hold_out="$tmp_root/hold.out"
hold_err="$tmp_root/hold.err"
owner_out="$tmp_root/owner.out"
owner_err="$tmp_root/owner.err"
follower_out="$tmp_root/follower.out"
follower_err="$tmp_root/follower.err"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-wrapper-sandbox-*|/tmp/runat-validate-*/tmp/beam-wrapper-sandbox-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

remove_owned_tmp_tree() {
  local path="$1"
  expect_owned_tmp_dir "$path"
  rm -rf -- "$path"
}

cleanup() {
  if [ -n "${hold_pid:-}" ]; then
    kill "$hold_pid" > /dev/null 2>&1 || true
    wait "$hold_pid" 2>/dev/null || true
  fi
  if [ -n "${owner_pid:-}" ]; then
    kill "$owner_pid" > /dev/null 2>&1 || true
    wait "$owner_pid" 2>/dev/null || true
  fi
  if [ -n "${follower_pid:-}" ]; then
    sandbox_beam cancel wrapper-sandbox-follower > /dev/null 2>&1 || true
    wait "$follower_pid" 2>/dev/null || true
  fi
  remove_owned_tmp_tree "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$project_root" "$control_root"
rsync -a tests/save_olean_project/ "$project_root"/
mkdir -p "$project_root/tests/scenario/docs"
cp tests/scenario/docs/SlowPoll.lean "$project_root/tests/scenario/docs/SlowPoll.lean"

sandbox_beam() {
  bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    --chdir "$project_root" \
    -- /usr/bin/env BEAM_CONTROL_DIR="$control_root" "$beam_script" --root "$project_root" "$@"
}

sandbox_shell_hold() {
  local hold_secs="$1"
  bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    --chdir "$project_root" \
    -- /bin/bash -lc "export BEAM_CONTROL_DIR='$control_root'; '$beam_script' --root '$project_root' ensure lean >'$hold_out' 2>'$hold_err'; sleep $hold_secs"
}

wait_for_registry() {
  local remaining=30
  while [ "$remaining" -gt 0 ]; do
    registry="$(find "$control_root" -name beam-daemon.json -print | sed -n '1p')"
    if [ -n "$registry" ] && [ -f "$registry" ]; then
      return 0
    fi
    sleep 0.2
    remaining=$((remaining - 1))
  done
  return 1
}

sandbox_shell_hold 10 &
hold_pid="$!"

if ! wait_for_registry; then
  echo "expected sandboxed wrapper ensure to create a control-dir registry" >&2
  cat "$hold_err" >&2
  exit 1
fi

daemon_id_1="$(read_json_field "$registry" daemonId)"
port_1="$(read_json_field "$registry" port)"
pid_ns_1="$(read_json_field "$registry" pidNamespace 2>/dev/null || true)"

if [ -z "$pid_ns_1" ]; then
  echo "expected sandboxed wrapper registry to record the daemon pid namespace for debugging" >&2
  cat "$registry" >&2
  exit 1
fi

doctor_out="$(sandbox_beam doctor)"
if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
  echo "expected a PID-isolated wrapper invocation to reuse the live daemon via the registry endpoint" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'daemon pid namespace: '; then
  echo "expected doctor output to surface the daemon pid namespace for debugging" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi

sandbox_beam ensure lean > /dev/null

daemon_id_2="$(read_json_field "$registry" daemonId)"
port_2="$(read_json_field "$registry" port)"
pid_ns_2="$(read_json_field "$registry" pidNamespace 2>/dev/null || true)"

if [ "$daemon_id_1" != "$daemon_id_2" ]; then
  echo "expected PID-isolated wrapper ensure to reuse the existing daemon instead of starting a new one" >&2
  printf 'before daemonId: %s\n' "$daemon_id_1" >&2
  printf 'after daemonId: %s\n' "$daemon_id_2" >&2
  exit 1
fi

if [ "$port_1" != "$port_2" ]; then
  echo "expected PID-isolated wrapper ensure to preserve the daemon endpoint" >&2
  printf 'before port: %s\n' "$port_1" >&2
  printf 'after port: %s\n' "$port_2" >&2
  exit 1
fi

if [ "$pid_ns_1" != "$pid_ns_2" ]; then
  echo "expected PID-isolated wrapper ensure to preserve the recorded daemon pid namespace" >&2
  printf 'before pid namespace: %s\n' "$pid_ns_1" >&2
  printf 'after pid namespace: %s\n' "$pid_ns_2" >&2
  exit 1
fi

kill "$hold_pid" > /dev/null 2>&1 || true
wait "$hold_pid" 2>/dev/null || true
hold_pid=""

find "$control_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

sandbox_beam sync CommandA.lean >"$owner_out" 2>"$owner_err" &
owner_pid="$!"
sleep 0.2
BEAM_PROGRESS=1 BEAM_REQUEST_ID=wrapper-sandbox-follower \
  sandbox_beam lean-run-at tests/scenario/docs/SlowPoll.lean 25 2 poll_sleep_cmd \
  >"$follower_out" 2>"$follower_err" &
follower_pid="$!"

sleep 1

if ! kill -0 "$follower_pid" 2>/dev/null; then
  echo "expected the follower sandbox request to stay alive while the owner request finishes" >&2
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi

cancel_json="$(sandbox_beam cancel wrapper-sandbox-follower)"
if ! printf '%s\n' "$cancel_json" | python3 -c 'import json,sys; payload=json.load(sys.stdin); raise SystemExit(0 if payload.get("result", {}).get("cancelled") is True else 1)'; then
  echo "expected sandbox wrapper cancel request to acknowledge the follower request id" >&2
  printf '%s\n' "$cancel_json" >&2
  exit 1
fi
set +e
wait "$follower_pid"
follower_status=$?
set -e
follower_pid=""

if [ "$follower_status" = "0" ]; then
  echo "expected follower sandbox wrapper request to exit non-zero after cancellation" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi

follower_json="$(cat "$follower_out")"
if ! python3 -c 'import json,sys; payload=json.load(sys.stdin); raise SystemExit(0 if payload.get("error", {}).get("code") == "requestCancelled" else 1)' <<<"$follower_json"
then
  echo "expected follower sandbox wrapper request to report requestCancelled after SIGINT" >&2
  printf '%s\n' "$follower_json" >&2
  cat "$follower_err" >&2
  exit 1
fi

wait "$owner_pid"
owner_pid=""
