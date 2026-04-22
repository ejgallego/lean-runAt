#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

beam_script=""
search_helper=""
client=""
beam_wrapper_tmp_root=""
declare -a beam_wrapper_managed_roots=()
declare -a beam_wrapper_managed_pids=()

beam_wrapper_require_bins() {
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
}

beam_wrapper_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

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

sed_in_place_portable() {
  local expr="$1"
  local path="$2"
  local tmp
  tmp="$(mktemp "${path}.sed-XXXXXX")"
  sed "$expr" "$path" >"$tmp"
  mv "$tmp" "$path"
}

wait_for_exit() {
  local pid="$1"
  local label="$2"
  local tries="${3:-60}"
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

beam_wrapper_expect_file() {
  if [ ! -f "$1" ]; then
    echo "missing expected file: $1" >&2
    exit 1
  fi
}

beam_wrapper_is_owned_path() {
  case "$1" in
    "$beam_wrapper_tmp_root"|"$beam_wrapper_tmp_root"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

beam_wrapper_remove_owned_tree() {
  local path="$1"
  if ! beam_wrapper_is_owned_path "$path"; then
    echo "refusing to touch unexpected temp path: $path" >&2
    exit 1
  fi
  rm -rf -- "$path"
}

beam_wrapper_cleanup() {
  local pid root

  for pid in "${beam_wrapper_managed_pids[@]}"; do
    kill "$pid" > /dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  done

  for root in "${beam_wrapper_managed_roots[@]}"; do
    "$beam_script" --root "$root" shutdown > /dev/null 2>&1 || true
  done

  if [ -n "${beam_wrapper_tmp_root:-}" ] && [ -d "$beam_wrapper_tmp_root" ]; then
    beam_wrapper_remove_owned_tree "$beam_wrapper_tmp_root"
  fi
}

beam_wrapper_init() {
  beam_wrapper_require_bins
  beam_wrapper_tmp_root="$(mktemp -d /tmp/beam-wrapper-suite-XXXXXX)"
  declare -ga beam_wrapper_managed_roots=()
  declare -ga beam_wrapper_managed_pids=()
  trap beam_wrapper_cleanup EXIT
}

beam_wrapper_register_root() {
  beam_wrapper_managed_roots+=("$1")
}

beam_wrapper_register_pid() {
  beam_wrapper_managed_pids+=("$1")
}

beam_wrapper_prepare_project_root() {
  local name="$1"
  local root="$beam_wrapper_tmp_root/$name"

  mkdir -p "$root"
  rsync -a tests/save_olean_project/ "$root"/
  rm -rf -- "$root/.beam"
  mkdir -p "$root/.beam"
  beam_wrapper_register_root "$root"
  printf '%s\n' "$root"
}

beam_wrapper_prepare_project_root_with_scenario_docs() {
  local name="$1"
  local root
  root="$(beam_wrapper_prepare_project_root "$name")"
  mkdir -p "$root/tests/scenario/docs"
  cp tests/scenario/docs/CommandA.lean "$root/tests/scenario/docs/CommandA.lean"
  cp tests/scenario/docs/SlowPoll.lean "$root/tests/scenario/docs/SlowPoll.lean"
  printf '%s\n' "$root"
}

beam_wrapper_mktemp_file() {
  mktemp "$beam_wrapper_tmp_root/$1-XXXXXX"
}

beam_wrapper_registry_path() {
  printf '%s\n' "$1/.beam/beam-daemon.json"
}
