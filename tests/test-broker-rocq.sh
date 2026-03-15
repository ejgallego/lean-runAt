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

ROCQ_LSP=""
for candidate in "_opam/bin/coq-lsp" "_opam/_opam/bin/coq-lsp"; do
  if [ -x "$candidate" ]; then
    ROCQ_LSP="$candidate"
    break
  fi
done

if [ -z "$ROCQ_LSP" ]; then
  echo "missing coq-lsp; run tests/setup-rocq-opam.sh first" >&2
  exit 1
fi

if [ -d "_opam/_opam" ]; then
  eval "$(opam env --switch=./_opam --set-switch)"
fi

echo "[broker-rocq] wrapper tests"
BEAM_ROCQ_CMD="$PWD/$ROCQ_LSP" bash tests/test-beam-wrapper-rocq.sh > /dev/null

echo "[broker-rocq] smoke test"
BEAM_ROCQ_CMD="$PWD/$ROCQ_LSP" .lake/build/bin/beam-daemon-rocq-smoke-test > /dev/null
