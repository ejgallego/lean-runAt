#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp_bundle_dir="$(mktemp -d /tmp/runat-broker-bundles-XXXXXX)"
tmp_env_root="$(mktemp -d /tmp/runat-broker-env-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/runat-broker-bundles-*|/tmp/runat-broker-env-*|/tmp/runat-validate-*/tmp/runat-broker-bundles-*|/tmp/runat-validate-*/tmp/runat-broker-env-*)
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
  remove_owned_tmp_tree "$tmp_bundle_dir"
  remove_owned_tmp_tree "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"

echo "[broker-slow] build"
lake build \
  RunAt:shared \
  runAt-cli \
  runAt-cli-daemon \
  runAt-cli-client \
  runAt-cli-daemon-rocq-smoke-test \
  > /dev/null

echo "[broker-slow] bundle install"
RUNAT_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" ./.lake/build/bin/runAt-cli bundle-install "$toolchain" > /dev/null

echo "[broker-slow] wrapper tests"
HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  RUNAT_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" bash tests/test-runat-wrapper.sh > /dev/null

echo "[broker-slow] install tests"
bash tests/test-install.sh > /dev/null

echo "[broker-slow] save replay tests"
HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  RUNAT_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" bash tests/test-broker-save-olean.sh > /dev/null

ROCQ_LSP=""
for candidate in "_opam/bin/coq-lsp" "_opam/_opam/bin/coq-lsp"; do
  if [ -x "$candidate" ]; then
    ROCQ_LSP="$candidate"
    break
  fi
done

if [ -n "$ROCQ_LSP" ]; then
  echo "[broker-slow] rocq wrapper tests"
  if [ -d "_opam/_opam" ]; then
    eval "$(opam env --switch=./_opam --set-switch)"
  fi
  RUNAT_ROCQ_CMD="$PWD/$ROCQ_LSP" bash tests/test-runat-wrapper-rocq.sh > /dev/null
  echo "[broker-slow] rocq smoke test"
  RUNAT_ROCQ_CMD="$PWD/$ROCQ_LSP" .lake/build/bin/runAt-cli-daemon-rocq-smoke-test > /dev/null
else
  echo "[broker-slow] rocq skipped: install coq-lsp with tests/setup-rocq-opam.sh." >&2
fi
