#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

files=(
  scripts/*.sh
  scripts/lean-beam
  scripts/lean-beam-search
  tests/*.sh
)

shellcheck -x "${files[@]}"
