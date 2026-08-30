#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

. scripts/shared-lib.sh
# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-mcp-modern-sdk}"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "error: Node.js and npm are required to run the official MCP SDK test" >&2
  exit 1
fi

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [ "$node_major" -lt 20 ]; then
  echo "error: the official MCP TypeScript SDK requires Node.js 20 or newer" >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/lean-beam-mcp-modern-sdk-XXXXXX)"
sdk_root="$tmp_dir/sdk"
project_root="$tmp_dir/project"
npm_cache="${MCP_SDK_NPM_CACHE:-$tmp_dir/npm-cache}"
sdk_package="${MCP_SDK_PACKAGE:-@modelcontextprotocol/client@2.0.0}"

cleanup() {
  case "$tmp_dir" in
    /tmp/lean-beam-mcp-modern-sdk-*)
      rm -rf -- "$tmp_dir"
      ;;
    *)
      echo "refusing to clean unexpected temp dir: $tmp_dir" >&2
      ;;
  esac
}
trap cleanup EXIT

install_sdk() {
  mkdir -p "$sdk_root" "$npm_cache"
  npm_config_cache="$npm_cache" npm_config_update_notifier=false \
    npm install --prefix "$sdk_root" --no-audit --no-fund --no-save --no-package-lock "$sdk_package"
}

run_sdk_mode() {
  local mode="$1"
  node tests/mcp-modern-sdk-client.mjs \
    --sdk-root "$sdk_root" \
    --server "$(pwd)/.lake/build/bin/lean-beam-mcp" \
    --server-cwd "$(pwd)" \
    --root "$project_root" \
    --lean-cmd "$(command -v lean)" \
    --lean-plugin "$(pwd)/.lake/build/lib/$(beam_shared_lib_name beam_Beam_LSP)" \
    --mode "$mode"
}

run_step "build MCP server" lake build Beam.LSP:shared beam-daemon lean-beam-mcp
run_step "install official MCP TypeScript client" install_sdk
mkdir -p "$project_root"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root"/
run_step "official SDK automatic negotiation" run_sdk_mode auto
run_step "official SDK pinned modern negotiation" run_sdk_mode pin
