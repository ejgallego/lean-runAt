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
paused_daemon_pid=""
busy_pid=""
busy_port_file=""

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
  if [ -n "$busy_pid" ]; then
    kill "$busy_pid" > /dev/null 2>&1 || true
    wait "$busy_pid" 2>/dev/null || true
    busy_pid=""
  fi
  if [ -n "$busy_port_file" ]; then
    rm -f -- "$busy_port_file"
    busy_port_file=""
  fi
  if [ -n "$paused_daemon_pid" ]; then
    kill -CONT "$paused_daemon_pid" > /dev/null 2>&1 || true
    paused_daemon_pid=""
  fi
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

machine_stats_json="$("$beam_script" --root "$tmp1" request-stream \
  '{"op":"stats","clientRequestId":"machine-stats"}')"
assert_json_field_equals "root-aware machine stream kind" "$machine_stats_json" kind response
assert_json_field_equals \
  "root-aware machine stream request id" "$machine_stats_json" clientRequestId machine-stats
assert_json_field_equals \
  "root-aware machine stream response" "$machine_stats_json" payload.ok true
if "$beam_script" request-stream '{"op":"stats","clientRequestId":"missing-root"}' \
    > "$tmp1/machine-missing-root.out" 2> "$tmp1/machine-missing-root.err"; then
  echo "expected the machine stream interface to require --root" >&2
  exit 1
fi
if ! grep -Fq "requires an explicit --root PATH" "$tmp1/machine-missing-root.err"; then
  echo "expected missing-root machine diagnostics to explain the explicit selector" >&2
  cat "$tmp1/machine-missing-root.err" >&2
  exit 1
fi
if "$beam_script" --root "$tmp1" request-stream \
    '{"op":"stats","clientRequestId":"caller-route","workspaceId":"beam-cli-project"}' \
    > "$tmp1/machine-route.out" 2> "$tmp1/machine-route.err"; then
  echo "expected machine requests to reject caller-selected session routing" >&2
  exit 1
fi
if ! grep -Fq "session-owned fields: workspaceId" "$tmp1/machine-route.err"; then
  echo "expected machine routing rejection to name the forbidden field" >&2
  cat "$tmp1/machine-route.err" >&2
  exit 1
fi

python3 - "$registry" "$tmp1" <<'PY'
import json
import os
import sys

registry, root = sys.argv[1:]
with open(registry, encoding="utf-8") as stream:
    entry = json.load(stream)
if entry.get("schemaVersion") != 2:
    raise SystemExit(f"unexpected session schema: {entry.get('schemaVersion')}")
workspaces = entry.get("workspaces")
if not isinstance(workspaces, list) or len(workspaces) != 1:
    raise SystemExit(f"unexpected workspace bindings: {workspaces!r}")
workspace = workspaces[0]
if workspace.get("root") != os.path.realpath(root):
    raise SystemExit(f"unexpected workspace root: {workspace!r}")
if workspace.get("workspaceId") != "beam-cli-project":
    raise SystemExit(f"unexpected workspace id: {workspace!r}")
PY

case "$(uname -s)" in
  Darwin) registry_mode="$(stat -f '%Lp' "$registry")" ;;
  *) registry_mode="$(stat -c '%a' "$registry")" ;;
esac
if [ "$registry_mode" != "600" ]; then
  echo "expected the capability-bearing registry to use mode 600, got $registry_mode" >&2
  exit 1
fi

if "$beam_script" --root "$tmp1" recover --generation "$daemon1_id" \
    > "$tmp1/live-recover.out" 2> "$tmp1/live-recover.err"; then
  echo "expected explicit recovery to refuse a responding generation" >&2
  exit 1
fi
if ! grep -Fq "still responds" "$tmp1/live-recover.err"; then
  echo "expected live-generation recovery refusal to explain the active endpoint" >&2
  cat "$tmp1/live-recover.err" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon1_id" ] || \
    ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "live-generation recovery refusal must preserve the owner and descriptor" >&2
  exit 1
fi

port1="$(read_json_field "$registry" port)"
python3 - "$port1" <<'PY'
import json
import socket
import sys
import time

port = int(sys.argv[1])

def receive_frame(sock):
    header = bytearray()
    while not header.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("daemon closed before returning a framed error")
        header.extend(chunk)
    size = int(header[:-1])
    payload = bytearray()
    while len(payload) < size:
        chunk = sock.recv(size - len(payload))
        if not chunk:
            raise RuntimeError("daemon closed during its framed error")
        payload.extend(chunk)
    return json.loads(payload)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    request = json.dumps({
        "op": "shutdown",
        "daemonCapability": "not-the-owner-capability",
    }).encode()
    sock.sendall(str(len(request)).encode() + b"\n" + request)
    response = receive_frame(sock)
    payload = response.get("payload", {})
    if payload.get("ok") is not False:
        raise RuntimeError(f"unauthorized shutdown unexpectedly succeeded: {response}")
    message = payload.get("error", {}).get("message", "")
    if "invalid Beam daemon capability" not in message:
        raise RuntimeError(f"unexpected unauthorized-shutdown response: {response}")

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.sendall(b"16777217\n")
    response = receive_frame(sock)
    if "exceeds 16777216 bytes" not in response.get("payload", {}).get("error", {}).get("message", ""):
        raise RuntimeError(f"unexpected oversized-frame response: {response}")

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    time.sleep(5.5)
    response = receive_frame(sock)
    if "initial request timed out" not in response.get("payload", {}).get("error", {}).get("message", ""):
        raise RuntimeError(f"unexpected first-message-timeout response: {response}")
PY

stats_after_security_probes_json="$("$beam_script" --root "$tmp1" stats)"
assert_json_field_equals \
  "stats after unauthorized shutdown and transport limit probes" \
  "$stats_after_security_probes_json" ok true
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "expected unauthorized shutdown to preserve both owner and daemon" >&2
  exit 1
fi

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

collision_out="$tmp2/collision.out"
collision_err="$tmp2/collision.err"
if "$beam_script" --root "$tmp2" --port "$port1" ensure --hold > "$collision_out" 2> "$collision_err"; then
  echo "expected an owner not to claim another project's endpoint" >&2
  cat "$collision_out" >&2
  exit 1
fi
if ! grep -Fq "invalid Beam daemon capability" "$collision_err"; then
  echo "expected endpoint collision not to disclose an authenticated daemon's project" >&2
  cat "$collision_err" >&2
  exit 1
fi
if [ -e "$tmp2/.beam/beam-daemon.json" ]; then
  echo "expected endpoint collision not to publish a registry" >&2
  cat "$tmp2/.beam/beam-daemon.json" >&2
  exit 1
fi

stale_registry="$tmp2/.beam/beam-daemon.json"
REGISTRY_TEMPLATE="$registry" STALE_REGISTRY="$stale_registry" STALE_ROOT="$tmp2" python3 - <<'PY'
import json
import os

with open(os.environ["REGISTRY_TEMPLATE"], encoding="utf-8") as stream:
    entry = json.load(stream)
entry["workspaces"][0]["root"] = os.path.realpath(os.environ["STALE_ROOT"])
replacement = os.environ["STALE_REGISTRY"] + ".replacement"
with open(replacement, "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
os.replace(replacement, os.environ["STALE_REGISTRY"])
PY
stale_shutdown_out="$tmp2/stale-cross-root-shutdown.out"
stale_shutdown_err="$tmp2/stale-cross-root-shutdown.err"
if "$beam_script" --root "$tmp2" shutdown \
    > "$stale_shutdown_out" 2> "$stale_shutdown_err"; then
  echo "expected shutdown to reject a registry whose endpoint serves another root" >&2
  cat "$stale_shutdown_out" >&2
  exit 1
fi
if ! grep -Fq "serves another root" "$stale_shutdown_err"; then
  echo "expected cross-root registry rejection to explain the identity mismatch" >&2
  cat "$stale_shutdown_err" >&2
  exit 1
fi
if [ ! -e "$stale_registry" ]; then
  echo "cross-root registry rejection must preserve the unsafe registry as recovery evidence" >&2
  exit 1
fi
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "cross-root registry rejection must not stop the daemon or owner serving the other root" >&2
  exit 1
fi
rm -f -- "$stale_registry"

LEGACY_REGISTRY="$stale_registry" LEGACY_ROOT="$tmp2" python3 - <<'PY'
import json
import os

entry = {
    "daemonId": "legacy-generation",
    "pid": 999999999,
    "ownerPid": 999999999,
    "port": 42424,
    "root": os.path.realpath(os.environ["LEGACY_ROOT"]),
    "configHash": "legacy-config",
    "startedAt": "2026-08-27T00:00:00Z",
}
with open(os.environ["LEGACY_REGISTRY"], "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
PY
legacy_before="$(cat "$stale_registry")"
legacy_owner_out="$tmp2/legacy-owner.out"
legacy_owner_err="$tmp2/legacy-owner.err"
if "$beam_script" --root "$tmp2" ensure --hold \
    > "$legacy_owner_out" 2> "$legacy_owner_err"; then
  echo "expected owner startup to reject a schema-less legacy registry" >&2
  cat "$legacy_owner_out" >&2
  exit 1
fi
if ! grep -Fq "legacy registry has no schemaVersion" "$legacy_owner_err"; then
  echo "expected legacy-registry rejection to explain the unsupported schema" >&2
  cat "$legacy_owner_err" >&2
  exit 1
fi
if [ "$(cat "$stale_registry")" != "$legacy_before" ]; then
  echo "legacy-registry rejection must preserve the recovery evidence" >&2
  cat "$stale_registry" >&2
  exit 1
fi
legacy_recover_json="$("$beam_script" --root "$tmp2" recover --force)"
assert_json_field_equals "opaque registry recovery" "$legacy_recover_json" recovered true
if [ -e "$stale_registry" ]; then
  echo "expected explicit opaque recovery to quarantine the legacy descriptor" >&2
  exit 1
fi
legacy_quarantine="$(json_text_field "$legacy_recover_json" quarantinedPath)"
if [ ! -f "$legacy_quarantine" ]; then
  echo "expected opaque recovery to preserve quarantined evidence" >&2
  printf '%s\n' "$legacy_recover_json" >&2
  exit 1
fi

busy_port_file="$(mktemp "$tmp2/non-beam-port-XXXXXX")"
python3 - "$busy_port_file" <<'PY' &
import socketserver
import sys

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.recv(4096)

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w", encoding="utf-8") as stream:
        print(server.server_address[1], file=stream, flush=True)
    server.serve_forever()
PY
busy_pid="$!"
if ! wait_for_nonempty_file "$busy_port_file" "non-Beam occupied port"; then
  exit 1
fi
busy_port="$(cat "$busy_port_file")"
busy_out="$tmp2/non-beam-port.out"
busy_err="$tmp2/non-beam-port.err"
if "$beam_script" --root "$tmp2" --port "$busy_port" ensure --hold > "$busy_out" 2> "$busy_err"; then
  echo "expected owner startup to reject a port occupied by a non-Beam service" >&2
  cat "$busy_out" >&2
  exit 1
fi
if ! grep -Fq "already in use" "$busy_err"; then
  echo "expected non-Beam port collision to report the occupied endpoint" >&2
  cat "$busy_err" >&2
  exit 1
fi
if [ -e "$tmp2/.beam/beam-daemon.json" ]; then
  echo "expected non-Beam port collision not to publish a registry" >&2
  cat "$tmp2/.beam/beam-daemon.json" >&2
  exit 1
fi
kill "$busy_pid" > /dev/null 2>&1 || true
wait "$busy_pid" 2>/dev/null || true
busy_pid=""
rm -f -- "$busy_port_file"
busy_port_file=""

busy_port_file="$(mktemp "$tmp2/silent-non-beam-port-XXXXXX")"
python3 - "$busy_port_file" <<'PY' &
import socketserver
import sys
import time

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(10)

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w", encoding="utf-8") as stream:
        print(server.server_address[1], file=stream, flush=True)
    server.serve_forever()
PY
busy_pid="$!"
if ! wait_for_nonempty_file "$busy_port_file" "silent non-Beam occupied port"; then
  exit 1
fi
busy_port="$(cat "$busy_port_file")"
busy_out="$tmp2/silent-non-beam-port.out"
busy_err="$tmp2/silent-non-beam-port.err"
silent_probe_started="$SECONDS"
if "$beam_script" --root "$tmp2" --port "$busy_port" ensure --hold > "$busy_out" 2> "$busy_err"; then
  echo "expected owner startup to reject a silent non-Beam service" >&2
  cat "$busy_out" >&2
  exit 1
fi
silent_probe_elapsed="$((SECONDS - silent_probe_started))"
if [ "$silent_probe_elapsed" -ge 8 ]; then
  echo "expected silent non-Beam probe to honor its response deadline, took ${silent_probe_elapsed}s" >&2
  cat "$busy_err" >&2
  exit 1
fi
if ! grep -Fq "response timed out" "$busy_err"; then
  echo "expected silent non-Beam collision to report the bounded probe timeout" >&2
  cat "$busy_err" >&2
  exit 1
fi
if [ -e "$tmp2/.beam/beam-daemon.json" ]; then
  echo "expected silent non-Beam collision not to publish a registry" >&2
  cat "$tmp2/.beam/beam-daemon.json" >&2
  exit 1
fi
kill "$busy_pid" > /dev/null 2>&1 || true
wait "$busy_pid" 2>/dev/null || true
busy_pid=""
rm -f -- "$busy_port_file"
busy_port_file=""

start_slow_request "$tmp1" "shutdown-active" "shutdown-active"

# The desired owner configuration includes installed bundle paths. An ordinary attaching command
# must use the descriptor's frozen configuration without rebuilding a local desired hash. A second
# owner still computes its proposed configuration and reports the mismatch without disturbing the
# running generation.
drift_bundle_dir="$tmp2/config-drift-bundles"
mkdir -p "$drift_bundle_dir"
rsync -a "$BEAM_INSTALL_BUNDLE_DIR/" "$drift_bundle_dir/"
drift_out="$tmp1/config-drift.out"
drift_err="$tmp1/config-drift.err"
if ! BEAM_INSTALL_BUNDLE_DIR="$drift_bundle_dir" \
    "$beam_script" --root "$tmp1" ensure > "$drift_out" 2> "$drift_err"; then
  echo "expected ordinary attachment to use the owner's frozen configuration" >&2
  cat "$drift_err" >&2
  exit 1
fi
assert_json_file_field_equals \
  "frozen-configuration attachment" "$drift_out" ok true "$drift_err"
drift_owner_out="$tmp1/config-drift-owner.out"
drift_owner_err="$tmp1/config-drift-owner.err"
if BEAM_INSTALL_BUNDLE_DIR="$drift_bundle_dir" \
    "$beam_script" --root "$tmp1" ensure --hold \
      > "$drift_owner_out" 2> "$drift_owner_err"; then
  echo "expected a mismatched replacement owner to be rejected" >&2
  cat "$drift_owner_out" >&2
  exit 1
fi
if ! grep -Fq "current owner was preserved" "$drift_owner_err"; then
  echo "expected replacement-owner drift diagnostics to preserve the current owner" >&2
  cat "$drift_owner_err" >&2
  exit 1
fi
if [ -s "$drift_err" ]; then
  echo "ordinary frozen-configuration attachment produced unexpected diagnostics" >&2
  cat "$drift_out" >&2
  cat "$drift_err" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon1_id" ] || \
    [ "$(read_json_field "$registry" pid)" != "$daemon1_pid" ]; then
  echo "configuration-drift lookup changed the live daemon generation" >&2
  cat "$registry" >&2
  exit 1
fi
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null || \
    ! kill -0 "$active_request_pid" 2>/dev/null; then
  echo "configuration-drift lookup terminated the owner, daemon, or active request" >&2
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
if [ ! -e "$registry" ]; then
  echo "expected an unexpected daemon crash to preserve its exact session fence" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon2_id" ] || \
    [ "$(read_json_field "$registry" lifecycle)" != "draining" ]; then
  echo "expected an unexpected daemon crash to leave its generation draining" >&2
  cat "$registry" >&2
  exit 1
fi
if "$beam_script" --root "$tmp1" ensure --hold \
    > "$tmp1/crash-replacement.out" 2> "$tmp1/crash-replacement.err"; then
  echo "expected crash-fenced state to reject a replacement owner" >&2
  exit 1
fi
crash_recovery_json="$("$beam_script" --root "$tmp1" recover --generation "$daemon2_id")"
assert_json_field_equals "unexpected-crash recovery" "$crash_recovery_json" recovered true
if [ -e "$registry" ]; then
  echo "expected exact-generation crash recovery to quarantine the fence" >&2
  exit 1
fi

start_owner "$tmp1" "owner-draining-fence"
draining_daemon_pid="$(read_json_field "$registry" pid)"
draining_daemon_id="$(read_json_field "$registry" daemonId)"
start_slow_request "$tmp1" "draining-process-tree" "draining-process-tree"
draining_backend_pids="$(pgrep -P "$draining_daemon_pid" || true)"
if [ -z "$draining_backend_pids" ]; then
  echo "expected the active request to create a daemon-owned backend process" >&2
  exit 1
fi
kill -STOP "$draining_daemon_pid"
paused_daemon_pid="$draining_daemon_pid"
kill -INT "$hold_pid"
for _ in $(seq 1 40); do
  if [ -e "$registry" ] && [ "$(read_json_field "$registry" lifecycle)" = "draining" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -e "$registry" ] || [ "$(read_json_field "$registry" lifecycle)" != "draining" ]; then
  echo "expected an interrupted owner to retain a draining generation fence" >&2
  cat "$registry" >&2
  exit 1
fi
if ! kill -0 "$hold_pid" 2>/dev/null || ! kill -0 "$draining_daemon_pid" 2>/dev/null; then
  echo "expected the paused daemon and its owner to remain alive during the drain check" >&2
  exit 1
fi
draining_lookup_out="$tmp1/draining-lookup.out"
draining_lookup_err="$tmp1/draining-lookup.err"
if "$beam_script" --root "$tmp1" ensure > "$draining_lookup_out" 2> "$draining_lookup_err"; then
  echo "expected an ordinary command not to attach to a draining generation" >&2
  cat "$draining_lookup_out" >&2
  exit 1
fi
if ! grep -Fq "is draining" "$draining_lookup_err"; then
  echo "expected ordinary commands to report the draining generation" >&2
  cat "$draining_lookup_err" >&2
  exit 1
fi
replacement_owner_out="$tmp1/replacement-during-drain.out"
replacement_owner_err="$tmp1/replacement-during-drain.err"
if "$beam_script" --root "$tmp1" ensure --hold \
    > "$replacement_owner_out" 2> "$replacement_owner_err"; then
  echo "expected a draining generation to fence out a replacement owner" >&2
  cat "$replacement_owner_out" >&2
  exit 1
fi
if ! grep -Fq "is draining" "$replacement_owner_err"; then
  echo "expected replacement-owner rejection to identify the draining generation" >&2
  cat "$replacement_owner_err" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$draining_daemon_id" ] || \
    [ "$(read_json_field "$registry" pid)" != "$draining_daemon_pid" ]; then
  echo "replacement attempt changed the draining generation fence" >&2
  cat "$registry" >&2
  exit 1
fi
if ! wait_for_exit "$hold_pid" "owner after forced draining-fence cleanup" 300 0.05; then
  cat "$tmp1/owner-draining-fence.err" >&2
  exit 1
fi
wait "$hold_pid"
hold_pid=""
paused_daemon_pid=""
if ! wait_for_exit "$draining_daemon_pid" "daemon after forced draining-fence cleanup" 40 0.05; then
  exit 1
fi
for backend_pid in $draining_backend_pids; do
  if ! wait_for_exit "$backend_pid" "backend after forced draining-fence cleanup" 40 0.05; then
    echo "forced owner cleanup left backend pid $backend_pid alive" >&2
    exit 1
  fi
done
set +e
wait "$active_request_pid"
draining_request_status="$?"
set -e
active_request_pid=""
if [ "$draining_request_status" -eq 0 ]; then
  echo "expected the active request to fail when forced drain kills its process group" >&2
  exit 1
fi
if [ -e "$registry" ]; then
  echo "expected the draining fence to disappear only after the daemon was reaped" >&2
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
  echo "expected a command after owner loss to preserve the abnormal-session fence" >&2
  cat "$owner_loss_out" >&2
  exit 1
fi
owner_loss_generation="$(read_json_field "$registry" daemonId)"
if ! grep -Fq "recover --generation $owner_loss_generation" "$owner_loss_err"; then
  echo "expected owner-loss diagnostics to name exact-generation recovery" >&2
  cat "$owner_loss_err" >&2
  exit 1
fi
if [ ! -e "$registry" ]; then
  echo "ordinary owner-loss lookup must not mutate the stale registry" >&2
  exit 1
fi
if "$beam_script" --root "$tmp1" recover --generation wrong-generation \
    > "$tmp1/recover-wrong.out" 2> "$tmp1/recover-wrong.err"; then
  echo "expected recovery with the wrong generation to fail closed" >&2
  exit 1
fi
if [ ! -e "$registry" ]; then
  echo "wrong-generation recovery must preserve the session fence" >&2
  exit 1
fi
recover_json="$("$beam_script" --root "$tmp1" recover --generation "$owner_loss_generation")"
assert_json_field_equals "exact-generation recovery" "$recover_json" recovered true
if [ -e "$registry" ]; then
  echo "expected explicit recovery to quarantine the stale session descriptor" >&2
  exit 1
fi
quarantined_registry="$(json_text_field "$recover_json" quarantinedPath)"
if [ ! -f "$quarantined_registry" ]; then
  echo "expected explicit recovery to preserve quarantined evidence" >&2
  printf '%s\n' "$recover_json" >&2
  exit 1
fi

explicit_control="$tmp2/shared-control"
mkdir -p "$explicit_control"
"$beam_script" --root "$tmp2" --control-dir "$explicit_control" ensure --hold \
  > "$tmp2/explicit-control-owner.out" 2> "$tmp2/explicit-control-owner.err" &
hold_pid="$!"
explicit_registry="$explicit_control/beam-daemon.json"
if ! wait_for_nonempty_file "$explicit_registry" "explicit control-directory session descriptor"; then
  cat "$tmp2/explicit-control-owner.err" >&2
  exit 1
fi
explicit_stats="$("$beam_script" --root "$tmp2" --control-dir "$explicit_control" stats)"
assert_json_field_equals "explicit control-directory attachment" "$explicit_stats" ok true
if "$beam_script" --root "$tmp2" stats \
    > "$tmp2/default-control-stats.out" 2> "$tmp2/default-control-stats.err"; then
  echo "expected the default and explicit control selections to remain distinct" >&2
  exit 1
fi
if [ -e "$tmp2/.beam/beam-daemon.json" ]; then
  echo "explicit control-directory ownership must not publish a project-local descriptor" >&2
  exit 1
fi
if [ ! -f "$explicit_control/beam-daemon-startup.log" ]; then
  echo "expected explicit control-directory startup diagnostics beside the descriptor" >&2
  exit 1
fi
stop_hold_process true
if [ -e "$explicit_registry" ]; then
  echo "expected normal explicit-control teardown to remove its descriptor" >&2
  exit 1
fi

generation_registry="$tmp2/.beam/beam-daemon.json"
start_owner "$tmp2" "owner-generation"
generation_daemon_pid="$(read_json_field "$generation_registry" pid)"
generation_id="$(read_json_field "$generation_registry" daemonId)"
replacement_generation_id="$generation_id-replacement"
replacement_generation_capability="replacement-generation-capability"
python3 - "$generation_registry" "$replacement_generation_id" \
    "$replacement_generation_capability" <<'PY'
import json
import os
import sys

path, replacement_id, replacement_capability = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    entry = json.load(stream)
entry["daemonId"] = replacement_id
entry["capability"] = replacement_capability
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
if [ "$(read_json_field "$generation_registry" capability)" != \
    "$replacement_generation_capability" ]; then
  echo "expected old-owner cleanup to preserve the replacement capability" >&2
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
if [ -e "$tmp1" ]; then
  echo "owner cleanup recreated the removed project root" >&2
  exit 1
fi
