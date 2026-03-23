#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

beam_shared_lib_ext() {
  case "$(uname -s)" in
    Darwin)
      printf 'dylib\n'
      ;;
    CYGWIN*|MINGW*|MSYS*|Windows_NT)
      printf 'dll\n'
      ;;
    *)
      printf 'so\n'
      ;;
  esac
}

beam_shared_lib_name() {
  local base="$1"
  local ext
  ext="$(beam_shared_lib_ext)"
  case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*|Windows_NT)
      printf '%s.%s\n' "$base" "$ext"
      ;;
    *)
      printf 'lib%s.%s\n' "$base" "$ext"
      ;;
  esac
}
