#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

bash tests/test-beam-wrapper-probe.sh
bash tests/test-beam-wrapper-runtime.sh
bash tests/test-beam-wrapper-sync-save.sh
bash tests/test-beam-wrapper-handle.sh
bash tests/test-beam-wrapper-diagnostics.sh
