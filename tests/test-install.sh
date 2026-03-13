#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp_root="$(mktemp -d /tmp/runat-install-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/runat-install-*)
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
export RUNAT_INSTALL_ROOT="$tmp_root/install-root"

mkdir -p "$HOME" "$RUNAT_INSTALL_ROOT"

toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"
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
  assert_file "$runtime_root/RunAtCli.lean"
  assert_file "$runtime_root/RunAtCli/Broker/Server.lean"
  assert_file "$runtime_root/RunAt/Internal/SaveArtifacts.lean"
  assert_file "$runtime_root/libexec/runAt-cli"
  assert_file "$runtime_root/libexec/runAt-cli-daemon"
  assert_file "$runtime_root/libexec/runAt-cli-client"
  assert_file "$runtime_root/libexec/librunAt_RunAt.so"
  assert_not_exists "$runtime_root/.lake/build"
  assert_file "$runtime_root/bin/runat"
  assert_file "$runtime_root/bin/runat-lean-search"
}

assert_manifest_metadata() {
  local manifest_path="$1"
  local expected_payload="$2"
  local expected_toolchain="$3"
  local expected_source_commit="$4"
  python3 - "$manifest_path" "$expected_payload" "$expected_toolchain" "$expected_source_commit" <<'PY'
import json
import sys

manifest_path, expected_payload, expected_toolchain, expected_source_commit = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)

if manifest.get("schemaVersion") != 1:
    raise SystemExit(f"unexpected manifest schemaVersion: {manifest.get('schemaVersion')}")
if manifest.get("payloadHash") != expected_payload:
    raise SystemExit(f"unexpected manifest payloadHash: {manifest.get('payloadHash')}")
if manifest.get("toolchain") != expected_toolchain:
    raise SystemExit(f"unexpected manifest toolchain: {manifest.get('toolchain')}")
actual_source_commit = manifest.get("sourceCommit", "sentinel")
if expected_source_commit:
    if actual_source_commit != expected_source_commit:
        raise SystemExit(f"unexpected manifest sourceCommit: {actual_source_commit}")
else:
    if actual_source_commit is not None:
        raise SystemExit(f"expected manifest sourceCommit to be null in non-git install copy: {actual_source_commit}")

artifacts = manifest.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("manifest artifacts payload is missing")

root_files = artifacts.get("rootFiles")
source_dirs = artifacts.get("sourceDirs")
runtime_paths = artifacts.get("runtimePaths")
wrapper_paths = artifacts.get("wrapperPaths")

expected_root_files = {"RunAt.lean", "RunAtCli.lean", "lakefile.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain"}
expected_source_dirs = {"RunAt", "RunAtCli", "ffi"}
expected_runtime_paths = {
    "libexec/runAt-cli",
    "libexec/runAt-cli-daemon",
    "libexec/runAt-cli-client",
    "libexec/librunAt_RunAt.so",
    ".lake/packages",
}
expected_wrapper_paths = {"bin/runat", "bin/runat-lean-search"}

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
  local metadata
  metadata="$(find "$bundle_root" -name metadata.json | head -n 1 || true)"
  if [ -z "$metadata" ]; then
    echo "missing bundle metadata under $bundle_root" >&2
    exit 1
  fi
  if ! rg -n --fixed-strings "\"toolchain\": \"$toolchain\"" "$metadata" > /dev/null; then
    echo "bundle metadata does not mention expected toolchain $toolchain: $metadata" >&2
    exit 1
  fi

  local workspace
  workspace="$(dirname "$metadata")/workspace"
  assert_file "$workspace/RunAtCli.lean"
  assert_file "$workspace/RunAtCli/Broker/Server.lean"
  assert_file "$workspace/RunAt/Internal/SaveArtifacts.lean"
  assert_file "$workspace/.lake/build/bin/runAt-cli-daemon"
  assert_file "$workspace/.lake/build/bin/runAt-cli-client"
  assert_file "$workspace/.lake/build/lib/librunAt_RunAt.so"
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
  PATH="$path_no_elan" bash scripts/install-runat-skills.sh > /dev/null 2>"$missing_elan_err"
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
assert_not_exists "$RUNAT_INSTALL_ROOT/current"
assert_version_count "$RUNAT_INSTALL_ROOT/versions" 0
assert_not_exists "$RUNAT_INSTALL_ROOT/state"

relative_root_err="$(mktemp "$tmp_root/install-relative-root-XXXXXX")"
if (
  cd "$source_checkout"
  RUNAT_INSTALL_ROOT="relative/install-root" bash scripts/install-runat-skills.sh > /dev/null 2>"$relative_root_err"
); then
  echo "expected install to fail when RUNAT_INSTALL_ROOT is relative" >&2
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

(
  cd "$source_checkout"
  bash scripts/install-runat-skills.sh > /dev/null
)
expected_source_commit="$(git -C "$source_checkout" rev-parse HEAD 2>/dev/null || true)"

installed_runat="$HOME/.local/bin/runat"
installed_helper="$HOME/.local/bin/runat-lean-search"
installed_runtime_root="$RUNAT_INSTALL_ROOT/current"

if [ ! -L "$installed_runat" ]; then
  echo "expected installed runat symlink at $installed_runat" >&2
  exit 1
fi

if [ ! -L "$installed_helper" ]; then
  echo "expected installed runat-lean-search symlink at $installed_helper" >&2
  exit 1
fi

assert_symlink_target "$installed_runat" "$installed_runtime_root/bin/runat"
assert_symlink_target "$installed_helper" "$installed_runtime_root/bin/runat-lean-search"
assert_runtime_layout "$installed_runtime_root"
assert_version_count "$RUNAT_INSTALL_ROOT/versions" 1
installed_version_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$installed_runtime_root")"
installed_payload_id="$(basename "$installed_version_root")"
assert_file "$installed_runtime_root/manifest.json"
assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$toolchain" "$expected_source_commit"

assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_bundle_layout "$RUNAT_INSTALL_ROOT/state/install-bundles"

(
  cd "$source_checkout"
  bash scripts/install-runat-skills.sh --all-skills > /dev/null
)

for skills_home in "$CODEX_HOME" "$CLAUDE_HOME"; do
  assert_file "$skills_home/skills/lean-runat/SKILL.md"
  assert_file "$skills_home/skills/rocq-runat/SKILL.md"
  assert_no_skill_socket_guidance "$skills_home/skills/lean-runat/SKILL.md"
  assert_no_skill_socket_guidance "$skills_home/skills/rocq-runat/SKILL.md"
done
assert_version_count "$RUNAT_INSTALL_ROOT/versions" 1
assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$toolchain" "$expected_source_commit"

blocked_home="$tmp_root/blocked-home"
blocked_install_root="$tmp_root/blocked-install-root"
blocked_runat_dir="$blocked_home/.local/bin/runat"
mkdir -p "$blocked_runat_dir" "$blocked_install_root"
blocked_wrapper_err="$(mktemp "$tmp_root/install-wrapper-dir-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_home" RUNAT_INSTALL_ROOT="$blocked_install_root" \
    bash scripts/install-runat-skills.sh > /dev/null 2>"$blocked_wrapper_err"
); then
  echo "expected install to fail when the wrapper target path is a real directory" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
if ! grep -q "refusing to replace directory at $blocked_runat_dir" "$blocked_wrapper_err"; then
  echo "expected wrapper-directory install failure to explain the refusal" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
remove_tmp_file "$blocked_wrapper_err"
if [ ! -d "$blocked_runat_dir" ]; then
  echo "expected blocked wrapper directory to remain untouched" >&2
  exit 1
fi
assert_not_exists "$blocked_home/.local/bin/runat-lean-search"
assert_not_exists "$blocked_install_root/current"
assert_not_exists "$blocked_install_root/versions"
assert_not_exists "$blocked_install_root/state"

remove_tmp_tree "$source_checkout"

project_root="$tmp_root/external-project"
rsync -a tests/save_olean_project/ "$project_root"/

doctor_out="$("$installed_runat" --root "$project_root" doctor lean)"
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

(
  cd "$project_root"
  lake build SaveSmoke/A.lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
)

stale_sync_err="$(mktemp "$tmp_root/install-stale-sync-XXXXXX")"
if "$installed_runat" --root "$project_root" lean-sync SaveSmoke/A.lean >"$stale_sync_err" 2>&1; then
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

standalone_sync="$("$installed_runat" --root "$project_root_standalone" lean-sync StandaloneSaveSmoke.lean)"
if ! printf '%s\n' "$standalone_sync" | python3 -c 'import json,sys; payload=json.load(sys.stdin); sys.exit(0 if payload.get("error") is None else 1)'; then
  echo "expected installed wrapper lean-sync to succeed on a standalone file the daemon can open" >&2
  printf '%s\n' "$standalone_sync" >&2
  exit 1
fi

standalone_save_err="$(mktemp "$tmp_root/install-standalone-save-XXXXXX")"
if "$installed_runat" --root "$project_root_standalone" lean-save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
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
