#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh
# shellcheck source=tests/lib/wait.sh
. tests/lib/wait.sh

beam_script="$PWD/scripts/lean-beam"
rocq_cmd="${BEAM_ROCQ_CMD:-}"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi

if [ -z "$rocq_cmd" ] && ! command -v coq-lsp > /dev/null 2>&1; then
  echo "missing coq-lsp; set BEAM_ROCQ_CMD or install it in PATH" >&2
  exit 1
fi

tmp_repo="$(mktemp -d /tmp/beam-wrapper-rocq-XXXXXX)"

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-wrapper-rocq
}

remove_owned_tmp_tree() {
  local path="$1"
  beam_test_remove_owned_tmp_tree "$path" beam-wrapper-rocq
}

cleanup() {
  if [ -d "$tmp_repo/tests/rocq/Minimal" ]; then
    if [ -n "$rocq_cmd" ]; then
      BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null 2>&1 || true
    else
      "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null 2>&1 || true
    fi
  fi
  remove_owned_tmp_tree "$tmp_repo"
}
trap cleanup EXIT

rsync -a \
  --exclude='.git/' \
  --exclude='.lake/' \
  --exclude='.beam/' \
  --exclude='_opam/' \
  "$PWD"/ "$tmp_repo"/

(
  cd "$tmp_repo"
  lake build beam-cli > /dev/null
  if [ -x ".lake/build/bin/beam-daemon" ] || [ -x ".lake/build/bin/beam-client" ]; then
    echo "expected lake build beam-cli not to prebuild Beam daemon helper executables" >&2
    exit 1
  fi
  if [ -n "$rocq_cmd" ]; then
    BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" doctor rocq > /dev/null
  else
    "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" doctor rocq > /dev/null
  fi
  if [ -x ".lake/build/bin/beam-daemon" ] || [ -x ".lake/build/bin/beam-client" ]; then
    echo "expected doctor rocq to remain read-only and not build Beam daemon helpers" >&2
    exit 1
  fi
  rocq_owner_err="$tmp_repo/rocq-owner.err"
  if [ -n "$rocq_cmd" ]; then
    BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" ensure rocq --hold \
      > /dev/null 2>"$rocq_owner_err" &
  else
    "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" ensure rocq --hold \
      > /dev/null 2>"$rocq_owner_err" &
  fi
  rocq_owner_pid="$!"
  if ! wait_for_file_text "$rocq_owner_err" "owning Beam session" "Rocq session owner" 600 0.1; then
    exit 1
  fi
  if [ ! -x ".lake/build/bin/beam-daemon" ] || [ ! -x ".lake/build/bin/beam-client" ]; then
    echo "expected rocq CLI startup to build missing Beam daemon helpers on demand" >&2
    exit 1
  fi
  if [ -n "$rocq_cmd" ]; then
    BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null
  else
    "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null
  fi
  wait_for_exit "$rocq_owner_pid" "Rocq session owner" 120 0.1
  wait "$rocq_owner_pid"
)
