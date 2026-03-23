#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_root/scripts/shared-lib.sh"
codex_skills_home="${CODEX_HOME:-$HOME/.codex}/skills"
claude_skills_home="${CLAUDE_HOME:-$HOME/.claude}/skills"
bin_home="${HOME}/.local/bin"
install_root="${BEAM_INSTALL_ROOT:-$HOME/.local/share/beam}"
versions_root="$install_root/versions"
current_root="$install_root/current"
state_root="$install_root/state"
install_bundles_root="$state_root/install-bundles"
beam_cli="$repo_root/.lake/build/bin/beam-cli"
install_notes_path="$repo_root/scripts/install-beam-notes.txt"
installer_cmd="./scripts/install-beam.sh"
install_codex_skills=0
install_claude_skills=0
install_all_supported=0
requested_toolchains=()
installed_skill_targets=()
style_reset=""
style_bold=""
style_green=""
style_blue=""
style_yellow=""
style_dim=""
runat_plugin_shared_lib="$(beam_shared_lib_name runAt_RunAt)"

runtime_payload_spec=(
  "copy|rootFiles|RunAt.lean|RunAt.lean"
  "copy|rootFiles|Beam.lean|Beam.lean"
  "copy|rootFiles|lakefile.lean|lakefile.lean"
  "copy|rootFiles|lakefile.toml|lakefile.toml"
  "copy|rootFiles|lake-manifest.json|lake-manifest.json"
  "copy|rootFiles|lean-toolchain|lean-toolchain"
  "copy|rootFiles|supported-lean-toolchains|supported-lean-toolchains"
  "copy|sourceDirs|RunAt|RunAt"
  "copy|sourceDirs|Beam|Beam"
  "copy|sourceDirs|ffi|ffi"
  "copy|runtimePaths|.lake/build/bin/beam-cli|libexec/beam-cli"
  "copy|runtimePaths|.lake/build/bin/beam-daemon|libexec/beam-daemon"
  "copy|runtimePaths|.lake/build/bin/beam-client|libexec/beam-client"
  "copy|runtimePaths|.lake/build/lib/$runat_plugin_shared_lib|libexec/$runat_plugin_shared_lib"
  "copy|runtimePaths|.lake/packages|.lake/packages"
  "copy|wrapperPaths|scripts/lean-beam|bin/lean-beam"
  "copy|wrapperPaths|scripts/lean-beam-search|bin/lean-beam-search"
)

usage() {
  cat <<EOF
Usage:
  $installer_cmd [--toolchain TOOLCHAIN ... | --all-supported] [--codex] [--claude] [--all-skills]

Installs the local beam command wrappers and self-contained runtime under:
  $install_root

With no flags, this installs:
  - $bin_home/lean-beam
  - $bin_home/lean-beam-search
  - one prebuilt toolchain build for the repo-pinned Lean toolchain

With no agent flags, this does not install Codex or Claude Code skills.

Optional flags:
  --toolchain    prebuild one supported Lean toolchain; may be repeated
  --all-supported
                prebuild every supported Lean toolchain
  --codex       install bundled Lean and Rocq skills into $codex_skills_home
  --claude      install bundled Lean and Rocq skills into $claude_skills_home
  --all-skills  install bundled skills for both Codex and Claude Code
  -h, --help    show this help

Environment:
  BEAM_INSTALL_ROOT   override the runtime install root
  CODEX_HOME           override the Codex home used by --codex
  CLAUDE_HOME          override the Claude home used by --claude

Requirements:
  elan must be on PATH so the installer can prebuild the selected Lean bundle(s)
EOF
}

setup_styles() {
  if [ -t 2 ] && [ "${TERM:-}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    style_reset=$'\033[0m'
    style_bold=$'\033[1m'
    style_green=$'\033[32m'
    style_blue=$'\033[34m'
    style_yellow=$'\033[33m'
    style_dim=$'\033[2m'
  fi
}

print_section() {
  local color="$1"
  local title="$2"
  printf '\n%s%s%s%s\n' "$style_bold" "$color" "$title" "$style_reset" >&2
}

print_field() {
  local label="$1"
  local value="$2"
  printf '  %s%-18s%s %s\n' "$style_dim" "$label" "$style_reset" "$value" >&2
}

path_contains_dir() {
  local dir="$1"
  case ":${PATH:-}:" in
    *":$dir:"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
  rm -f -- "$link_path"
  mv "$tmp_link" "$link_path"
  rmdir "$tmp_dir"
}

verify_publish_targets() {
  ensure_replaceable_path "$current_root" "$install_root" "current link"
  ensure_replaceable_path "$bin_home/lean-beam" "$bin_home" "lean-beam wrapper link"
  ensure_replaceable_path "$bin_home/lean-beam-search" "$bin_home" "lean-beam-search link"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --toolchain)
        if [ "$#" -lt 2 ]; then
          die "missing value for --toolchain"
        fi
        requested_toolchains+=("$2")
        shift
        ;;
      --all-supported)
        install_all_supported=1
        ;;
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

read_supported_toolchains() {
  "$beam_cli" supported-toolchains lean
}

array_contains() {
  local needle="$1"
  shift
  local value=""
  for value in "$@"; do
    if [ "$value" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

resolve_install_toolchains() {
  local repo_toolchain="$1"
  local supported_toolchains=()
  local selected=()
  local toolchain=""

  if [ "$install_all_supported" -eq 1 ] && [ "${#requested_toolchains[@]}" -gt 0 ]; then
    die "cannot combine --all-supported with --toolchain"
  fi

  mapfile -t supported_toolchains < <(read_supported_toolchains)
  if [ "${#supported_toolchains[@]}" -eq 0 ]; then
    die "beam CLI reported no supported Lean toolchains"
  fi

  if [ "$install_all_supported" -eq 1 ]; then
    selected=("${supported_toolchains[@]}")
  elif [ "${#requested_toolchains[@]}" -gt 0 ]; then
    for toolchain in "${requested_toolchains[@]}"; do
      if ! array_contains "$toolchain" "${supported_toolchains[@]}"; then
        die "unsupported Lean toolchain requested for install: $toolchain"
      fi
      if ! array_contains "$toolchain" "${selected[@]}"; then
        selected+=("$toolchain")
      fi
    done
  else
    if ! array_contains "$repo_toolchain" "${supported_toolchains[@]}"; then
      die "pinned Lean toolchain is not in supported-lean-toolchains: $repo_toolchain"
    fi
    selected=("$repo_toolchain")
  fi

  printf '%s\n' "${selected[@]}"
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
  if [ -x "$beam_cli" ] \
    && [ -x "$repo_root/.lake/build/bin/beam-daemon" ] \
    && [ -x "$repo_root/.lake/build/bin/beam-client" ] \
    && [ -f "$repo_root/.lake/build/lib/$runat_plugin_shared_lib" ]; then
    return 0
  fi
  echo "building beam runtime artifacts" >&2
  (
    cd "$repo_root"
    lake build RunAt:shared beam-cli beam-daemon beam-client
  )
}

repo_source_commit() {
  git -C "$repo_root" rev-parse HEAD 2>/dev/null || true
}

require_elan() {
  if ! command -v elan >/dev/null 2>&1; then
    echo "missing elan on PATH; beam install requires elan to prebuild the pinned Lean bundle" >&2
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
  local src_rel=""
  local dest_rel=""
  mkdir -p "$dest"
  for entry in "${runtime_payload_spec[@]}"; do
    IFS='|' read -r mode _ src_rel dest_rel <<< "$entry"
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

stage_install_version() {
  local dest="$1"
  stage_runtime_tree "$dest"
}

write_install_manifest() {
  local dest="$1"
  local payload_id="$2"
  local source_commit="$3"
  local toolchains_name="$4"
  local -n toolchains_ref="$toolchains_name"
  local source_commit_arg="-"
  if [ -n "$source_commit" ]; then
    source_commit_arg="$source_commit"
  fi
  "$beam_cli" install-manifest "$payload_id" "$source_commit_arg" "${toolchains_ref[@]}" >"$dest"
}

prebuild_bundle() {
  local runtime_home="$1"
  local toolchain="$2"
  local bundle_home="$3"
  mkdir -p "$bundle_home"
  BEAM_HOME="$runtime_home" BEAM_INSTALL_BUNDLE_DIR="$bundle_home" \
    "$runtime_home/libexec/beam-cli" bundle-install "$toolchain"
}

install_skills() {
  local skills_home="$1"
  require_absolute_path "$skills_home" "skills home"
  mkdir -p "$skills_home/lean-beam" "$skills_home/rocq-beam"
  rsync -a "$repo_root/skills/lean-beam/" "$skills_home/lean-beam/"
  rsync -a "$repo_root/skills/rocq-beam/" "$skills_home/rocq-beam/"
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
  local selected_name="$2"
  local -n toolchain_ref="$toolchain_name"
  local -n selected_toolchains_ref="$selected_name"
  local resolved_toolchains=""
  require_elan
  toolchain_ref="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
  require_repo_toolchain "$toolchain_ref"
  ensure_runtime_artifacts
  resolved_toolchains="$(resolve_install_toolchains "$toolchain_ref")"
  # shellcheck disable=SC2034
  if [ -n "$resolved_toolchains" ]; then
    mapfile -t selected_toolchains_ref <<< "$resolved_toolchains"
  else
    selected_toolchains_ref=()
  fi
  verify_publish_targets
  mkdir -p "$bin_home" "$versions_root" "$state_root"
}

prepare_install_version() {
  local staging_root="$1"
  local toolchains_name="$2"
  local payload_name="$3"
  local version_root_name="$4"
  local source_commit_name="$5"
  local -n toolchains_ref="$toolchains_name"
  local -n payload_ref="$payload_name"
  local -n version_root_ref="$version_root_name"
  local -n source_commit_ref="$source_commit_name"
  stage_install_version "$staging_root"
  payload_ref="$(hash_tree "$staging_root")"
  version_root_ref="$versions_root/$payload_ref"
  source_commit_ref="$(repo_source_commit)"
  write_install_manifest "$staging_root/manifest.json" "$payload_ref" "$source_commit_ref" "$toolchains_name"
  if [ ! -d "$version_root_ref" ]; then
    move_staging_dir_into_versions "$staging_root" "$version_root_ref"
  else
    remove_owned_staging_dir "$staging_root"
  fi
  if [ ! -f "$version_root_ref/manifest.json" ]; then
    write_install_manifest "$version_root_ref/manifest.json" "$payload_ref" "$source_commit_ref" "$toolchains_name"
  fi
}

prebuild_install_bundles() {
  local version_root="$1"
  shift
  local toolchain=""
  for toolchain in "$@"; do
    echo "prebuilding beam bundle for $toolchain" >&2
    prebuild_bundle "$version_root" "$toolchain" "$install_bundles_root"
  done
}

publish_runtime() {
  local version_root="$1"
  replace_symlink_atomically "$version_root" "$current_root" "$install_root" "current link"
  replace_symlink_atomically "$current_root/bin/lean-beam" "$bin_home/lean-beam" "$bin_home" "lean-beam wrapper link"
  replace_symlink_atomically "$current_root/bin/lean-beam-search" "$bin_home/lean-beam-search" "$bin_home" "lean-beam-search link"
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
  local version_root="$1"
  shift
  local toolchain=""
  local codex_status="not installed"
  local claude_status="not installed"
  local path_status="$bin_home is not on PATH yet"

  if path_contains_dir "$bin_home"; then
    path_status="ready for direct \`lean-beam\` use in this shell"
  fi
  for toolchain in "${installed_skill_targets[@]}"; do
    case "$toolchain" in
      Codex:*)
        codex_status="installed at ${toolchain#Codex: }"
        ;;
      "Claude Code:"*)
        claude_status="installed at ${toolchain#Claude Code: }"
        ;;
    esac
  done

  print_section "$style_green" "Install Complete"
  print_field "lean-beam" "$bin_home/lean-beam"
  print_field "lean search helper" "$bin_home/lean-beam-search"
  print_field "active install" "$current_root"
  print_field "versioned install" "$version_root"
  print_field "Lean toolchain store" "$install_bundles_root"
  if [ "$#" -gt 0 ]; then
    print_field "prebuilt toolchains" "$1"
    shift
    for toolchain in "$@"; do
      printf '  %s%-18s%s %s\n' "$style_dim" "" "$style_reset" "$toolchain" >&2
    done
  else
    print_field "prebuilt toolchains" "none"
  fi
  print_field "shell PATH" "$path_status"

  print_section "$style_blue" "Agent Skills"
  print_field "Codex skill" "$codex_status"
  print_field "Claude skill" "$claude_status"
  if [ "$codex_status" = "not installed" ] && [ "$claude_status" = "not installed" ]; then
    print_field "note" "the base install does not add agent skills unless you request them"
  fi

  print_section "$style_yellow" "Optional Next Steps"
  if [ "$codex_status" = "not installed" ]; then
    print_field "Codex" "$installer_cmd --codex"
  fi
  if [ "$claude_status" = "not installed" ]; then
    print_field "Claude Code" "$installer_cmd --claude"
  fi
  if [ "$codex_status" = "not installed" ] || [ "$claude_status" = "not installed" ]; then
    print_field "both skills" "$installer_cmd --all-skills"
  fi
}

print_post_install_notes() {
  print_section "$style_blue" "Try It"
  cat "$install_notes_path" >&2
}

main() {
  local staging_root=""
  local repo_toolchain=""
  local selected_toolchains=()
  local payload_id=""
  local version_root=""
  local source_commit=""
  setup_styles
  parse_args "$@"
  validate_install_config
  prepare_install_environment repo_toolchain selected_toolchains

  staging_root="$(mktemp -d "$install_root/.staging-XXXXXX")"
  trap 'remove_owned_staging_dir "$staging_root"' EXIT
  prepare_install_version "$staging_root" selected_toolchains payload_id version_root source_commit
  trap - EXIT

  prebuild_install_bundles "$version_root" "${selected_toolchains[@]}"
  publish_runtime "$version_root"
  install_requested_skills
  print_install_summary "$version_root" "${selected_toolchains[@]}"
  print_post_install_notes
}

main "$@"
