#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

outside_root="$(mktemp -d /tmp/defensive-outside-XXXXXX)"

cleanup() {
  rm -rf -- "$outside_root"
}
trap cleanup EXIT

if ! bash scripts/validate-defensive.sh -- bash -c '
  case "$HOME" in
    /tmp/runat-validate-*/home)
      ;;
    *)
      echo "unexpected HOME inside defensive validation: $HOME" >&2
      exit 1
      ;;
  esac

  case "$CODEX_HOME" in
    /tmp/runat-validate-*/codex)
      ;;
    *)
      echo "unexpected CODEX_HOME inside defensive validation: $CODEX_HOME" >&2
      exit 1
      ;;
  esac

  case "$CLAUDE_HOME" in
    /tmp/runat-validate-*/claude)
      ;;
    *)
      echo "unexpected CLAUDE_HOME inside defensive validation: $CLAUDE_HOME" >&2
      exit 1
      ;;
  esac

  case "$TMPDIR" in
    /tmp/runat-validate-*/tmp)
      ;;
    *)
      echo "unexpected TMPDIR inside defensive validation: $TMPDIR" >&2
      exit 1
      ;;
  esac

  mkdir -p "$HOME/allowed-dir"
  rm -rf "$HOME/allowed-dir"

  rewritten_tmp="$(mktemp -d /tmp/runat-rewrite-XXXXXX)"
  case "$rewritten_tmp" in
    /tmp/runat-validate-*/tmp/runat-rewrite-*)
      ;;
    *)
      echo "expected mktemp template rewrite into validation root, got $rewritten_tmp" >&2
      exit 1
      ;;
  esac
  rm -rf "$rewritten_tmp"

  blocked_path="'"$outside_root"'"
  if rm -rf "$blocked_path" > /dev/null 2>&1; then
    echo "expected defensive validation wrapper to block rm outside the validation root" >&2
    exit 1
  fi
'; then
  echo "expected defensive validation smoke test to succeed" >&2
  exit 1
fi

if [ ! -d "$outside_root" ]; then
  echo "expected defensive validation wrapper to leave outside temp root intact" >&2
  exit 1
fi
