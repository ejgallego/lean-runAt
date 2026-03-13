#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

runat_script="$PWD/scripts/runat"
rocq_cmd="${RUNAT_ROCQ_CMD:-}"

if [ ! -x "$runat_script" ]; then
  echo "missing runat wrapper at $runat_script" >&2
  exit 1
fi

if [ -z "$rocq_cmd" ]; then
  echo "missing RUNAT_ROCQ_CMD for Rocq wrapper test" >&2
  exit 1
fi

tmp_repo="$(mktemp -d /tmp/runat-wrapper-rocq-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/runat-wrapper-rocq-*|/tmp/runat-validate-*/tmp/runat-wrapper-rocq-*)
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
  if [ -d "$tmp_repo/tests/rocq/Minimal" ]; then
    RUNAT_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/runat" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null 2>&1 || true
  fi
  remove_owned_tmp_tree "$tmp_repo"
}
trap cleanup EXIT

rsync -a \
  --exclude='.git/' \
  --exclude='.lake/' \
  --exclude='.runat/' \
  --exclude='_opam/' \
  "$PWD"/ "$tmp_repo"/

(
  cd "$tmp_repo"
  lake build runAt-cli > /dev/null
  if [ -x ".lake/build/bin/runAt-cli-daemon" ] || [ -x ".lake/build/bin/runAt-cli-client" ]; then
    echo "expected lake build runAt-cli not to prebuild CLI daemon helper executables" >&2
    exit 1
  fi
  RUNAT_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/runat" --root "$tmp_repo/tests/rocq/Minimal" doctor rocq > /dev/null
  if [ -x ".lake/build/bin/runAt-cli-daemon" ] || [ -x ".lake/build/bin/runAt-cli-client" ]; then
    echo "expected doctor rocq to remain read-only and not build CLI daemon helpers" >&2
    exit 1
  fi
  RUNAT_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/runat" --root "$tmp_repo/tests/rocq/Minimal" ensure rocq > /dev/null
  if [ ! -x ".lake/build/bin/runAt-cli-daemon" ] || [ ! -x ".lake/build/bin/runAt-cli-client" ]; then
    echo "expected rocq CLI startup to build missing CLI daemon helpers on demand" >&2
    exit 1
  fi
  RUNAT_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/runat" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null
)
