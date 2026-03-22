#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

tmp_bundle_dir="$(mktemp -d /tmp/beam-daemon-bundles-XXXXXX)"
tmp_env_root="$(mktemp -d /tmp/beam-daemon-env-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-daemon-bundles-*|/tmp/beam-daemon-env-*|/tmp/runat-validate-*/tmp/beam-daemon-bundles-*|/tmp/runat-validate-*/tmp/beam-daemon-env-*)
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
  remove_owned_tmp_tree "$tmp_bundle_dir"
  remove_owned_tmp_tree "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"

echo "[broker-slow] shell lint"
bash scripts/lint-shell.sh > /dev/null

echo "[broker-slow] build"
lake build \
  RunAt:shared \
  beam-cli \
  beam-daemon \
  beam-client \
  > /dev/null

echo "[broker-slow] bundle install"
BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" ./.lake/build/bin/beam-cli bundle-install "$toolchain" > /dev/null

echo "[broker-slow] wrapper tests"
HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" bash tests/test-beam-wrapper.sh > /dev/null

echo "[broker-slow] save replay tests"
HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" bash tests/test-broker-save-olean.sh > /dev/null
