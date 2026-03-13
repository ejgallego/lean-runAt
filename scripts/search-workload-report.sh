#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
playouts="${1:-100}"
base_seed="${2:-20260311}"
output_path="${3:-}"

cmd=(lake exe runAt-search-workload-report "$playouts" "$base_seed")

if [ -n "$output_path" ]; then
  mkdir -p "$(dirname "$output_path")"
  (
    cd "$repo_root"
    "${cmd[@]}" | tee "$output_path"
  )
else
  (
    cd "$repo_root"
    "${cmd[@]}"
  )
fi
