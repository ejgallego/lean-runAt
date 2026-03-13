#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
codex_skills_home="${CODEX_HOME:-$HOME/.codex}/skills"
claude_skills_home="${CLAUDE_HOME:-$HOME/.claude}/skills"
bin_home="${HOME}/.local/bin"
runat_state_dir=".runat"
install_bundles_rel="$runat_state_dir/install-bundles"
runtime_bundles_rel="$runat_state_dir/bundles"
runat_cli="$repo_root/.lake/build/bin/runAt-cli"

ensure_runat_cli() {
  if [ -x "$runat_cli" ]; then
    return 0
  fi
  echo "building runAt CLI (required for bundle prebuild)" >&2
  (
    cd "$repo_root"
    lake build runAt-cli
  )
}

prebuild_bundle() {
  local skills_home="$1"
  local toolchain="$2"
  local bundle_home="$skills_home/lean-runat/$install_bundles_rel"
  mkdir -p "$bundle_home"
  (
    cd "$repo_root"
    RUNAT_INSTALL_BUNDLE_DIR="$bundle_home" lake exe runAt-cli bundle-install "$toolchain"
  )
}

install_skills() {
  local skills_home="$1"
  mkdir -p "$skills_home/lean-runat" "$skills_home/rocq-runat"
  rsync -a "$repo_root/skills/lean-runat/" "$skills_home/lean-runat/"
  rsync -a "$repo_root/skills/rocq-runat/" "$skills_home/rocq-runat/"
}

mkdir -p "$bin_home"
install_skills "$codex_skills_home"
install_skills "$claude_skills_home"
ln -sf "$repo_root/scripts/runat" "$bin_home/runat"
ln -sf "$repo_root/scripts/runat-lean-search" "$bin_home/runat-lean-search"

if command -v elan >/dev/null 2>&1; then
  ensure_runat_cli
  repo_toolchain="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
  if [ -n "$repo_toolchain" ]; then
    echo "prebuilding runAt bundle for $repo_toolchain" >&2
    prebuild_bundle "$codex_skills_home" "$repo_toolchain"
    prebuild_bundle "$claude_skills_home" "$repo_toolchain"
  else
    echo "warning: could not determine repo lean-toolchain; skipping bundle prebuild" >&2
  fi
else
  echo "warning: elan not found on PATH; skipping bundle prebuild" >&2
fi

cat >&2 <<'EOF'
installed runAt wrapper and skills

human workflow:
  runat ensure lean
  runat lean-run-at "Foo.lean" 10 2 "exact trivial"
  # after a real edit saved to disk
  runat lean-sync "Foo.lean"
  # for a synced workspace module
  runat lean-save "MyPkg/Sub/Module.lean"
  # separate lean-run-at calls do not chain; for exact continuation use:
  runat lean-run-at-handle "Foo.lean" 10 2 "constructor"

diagnostics:
  lean-sync / lean-save / lean-close-save stream errors by default
  add +full to include warnings, info, and hints
  wrapper stderr is human-facing
  runAt-cli-client request-stream is the machine-readable surface

docs:
  see skills/lean-runat/SKILL.md for the Lean workflow contract
EOF
