#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

primary_root="$(beam_wrapper_prepare_project_root runtime-primary)"
other_root="$(beam_wrapper_prepare_project_root runtime-other)"
signal_root="$(beam_wrapper_prepare_project_root_with_scenario_docs runtime-signal)"
busy_port_root="$(beam_wrapper_prepare_project_root runtime-busy-port)"

(
  cd "$primary_root"
  "$beam_script" ensure lean > /dev/null
)

primary_registry="$(beam_wrapper_registry_path "$primary_root")"
beam_wrapper_expect_file "$primary_registry"
pid1="$(read_json_field "$primary_registry" pid)"
port1="$(read_json_field "$primary_registry" port)"
client1="$(read_json_field "$primary_registry" clientBin 2>/dev/null || true)"
if [ -z "$client1" ]; then
  client1="$client"
fi

(
  cd "$signal_root"
  "$beam_script" --root "$signal_root" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$signal_root" ensure lean > /dev/null

  interrupt_out="$(beam_wrapper_mktemp_file interrupt-out)"
  interrupt_err="$(beam_wrapper_mktemp_file interrupt-err)"
  interrupt_status="$(python3 - "$beam_script" "$signal_root" "$interrupt_out" "$interrupt_err" <<'PY'
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
        rc = proc.wait(timeout=30.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        rc = "timeout"

print(rc)
PY
)"
  if [ "$interrupt_status" = "timeout" ]; then
    cat "$interrupt_out" >&2
    cat "$interrupt_err" >&2
    exit 1
  fi
  if [ "$interrupt_status" = "0" ]; then
    echo "expected wrapper lean-run-at SIGINT path to exit non-zero after broker cancellation" >&2
    cat "$interrupt_out" >&2
    cat "$interrupt_err" >&2
    exit 1
  fi

  interrupt_json="$(cat "$interrupt_out")"
  if [ "$(RUNAT_JSON_PAYLOAD="$interrupt_json" read_json_text_field error.code)" != "requestCancelled" ]; then
    echo "expected wrapper SIGINT path to report requestCancelled" >&2
    printf '%s\n' "$interrupt_json" >&2
    cat "$interrupt_err" >&2
    exit 1
  fi
  if ! grep -q 'requesting broker cancellation' "$interrupt_err"; then
    echo "expected wrapper SIGINT path to log broker cancellation on stderr" >&2
    cat "$interrupt_err" >&2
    exit 1
  fi
  post_interrupt_hover="$("$beam_script" --root "$signal_root" lean-hover tests/scenario/docs/CommandA.lean 0 4)"
  if [ "$(RUNAT_JSON_PAYLOAD="$post_interrupt_hover" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper SIGINT cancellation to preserve the isolated Beam daemon session" >&2
    printf '%s\n' "$post_interrupt_hover" >&2
    exit 1
  fi

  "$beam_script" --root "$signal_root" shutdown > /dev/null 2>&1 || true
)

(
  cd "$signal_root"
  "$beam_script" --root "$signal_root" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$signal_root" ensure lean > /dev/null

  duplicate_slow_out="$(beam_wrapper_mktemp_file duplicate-slow-out)"
  duplicate_slow_err="$(beam_wrapper_mktemp_file duplicate-slow-err)"
  duplicate_out="$(beam_wrapper_mktemp_file duplicate-out)"
  duplicate_err="$(beam_wrapper_mktemp_file duplicate-err)"
  BEAM_PROGRESS=1 BEAM_REQUEST_ID=wrapper-duplicate-active \
    "$beam_script" --root "$signal_root" lean-run-at tests/scenario/docs/SlowPoll.lean 25 2 "poll_sleep_cmd" \
    >"$duplicate_slow_out" 2>"$duplicate_slow_err" &
  duplicate_slow_pid=$!
  sleep 1

  if BEAM_REQUEST_ID=wrapper-duplicate-active \
      "$beam_script" --root "$signal_root" lean-hover tests/scenario/docs/CommandA.lean 0 4 \
      >"$duplicate_out" 2>"$duplicate_err"; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to fail" >&2
    cat "$duplicate_out" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi

  duplicate_json="$(cat "$duplicate_out")"
  if [ "$(RUNAT_JSON_PAYLOAD="$duplicate_json" read_json_text_field error.code)" != "invalidParams" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to report invalidParams" >&2
    printf '%s\n' "$duplicate_json" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi
  if [ "$(RUNAT_JSON_PAYLOAD="$duplicate_json" read_json_text_field clientRequestId)" != "wrapper-duplicate-active" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper response to echo clientRequestId" >&2
    printf '%s\n' "$duplicate_json" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi
  if ! grep -q "already active" "$duplicate_out"; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to explain the conflict" >&2
    cat "$duplicate_out" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi

  cancel_json="$("$beam_script" --root "$signal_root" cancel wrapper-duplicate-active)"
  if [ "$(RUNAT_JSON_PAYLOAD="$cancel_json" read_json_text_field result.cancelled)" != "true" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID cancel to report cancelled=true" >&2
    printf '%s\n' "$cancel_json" >&2
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi
  if ! wait_for_exit "$duplicate_slow_pid" "duplicate active slow wrapper request"; then
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi
  if wait "$duplicate_slow_pid"; then
    echo "expected duplicate active slow wrapper request to exit non-zero after cancellation" >&2
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi

  duplicate_slow_json="$(cat "$duplicate_slow_out")"
  if [ "$(RUNAT_JSON_PAYLOAD="$duplicate_slow_json" read_json_text_field error.code)" != "requestCancelled" ]; then
    echo "expected cancelled duplicate active slow wrapper request to report requestCancelled" >&2
    printf '%s\n' "$duplicate_slow_json" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi
  stats_out="$("$beam_script" --root "$signal_root" stats)"
  if [ "$(RUNAT_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.invalidParamsCount)" -lt 1 ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper conflict to increment invalidParamsCount" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  "$beam_script" --root "$signal_root" shutdown > /dev/null 2>&1 || true
)

(
  cd "$other_root"
  "$beam_script" ensure lean > /dev/null
)

other_registry="$(beam_wrapper_registry_path "$other_root")"
beam_wrapper_expect_file "$other_registry"
pid2="$(read_json_field "$other_registry" pid)"
port2="$(read_json_field "$other_registry" port)"
if [ "$pid1" = "$pid2" ]; then
  echo "expected distinct Beam daemon processes per project" >&2
  exit 1
fi
if [ "$port1" = "$port2" ]; then
  echo "expected distinct Beam daemon ports per project" >&2
  exit 1
fi

cross_err="$(beam_wrapper_mktemp_file cross)"
cross_req="$(beam_wrapper_mktemp_file cross-req)"
printf '{"op":"ensure","root":"%s"}\n' "$other_root" > "$cross_req"
if "$client1" --port "$port1" request - <"$cross_req" >"$cross_err" 2>&1; then
  echo "expected single-root Beam daemon to reject another project root" >&2
  cat "$cross_err" >&2
  exit 1
fi
if ! grep -q "invalidParams" "$cross_err"; then
  echo "expected cross-root Beam daemon request to fail with invalidParams" >&2
  cat "$cross_err" >&2
  exit 1
fi

(
  cd "$busy_port_root"
  "$beam_script" ensure lean > /dev/null
  warm_out="$("$beam_script" lean-run-at SaveSmoke/B.lean 0 2 "#eval bVal")"
  if [ "$(RUNAT_JSON_PAYLOAD="$warm_out" read_json_text_field ok)" != "true" ]; then
    echo "expected busy-port warmup probe to succeed before reuse check" >&2
    printf '%s\n' "$warm_out" >&2
    exit 1
  fi
)

busy_registry="$(beam_wrapper_registry_path "$busy_port_root")"
beam_wrapper_expect_file "$busy_registry"
pid5="$(read_json_field "$busy_registry" pid)"
port5="$(read_json_field "$busy_registry" port)"
busy_port=43123
if [ "$busy_port" = "$port5" ]; then
  busy_port=43124
fi

python3 -m http.server "$busy_port" >/dev/null 2>&1 &
busy_pid=$!
beam_wrapper_register_pid "$busy_pid"
sleep 1

(
  cd "$busy_port_root"
  doctor_out="$("$beam_script" doctor lean)"
  if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
    echo "expected doctor lean to report a live Beam daemon before requested-port reuse check" >&2
    printf '%s\n' "$doctor_out" >&2
    exit 1
  fi
  sed_in_place_portable 's/1/2/' SaveSmoke/B.lean
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

pid5_after="$(read_json_field "$busy_registry" pid)"
port5_after="$(read_json_field "$busy_registry" port)"
if [ "$pid5" != "$pid5_after" ] || [ "$port5" != "$port5_after" ]; then
  echo "expected requested-port lean-sync reuse to preserve the original registry entry" >&2
  exit 1
fi
if ! kill -0 "$pid5" 2>/dev/null; then
  echo "expected original Beam daemon pid $pid5 to remain alive after busy-port lean-sync reuse" >&2
  exit 1
fi

(
  cd "$primary_root"
  "$beam_script" shutdown > /dev/null
)

if [ -f "$primary_registry" ]; then
  echo "expected shutdown to remove the project Beam daemon registry" >&2
  exit 1
fi
if kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be gone after shutdown" >&2
  exit 1
fi
