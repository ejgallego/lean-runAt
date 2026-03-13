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
install_notes_path="$repo_root/scripts/install-runat-skills-notes.txt"
install_codex_skills=0
install_claude_skills=0
installed_skill_targets=()

runtime_payload_spec=(
  "copy|rootFiles|RunAt.lean|RunAt.lean"
  "copy|rootFiles|RunAtCli.lean|RunAtCli.lean"
  "copy|rootFiles|lakefile.lean|lakefile.lean"
  "copy|rootFiles|lakefile.toml|lakefile.toml"
  "copy|rootFiles|lake-manifest.json|lake-manifest.json"
  "copy|rootFiles|lean-toolchain|lean-toolchain"
  "copy|sourceDirs|RunAt|RunAt"
  "copy|sourceDirs|RunAtCli|RunAtCli"
  "copy|sourceDirs|ffi|ffi"
  "copy|runtimePaths|.lake/build/bin/runAt-cli|libexec/runAt-cli"
  "copy|runtimePaths|.lake/build/bin/runAt-cli-daemon|libexec/runAt-cli-daemon"
  "copy|runtimePaths|.lake/build/bin/runAt-cli-client|libexec/runAt-cli-client"
  "copy|runtimePaths|.lake/build/lib/librunAt_RunAt.so|libexec/librunAt_RunAt.so"
  "copy|runtimePaths|.lake/packages|.lake/packages"
  "generated|wrapperPaths||bin/runat"
  "copy|wrapperPaths|scripts/runat-lean-search|bin/runat-lean-search"
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

die() {
  echo "$*" >&2
  exit 1
}

require_absolute_path() {
  local path="$1"
  local label="$2"
  if [ -z "$path" ]; then
    die "missing $label"
  fi
  case "$path" in
    /*)
      ;;
    *)
      die "$label must be an absolute path: $path"
      ;;
  esac
}

require_path_within() {
  local path="$1"
  local root="$2"
  local label="$3"
  require_absolute_path "$path" "$label"
  require_absolute_path "$root" "$label root"
  case "$path" in
    "$root"|"$root"/*)
      ;;
    *)
      die "refusing to use $label outside $root: $path"
      ;;
  esac
}

require_owned_staging_dir() {
  local path="$1"
  require_path_within "$path" "$install_root" "staging dir"
  case "$(basename "$path")" in
    .staging-*)
      ;;
    *)
      die "refusing to touch unexpected staging dir: $path"
      ;;
  esac
}

ensure_replaceable_path() {
  local path="$1"
  local root="$2"
  local label="$3"
  require_path_within "$path" "$root" "$label"
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    die "refusing to replace directory at $path"
  fi
}

remove_owned_staging_dir() {
  local path="$1"
  require_owned_staging_dir "$path"
  rm -rf -- "$path"
}

copy_repo_path_if_present() {
  local src="$1"
  local dest="$2"
  local dest_root="$3"
  require_path_within "$src" "$repo_root" "copy source"
  require_path_within "$dest" "$dest_root" "copy destination"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

move_staging_dir_into_versions() {
  local staging_dir="$1"
  local version_dir="$2"
  require_owned_staging_dir "$staging_dir"
  require_path_within "$version_dir" "$versions_root" "version dir"
  mv "$staging_dir" "$version_dir"
}

replace_symlink_atomically() {
  local target="$1"
  local link_path="$2"
  local allowed_root="$3"
  local label="$4"
  local link_dir=""
  local tmp_dir=""
  local tmp_link=""
  require_absolute_path "$target" "$label target"
  ensure_replaceable_path "$link_path" "$allowed_root" "$label"
  link_dir="$(dirname "$link_path")"
  require_path_within "$link_dir" "$allowed_root" "$label parent"
  mkdir -p "$link_dir"
  tmp_dir="$(mktemp -d "$link_dir/.link-swap-XXXXXX")"
  require_path_within "$tmp_dir" "$link_dir" "$label temp dir"
  tmp_link="$tmp_dir/link"
  ln -s "$target" "$tmp_link"
  mv -f "$tmp_link" "$link_path"
  rmdir "$tmp_dir"
}

verify_publish_targets() {
  ensure_replaceable_path "$current_root" "$install_root" "current link"
  ensure_replaceable_path "$bin_home/runat" "$bin_home" "runat wrapper link"
  ensure_replaceable_path "$bin_home/runat-lean-search" "$bin_home" "runat-lean-search link"
}

parse_args() {
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
}

validate_install_config() {
  require_absolute_path "$repo_root" "repo root"
  require_absolute_path "$bin_home" "bin home"
  require_absolute_path "$install_root" "install root"
  require_absolute_path "$install_notes_path" "install notes path"
  require_path_within "$versions_root" "$install_root" "versions root"
  require_path_within "$current_root" "$install_root" "current link"
  require_path_within "$state_root" "$install_root" "state root"
  require_path_within "$install_bundles_root" "$state_root" "install bundle root"
}

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

stage_runtime_tree() {
  local dest="$1"
  local entry=""
  local mode=""
  local manifest_group=""
  local src_rel=""
  local dest_rel=""
  mkdir -p "$dest"
  for entry in "${runtime_payload_spec[@]}"; do
    IFS='|' read -r mode manifest_group src_rel dest_rel <<< "$entry"
    case "$mode" in
      copy)
        copy_repo_path_if_present "$repo_root/$src_rel" "$dest/$dest_rel" "$dest"
        ;;
      generated)
        ;;
      *)
        die "unknown runtime payload mode: $mode"
        ;;
    esac
  done
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

stage_install_version() {
  local dest="$1"
  local default_home="$2"
  local default_install_bundles="$3"
  local entry=""
  local mode=""
  local manifest_group=""
  local src_rel=""
  local dest_rel=""
  stage_runtime_tree "$dest"
  for entry in "${runtime_payload_spec[@]}"; do
    IFS='|' read -r mode manifest_group src_rel dest_rel <<< "$entry"
    case "$mode" in
      generated)
        mkdir -p "$(dirname "$dest/$dest_rel")"
        case "$dest_rel" in
          bin/runat)
            write_runat_wrapper "$dest/$dest_rel" "$default_home" "$default_install_bundles"
            ;;
          *)
            die "unknown generated runtime payload destination: $dest_rel"
            ;;
        esac
        ;;
    esac
  done
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
  local entry=""
  local mode=""
  local manifest_group=""
  local src_rel=""
  local dest_rel=""
  local root_files=()
  local source_dirs=()
  local runtime_paths=()
  local wrapper_paths=()
  for entry in "${runtime_payload_spec[@]}"; do
    IFS='|' read -r mode manifest_group src_rel dest_rel <<< "$entry"
    case "$manifest_group" in
      rootFiles)
        root_files+=("$dest_rel")
        ;;
      sourceDirs)
        source_dirs+=("$dest_rel")
        ;;
      runtimePaths)
        runtime_paths+=("$dest_rel")
        ;;
      wrapperPaths)
        wrapper_paths+=("$dest_rel")
        ;;
      *)
        die "unknown manifest payload group: $manifest_group"
        ;;
    esac
  done
  cat >"$dest" <<EOF
{
  "schemaVersion": 1,
  "payloadHash": "$payload_id",
  "toolchain": "$toolchain",
  "sourceCommit": $(json_null_or_string "$source_commit"),
  "artifacts": {
EOF
  write_manifest_array "$dest" "rootFiles" "${root_files[@]}"
  cat >>"$dest" <<EOF
,
EOF
  write_manifest_array "$dest" "sourceDirs" "${source_dirs[@]}"
  cat >>"$dest" <<EOF
,
EOF
  write_manifest_array "$dest" "runtimePaths" "${runtime_paths[@]}"
  cat >>"$dest" <<EOF
,
EOF
  write_manifest_array "$dest" "wrapperPaths" "${wrapper_paths[@]}"
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
  require_absolute_path "$skills_home" "skills home"
  mkdir -p "$skills_home/lean-runat" "$skills_home/rocq-runat"
  rsync -a "$repo_root/skills/lean-runat/" "$skills_home/lean-runat/"
  rsync -a "$repo_root/skills/rocq-runat/" "$skills_home/rocq-runat/"
}

install_skill_target() {
  local enabled="$1"
  local label="$2"
  local skills_home="$3"
  if [ "$enabled" -ne 1 ]; then
    return 1
  fi
  install_skills "$skills_home"
  printf '%s: %s\n' "$label" "$skills_home"
}

prepare_install_environment() {
  local toolchain_name="$1"
  local -n toolchain_ref="$toolchain_name"
  require_elan
  toolchain_ref="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
  require_repo_toolchain "$toolchain_ref"
  verify_publish_targets
  mkdir -p "$bin_home" "$versions_root" "$state_root"
  ensure_runtime_artifacts
}

prepare_install_version() {
  local staging_root="$1"
  local toolchain="$2"
  local payload_name="$3"
  local version_root_name="$4"
  local source_commit_name="$5"
  local -n payload_ref="$payload_name"
  local -n version_root_ref="$version_root_name"
  local -n source_commit_ref="$source_commit_name"
  stage_install_version "$staging_root" "$current_root" "$install_bundles_root"
  payload_ref="$(hash_tree "$staging_root")"
  version_root_ref="$versions_root/$payload_ref"
  source_commit_ref="$(repo_source_commit)"
  write_install_manifest "$staging_root/manifest.json" "$payload_ref" "$toolchain" "$source_commit_ref"
  if [ ! -d "$version_root_ref" ]; then
    move_staging_dir_into_versions "$staging_root" "$version_root_ref"
  else
    remove_owned_staging_dir "$staging_root"
  fi
  if [ ! -f "$version_root_ref/manifest.json" ]; then
    write_install_manifest "$version_root_ref/manifest.json" "$payload_ref" "$toolchain" "$source_commit_ref"
  fi
}

prebuild_install_bundle() {
  local version_root="$1"
  local toolchain="$2"
  echo "prebuilding runAt bundle for $toolchain" >&2
  prebuild_bundle "$version_root" "$toolchain" "$install_bundles_root"
}

publish_runtime() {
  local version_root="$1"
  replace_symlink_atomically "$version_root" "$current_root" "$install_root" "current link"
  replace_symlink_atomically "$current_root/bin/runat" "$bin_home/runat" "$bin_home" "runat wrapper link"
  replace_symlink_atomically "$current_root/bin/runat-lean-search" "$bin_home/runat-lean-search" "$bin_home" "runat-lean-search link"
}

install_requested_skills() {
  local target=""
  if target="$(install_skill_target "$install_codex_skills" "Codex" "$codex_skills_home")"; then
    installed_skill_targets+=("$target")
  fi
  if target="$(install_skill_target "$install_claude_skills" "Claude Code" "$claude_skills_home")"; then
    installed_skill_targets+=("$target")
  fi
}

print_install_summary() {
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
}

print_post_install_notes() {
  cat "$install_notes_path" >&2
}

main() {
  local staging_root=""
  local repo_toolchain=""
  local payload_id=""
  local version_root=""
  local source_commit=""
  parse_args "$@"
  validate_install_config
  prepare_install_environment repo_toolchain

  staging_root="$(mktemp -d "$install_root/.staging-XXXXXX")"
  trap 'remove_owned_staging_dir "$staging_root"' EXIT
  prepare_install_version "$staging_root" "$repo_toolchain" payload_id version_root source_commit
  trap - EXIT

  prebuild_install_bundle "$version_root" "$repo_toolchain"
  publish_runtime "$version_root"
  install_requested_skills
  print_install_summary
  print_post_install_notes
}

main "$@"
