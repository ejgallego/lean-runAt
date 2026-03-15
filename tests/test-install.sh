#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

tmp_root="$(mktemp -d /tmp/runat-install-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/runat-install-*|/tmp/runat-validate-*/tmp/runat-install-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

expect_path_within_tmp_root() {
  local path="$1"
  case "$path" in
    "$tmp_root"|"$tmp_root"/*)
      ;;
    *)
      echo "refusing to touch path outside test temp root $tmp_root: $path" >&2
      exit 1
      ;;
  esac
}

remove_tmp_tree() {
  local path="$1"
  expect_path_within_tmp_root "$path"
  rm -rf -- "$path"
}

remove_tmp_file() {
  local path="$1"
  expect_path_within_tmp_root "$path"
  rm -f -- "$path"
}

cleanup() {
  expect_owned_tmp_dir "$tmp_root"
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

export HOME="$tmp_root/home"
export CODEX_HOME="$tmp_root/codex"
export CLAUDE_HOME="$tmp_root/claude"
export BEAM_INSTALL_ROOT="$tmp_root/install-root"

mkdir -p "$HOME" "$BEAM_INSTALL_ROOT"

mapfile -t supported_toolchains < <(grep -v '^[[:space:]]*#' supported-lean-toolchains | sed '/^[[:space:]]*$/d')
toolchain="${supported_toolchains[0]}"
source_checkout="$tmp_root/source-checkout"

assert_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "missing file: $path" >&2
    exit 1
  fi
}

assert_not_exists() {
  local path="$1"
  if [ -e "$path" ]; then
    echo "expected path to be absent: $path" >&2
    exit 1
  fi
}

assert_no_skill_socket_guidance() {
  local skill_doc="$1"
  if rg -n -- '--socket|Unix domain socket|unix domain socket' "$skill_doc" > /dev/null; then
    echo "unexpected socket guidance in installed skill: $skill_doc" >&2
    exit 1
  fi
}

assert_symlink_target() {
  local path="$1"
  local expected="$2"
  local actual resolved_expected
  actual="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path")"
  resolved_expected="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$expected")"
  if [ "$actual" != "$resolved_expected" ]; then
    echo "unexpected symlink target for $path: expected $resolved_expected, got $actual" >&2
    exit 1
  fi
}

assert_runtime_layout() {
  local runtime_root="$1"
  assert_file "$runtime_root/Beam.lean"
  assert_file "$runtime_root/Beam/Broker/Server.lean"
  assert_file "$runtime_root/RunAt/Internal/SaveArtifacts.lean"
  assert_file "$runtime_root/supported-lean-toolchains"
  assert_file "$runtime_root/libexec/beam-cli"
  assert_file "$runtime_root/libexec/beam-daemon"
  assert_file "$runtime_root/libexec/beam-client"
  assert_file "$runtime_root/libexec/librunAt_RunAt.so"
  assert_not_exists "$runtime_root/.lake/build"
  assert_file "$runtime_root/bin/lean-beam"
  assert_file "$runtime_root/bin/lean-beam-search"
  assert_not_exists "$runtime_root/bin/beam"
  assert_not_exists "$runtime_root/bin/beam-lean-search"
}

assert_manifest_metadata() {
  local manifest_path="$1"
  local expected_payload="$2"
  local expected_source_commit="$3"
  shift 3
  python3 - "$manifest_path" "$expected_payload" "$expected_source_commit" "$@" <<'PY'
import json
import os
import sys

manifest_path, expected_payload, expected_source_commit, *expected_toolchains = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)
layout = json.loads(os.environ["BEAM_INSTALL_LAYOUT_JSON"])

if manifest.get("schemaVersion") != 2:
    raise SystemExit(f"unexpected manifest schemaVersion: {manifest.get('schemaVersion')}")
if manifest.get("payloadHash") != expected_payload:
    raise SystemExit(f"unexpected manifest payloadHash: {manifest.get('payloadHash')}")
if manifest.get("toolchains") != expected_toolchains:
    raise SystemExit(f"unexpected manifest toolchains: {manifest.get('toolchains')}")
if "toolchain" in manifest:
    raise SystemExit(f"unexpected legacy manifest toolchain field: {manifest.get('toolchain')}")
actual_source_commit = manifest.get("sourceCommit", None)
if expected_source_commit:
    if actual_source_commit != expected_source_commit:
        raise SystemExit(f"unexpected manifest sourceCommit: {actual_source_commit}")
else:
    if actual_source_commit is not None:
        raise SystemExit(f"expected manifest sourceCommit to be null or absent in non-git install copy: {actual_source_commit}")

artifacts = manifest.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("manifest artifacts payload is missing")

root_files = artifacts.get("rootFiles")
source_dirs = artifacts.get("sourceDirs")
runtime_paths = artifacts.get("runtimePaths")
wrapper_paths = artifacts.get("wrapperPaths")

expected_root_files = set(layout.get("rootFiles") or [])
expected_source_dirs = set(layout.get("sourceDirs") or [])
expected_runtime_paths = set(layout.get("runtimePaths") or [])
expected_wrapper_paths = set(layout.get("wrapperPaths") or [])

if set(root_files or []) != expected_root_files:
    raise SystemExit(f"unexpected manifest rootFiles: {root_files}")
if set(source_dirs or []) != expected_source_dirs:
    raise SystemExit(f"unexpected manifest sourceDirs: {source_dirs}")
if set(runtime_paths or []) != expected_runtime_paths:
    raise SystemExit(f"unexpected manifest runtimePaths: {runtime_paths}")
if set(wrapper_paths or []) != expected_wrapper_paths:
    raise SystemExit(f"unexpected manifest wrapperPaths: {wrapper_paths}")
PY
}

assert_version_count() {
  local versions_root="$1"
  local expected="$2"
  local actual
  if [ -d "$versions_root" ]; then
    actual="$(find "$versions_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  else
    actual="0"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "expected $expected installed runtime version(s) under $versions_root, got $actual" >&2
    exit 1
  fi
}

path_without_elan() {
  local old_ifs="$IFS"
  local dir=""
  local filtered=()
  IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || dir="."
    if [ -x "$dir/elan" ]; then
      continue
    fi
    filtered+=("$dir")
  done
  IFS="$old_ifs"
  (
    IFS=':'
    printf '%s' "${filtered[*]}"
  )
}

assert_bundle_layout() {
  local bundle_root="$1"
  shift
  local metadata_files=()
  local metadata=""
  local expected_toolchain=""
  local found=""
  mapfile -t metadata_files < <(find "$bundle_root" -name metadata.json | sort)
  if [ "${#metadata_files[@]}" -eq 0 ]; then
    echo "missing bundle metadata under $bundle_root" >&2
    exit 1
  fi
  for expected_toolchain in "$@"; do
    found=""
    for metadata in "${metadata_files[@]}"; do
      if command -v rg >/dev/null 2>&1; then
        if rg -n --fixed-strings "\"toolchain\": \"$expected_toolchain\"" "$metadata" > /dev/null; then
          found="$metadata"
          break
        fi
      elif grep -F "\"toolchain\": \"$expected_toolchain\"" "$metadata" > /dev/null; then
        found="$metadata"
        break
      fi
    done
    if [ -z "$found" ]; then
      echo "bundle metadata does not mention expected toolchain $expected_toolchain under $bundle_root" >&2
      exit 1
    fi
    local workspace
    workspace="$(dirname "$found")/workspace"
    assert_file "$workspace/Beam.lean"
    assert_file "$workspace/Beam/Broker/Server.lean"
    assert_file "$workspace/RunAt/Internal/SaveArtifacts.lean"
    assert_file "$workspace/.lake/build/bin/beam-daemon"
    assert_file "$workspace/.lake/build/bin/beam-client"
    assert_file "$workspace/.lake/build/lib/librunAt_RunAt.so"
  done
}

rsync -a --exclude='.git' ./ "$source_checkout"/
path_no_elan="$(path_without_elan)"
if PATH="$path_no_elan" command -v elan >/dev/null 2>&1; then
  echo "failed to construct a PATH without elan for the negative install test" >&2
  exit 1
fi
missing_elan_err="$(mktemp "$tmp_root/install-missing-elan-XXXXXX")"
if (
  cd "$source_checkout"
  PATH="$path_no_elan" bash scripts/install-beam.sh > /dev/null 2>"$missing_elan_err"
); then
  echo "expected install to fail when elan is missing from PATH" >&2
  cat "$missing_elan_err" >&2
  remove_tmp_file "$missing_elan_err"
  exit 1
fi
if ! grep -q 'missing elan on PATH' "$missing_elan_err"; then
  echo "expected missing-elan install failure to explain the prebuild requirement" >&2
  cat "$missing_elan_err" >&2
  remove_tmp_file "$missing_elan_err"
  exit 1
fi
remove_tmp_file "$missing_elan_err"
assert_not_exists "$HOME/.local"
assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$BEAM_INSTALL_ROOT/current"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 0
assert_not_exists "$BEAM_INSTALL_ROOT/state"

relative_root_err="$(mktemp "$tmp_root/install-relative-root-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_INSTALL_ROOT="relative/install-root" bash scripts/install-beam.sh > /dev/null 2>"$relative_root_err"
); then
  echo "expected install to fail when BEAM_INSTALL_ROOT is relative" >&2
  cat "$relative_root_err" >&2
  remove_tmp_file "$relative_root_err"
  exit 1
fi
if ! grep -q 'install root must be an absolute path' "$relative_root_err"; then
  echo "expected relative install root failure to explain the absolute-path requirement" >&2
  cat "$relative_root_err" >&2
  remove_tmp_file "$relative_root_err"
  exit 1
fi
remove_tmp_file "$relative_root_err"
assert_not_exists "$source_checkout/relative"

unsupported_install_err="$(mktemp "$tmp_root/install-unsupported-toolchain-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --toolchain leanprover/lean4:v4.26.0 > /dev/null 2>"$unsupported_install_err"
); then
  echo "expected install to fail when an unsupported toolchain is requested explicitly" >&2
  cat "$unsupported_install_err" >&2
  remove_tmp_file "$unsupported_install_err"
  exit 1
fi
if ! grep -q 'unsupported Lean toolchain requested for install: leanprover/lean4:v4.26.0' "$unsupported_install_err"; then
  echo "expected unsupported installer toolchain failure to name the rejected toolchain" >&2
  cat "$unsupported_install_err" >&2
  remove_tmp_file "$unsupported_install_err"
  exit 1
fi
remove_tmp_file "$unsupported_install_err"
assert_not_exists "$BEAM_INSTALL_ROOT/current"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 0
assert_not_exists "$BEAM_INSTALL_ROOT/state"

(
  cd "$source_checkout"
  bash scripts/install-beam.sh > /dev/null
)
expected_source_commit="$(git -C "$source_checkout" rev-parse HEAD 2>/dev/null || true)"
install_layout_json="$(cd "$source_checkout" && ./.lake/build/bin/beam-cli install-layout)"

installed_lean_beam="$HOME/.local/bin/lean-beam"
installed_helper="$HOME/.local/bin/lean-beam-search"
installed_runtime_root="$BEAM_INSTALL_ROOT/current"

if [ ! -L "$installed_lean_beam" ]; then
  echo "expected installed lean-beam symlink at $installed_lean_beam" >&2
  exit 1
fi

if [ ! -L "$installed_helper" ]; then
  echo "expected installed lean-beam-search symlink at $installed_helper" >&2
  exit 1
fi

assert_symlink_target "$installed_lean_beam" "$installed_runtime_root/bin/lean-beam"
assert_symlink_target "$installed_helper" "$installed_runtime_root/bin/lean-beam-search"
assert_not_exists "$HOME/.local/bin/beam"
assert_not_exists "$HOME/.local/bin/beam-lean-search"
assert_runtime_layout "$installed_runtime_root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
installed_version_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$installed_runtime_root")"
installed_payload_id="$(basename "$installed_version_root")"
assert_file "$installed_runtime_root/manifest.json"
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"

assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_bundle_layout "$BEAM_INSTALL_ROOT/state/install-bundles" "$toolchain"

(
  cd "$source_checkout"
  bash scripts/install-beam.sh --all-supported > /dev/null
)

assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"
assert_bundle_layout "$BEAM_INSTALL_ROOT/state/install-bundles" "${supported_toolchains[@]}"

(
  cd "$source_checkout"
  bash scripts/install-beam.sh --toolchain "$toolchain" --all-skills > /dev/null
)

for skills_home in "$CODEX_HOME" "$CLAUDE_HOME"; do
  assert_file "$skills_home/skills/lean-beam/SKILL.md"
  assert_file "$skills_home/skills/rocq-beam/SKILL.md"
  assert_no_skill_socket_guidance "$skills_home/skills/lean-beam/SKILL.md"
  assert_no_skill_socket_guidance "$skills_home/skills/rocq-beam/SKILL.md"
done
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"

blocked_home="$tmp_root/blocked-home"
blocked_install_root="$tmp_root/blocked-install-root"
blocked_lean_beam_dir="$blocked_home/.local/bin/lean-beam"
mkdir -p "$blocked_lean_beam_dir" "$blocked_install_root"
blocked_wrapper_err="$(mktemp "$tmp_root/install-wrapper-dir-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_home" BEAM_INSTALL_ROOT="$blocked_install_root" \
    bash scripts/install-beam.sh > /dev/null 2>"$blocked_wrapper_err"
); then
  echo "expected install to fail when the wrapper target path is a real directory" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
if ! grep -q "refusing to replace directory at $blocked_lean_beam_dir" "$blocked_wrapper_err"; then
  echo "expected wrapper-directory install failure to explain the refusal" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
remove_tmp_file "$blocked_wrapper_err"
if [ ! -d "$blocked_lean_beam_dir" ]; then
  echo "expected blocked wrapper directory to remain untouched" >&2
  exit 1
fi
assert_not_exists "$blocked_home/.local/bin/lean-beam-search"
assert_not_exists "$blocked_home/.local/bin/beam"
assert_not_exists "$blocked_home/.local/bin/beam-lean-search"
assert_not_exists "$blocked_install_root/current"
assert_not_exists "$blocked_install_root/versions"
assert_not_exists "$blocked_install_root/state"

remove_tmp_tree "$source_checkout"

project_root="$tmp_root/external-project"
rsync -a tests/save_olean_project/ "$project_root"/

supported_out="$("$installed_lean_beam" supported-toolchains)"
if ! printf '%s\n' "$supported_out" | grep -qx "$toolchain"; then
  echo "expected supported-toolchains to include the pinned repo toolchain" >&2
  printf '%s\n' "$supported_out" >&2
  exit 1
fi

doctor_out="$("$installed_lean_beam" --root "$project_root" doctor)"
if ! printf '%s\n' "$doctor_out" | grep -q 'project toolchain supported: true'; then
  echo "expected installed wrapper doctor lean to report a supported project toolchain" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'supported toolchains registry: '; then
  echo "expected installed wrapper doctor lean to report the support registry path" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'bundle source inputs: '; then
  echo "expected installed wrapper doctor lean to report bundle source inputs" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'supported-lean-toolchains'; then
  echo "expected installed wrapper doctor lean to include supported-lean-toolchains in the source-hash inputs" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if printf '%s\n' "$doctor_out" | grep -q '\.lake/packages'; then
  echo "expected installed wrapper doctor lean to exclude .lake/packages from bundle source-hash inputs" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'bundle source: installed'; then
  echo "expected installed wrapper doctor lean to resolve the installed bundle" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'bundle ready: true'; then
  echo "expected installed wrapper doctor lean to report bundle ready" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi

unsupported_project_root="$tmp_root/external-project-unsupported"
rsync -a tests/save_olean_project/ "$unsupported_project_root"/
printf 'leanprover/lean4:v4.26.0\n' > "$unsupported_project_root/lean-toolchain"

unsupported_doctor_out="$("$installed_lean_beam" --root "$unsupported_project_root" doctor)"
if ! printf '%s\n' "$unsupported_doctor_out" | grep -q 'project toolchain supported: false'; then
  echo "expected doctor lean to report unsupported toolchains explicitly" >&2
  printf '%s\n' "$unsupported_doctor_out" >&2
  exit 1
fi

unsupported_err="$(mktemp "$tmp_root/install-unsupported-toolchain-XXXXXX")"
if "$installed_lean_beam" --root "$unsupported_project_root" ensure >"$unsupported_err" 2>&1; then
  echo "expected installed wrapper ensure lean to reject an unsupported toolchain" >&2
  cat "$unsupported_err" >&2
  remove_tmp_file "$unsupported_err"
  exit 1
fi
if ! grep -q 'unsupported Lean toolchain: leanprover/lean4:v4.26.0' "$unsupported_err"; then
  echo "expected unsupported toolchain failure to name the rejected toolchain" >&2
  cat "$unsupported_err" >&2
  remove_tmp_file "$unsupported_err"
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -q 'run `lean-beam supported-toolchains` to list the validated toolchains' "$unsupported_err"; then
  echo "expected unsupported toolchain failure to advertise the support registry command" >&2
  cat "$unsupported_err" >&2
  remove_tmp_file "$unsupported_err"
  exit 1
fi
remove_tmp_file "$unsupported_err"

(
  cd "$project_root"
  lake build SaveSmoke/A.lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
)

stale_sync_err="$(mktemp "$tmp_root/install-stale-sync-XXXXXX")"
if "$installed_lean_beam" --root "$project_root" sync SaveSmoke/A.lean >"$stale_sync_err" 2>&1; then
  echo "expected installed wrapper lean-sync to fail on a stale imported target" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
if ! grep -q '"code": "syncBarrierIncomplete"' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import lean-sync failure to expose syncBarrierIncomplete" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -q 'Run `lake build` or fix the upstream module first' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import lean-sync failure to include a recovery hint" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
remove_tmp_file "$stale_sync_err"

project_root_standalone="$tmp_root/external-project-standalone"
rsync -a tests/save_olean_project/ "$project_root_standalone"/

cat > "$project_root_standalone/StandaloneSaveSmoke.lean" <<'EOF'
import SaveSmoke.B

#check bVal
EOF

standalone_sync="$("$installed_lean_beam" --root "$project_root_standalone" sync StandaloneSaveSmoke.lean)"
if ! printf '%s\n' "$standalone_sync" | python3 -c 'import json,sys; payload=json.load(sys.stdin); sys.exit(0 if payload.get("error") is None else 1)'; then
  echo "expected installed wrapper lean-sync to succeed on a standalone file the daemon can open" >&2
  printf '%s\n' "$standalone_sync" >&2
  exit 1
fi

standalone_save_err="$(mktemp "$tmp_root/install-standalone-save-XXXXXX")"
if "$installed_lean_beam" --root "$project_root_standalone" save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
  echo "expected installed wrapper lean-save to reject a standalone file outside the Lake module graph" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! grep -q '"code": "saveTargetNotModule"' "$standalone_save_err"; then
  echo "expected installed wrapper standalone lean-save failure to expose saveTargetNotModule" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! grep -q 'lean-save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
  echo "expected installed wrapper standalone lean-save failure to explain the Lake module requirement" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
remove_tmp_file "$standalone_save_err"
