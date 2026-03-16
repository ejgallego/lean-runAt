#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v opam > /dev/null 2>&1; then
  echo "missing opam; install it first or run under ocaml/setup-ocaml" >&2
  exit 1
fi

if ! opam switch show > /dev/null 2>&1; then
  echo "missing active opam switch; run under ocaml/setup-ocaml or select a switch first" >&2
  exit 1
fi

eval "$(opam env)"

if ! opam repo list --short | grep -qx 'coq-released'; then
  opam repo add coq-released https://coq.inria.fr/opam/released
fi

opam update

opam install -y ./tests/rocq-ci.opam --deps-only
