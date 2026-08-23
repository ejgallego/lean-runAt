#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

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

tmp_root="$(mktemp -d /tmp/beam-wrapper-sandbox-XXXXXX)"
project_root="$tmp_root/project"
control_root="$tmp_root/control"
hold_out="$tmp_root/hold.out"
hold_err="$tmp_root/hold.err"
owner_out="$tmp_root/owner.out"
owner_err="$tmp_root/owner.err"
owner_stop="$tmp_root/owner.stop"
follower_out="$tmp_root/follower.out"
follower_err="$tmp_root/follower.err"
follower_request_id=""
replacement_owner_a_pid=""
replacement_owner_b_pid=""

cleanup() {
  if [ -n "${hold_pid:-}" ]; then
    kill "$hold_pid" > /dev/null 2>&1 || true
    wait "$hold_pid" 2>/dev/null || true
  fi
  if [ -n "${owner_pid:-}" ]; then
    kill "$owner_pid" > /dev/null 2>&1 || true
    wait "$owner_pid" 2>/dev/null || true
  fi
  if [ -n "${replacement_owner_a_pid:-}" ]; then
    kill "$replacement_owner_a_pid" > /dev/null 2>&1 || true
    wait "$replacement_owner_a_pid" 2>/dev/null || true
  fi
  if [ -n "${replacement_owner_b_pid:-}" ]; then
    kill "$replacement_owner_b_pid" > /dev/null 2>&1 || true
    wait "$replacement_owner_b_pid" 2>/dev/null || true
  fi
  if [ -n "${follower_pid:-}" ]; then
    if [ -n "$follower_request_id" ]; then
      sandbox_beam cancel "$follower_request_id" > /dev/null 2>&1 || true
    fi
    kill "$follower_pid" > /dev/null 2>&1 || true
    wait "$follower_pid" 2>/dev/null || true
  fi
  remove_owned_tmp_tree "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$project_root" "$control_root"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root"/
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

assert_no_connection_closed_incidents() {
  local label="$1"
  if find "$control_root" -path '*/daemon-failures/*connectionClosed*.json' -print -quit | grep -q .; then
    echo "expected $label to produce no connectionClosed incident" >&2
    find "$control_root" -path '*/daemon-failures/*.json' -print -exec cat {} \; >&2
    exit 1
  fi
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

sandbox_owner_hold() {
  local output_path="$1"
  local error_path="$2"
  local stop_path="$3"
  bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    --chdir "$project_root" \
    -- /bin/bash -lc \
      "export BEAM_CONTROL_DIR='$control_root'; \
       '$beam_script' --root '$project_root' ensure lean --hold >'$output_path' 2>'$error_path' & \
       wrapper_pid=\$!; \
       while [ ! -f '$stop_path' ]; do sleep 0.05; done; \
       kill -INT \"\$wrapper_pid\"; \
       wait \"\$wrapper_pid\""
}

sandbox_paused_follower() {
  local version="$1"
  local request_id="$2"
  local output_path="$3"
  local error_path="$4"
  local pause_path="$5"
  local paused_path="$6"
  local resume_path="$7"
  bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    --chdir "$project_root" \
    -- /bin/bash -lc \
      "export BEAM_CONTROL_DIR='$control_root' BEAM_PROGRESS=1 BEAM_REQUEST_ID='$request_id'; \
       '$beam_script' --root '$project_root' run-at tests/scenario/docs/SlowPoll.lean '$version' 25 2 poll_sleep_cmd >'$output_path' 2>'$error_path' & \
       wrapper_pid=\$!; \
       while [ ! -f '$pause_path' ]; do sleep 0.05; done; \
       kill -STOP \"\$wrapper_pid\"; \
       touch '$paused_path'; \
       while [ ! -f '$resume_path' ]; do sleep 0.05; done; \
       kill -CONT \"\$wrapper_pid\"; \
       wait \"\$wrapper_pid\""
}

wait_for_registry() {
  local remaining=300
  while [ "$remaining" -gt 0 ]; do
    # The control lock is intentionally short-lived and may disappear while `find` walks the
    # per-root directory. Ignore that observational traversal race and keep probing for the file.
    registry="$(find "$control_root" -name beam-daemon.json -print 2>/dev/null | sed -n '1p' || true)"
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
pid_domain_1="$(read_json_field "$registry" pidDomain 2>/dev/null || true)"

if [ -z "$pid_domain_1" ]; then
  echo "expected sandboxed wrapper registry to record the daemon PID domain for debugging" >&2
  cat "$registry" >&2
  exit 1
fi

doctor_out="$(sandbox_beam doctor)"
if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
  echo "expected a PID-isolated wrapper invocation to reuse the live daemon via the registry endpoint" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'daemon pid domain: '; then
  echo "expected doctor output to surface the daemon pid domain for debugging" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi

sandbox_beam ensure lean > /dev/null

daemon_id_2="$(read_json_field "$registry" daemonId)"
port_2="$(read_json_field "$registry" port)"
pid_domain_2="$(read_json_field "$registry" pidDomain 2>/dev/null || true)"

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

if [ "$pid_domain_1" != "$pid_domain_2" ]; then
  echo "expected PID-isolated wrapper ensure to preserve the recorded daemon PID domain" >&2
  printf 'before PID domain: %s\n' "$pid_domain_1" >&2
  printf 'after PID domain: %s\n' "$pid_domain_2" >&2
  exit 1
fi

kill "$hold_pid" > /dev/null 2>&1 || true
wait "$hold_pid" 2>/dev/null || true
hold_pid=""

find "$control_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

sandbox_owner_hold "$owner_out" "$owner_err" "$owner_stop" &
owner_pid="$!"
if ! wait_for_registry; then
  echo "expected owner sandbox wrapper request to create a control-dir registry" >&2
  cat "$owner_err" >&2
  exit 1
fi
follower_version="$(beam_wrapper_update_version "sandbox SlowPoll" sandbox_beam update tests/scenario/docs/SlowPoll.lean)"
follower_request_id="wrapper-sandbox-follower"
BEAM_PROGRESS=1 BEAM_REQUEST_ID="$follower_request_id" \
  sandbox_beam run-at tests/scenario/docs/SlowPoll.lean "$follower_version" 25 2 poll_sleep_cmd \
  >"$follower_out" 2>"$follower_err" &
follower_pid="$!"

if ! wait_for_file_text "$follower_err" "snapshot progress" "follower sandbox wrapper request progress"; then
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi
if ! wait_for_nonempty_file "$owner_out" "owner sandbox ensure response"; then
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi

touch "$owner_stop"

# The original owner-lifetime implementation stopped tracking siblings after a fixed
# 30-second polling window. Keep the follower active beyond that boundary so this test
# proves ownership follows the request lifetime rather than an elapsed-duration guess.
sleep 31

if ! kill -0 "$owner_pid" 2>/dev/null; then
  echo "expected the owner sandbox wrapper to outlive a follower active for more than 30 seconds" >&2
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi

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
follower_request_id=""

if [ "$follower_status" = "0" ]; then
  echo "expected follower sandbox wrapper request to exit non-zero after cancellation" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi

follower_json="$(cat "$follower_out")"
if ! python3 -c 'import json,sys; payload=json.load(sys.stdin); raise SystemExit(0 if payload.get("error", {}).get("code") == "requestCancelled" else 1)' <<<"$follower_json"
then
  echo "expected follower sandbox wrapper request to report requestCancelled after cancellation" >&2
  printf '%s\n' "$follower_json" >&2
  cat "$follower_err" >&2
  exit 1
fi

wait "$owner_pid"
owner_pid=""

assert_no_connection_closed_incidents "the long-lived follower regression"

# Heartbeat expiry is a revocation decision, not permission to kill broker work that was already
# admitted. Suspend the entire follower wrapper beyond the timeout, let the owner revoke its
# filesystem lease, then resume it. The daemon-side active-request fence must keep the owner alive;
# the resumed wrapper must cancel cleanly instead of reconnecting through the removed lease.
find "$control_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
owner_out="$tmp_root/paused-owner.out"
owner_err="$tmp_root/paused-owner.err"
owner_stop="$tmp_root/paused-owner.stop"
follower_out="$tmp_root/paused-follower.out"
follower_err="$tmp_root/paused-follower.err"
pause_follower="$tmp_root/pause-follower"
follower_paused="$tmp_root/follower-paused"
resume_follower="$tmp_root/resume-follower"

sandbox_owner_hold "$owner_out" "$owner_err" "$owner_stop" &
owner_pid="$!"
if ! wait_for_registry; then
  echo "expected paused-follower owner to create a control-dir registry" >&2
  cat "$owner_err" >&2
  exit 1
fi
paused_version="$(beam_wrapper_update_version "paused sandbox SlowPoll" sandbox_beam update tests/scenario/docs/SlowPoll.lean)"
follower_request_id="wrapper-sandbox-paused-follower"
sandbox_paused_follower "$paused_version" "$follower_request_id" \
  "$follower_out" "$follower_err" "$pause_follower" "$follower_paused" "$resume_follower" &
follower_pid="$!"

if ! wait_for_file_text "$follower_err" "snapshot progress" "paused follower request progress"; then
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi
touch "$pause_follower"
if ! wait_for_file "$follower_paused" "paused follower acknowledgement" 12; then
  cat "$follower_err" >&2
  exit 1
fi
touch "$owner_stop"

revoked_lease=""
for _ in $(seq 1 120); do
  revoked_lease="$(find "$control_root" -name '*.revoked' -print -quit)"
  if [ -n "$revoked_lease" ]; then
    break
  fi
  sleep 0.1
done
if [ -z "$revoked_lease" ]; then
  echo "expected the suspended follower lease to receive a persistent revocation tombstone" >&2
  find "$control_root" -name '*.lease' -print -exec cat {} \; >&2
  exit 1
fi
if ! kill -0 "$owner_pid" 2>/dev/null; then
  echo "expected the daemon owner to stay alive for a revoked but still-admitted request" >&2
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi

touch "$resume_follower"
set +e
wait "$follower_pid"
paused_follower_status="$?"
set -e
follower_pid=""
follower_request_id=""
if [ "$paused_follower_status" -eq 0 ]; then
  echo "expected the resumed wrapper to fail after observing lease revocation" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi
if ! python3 -c 'import json,sys; payload=json.load(sys.stdin); raise SystemExit(0 if payload.get("error", {}).get("code") == "requestCancelled" else 1)' < "$follower_out"
then
  echo "expected the resumed wrapper request to report requestCancelled" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi
if ! wait_for_exit "$owner_pid" "owner after suspended follower cancellation" 120 0.1; then
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi
wait "$owner_pid"
owner_pid=""

assert_no_connection_closed_incidents "suspended-follower revocation"

# A follower killed from outside its PID namespace cannot remove its own lease. Its heartbeat
# must expire so the owner can drain, retire the generation, and permit a later clean ensure.
find "$control_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
owner_out="$tmp_root/killed-owner.out"
owner_err="$tmp_root/killed-owner.err"
owner_stop="$tmp_root/killed-owner.stop"
follower_out="$tmp_root/killed-follower.out"
follower_err="$tmp_root/killed-follower.err"

sandbox_owner_hold "$owner_out" "$owner_err" "$owner_stop" &
owner_pid="$!"
if ! wait_for_registry; then
  echo "expected killed-follower owner to create a control-dir registry" >&2
  cat "$owner_err" >&2
  exit 1
fi
killed_version="$(beam_wrapper_update_version "killed sandbox SlowPoll" sandbox_beam update tests/scenario/docs/SlowPoll.lean)"
follower_request_id="wrapper-sandbox-killed-follower"
BEAM_PROGRESS=1 BEAM_REQUEST_ID="$follower_request_id" \
  sandbox_beam run-at tests/scenario/docs/SlowPoll.lean "$killed_version" 25 2 poll_sleep_cmd \
  >"$follower_out" 2>"$follower_err" &
follower_pid="$!"

if ! wait_for_file_text "$follower_err" "snapshot progress" "killed follower request progress"; then
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  cat "$follower_out" >&2
  cat "$follower_err" >&2
  exit 1
fi
touch "$owner_stop"
kill -KILL "$follower_pid" > /dev/null 2>&1 || true
set +e
wait "$follower_pid" 2>/dev/null
set -e
follower_pid=""
follower_request_id=""

if ! wait_for_exit "$owner_pid" "owner waiting on killed cross-namespace follower" 120 0.1; then
  cat "$owner_out" >&2
  cat "$owner_err" >&2
  find "$control_root" -name '*.lease' -print -exec cat {} \; >&2
  exit 1
fi
wait "$owner_pid"
owner_pid=""

recovery_json="$(sandbox_beam ensure lean)"
if [ "$(json_text_field "$recovery_json" ok)" != "true" ]; then
  echo "expected ensure to recover after pruning a killed follower lease" >&2
  printf '%s\n' "$recovery_json" >&2
  exit 1
fi

# Replacing a daemon while its original starter is still active creates two starter leases. The
# obsolete starter must notice the registry generation change before waiting on the replacement
# owner's lease, or both owners keep each other's heartbeats alive forever.
find "$control_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
replacement_a_out="$tmp_root/replacement-a.out"
replacement_a_err="$tmp_root/replacement-a.err"
replacement_a_stop="$tmp_root/replacement-a.stop"
replacement_b_out="$tmp_root/replacement-b.out"
replacement_b_err="$tmp_root/replacement-b.err"
replacement_b_stop="$tmp_root/replacement-b.stop"

sandbox_owner_hold "$replacement_a_out" "$replacement_a_err" "$replacement_a_stop" &
replacement_owner_a_pid="$!"
if ! wait_for_registry || ! wait_for_nonempty_file "$replacement_a_out" "original replacement owner response"; then
  cat "$replacement_a_out" >&2
  cat "$replacement_a_err" >&2
  exit 1
fi
replacement_daemon_a="$(read_json_field "$registry" daemonId)"

replacement_shutdown_json="$(sandbox_beam shutdown)"
if ! python3 -c 'import json,sys; payload=json.load(sys.stdin); raise SystemExit(0 if payload.get("result", {}).get("shutdown") is True else 1)' <<<"$replacement_shutdown_json"
then
  echo "expected replacement setup to shut down the original daemon" >&2
  printf '%s\n' "$replacement_shutdown_json" >&2
  exit 1
fi

sandbox_owner_hold "$replacement_b_out" "$replacement_b_err" "$replacement_b_stop" &
replacement_owner_b_pid="$!"
if ! wait_for_registry || ! wait_for_nonempty_file "$replacement_b_out" "replacement owner response"; then
  cat "$replacement_a_out" >&2
  cat "$replacement_a_err" >&2
  cat "$replacement_b_out" >&2
  cat "$replacement_b_err" >&2
  exit 1
fi
replacement_daemon_b="$(read_json_field "$registry" daemonId)"
if [ "$replacement_daemon_a" = "$replacement_daemon_b" ]; then
  echo "expected successive PID-isolated daemon starts to receive distinct generation ids" >&2
  printf 'original daemonId: %s\nreplacement daemonId: %s\n' \
    "$replacement_daemon_a" "$replacement_daemon_b" >&2
  exit 1
fi

touch "$replacement_a_stop"
if ! wait_for_exit "$replacement_owner_a_pid" "obsolete daemon generation owner" 100 0.1; then
  cat "$replacement_a_out" >&2
  cat "$replacement_a_err" >&2
  cat "$replacement_b_out" >&2
  cat "$replacement_b_err" >&2
  find "$control_root" -name '*.lease' -print -exec cat {} \; >&2
  exit 1
fi
wait "$replacement_owner_a_pid"
replacement_owner_a_pid=""

if ! kill -0 "$replacement_owner_b_pid" 2>/dev/null; then
  echo "expected the replacement daemon owner to remain active after the obsolete owner exited" >&2
  cat "$replacement_b_out" >&2
  cat "$replacement_b_err" >&2
  exit 1
fi
touch "$replacement_b_stop"
if ! wait_for_exit "$replacement_owner_b_pid" "replacement daemon generation owner" 120 0.1; then
  cat "$replacement_b_out" >&2
  cat "$replacement_b_err" >&2
  find "$control_root" -name '*.lease' -print -exec cat {} \; >&2
  exit 1
fi
wait "$replacement_owner_b_pid"
replacement_owner_b_pid=""

assert_no_connection_closed_incidents "replacement generation ownership"

# Supplement the deterministic lifetime cases with a cold-start fanout. Every wrapper should
# complete successfully through serialized admission without connection loss.
find "$control_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fanout_count=8
fanout_pids=()
for i in $(seq 1 "$fanout_count"); do
  sandbox_beam ensure lean >"$tmp_root/fanout-$i.out" 2>"$tmp_root/fanout-$i.err" &
  fanout_pids+=("$!")
done
fanout_failed=false
for pid in ${fanout_pids[@]+"${fanout_pids[@]}"}; do
  if ! wait "$pid"; then
    fanout_failed=true
  fi
done
for i in $(seq 1 "$fanout_count"); do
  if [ "$(json_file_text_field "$tmp_root/fanout-$i.out" ok)" != "true" ]; then
    echo "expected cold-start fanout wrapper $i to succeed" >&2
    cat "$tmp_root/fanout-$i.out" >&2
    cat "$tmp_root/fanout-$i.err" >&2
    fanout_failed=true
  fi
done
if [ "$fanout_failed" = "true" ]; then
  exit 1
fi

assert_no_connection_closed_incidents "the sandbox lifecycle regressions"
