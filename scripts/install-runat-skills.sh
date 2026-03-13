#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
codex_skills_home="${CODEX_HOME:-$HOME/.codex}/skills"
claude_skills_home="${CLAUDE_HOME:-$HOME/.claude}/skills"
bin_home="${HOME}/.local/bin"
install_root="${RUNAT_INSTALL_ROOT:-$HOME/.local/share/runat}"
versions_root="$install_root/versions"
current_root="$install_root/current"
state_root="$install_root/state"
install_bundles_root="$state_root/install-bundles"
runat_cli="$repo_root/.lake/build/bin/runAt-cli"
install_codex_skills=0
install_claude_skills=0
installed_skill_targets=()

runtime_root_files=(
  "RunAt.lean"
  "RunAtCli.lean"
  "lakefile.lean"
  "lakefile.toml"
  "lake-manifest.json"
  "lean-toolchain"
)

runtime_source_dirs=(
  "RunAt"
  "RunAtCli"
  "ffi"
)

runtime_build_paths=(
  "libexec/runAt-cli"
  "libexec/runAt-cli-daemon"
  "libexec/runAt-cli-client"
  "libexec/librunAt_RunAt.so"
  ".lake/packages"
)

runtime_binary_artifacts=(
  ".lake/build/bin/runAt-cli:libexec/runAt-cli"
  ".lake/build/bin/runAt-cli-daemon:libexec/runAt-cli-daemon"
  ".lake/build/bin/runAt-cli-client:libexec/runAt-cli-client"
  ".lake/build/lib/librunAt_RunAt.so:libexec/librunAt_RunAt.so"
)

runtime_wrapper_paths=(
  "bin/runat"
  "bin/runat-lean-search"
)

usage() {
  cat <<EOF
Usage:
  bash scripts/install-runat-skills.sh [--codex] [--claude] [--all-skills]

Installs the self-contained runAt runtime into:
  $install_root

Default behavior installs the runtime only. Optional flags add bundled skills:
  --codex       install bundled Lean and Rocq skills into $codex_skills_home
  --claude      install bundled Lean and Rocq skills into $claude_skills_home
  --all-skills  install bundled skills for both Codex and Claude Code
  -h, --help    show this help

Environment:
  RUNAT_INSTALL_ROOT   override the runtime install root
  CODEX_HOME           override the Codex home used by --codex
  CLAUDE_HOME          override the Claude home used by --claude

Requirements:
  elan must be on PATH so the installer can prebuild the pinned Lean bundle
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex)
      install_codex_skills=1
      ;;
    --claude)
      install_claude_skills=1
      ;;
    --all-skills)
      install_codex_skills=1
      install_claude_skills=1
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

hash_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
  elif command -v shasum >/dev/null 2>&1; then
    printf 'shasum\n'
  else
    echo "missing sha256sum or shasum for install payload hashing" >&2
    exit 1
  fi
}

hash_tree() {
  local root="$1"
  local tool
  tool="$(hash_tool)"
  if [ "$tool" = "sha256sum" ]; then
    (
      cd "$root"
      find . -type f -print | LC_ALL=C sort | while IFS= read -r rel; do
        sha256sum "$rel"
      done | sha256sum | awk '{print $1}'
    )
  else
    (
      cd "$root"
      find . -type f -print | LC_ALL=C sort | while IFS= read -r rel; do
        shasum -a 256 "$rel"
      done | shasum -a 256 | awk '{print $1}'
    )
  fi
}

ensure_runtime_artifacts() {
  if [ -x "$runat_cli" ] \
    && [ -x "$repo_root/.lake/build/bin/runAt-cli-daemon" ] \
    && [ -x "$repo_root/.lake/build/bin/runAt-cli-client" ] \
    && [ -f "$repo_root/.lake/build/lib/librunAt_RunAt.so" ]; then
    return 0
  fi
  echo "building runAt runtime artifacts" >&2
  (
    cd "$repo_root"
    lake build RunAt:shared runAt-cli runAt-cli-daemon runAt-cli-client
  )
}

json_null_or_string() {
  local value="${1-}"
  if [ -z "$value" ]; then
    printf 'null'
  else
    printf '"%s"' "$value"
  fi
}

repo_source_commit() {
  git -C "$repo_root" rev-parse HEAD 2>/dev/null || true
}

require_elan() {
  if ! command -v elan >/dev/null 2>&1; then
    echo "missing elan on PATH; runAt install requires elan to prebuild the pinned Lean bundle" >&2
    exit 1
  fi
}

require_repo_toolchain() {
  local toolchain="$1"
  if [ -z "$toolchain" ]; then
    echo "missing pinned Lean toolchain in $repo_root/lean-toolchain; refusing incomplete install" >&2
    exit 1
  fi
}

copy_if_present() {
  local src="$1"
  local dest="$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

stage_runtime_tree() {
  local dest="$1"
  local path=""
  local mapping=""
  local src_rel=""
  local dest_rel=""
  mkdir -p "$dest"
  for path in "${runtime_root_files[@]}"; do
    copy_if_present "$repo_root/$path" "$dest/$path"
  done
  for path in "${runtime_source_dirs[@]}"; do
    copy_if_present "$repo_root/$path" "$dest/$path"
  done
  for mapping in "${runtime_binary_artifacts[@]}"; do
    src_rel="${mapping%%:*}"
    dest_rel="${mapping#*:}"
    copy_if_present "$repo_root/$src_rel" "$dest/$dest_rel"
  done
  copy_if_present "$repo_root/.lake/packages" "$dest/.lake/packages"
}

write_runat_wrapper() {
  local dest="$1"
  local default_home="$2"
  local default_install_bundles="$3"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail

default_runat_home="$default_home"
default_install_bundle_dir="$default_install_bundles"
runat_home="\${RUNAT_HOME:-\$default_runat_home}"
runat_install_bundle_dir="\${RUNAT_INSTALL_BUNDLE_DIR:-\$default_install_bundle_dir}"
runat_bin="\$runat_home/libexec/runAt-cli"

if [ ! -x "\$runat_bin" ]; then
  echo "missing runAt CLI at \$runat_bin" >&2
  exit 1
fi

export RUNAT_HOME="\$runat_home"
export RUNAT_INSTALL_BUNDLE_DIR="\$runat_install_bundle_dir"
exec "\$runat_bin" "\$@"
EOF
  chmod +x "$dest"
}

write_search_helper() {
  local dest="$1"
  local default_home="$2"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail

default_runat_home="$default_home"
runat_home="\${RUNAT_HOME:-\$default_runat_home}"
runat_script="\$runat_home/bin/runat"

usage() {
  cat <<'USAGE' >&2
usage:
  runat-lean-search [runat opts...] mint <path> <line> <character> <text...>
  runat-lean-search [runat opts...] branch <path> <text...>
  runat-lean-search [runat opts...] linear <path> <text...>
  runat-lean-search [runat opts...] playout <path> <step> [step...]
  runat-lean-search [runat opts...] release <path>

notes:
  - branch, linear, playout, and release read a prior wrapper response or handle JSON from stdin
  - runat opts such as --root and --port may appear before the subcommand
USAGE
  exit 1
}

if [ ! -x "\$runat_script" ]; then
  echo "missing runat wrapper at \$runat_script" >&2
  exit 1
fi

runat_prefix=()
subcmd=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    mint|branch|linear|playout|release)
      subcmd="\$1"
      shift
      break
      ;;
    *)
      runat_prefix+=("\$1")
      shift
      ;;
  esac
done

[ -n "\$subcmd" ] || usage

case "\$subcmd" in
  mint)
    [ "\$#" -ge 4 ] || usage
    path="\$1"
    line="\$2"
    character="\$3"
    shift 3
    exec "\$runat_script" "\${runat_prefix[@]}" lean-run-at-handle "\$path" "\$line" "\$character" "\$@"
    ;;
  branch)
    [ "\$#" -ge 2 ] || usage
    path="\$1"
    shift
    exec "\$runat_script" "\${runat_prefix[@]}" lean-run-with "\$path" - "\$@"
    ;;
  linear)
    [ "\$#" -ge 2 ] || usage
    path="\$1"
    shift
    exec "\$runat_script" "\${runat_prefix[@]}" lean-run-with-linear "\$path" - "\$@"
    ;;
  release)
    [ "\$#" -eq 1 ] || usage
    path="\$1"
    exec "\$runat_script" "\${runat_prefix[@]}" lean-release "\$path" -
    ;;
  playout)
    [ "\$#" -ge 2 ] || usage
    path="\$1"
    shift
    current="\$(cat)"
    for step in "\$@"; do
      current="\$(printf '%s\n' "\$current" | "\$runat_script" "\${runat_prefix[@]}" lean-run-with-linear "\$path" - "\$step")"
    done
    printf '%s\n' "\$current"
    ;;
esac
EOF
  chmod +x "$dest"
}

stage_install_version() {
  local dest="$1"
  local default_home="$2"
  local default_install_bundles="$3"
  stage_runtime_tree "$dest"
  mkdir -p "$dest/bin"
  write_runat_wrapper "$dest/bin/runat" "$default_home" "$default_install_bundles"
  write_search_helper "$dest/bin/runat-lean-search" "$default_home"
}

write_manifest_array() {
  local dest="$1"
  local entries_name="$2"
  shift 2
  local entries=("$@")
  local idx=0
  printf '    "%s": [\n' "$entries_name" >>"$dest"
  for idx in "${!entries[@]}"; do
    if [ "$idx" -gt 0 ]; then
      printf ',\n' >>"$dest"
    fi
    printf '      "%s"' "${entries[$idx]}" >>"$dest"
  done
  printf '\n    ]' >>"$dest"
}

write_install_manifest() {
  local dest="$1"
  local payload_id="$2"
  local toolchain="$3"
  local source_commit="$4"
  cat >"$dest" <<EOF
{
  "schemaVersion": 1,
  "payloadHash": "$payload_id",
  "toolchain": "$toolchain",
  "sourceCommit": $(json_null_or_string "$source_commit"),
  "artifacts": {
EOF
  write_manifest_array "$dest" "rootFiles" "${runtime_root_files[@]}"
  cat >>"$dest" <<EOF
,
EOF
  write_manifest_array "$dest" "sourceDirs" "${runtime_source_dirs[@]}"
  cat >>"$dest" <<EOF
,
EOF
  write_manifest_array "$dest" "runtimePaths" "${runtime_build_paths[@]}"
  cat >>"$dest" <<EOF
,
EOF
  write_manifest_array "$dest" "wrapperPaths" "${runtime_wrapper_paths[@]}"
  cat >>"$dest" <<'EOF'
  }
}
EOF
}

prebuild_bundle() {
  local runtime_home="$1"
  local toolchain="$2"
  local bundle_home="$3"
  mkdir -p "$bundle_home"
  RUNAT_HOME="$runtime_home" RUNAT_INSTALL_BUNDLE_DIR="$bundle_home" \
    "$runtime_home/libexec/runAt-cli" bundle-install "$toolchain"
}

install_skills() {
  local skills_home="$1"
  mkdir -p "$skills_home/lean-runat" "$skills_home/rocq-runat"
  rsync -a "$repo_root/skills/lean-runat/" "$skills_home/lean-runat/"
  rsync -a "$repo_root/skills/rocq-runat/" "$skills_home/rocq-runat/"
}

require_elan
repo_toolchain="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
require_repo_toolchain "$repo_toolchain"

mkdir -p "$bin_home" "$versions_root" "$state_root"
ensure_runtime_artifacts

staging_root="$(mktemp -d "$install_root/.staging-XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
stage_install_version "$staging_root" "$current_root" "$install_bundles_root"
payload_id="$(hash_tree "$staging_root")"
version_root="$versions_root/$payload_id"
source_commit="$(repo_source_commit)"
write_install_manifest "$staging_root/manifest.json" "$payload_id" "$repo_toolchain" "$source_commit"
if [ ! -d "$version_root" ]; then
  mv "$staging_root" "$version_root"
else
  rm -rf "$staging_root"
fi
trap - EXIT

if [ ! -f "$version_root/manifest.json" ]; then
  write_install_manifest "$version_root/manifest.json" "$payload_id" "$repo_toolchain" "$source_commit"
fi

echo "prebuilding runAt bundle for $repo_toolchain" >&2
prebuild_bundle "$version_root" "$repo_toolchain" "$install_bundles_root"

ln -sfn "$version_root" "$current_root"
ln -sfn "$current_root/bin/runat" "$bin_home/runat"
ln -sfn "$current_root/bin/runat-lean-search" "$bin_home/runat-lean-search"

if [ "$install_codex_skills" -eq 1 ]; then
  install_skills "$codex_skills_home"
  installed_skill_targets+=("Codex: $codex_skills_home")
fi

if [ "$install_claude_skills" -eq 1 ]; then
  install_skills "$claude_skills_home"
  installed_skill_targets+=("Claude Code: $claude_skills_home")
fi

echo "installed runAt runtime" >&2
echo "  runtime root: $current_root" >&2
echo "  wrappers: $bin_home/runat, $bin_home/runat-lean-search" >&2
if [ "${#installed_skill_targets[@]}" -gt 0 ]; then
  echo "  bundled skills:" >&2
  for target in "${installed_skill_targets[@]}"; do
    echo "    $target" >&2
  done
else
  cat >&2 <<'EOF'
  bundled skills: not installed
  install Codex skills with: bash scripts/install-runat-skills.sh --codex
  install Claude Code skills with: bash scripts/install-runat-skills.sh --claude
  install both skill sets with: bash scripts/install-runat-skills.sh --all-skills
EOF
fi

cat >&2 <<'EOF'

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
