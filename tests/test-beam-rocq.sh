#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-beam-rocq}"

run_step "build" lake build \
  beam-cli \
  beam-daemon \
  beam-daemon-rocq-smoke-test

eval "$(opam env)"

if ! command -v coq-lsp > /dev/null 2>&1; then
  echo "missing coq-lsp; run tests/setup-rocq-opam.sh first" >&2
  exit 1
fi

run_step "wrapper tests" bash tests/test-beam-wrapper-rocq.sh

run_step "smoke test" .lake/build/bin/beam-daemon-rocq-smoke-test
