#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

echo "[broker-rocq] build"
lake build \
  beam-cli \
  beam-daemon \
  beam-client \
  beam-daemon-rocq-smoke-test \
  > /dev/null

eval "$(opam env)"

if ! command -v coq-lsp > /dev/null 2>&1; then
  echo "missing coq-lsp; run tests/setup-rocq-opam.sh first" >&2
  exit 1
fi

echo "[broker-rocq] wrapper tests"
bash tests/test-beam-wrapper-rocq.sh > /dev/null

echo "[broker-rocq] smoke test"
.lake/build/bin/beam-daemon-rocq-smoke-test > /dev/null
