#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runat_script="$PWD/scripts/runat"
lake_cmd="$(command -v lake)"

if [ ! -x "$runat_script" ]; then
  echo "missing runat wrapper at $runat_script" >&2
  exit 1
fi

if [ -z "$lake_cmd" ]; then
  echo "missing lake on PATH" >&2
  exit 1
fi

expect_owned_tmp_path() {
  case "$1" in
    /tmp/runat-save-olean-*|/tmp/tmp.*)
      ;;
    *)
      echo "refusing to touch unexpected path: $1" >&2
      exit 1
      ;;
  esac
}

mkproj() {
  local dest="$1"
  expect_owned_tmp_path "$dest"
  rm -rf "$dest"
  mkdir -p "$dest"
  rsync -a tests/save_olean_project/ "$dest"/
}

edit_b() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/B.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("def bVal : Nat := 1", "def bVal : Nat := 2")
path.write_text(text)
PY
}

edit_b_slow() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/B.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("""import Lean

open Lean Elab Command

elab "save_sleep_cmd" : command => do
  IO.sleep 1500

def bVal : Nat := 2

save_sleep_cmd
""")
PY
}

edit_b_final() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/B.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("def bVal : Nat := 3\n")
PY
}

tmp1="$(mktemp -d /tmp/runat-save-olean-build-XXXXXX)"
tmp2="$(mktemp -d /tmp/runat-save-olean-broker-XXXXXX)"
tmp3="$(mktemp -d /tmp/runat-save-olean-race-XXXXXX)"
tmp4="$(mktemp -d /tmp/runat-save-olean-cancel-XXXXXX)"
tmp5="$(mktemp -d /tmp/runat-save-olean-stale-XXXXXX)"
log1="$(mktemp /tmp/runat-save-olean-build-log-XXXXXX)"
log2="$(mktemp /tmp/runat-save-olean-broker-log-XXXXXX)"
log3="$(mktemp /tmp/runat-save-olean-race-log-XXXXXX)"
log4="$(mktemp /tmp/runat-save-olean-exact-log-XXXXXX)"
log5="$(mktemp /tmp/runat-save-olean-downstream-log-XXXXXX)"

cleanup() {
  expect_owned_tmp_path "$tmp1"
  expect_owned_tmp_path "$tmp2"
  expect_owned_tmp_path "$tmp3"
  expect_owned_tmp_path "$tmp4"
  expect_owned_tmp_path "$tmp5"
  expect_owned_tmp_path "$log1"
  expect_owned_tmp_path "$log2"
  expect_owned_tmp_path "$log3"
  expect_owned_tmp_path "$log4"
  expect_owned_tmp_path "$log5"
  rm -rf "$tmp1" "$tmp2" "$tmp3" "$tmp4" "$tmp5" "$log1" "$log2" "$log3" "$log4" "$log5"
}
trap cleanup EXIT

mkproj "$tmp1"
mkproj "$tmp2"
mkproj "$tmp3"
mkproj "$tmp4"
mkproj "$tmp5"

(cd "$tmp1" && lake build > /dev/null)
edit_b "$tmp1"
if ! (cd "$tmp1" && lake build >"$log1" 2>&1); then
  :
fi
if ! grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log1"; then
  echo "expected normal lake build after edit to rebuild SaveSmoke.B" >&2
  cat "$log1" >&2
  exit 1
fi

(cd "$tmp2" && lake build > /dev/null)
edit_b "$tmp2"
(
  cd "$tmp2"
  "$runat_script" --root "$tmp2" shutdown > /dev/null 2>&1 || true
  save_json="$("$runat_script" --root "$tmp2" lean-close-save SaveSmoke/B.lean)"
  if [ "$(RUNAT_JSON_PAYLOAD="$save_json" python3 - <<'PY'
import json, os
print(json.loads(os.environ["RUNAT_JSON_PAYLOAD"])["result"]["saved"]["version"])
PY
)" != "1" ]; then
    echo "expected lean-close-save to report saved version 1" >&2
    printf '%s\n' "$save_json" >&2
    exit 1
  fi
  if [ -z "$(RUNAT_JSON_PAYLOAD="$save_json" python3 - <<'PY'
import json, os
print(json.loads(os.environ["RUNAT_JSON_PAYLOAD"])["result"]["saved"]["sourceHash"])
PY
)" ]; then
    echo "expected lean-close-save to report a non-empty sourceHash" >&2
    printf '%s\n' "$save_json" >&2
    exit 1
  fi
  "$runat_script" --root "$tmp2" shutdown > /dev/null 2>&1 || true
  "$lake_cmd" build -v SaveSmoke/B.lean >"$log4" 2>&1
  rm -f .lake/build/lib/lean/SaveSmoke/A.olean .lake/build/lib/lean/SaveSmoke/A.ilean .lake/build/lib/lean/SaveSmoke/A.trace .lake/build/ir/SaveSmoke/A.c
  "$lake_cmd" build -v SaveSmoke/A.lean >"$log5" 2>&1
  "$lake_cmd" build >"$log2" 2>&1
  "$runat_script" --root "$tmp2" shutdown > /dev/null 2>&1 || true
)
if ! grep -Eq "Replayed SaveSmoke\\.B" "$log4"; then
  echo "expected exact-target lake build to replay SaveSmoke.B after broker save" >&2
  cat "$log4" >&2
  exit 1
fi
if grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log4"; then
  echo "expected exact-target lake build not to rebuild SaveSmoke.B after broker save" >&2
  cat "$log4" >&2
  exit 1
fi
if ! grep -Eq "Replayed SaveSmoke\\.B" "$log5"; then
  echo "expected downstream rebuild to reuse saved SaveSmoke.B artifact after daemon shutdown" >&2
  cat "$log5" >&2
  exit 1
fi
if ! grep -Eq "Built SaveSmoke\\.A|Building SaveSmoke\\.A" "$log5"; then
  echo "expected downstream rebuild to rebuild SaveSmoke.A after deleting its outputs" >&2
  cat "$log5" >&2
  exit 1
fi
if grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log2"; then
  echo "expected broker save_olean path to leave SaveSmoke.B up to date for lake build" >&2
  cat "$log2" >&2
  exit 1
fi

(cd "$tmp3" && lake build > /dev/null)
(
  cd "$tmp3"
  "$runat_script" --root "$tmp3" shutdown > /dev/null 2>&1 || true
  "$runat_script" --root "$tmp3" lean-sync SaveSmoke/B.lean > /dev/null
)
edit_b_slow "$tmp3"
(
  cd "$tmp3"
  (
    sleep 0.3
    edit_b_final "$tmp3"
  ) &
  racer_pid="$!"
  "$runat_script" --root "$tmp3" lean-close-save SaveSmoke/B.lean > /dev/null
  wait "$racer_pid"
  "$lake_cmd" build -v SaveSmoke/A.lean >"$log3" 2>&1
  "$runat_script" --root "$tmp3" shutdown > /dev/null 2>&1 || true
)
if ! grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log3"; then
  echo "expected save_olean race to leave SaveSmoke.B stale for downstream builds" >&2
  cat "$log3" >&2
  exit 1
fi

(cd "$tmp4" && lake build > /dev/null)
edit_b_slow "$tmp4"
(
  cd "$tmp4"
  "$runat_script" --root "$tmp4" shutdown > /dev/null 2>&1 || true
  "$runat_script" --root "$tmp4" ensure lean > /dev/null
  close_out="$(mktemp /tmp/runat-close-save-cancel-out-XXXXXX)"
  close_err="$(mktemp /tmp/runat-close-save-cancel-err-XXXXXX)"
  RUNAT_REQUEST_ID=cancel-close-save \
    "$runat_script" --root "$tmp4" lean-close-save SaveSmoke/B.lean >"$close_out" 2>"$close_err" &
  close_pid=$!
  sleep 0.5
  cancel_json="$("$runat_script" --root "$tmp4" cancel cancel-close-save)"
  if ! printf '%s\n' "$cancel_json" | grep -q '"cancelled": true'; then
    echo "expected explicit cancel to report cancelled=true for lean-close-save" >&2
    printf '%s\n' "$cancel_json" >&2
    cat "$close_out" >&2
    cat "$close_err" >&2
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  if wait "$close_pid"; then
    echo "expected cancelled lean-close-save to exit non-zero" >&2
    cat "$close_out" >&2
    cat "$close_err" >&2
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  if ! grep -q '"code": "requestCancelled"' "$close_out"; then
    echo "expected cancelled lean-close-save to report requestCancelled" >&2
    cat "$close_out" >&2
    cat "$close_err" >&2
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  "$runat_script" --root "$tmp4" stats > /dev/null
  rm -f "$close_out" "$close_err"
)

(cd "$tmp5" && lake build SaveSmoke/A.lean > /dev/null)
printf 'def bVal : Nat := "broken"\n' > "$tmp5/SaveSmoke/B.lean"
(
  cd "$tmp5"
  "$runat_script" --root "$tmp5" shutdown > /dev/null 2>&1 || true
  "$runat_script" --root "$tmp5" ensure lean > /dev/null
  sync_out="$(mktemp /tmp/runat-stale-sync-out-XXXXXX)"
  sync_err="$(mktemp /tmp/runat-stale-sync-err-XXXXXX)"
  save_out="$(mktemp /tmp/runat-stale-save-out-XXXXXX)"
  save_err="$(mktemp /tmp/runat-stale-save-err-XXXXXX)"
  RUNAT_REQUEST_ID=concurrent-stale-sync \
    "$runat_script" --root "$tmp5" lean-sync SaveSmoke/A.lean >"$sync_out" 2>"$sync_err" &
  sync_pid=$!
  sleep 0.1
  RUNAT_REQUEST_ID=concurrent-stale-save \
    "$runat_script" --root "$tmp5" lean-save SaveSmoke/A.lean >"$save_out" 2>"$save_err" &
  save_pid=$!
  if wait "$sync_pid"; then
    echo "expected concurrent stale lean-sync to fail" >&2
    cat "$sync_out" >&2
    cat "$sync_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if wait "$save_pid"; then
    echo "expected concurrent stale lean-save to fail" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if ! grep -q '"code": "syncBarrierIncomplete"' "$sync_out"; then
    echo "expected concurrent stale lean-sync to report syncBarrierIncomplete" >&2
    cat "$sync_out" >&2
    cat "$sync_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if ! grep -q '"code": "syncBarrierIncomplete"' "$save_out"; then
    echo "expected concurrent stale lean-save to report syncBarrierIncomplete" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if grep -q 'CLI daemon connection closed' "$sync_err"; then
    echo "expected concurrent stale lean-sync to preserve the daemon connection" >&2
    cat "$sync_out" >&2
    cat "$sync_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if grep -q 'CLI daemon connection closed' "$save_err"; then
    echo "expected concurrent stale lean-save to preserve the daemon connection" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  "$runat_script" --root "$tmp5" stats > /dev/null
  rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
)
