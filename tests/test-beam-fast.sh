#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

lake build \
  RunAt:shared \
  beam-cli \
  beam-daemon \
  beam-client \
  RunAtTest.Broker.StreamDedupTest \
  beam-daemon-smoke-test \
  beam-daemon-save-stream-test \
  beam-daemon-request-stream-test \
  beam-daemon-startup-handshake-test \
  > /dev/null

.lake/build/bin/beam-daemon-smoke-test > /dev/null
.lake/build/bin/beam-daemon-save-stream-test > /dev/null
.lake/build/bin/beam-daemon-request-stream-test > /dev/null
.lake/build/bin/beam-daemon-startup-handshake-test > /dev/null
