#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

files=(
  scripts/*.sh
  scripts/runat
  scripts/runat-lean-search
  tests/*.sh
)

shellcheck "${files[@]}"
