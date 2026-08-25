#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage:
  scripts/pr-message.sh [--title TITLE] [--summary TEXT] [--change TEXT]...

Print the public PR title/body scaffold for this branch.

Options:
  --title TITLE    Override the PR title. Defaults to the current commit subject.
  --summary TEXT   Override the opening body paragraph. It should start with "This PR".
  --change TEXT    Add one optional behavior/review bullet. Repeat as needed.
  --base REF       Override the base branch shown in the scaffold. Defaults to main.
  --repo OWNER/REPO
                   Override the repository shown in the scaffold. Defaults to leanprover/lean-beam.
  -h, --help       Show this help.
USAGE
}

current_branch() {
  if branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
    printf '%s\n' "$branch"
  else
    git rev-parse --short HEAD
  fi
}

current_commit_subject() {
  git log -1 --pretty=%s
}

repo="leanprover/lean-beam"
base="main"
title="$(current_commit_subject)"
summary="This PR <short summary of the problem solved and useful outcome>."
changes=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)
      if [ "$#" -lt 2 ]; then
        echo "missing value for --title" >&2
        exit 2
      fi
      title="$2"
      shift 2
      ;;
    --summary)
      if [ "$#" -lt 2 ]; then
        echo "missing value for --summary" >&2
        exit 2
      fi
      summary="$2"
      shift 2
      ;;
    --change)
      if [ "$#" -lt 2 ]; then
        echo "missing value for --change" >&2
        exit 2
      fi
      changes+=("$2")
      shift 2
      ;;
    --base)
      if [ "$#" -lt 2 ]; then
        echo "missing value for --base" >&2
        exit 2
      fi
      base="$2"
      shift 2
      ;;
    --repo)
      if [ "$#" -lt 2 ]; then
        echo "missing value for --repo" >&2
        exit 2
      fi
      repo="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

branch="$(current_branch)"

printf 'repository=%s\n' "$repo"
printf 'base=%s\n' "$base"
printf 'head=%s\n' "$branch"
printf 'draft=true\n'
printf 'recommended_merge_method=squash\n'
printf 'pr_title=%s\n' "$title"
printf '\n'
printf '## Submission\n'
printf -- "- Push \`%s\` to a branch visible to \`%s\`.\n" "$branch" "$repo"
printf -- "- Open a draft PR against \`%s:%s\` using the title and body below.\n" "$repo" "$base"
printf -- '- Keep local worktree names, command transcripts, routine validation logs, and coordination notes out of the public body.\n'
printf '\n'
printf '## PR Submission Guardrails\n'
printf -- '- Use the PR title and body below as the public PR metadata; do not hand-roll a replacement from local status notes.\n'
printf -- '- Keep the title and body suitable as the final squash commit message.\n'
printf -- "- Do not add generator or tool prefixes such as \`[codex]\` to the public PR title.\n"
printf -- "- Do not add a \`Testing\` or \`Validation\` section for routine checks that CI already runs.\n"
printf -- '- Mention tests only for rare validation that CI cannot represent, and explain why that result matters to review.\n'
printf '\n'
printf '## PR Title\n'
printf '%s\n' "$title"
printf '\n'
printf '## PR Body\n'
printf '%s\n' "$summary"

if [ "${#changes[@]}" -gt 0 ]; then
  printf '\n'
  for item in ${changes[@]+"${changes[@]}"}; do
    printf -- '- %s\n' "$item"
  done
else
  printf '\n'
  printf '<Optional: one short paragraph or a few bullets with the main behavior, compatibility notes, or review-relevant risk. Avoid module-by-module implementation inventory.>\n'
fi
