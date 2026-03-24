#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd)"
primary_root="$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')"

tmp_root="$(mktemp -d /tmp/runat-codex-harness-XXXXXX)"

export RUNAT_CODEX_WORKTREE_ROOT="$tmp_root/worktrees"
task_id="test-codex-harness-$$"
task_slug="${task_id}"
worktree_path="$RUNAT_CODEX_WORKTREE_ROOT/$task_slug"
default_home="$tmp_root/default-home"
default_root="$default_home/.codex/worktrees/lean-beam"
default_task_id="test-codex-harness-default-$$"
default_task_slug="${default_task_id}"
default_worktree_path="$default_root/$default_task_slug"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/runat-codex-harness-*|/tmp/runat-validate-*/tmp/runat-codex-harness-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

remove_owned_tmp_tree() {
  local path="$1"
  expect_owned_tmp_dir "$path"
  rm -rf -- "$path"
}

cleanup() {
  if [ -d "$worktree_path" ]; then
    git worktree remove "$worktree_path" >/dev/null 2>&1 || true
  fi
  if git show-ref --verify --quiet "refs/heads/codex/$task_slug"; then
    git branch -D "codex/$task_slug" >/dev/null 2>&1 || true
  fi
  if [ -d "$default_worktree_path" ]; then
    git worktree remove "$default_worktree_path" >/dev/null 2>&1 || true
  fi
  if git show-ref --verify --quiet "refs/heads/codex/$default_task_slug"; then
    git branch -D "codex/$default_task_slug" >/dev/null 2>&1 || true
  fi
  remove_owned_tmp_tree "$tmp_root"
}
trap cleanup EXIT

session_out="$(./scripts/codex-harness.sh session start "$task_id")"
if ! printf '%s\n' "$session_out" | grep -q "$worktree_path"; then
  echo "expected session start to print the dedicated worktree path" >&2
  printf '%s\n' "$session_out" >&2
  exit 1
fi

if [ ! -d "$worktree_path/.git" ] && [ ! -f "$worktree_path/.git" ]; then
  echo "expected dedicated worktree to be created at $worktree_path" >&2
  exit 1
fi

mkdir -p "$default_home"
default_session_out="$(env -u RUNAT_CODEX_WORKTREE_ROOT HOME="$default_home" ./scripts/codex-harness.sh session start "$default_task_id")"
if ! printf '%s\n' "$default_session_out" | grep -q "$default_worktree_path"; then
  echo "expected session start without RUNAT_CODEX_WORKTREE_ROOT to use the persistent home-scoped default" >&2
  printf '%s\n' "$default_session_out" >&2
  exit 1
fi

if [ ! -d "$default_worktree_path/.git" ] && [ ! -f "$default_worktree_path/.git" ]; then
  echo "expected default dedicated worktree to be created at $default_worktree_path" >&2
  exit 1
fi

worktree_session_out="$(cd "$worktree_path" && "$repo_root/scripts/codex-session-start.sh")"
if ! printf '%s\n' "$worktree_session_out" | grep -q 'worktree discipline: dedicated task checkout'; then
  echo "expected codex-session-start inside a task worktree to report dedicated checkout status" >&2
  printf '%s\n' "$worktree_session_out" >&2
  exit 1
fi

primary_err="$tmp_root/primary.err"
if (
  cd "$primary_root"
  "$repo_root/scripts/codex-session-start.sh" >"$tmp_root/primary.out" 2>"$primary_err"
); then
  echo "expected codex-session-start in the primary checkout to fail without override" >&2
  exit 1
fi

if ! grep -q 'use ./scripts/codex-harness.sh session start <task-id> instead' "$primary_err"; then
  echo "expected primary checkout refusal to include the worktree guidance" >&2
  cat "$primary_err" >&2
  exit 1
fi

unsafe_root_err="$tmp_root/unsafe-root.err"
if RUNAT_CODEX_WORKTREE_ROOT="/" ./scripts/codex-harness.sh worktree add "unsafe-root-$$" >"$tmp_root/unsafe-root.out" 2>"$unsafe_root_err"; then
  echo "expected harness to reject / as RUNAT_CODEX_WORKTREE_ROOT" >&2
  exit 1
fi

if ! grep -q 'RUNAT_CODEX_WORKTREE_ROOT must not be /' "$unsafe_root_err"; then
  echo "expected unsafe worktree root refusal to mention / explicitly" >&2
  cat "$unsafe_root_err" >&2
  exit 1
fi
