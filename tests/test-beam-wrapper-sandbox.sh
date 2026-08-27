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

tmp_root="$(mktemp -d /tmp/beam-wrapper-sandbox-owner-XXXXXX)"
project_root="$tmp_root/project"
control_root="$tmp_root/control"
owner_pid=""
owner_stop=""
owner_kill=""
owner_resume=""

cleanup() {
  if [ -n "$owner_pid" ]; then
    if [ -n "$owner_resume" ]; then
      touch "$owner_resume"
    fi
    if [ -n "$owner_stop" ]; then
      touch "$owner_stop"
    fi
    if ! wait_for_exit "$owner_pid" "sandbox owner cleanup" 100 0.05; then
      kill "$owner_pid" >/dev/null 2>&1 || true
    fi
    wait "$owner_pid" 2>/dev/null || true
  fi
  remove_owned_tmp_tree "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$project_root" "$control_root"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root"/

sandbox_beam() {
  bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    --chdir "$project_root" \
    -- /usr/bin/env BEAM_CONTROL_DIR="$control_root" \
      "$beam_script" --root "$project_root" "$@"
}

wait_for_registry() {
  local remaining=300
  while [ "$remaining" -gt 0 ]; do
    # Registry publication is concurrent with this traversal. Ignore transient observational
    # misses while the per-root control directory is being created.
    registry="$(find "$control_root" -name beam-daemon.json -print 2>/dev/null | sed -n '1p' || true)"
    if [ -n "$registry" ] && [ -f "$registry" ]; then
      return 0
    fi
    sleep 0.2
    remaining=$((remaining - 1))
  done
  return 1
}

assert_no_daemon_failure_incidents() {
  local label="$1"
  if find "$control_root" -path '*/daemon-failures/*.json' -print -quit | grep -q .; then
    echo "expected $label to produce no daemon failure incident" >&2
    find "$control_root" -path '*/daemon-failures/*.json' -print -exec sed -n '1,160p' {} \; >&2
    exit 1
  fi
}

assert_no_lease_artifacts() {
  local artifact
  artifact="$(find "$control_root" -type f \
    \( -name '*.lease' -o -name '*.revoked' -o -name '*retir*' \) -print -quit)"
  if [ -n "$artifact" ]; then
    echo "explicit ownership must not publish lease or retirement artifacts: $artifact" >&2
    exit 1
  fi
}

sandbox_owner() {
  local name="$1"
  local out="$tmp_root/$name.out"
  local err="$tmp_root/$name.err"
  local stop="$tmp_root/$name.stop"
  local kill_marker="$tmp_root/$name.kill"
  local pause="$tmp_root/$name.pause"
  local paused="$tmp_root/$name.paused"
  local resume="$tmp_root/$name.resume"

  bwrap --new-session --die-with-parent \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --bind /tmp /tmp \
    --proc /proc \
    --unshare-pid \
    --chdir "$project_root" \
    -- /bin/bash -lc \
      "export BEAM_CONTROL_DIR='$control_root'; \
       '$beam_script' --root '$project_root' ensure --hold >'$out' 2>'$err' & \
       wrapper_pid=\$!; \
       (paused=false; \
        while kill -0 \"\$wrapper_pid\" 2>/dev/null; do \
          if [ -f '$pause' ] && [ \"\$paused\" = false ]; then \
            kill -STOP \"\$wrapper_pid\"; paused=true; touch '$paused'; \
          fi; \
          if [ -f '$resume' ] && [ \"\$paused\" = true ]; then \
            kill -CONT \"\$wrapper_pid\"; paused=false; \
          fi; \
          if [ -f '$kill_marker' ]; then \
            [ \"\$paused\" = false ] || kill -CONT \"\$wrapper_pid\"; \
            kill -KILL \"\$wrapper_pid\"; exit 0; \
          fi; \
          if [ -f '$stop' ]; then \
            [ \"\$paused\" = false ] || kill -CONT \"\$wrapper_pid\"; \
            kill -INT \"\$wrapper_pid\"; exit 0; \
          fi; \
          sleep 0.05; \
        done) & \
       controller_pid=\$!; \
       set +e; wait \"\$wrapper_pid\" 2>/dev/null; status=\$?; set -e; \
       kill \"\$controller_pid\" 2>/dev/null || true; \
       wait \"\$controller_pid\" 2>/dev/null || true; \
       exit \"\$status\"" &

  owner_pid="$!"
  owner_stop="$stop"
  owner_kill="$kill_marker"
  owner_pause="$pause"
  owner_paused="$paused"
  owner_resume="$resume"
  owner_out="$out"
  owner_err="$err"
}

missing_out="$tmp_root/missing.out"
missing_err="$tmp_root/missing.err"
if sandbox_beam ensure >"$missing_out" 2>"$missing_err"; then
  echo "expected an ordinary sandbox command not to start an implicit daemon" >&2
  sed -n '1,160p' "$missing_out" >&2
  exit 1
fi
if ! grep -Fq "start 'lean-beam ensure --hold'" "$missing_err"; then
  echo "expected the missing-owner error to provide the ownership command" >&2
  sed -n '1,160p' "$missing_err" >&2
  exit 1
fi

sandbox_owner owner-1
if ! wait_for_registry || ! wait_for_nonempty_file "$owner_out" "sandbox owner response"; then
  echo "expected ensure --hold to publish an owned daemon" >&2
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi

daemon_id_1="$(read_json_field "$registry" daemonId)"
port_1="$(read_json_field "$registry" port)"
pid_domain_1="$(read_json_field "$registry" pidDomain 2>/dev/null || true)"
owner_pid_domain_1="$(read_json_field "$registry" ownerPidDomain 2>/dev/null || true)"
if [ -z "$pid_domain_1" ] || [ -z "$owner_pid_domain_1" ]; then
  echo "expected the registry to record daemon and owner PID domains" >&2
  sed -n '1,160p' "$registry" >&2
  exit 1
fi

doctor_out="$(sandbox_beam doctor)"
if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: live'; then
  echo "expected a separate PID namespace to observe the owned daemon endpoint" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi

ensure_json="$(sandbox_beam ensure)"
if [ "$(json_text_field "$ensure_json" ok)" != "true" ]; then
  echo "expected a separate PID namespace to attach to the owner session" >&2
  printf '%s\n' "$ensure_json" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon_id_1" ] || \
    [ "$(read_json_field "$registry" port)" != "$port_1" ]; then
  echo "ordinary commands must preserve the owner's daemon generation and endpoint" >&2
  exit 1
fi

duplicate_out="$tmp_root/duplicate.out"
duplicate_err="$tmp_root/duplicate.err"
if sandbox_beam ensure --hold >"$duplicate_out" 2>"$duplicate_err"; then
  echo "expected a second sandbox owner to be rejected" >&2
  exit 1
fi
if ! grep -Fq 'already owned' "$duplicate_err"; then
  echo "expected duplicate-owner diagnostics to identify the live owner" >&2
  sed -n '1,160p' "$duplicate_err" >&2
  exit 1
fi

# Ownership is the lifetime of the holder's inherited pipe, not a periodically renewed lease.
# Pausing the holder therefore leaves the session usable by clients in other PID namespaces.
touch "$owner_pause"
if ! wait_for_file "$owner_paused" "paused sandbox owner" 12; then
  sed -n '1,160p' "$owner_err" >&2
  exit 1
fi
sleep 3
paused_stats="$(sandbox_beam stats)"
if [ "$(json_text_field "$paused_stats" ok)" != "true" ]; then
  echo "expected the daemon to remain usable while its explicit owner is paused" >&2
  printf '%s\n' "$paused_stats" >&2
  exit 1
fi
assert_no_lease_artifacts
touch "$owner_resume"

shutdown_json="$(sandbox_beam shutdown)"
if [ "$(json_text_field "$shutdown_json" result.shutdown)" != "true" ]; then
  echo "expected explicit shutdown to close the owned sandbox session" >&2
  printf '%s\n' "$shutdown_json" >&2
  exit 1
fi
if ! wait_for_exit "$owner_pid" "sandbox owner after shutdown" 120 0.1; then
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
if ! wait "$owner_pid"; then
  echo "expected explicit shutdown to release the sandbox owner cleanly" >&2
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
owner_pid=""
if find "$control_root" -name beam-daemon.json -print -quit | grep -q .; then
  echo "expected explicit shutdown to remove the owned generation registry" >&2
  exit 1
fi

sandbox_owner owner-2
if ! wait_for_registry || ! wait_for_nonempty_file "$owner_out" "replacement sandbox owner response"; then
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
daemon_id_2="$(read_json_field "$registry" daemonId)"
if [ "$daemon_id_1" = "$daemon_id_2" ]; then
  echo "expected a replacement owner to publish a new daemon generation" >&2
  exit 1
fi

# Killing the holder closes the only write end of the inherited owner pipe. The daemon must stop
# without a heartbeat timeout. A later command in another PID namespace cannot prove that the
# foreign-domain process identities are gone, so it must preserve the registry for supervised
# recovery rather than silently treating endpoint unavailability as replacement authority.
touch "$owner_kill"
if ! wait_for_exit "$owner_pid" "killed sandbox owner" 120 0.1; then
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
set +e
wait "$owner_pid"
owner_status="$?"
set -e
owner_pid=""
if [ "$owner_status" -eq 0 ]; then
  echo "expected the deliberately killed owner wrapper to exit non-zero" >&2
  exit 1
fi
sleep 4

after_kill_out="$tmp_root/after-kill.out"
after_kill_err="$tmp_root/after-kill.err"
if sandbox_beam ensure >"$after_kill_out" 2>"$after_kill_err"; then
  echo "expected an ordinary command not to replace a dead owner implicitly" >&2
  sed -n '1,160p' "$after_kill_out" >&2
  exit 1
fi
if ! grep -Fq "recorded daemon endpoint is unavailable" "$after_kill_err"; then
  echo "expected cross-domain owner loss to fail closed on the unavailable endpoint" >&2
  sed -n '1,160p' "$after_kill_err" >&2
  exit 1
fi
if ! find "$control_root" -name beam-daemon.json -print -quit | grep -q .; then
  echo "expected ordinary cross-domain recovery to preserve the unsafe registry" >&2
  exit 1
fi

# This test harness supervised the complete bwrap owner namespace and observed its exit, so it can
# now perform the out-of-band recovery that an unsupervised client must refuse to infer.
rm -f -- "$registry"

sandbox_owner owner-3
if ! wait_for_registry || ! wait_for_nonempty_file "$owner_out" "final sandbox owner response"; then
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
final_stats="$(sandbox_beam stats)"
if [ "$(json_text_field "$final_stats" ok)" != "true" ]; then
  echo "expected a new explicit owner to restore the session" >&2
  printf '%s\n' "$final_stats" >&2
  exit 1
fi
touch "$owner_stop"
if ! wait_for_exit "$owner_pid" "interrupted sandbox owner" 120 0.1; then
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
if ! wait "$owner_pid"; then
  echo "expected SIGINT to release the final sandbox owner cleanly" >&2
  sed -n '1,200p' "$owner_err" >&2
  exit 1
fi
owner_pid=""

assert_no_lease_artifacts
assert_no_daemon_failure_incidents "the explicit sandbox ownership regressions"
