#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

toolchain="${1:-}"
if [ -z "$toolchain" ]; then
  echo "usage: bash tests/test-toolchain-compat.sh <toolchain>" >&2
  exit 1
fi

tmp_bundle_dir="$(mktemp -d /tmp/beam-toolchain-bundles-XXXXXX)"
tmp_env_root="$(mktemp -d /tmp/beam-toolchain-env-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-toolchain-bundles-*|/tmp/beam-toolchain-env-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

cleanup() {
  expect_owned_tmp_dir "$tmp_bundle_dir"
  expect_owned_tmp_dir "$tmp_env_root"
  rm -rf -- "$tmp_bundle_dir" "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

echo "[toolchain-compat] build"
lake build beam-cli > /dev/null

echo "[toolchain-compat] bundle install $toolchain"
env -u BEAM_HOME -u BEAM_INSTALL_BUNDLE_DIR -u BEAM_CONTROL_DIR \
  HOME="$tmp_env_root/home" \
  CODEX_HOME="$tmp_env_root/codex" \
  CLAUDE_HOME="$tmp_env_root/claude" \
  BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
  ./.lake/build/bin/beam-cli bundle-install "$toolchain" > /dev/null
