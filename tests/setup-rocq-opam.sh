#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d "_opam/_opam" ]; then
  opam switch create ./_opam 4.14.2
fi

eval "$(opam env --switch=./_opam --set-switch)"

if ! opam repo list --short | grep -qx 'coq-released'; then
  opam repo add coq-released https://coq.inria.fr/opam/released
fi

opam update

opam install -y rocq-core.9.1.1 rocq-stdlib coq-lsp.0.2.5+9.1
