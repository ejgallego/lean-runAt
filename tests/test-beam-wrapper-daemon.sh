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

stop_hold_process() {
  local require_clean_exit="${1:-false}"
  if [ -n "$hold_pid" ]; then
    kill -INT "$hold_pid" > /dev/null 2>&1 || true
    if ! wait_for_exit "$hold_pid" "ensure --hold wrapper" 20 0.1; then
      kill "$hold_pid" > /dev/null 2>&1 || true
      wait "$hold_pid" 2>/dev/null || true
      hold_pid=""
      if [ "$require_clean_exit" = "true" ]; then
        echo "expected ensure --hold wrapper to exit promptly after SIGINT" >&2
        return 1
      fi
    else
      local hold_status=0
      set +e
      wait "$hold_pid" 2>/dev/null
      hold_status="$?"
      set -e
      hold_pid=""
      if [ "$require_clean_exit" = "true" ] && [ "$hold_status" -ne 0 ]; then
        echo "expected ensure --hold wrapper to exit cleanly after SIGINT, got $hold_status" >&2
        return 1
      fi
    fi
    hold_pid=""
  fi
}

tmp1="$(mktemp -d /tmp/beam-wrapper-daemon-a-XXXXXX)"
tmp3="$(mktemp -d /tmp/beam-wrapper-daemon-c-XXXXXX)"
tmp9="$(mktemp -d /tmp/beam-wrapper-daemon-i-XXXXXX)"
owned_bundle_dir=""
if [ -z "${BEAM_INSTALL_BUNDLE_DIR:-}" ]; then
  owned_bundle_dir="$(mktemp -d /tmp/beam-wrapper-daemon-bundles-XXXXXX)"
  export BEAM_INSTALL_BUNDLE_DIR="$owned_bundle_dir"
fi
busy_pid=""
hold_pid=""
heartbeat_follower_pid=""
removed_root_pid=""
removed_root_err=""

cleanup() {
  stop_hold_process
  if [ -n "$busy_pid" ]; then
    kill "$busy_pid" > /dev/null 2>&1 || true
    wait "$busy_pid" 2>/dev/null || true
  fi
  if [ -n "$heartbeat_follower_pid" ]; then
    kill "$heartbeat_follower_pid" > /dev/null 2>&1 || true
    wait "$heartbeat_follower_pid" 2>/dev/null || true
  fi
  if [ -n "$removed_root_pid" ]; then
    kill "$removed_root_pid" > /dev/null 2>&1 || true
    wait "$removed_root_pid" 2>/dev/null || true
  fi
  if [ -n "$removed_root_err" ]; then
    rm -f "$removed_root_err"
  fi
  "$beam_script" --root "$tmp1" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp3" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp9" shutdown > /dev/null 2>&1 || true
  remove_owned_tmp_tree "$tmp1"
  remove_owned_tmp_tree "$tmp3"
  remove_owned_tmp_tree "$tmp9"
  if [ -n "$owned_bundle_dir" ]; then
    remove_owned_tmp_tree "$owned_bundle_dir"
  fi
}
trap cleanup EXIT

if [ -n "$owned_bundle_dir" ]; then
  expect_owned_tmp_dir "$owned_bundle_dir"
fi

fixture_toolchain="$(awk 'NR==1 {print $1}' tests/save_olean_project/lean-toolchain)"
"$beam_cli" bundle-install "$fixture_toolchain"

for tmp in "$tmp1" "$tmp3" "$tmp9"; do
  expect_owned_tmp_dir "$tmp"
  rsync -a --exclude='.beam/' tests/save_olean_project/ "$tmp"/
  remove_tmp_tree_within "$tmp/.beam" "$tmp"
  mkdir -p "$tmp/.beam"
done

"$beam_script" --root "$tmp9" ensure --hold > "$tmp9/hold.out" 2> "$tmp9/hold.err" &
hold_pid="$!"
hold_registry="$tmp9/.beam/beam-daemon.json"
# A cold installed-bundle qualification can build the selected Lean payload before `ensure`
# responds. Keep this bounded, but allow enough time for that legitimate first-use path on CI.
hold_ready_attempts="${BEAM_TEST_HOLD_READY_ATTEMPTS:-1800}"
case "$hold_ready_attempts" in
  ''|*[!0-9]*|0)
    echo "BEAM_TEST_HOLD_READY_ATTEMPTS must be a positive integer" >&2
    exit 1
    ;;
esac
for _ in $(seq 1 "$hold_ready_attempts"); do
  if [ -s "$tmp9/hold.out" ] && [ -f "$hold_registry" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -s "$tmp9/hold.out" ] || [ ! -f "$hold_registry" ]; then
  echo "expected ensure --hold to print an ensure response and create a registry after $hold_ready_attempts readiness probes" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
if ! kill -0 "$hold_pid" 2>/dev/null; then
  echo "expected ensure --hold wrapper process to remain alive" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
hold_json="$(cat "$tmp9/hold.out")"
assert_json_field_equals "ensure --hold response" "$hold_json" ok true "$tmp9/hold.err"

lease_dir="$tmp9/.beam/wrapper-leases"
retirement_path="$tmp9/.beam/daemon-retirement.json"

# A retirement marker is local control state, but its lease field must still be constrained to the
# wrapper-leases directory before cleanup code joins or removes that path.
outside_lease="$tmp9/.beam/outside.lease"
printf 'preserve\n' > "$outside_lease"
retirement_daemon_id="$(read_json_field "$hold_registry" daemonId)"
RETIREMENT_PATH="$retirement_path" DAEMON_ID="$retirement_daemon_id" python3 - <<'PY'
import json, os

with open(os.environ["RETIREMENT_PATH"], "w") as f:
    json.dump({"daemonId": os.environ["DAEMON_ID"], "ownerLeaseFile": "../outside.lease"}, f)
    f.write("\n")
PY
"$beam_script" --root "$tmp9" ensure lean > /dev/null
if [ ! -f "$outside_lease" ]; then
  echo "expected an invalid retirement owner path not to remove a file outside wrapper-leases" >&2
  exit 1
fi
if [ -e "$retirement_path" ]; then
  echo "expected an invalid retirement owner path to be discarded" >&2
  cat "$retirement_path" >&2
  exit 1
fi
rm -f "$outside_lease"

# A reused-daemon request must stop if its heartbeat writer fails; otherwise the owner can prune its
# expired lease while the request is still using the daemon. Block only the follower's atomic tmp
# path so the starter heartbeat remains healthy.
owner_lease="$(find "$lease_dir" -maxdepth 1 -type f -name '*.lease' -print | sed -n '1p')"
if [ -z "$owner_lease" ]; then
  echo "expected the foreground owner to hold a wrapper lease" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" ensure --hold \
  > "$tmp9/heartbeat-follower.out" 2> "$tmp9/heartbeat-follower.err" &
heartbeat_follower_pid="$!"
heartbeat_follower_lease=""
for _ in $(seq 1 100); do
  heartbeat_follower_lease="$(find "$lease_dir" -maxdepth 1 -type f -name '*.lease' \
    ! -path "$owner_lease" -print | sed -n '1p')"
  if [ -s "$tmp9/heartbeat-follower.out" ] && [ -n "$heartbeat_follower_lease" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$tmp9/heartbeat-follower.out" ] || [ -z "$heartbeat_follower_lease" ]; then
  echo "expected the heartbeat-failure follower to acquire a lease and print ensure output" >&2
  cat "$tmp9/heartbeat-follower.err" >&2
  exit 1
fi
heartbeat_tmp="${heartbeat_follower_lease%.lease}.tmp"
for _ in $(seq 1 100); do
  if mkdir "$heartbeat_tmp" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
if [ ! -d "$heartbeat_tmp" ]; then
  echo "could not block the follower heartbeat tmp path" >&2
  exit 1
fi
if ! wait_for_exit "$heartbeat_follower_pid" "wrapper with failed heartbeat writer" 100 0.05; then
  cat "$tmp9/heartbeat-follower.err" >&2
  exit 1
fi
set +e
wait "$heartbeat_follower_pid"
heartbeat_follower_status="$?"
set -e
heartbeat_follower_pid=""
rmdir "$heartbeat_tmp"
if [ "$heartbeat_follower_status" -eq 0 ]; then
  echo "expected a reused-daemon wrapper with a failed heartbeat writer to fail" >&2
  cat "$tmp9/heartbeat-follower.err" >&2
  exit 1
fi

# Neither an unreadable registry nor an unreadable sibling lease may make the starter leave its
# retirement loop. Restore each observation independently and require the owner to remain alive
# until the lease directory is provably drained.
unreadable_lease="$lease_dir/unreadable-sibling.lease"
mkdir "$unreadable_lease"
mv "$hold_registry" "$hold_registry.saved"
mkdir "$hold_registry"
kill -INT "$hold_pid"
sleep 0.5
if ! kill -0 "$hold_pid" 2>/dev/null; then
  echo "expected an owner to stay alive while registry state is unreadable" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
rmdir "$hold_registry"
mv "$hold_registry.saved" "$hold_registry"
sleep 0.5
if ! kill -0 "$hold_pid" 2>/dev/null; then
  echo "expected an owner to stay alive while a sibling lease is unreadable" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
rmdir "$unreadable_lease"
if ! wait_for_exit "$hold_pid" "owner after registry and lease recovery" 100 0.05; then
  cat "$tmp9/hold.err" >&2
  exit 1
fi
set +e
wait "$hold_pid"
hold_status="$?"
set -e
hold_pid=""
if [ "$hold_status" -ne 0 ]; then
  echo "expected the owner to exit cleanly after registry and lease recovery, got $hold_status" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" shutdown > /dev/null

stale_lease_dir="$tmp9/.beam/wrapper-leases"
stale_lease="$stale_lease_dir/stale-dead-wrapper.lease"
mkdir -p "$stale_lease_dir"
case "$(uname -s)" in
  Linux) pid_domain="$(readlink /proc/self/ns/pid 2>/dev/null || true)" ;;
  Darwin) pid_domain="host:Darwin" ;;
  *) pid_domain="" ;;
esac
LEASE_PATH="$stale_lease" PID_DOMAIN="$pid_domain" python3 - <<'PY'
import json, os, time

metadata = {
    "pid": 999999999,
    "pidDomain": os.environ["PID_DOMAIN"] or None,
    "heartbeatMonoNanos": time.monotonic_ns(),
}
with open(os.environ["LEASE_PATH"], "w") as f:
    json.dump(metadata, f)
    f.write("\n")
PY

"$beam_script" --root "$tmp9" ensure lean > /dev/null
if [ -e "$stale_lease" ]; then
  echo "expected wrapper ensure to remove a stale same-domain wrapper lease" >&2
  cat "$stale_lease" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" shutdown > /dev/null

malformed_lease="$stale_lease_dir/malformed-wrapper.lease"
printf '{\n' > "$malformed_lease"
"$beam_script" --root "$tmp9" ensure lean > /dev/null
if [ -e "$malformed_lease" ]; then
  echo "expected wrapper ensure to prune a malformed wrapper lease" >&2
  cat "$malformed_lease" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" shutdown > /dev/null

rm -f "$retirement_path"
mkdir "$retirement_path"
set +e
"$beam_script" --root "$tmp9" ensure lean > "$tmp9/retirement-read.out" 2> "$tmp9/retirement-read.err"
retirement_read_status="$?"
set -e
if [ "$retirement_read_status" -eq 0 ]; then
  echo "expected an unreadable retirement fence to fail closed" >&2
  cat "$tmp9/retirement-read.out" >&2
  cat "$tmp9/retirement-read.err" >&2
  exit 1
fi
if [ ! -d "$retirement_path" ]; then
  echo "expected an unreadable retirement fence to remain in place" >&2
  exit 1
fi
rmdir "$retirement_path"
"$beam_script" --root "$tmp9" ensure lean > /dev/null
"$beam_script" --root "$tmp9" shutdown > /dev/null

# If the daemon started by a foreground owner dies before retirement, that wrapper must not poll
# forever waiting for stats from a process that is provably gone. A later wrapper should replace
# the dead registry generation normally.
rm -f "$tmp9/dead-daemon-hold.out" "$tmp9/dead-daemon-hold.err"
"$beam_script" --root "$tmp9" ensure --hold \
  > "$tmp9/dead-daemon-hold.out" 2> "$tmp9/dead-daemon-hold.err" &
hold_pid="$!"
for _ in $(seq 1 200); do
  if [ -s "$tmp9/dead-daemon-hold.out" ] && [ -f "$hold_registry" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$tmp9/dead-daemon-hold.out" ] || [ ! -f "$hold_registry" ]; then
  echo "expected the crash-retirement owner to start a daemon" >&2
  cat "$tmp9/dead-daemon-hold.err" >&2
  exit 1
fi
dead_daemon_pid="$(read_json_field "$hold_registry" pid)"
dead_daemon_id="$(read_json_field "$hold_registry" daemonId)"
kill -KILL "$dead_daemon_pid"
dead_daemon_stopped="false"
for _ in $(seq 1 100); do
  if ! kill -0 "$dead_daemon_pid" 2>/dev/null; then
    dead_daemon_stopped="true"
    break
  fi
  if ps -o stat= -p "$dead_daemon_pid" 2>/dev/null | grep -Eq '^[[:space:]]*Z'; then
    dead_daemon_stopped="true"
    break
  fi
  sleep 0.05
done
if [ "$dead_daemon_stopped" != "true" ]; then
  echo "expected daemon $dead_daemon_pid to stop before owner retirement" >&2
  exit 1
fi
kill -INT "$hold_pid"
if ! wait_for_exit "$hold_pid" "owner of a provably dead daemon" 100 0.05; then
  cat "$tmp9/dead-daemon-hold.err" >&2
  exit 1
fi
set +e
wait "$hold_pid"
dead_daemon_owner_status="$?"
set -e
hold_pid=""
if [ "$dead_daemon_owner_status" -ne 0 ]; then
  echo "expected the owner of a provably dead daemon to exit cleanly, got $dead_daemon_owner_status" >&2
  cat "$tmp9/dead-daemon-hold.err" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" ensure lean > /dev/null
replacement_daemon_id="$(read_json_field "$hold_registry" daemonId)"
if [ "$replacement_daemon_id" = "$dead_daemon_id" ]; then
  echo "expected the next wrapper to replace the dead daemon generation" >&2
  cat "$hold_registry" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" shutdown > /dev/null

(
  cd "$tmp1"
  "$beam_script" ensure lean > /dev/null
)

reg1="$tmp1/.beam/beam-daemon.json"
expect_file "$reg1"

pid1="$(read_json_field "$reg1" pid)"
port1="$(read_json_field "$reg1" port)"
root1="$(read_json_field "$reg1" root)"
if [ "$root1" != "$(beam_test_realpath "$tmp1")" ]; then
  echo "wrapper registry root mismatch: expected $tmp1, got $root1" >&2
  exit 1
fi
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be alive" >&2
  exit 1
fi

(
  cd "$tmp3"
  collision_out="$(mktemp /tmp/beam-wrapper-port-collision-out-XXXXXX)"
  collision_err="$(mktemp /tmp/beam-wrapper-port-collision-err-XXXXXX)"
  if "$beam_script" --port "$port1" ensure lean >"$collision_out" 2>"$collision_err"; then
    echo "expected wrapper ensure to reject a port already serving another Beam root" >&2
    cat "$collision_out" >&2
    cat "$collision_err" >&2
    rm -f "$collision_out" "$collision_err"
    exit 1
  fi
  if ! grep -q 'already serves Beam root' "$collision_err"; then
    echo "expected port collision failure to name the existing Beam root" >&2
    cat "$collision_out" >&2
    cat "$collision_err" >&2
    rm -f "$collision_out" "$collision_err"
    exit 1
  fi
  if [ -f "$tmp3/.beam/beam-daemon.json" ]; then
    echo "expected port collision failure not to write a registry for the wrong endpoint" >&2
    cat "$tmp3/.beam/beam-daemon.json" >&2
    rm -f "$collision_out" "$collision_err"
    exit 1
  fi
  rm -f "$collision_out" "$collision_err"
)

stale_registry="$tmp3/.beam/beam-daemon.json"
REGISTRY_TEMPLATE="$reg1" STALE_REGISTRY="$stale_registry" STALE_ROOT="$tmp3" python3 - <<'PY'
import json
import os

with open(os.environ["REGISTRY_TEMPLATE"]) as f:
    data = json.load(f)
data["root"] = os.path.realpath(os.environ["STALE_ROOT"])
data["configHash"] = "stale-registry-test"
with open(os.environ["STALE_REGISTRY"], "w") as f:
    json.dump(data, f)
    f.write("\n")
PY

(
  cd "$tmp3"
  doctor_out="$("$beam_script" doctor lean)"
  if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: stale'; then
    echo "expected wrapper doctor to reject a stale registry whose endpoint serves another root" >&2
    printf '%s\n' "$doctor_out" >&2
    exit 1
  fi
  "$beam_script" shutdown > /dev/null
  if [ -f "$stale_registry" ]; then
    echo "expected wrapper shutdown to remove the stale registry" >&2
    cat "$stale_registry" >&2
    exit 1
  fi
)
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected stale registry shutdown not to kill the real Beam daemon for tmp1" >&2
  exit 1
fi

busy_port_file="$(mktemp /tmp/beam-wrapper-busy-port-XXXXXX)"
python3 - "$busy_port_file" <<'PY' &
import http.server
import socketserver
import sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w") as f:
        print(server.server_address[1], file=f, flush=True)
    server.serve_forever()
PY
busy_pid=$!
for _ in $(seq 1 100); do
  if [ -s "$busy_port_file" ]; then
    break
  fi
  if ! kill -0 "$busy_pid" 2>/dev/null; then
    echo "expected temporary busy-port server to stay alive" >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$busy_port_file" ]; then
  echo "timed out waiting for temporary busy-port server" >&2
  exit 1
fi
busy_port="$(cat "$busy_port_file")"

(
  cd "$tmp3"
  busy_out="$(mktemp /tmp/beam-wrapper-busy-port-out-XXXXXX)"
  busy_err="$(mktemp /tmp/beam-wrapper-busy-port-err-XXXXXX)"
  if "$beam_script" --port "$busy_port" ensure lean >"$busy_out" 2>"$busy_err"; then
    echo "expected wrapper ensure to reject a port already used by a non-Beam process" >&2
    cat "$busy_out" >&2
    cat "$busy_err" >&2
    rm -f "$busy_out" "$busy_err"
    exit 1
  fi
  if ! grep -q 'already in use' "$busy_err"; then
    echo "expected non-Beam port collision failure to report the occupied endpoint" >&2
    cat "$busy_out" >&2
    cat "$busy_err" >&2
    rm -f "$busy_out" "$busy_err"
    exit 1
  fi
  if [ -f "$tmp3/.beam/beam-daemon.json" ]; then
    echo "expected non-Beam port collision failure not to write a registry" >&2
    cat "$tmp3/.beam/beam-daemon.json" >&2
    rm -f "$busy_out" "$busy_err"
    exit 1
  fi
  rm -f "$busy_out" "$busy_err"
)
kill "$busy_pid" > /dev/null 2>&1 || true
wait "$busy_pid" 2>/dev/null || true
busy_pid=""
rm -f "$busy_port_file"

# Git removes the project-local registry together with a worktree. The daemon must observe the
# missing canonical root and stop itself, because no later wrapper invocation can discover it.
removed_root_pid="$pid1"
remove_owned_tmp_tree "$tmp1"
if ! wait_for_exit "$removed_root_pid" "daemon whose worktree was removed" 100 0.1; then
  echo "expected Beam daemon $removed_root_pid to exit after its project root disappeared" >&2
  exit 1
fi
removed_root_pid=""

removed_root_err="$(mktemp /tmp/beam-wrapper-removed-root-XXXXXX)"
if "$beam_script" --root "$tmp1" ensure lean > /dev/null 2>"$removed_root_err"; then
  echo "expected a wrapper request for the removed worktree to fail" >&2
  exit 1
fi
if ! grep -Fq 'workspace root does not resolve' "$removed_root_err"; then
  echo "expected a removed-worktree request to report that its workspace root no longer resolves" >&2
  cat "$removed_root_err" >&2
  exit 1
fi
rm -f "$removed_root_err"
removed_root_err=""
