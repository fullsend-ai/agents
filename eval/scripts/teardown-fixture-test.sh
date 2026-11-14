#!/usr/bin/env bash
# Tests for teardown-fixture.sh: the ephemeral repo is deleted whether its
# name arrives in EPHEMERAL_REPO (setup-fixture.sh succeeded and the
# harness forwarded its outputs) or only in CASE_WORKSPACE/.hook-outputs.yaml
# (setup failed after `gh repo create`, so the harness never collected the
# file), and nothing is deleted when neither names a repo.
#
# gh is stubbed so no GitHub call ever runs; yq is the real one.
#
# Run from the repo root:
#   bash eval/scripts/teardown-fixture-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEARDOWN="${SCRIPT_DIR}/teardown-fixture.sh"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required to run these tests (not on PATH)" >&2
  exit 1
fi

check() {
  local name="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAILURES=$((FAILURES + 1))
  fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CAPTURE_DIR}/gh-calls.log"
exit 0
STUB
chmod +x "$TMP/bin/gh"

# run_teardown <name> [VAR=value ...]: runs teardown-fixture.sh with
# EPHEMERAL_REPO unset unless given; sets WS, RC, CAPTURE.
run_teardown() {
  local name="$1"; shift
  WS="$TMP/ws-$name"
  CAPTURE="$TMP/capture-$name"
  mkdir -p "$WS" "$CAPTURE"
  : > "$CAPTURE/gh-calls.log"
  RC=0
  env -u EPHEMERAL_REPO "$@" \
    PATH="$TMP/bin:$PATH" CAPTURE_DIR="$CAPTURE" CASE_WORKSPACE="$WS" \
    bash "$TEARDOWN" > "$WS/teardown.log" 2>&1 || RC=$?
}

# --- 1. Repo name forwarded in the environment ---------------------------
run_teardown env EPHEMERAL_REPO=halfsend/eval-from-env
check "env: exits zero" "0" "$RC"
check "env: deletes the repo named by EPHEMERAL_REPO" \
  "repo delete halfsend/eval-from-env --yes" "$(cat "$CAPTURE/gh-calls.log")"

# --- 2. Repo name only in the uncollected .hook-outputs.yaml -------------
run_teardown file
cat > "$WS/.hook-outputs.yaml" <<'YAML'
env:
  EPHEMERAL_REPO: "halfsend/eval-from-file"
data:
  ephemeral_repo: "halfsend/eval-from-file"
YAML
run_teardown file
check "file: exits zero" "0" "$RC"
check "file: deletes the repo named in the workspace hook outputs" \
  "repo delete halfsend/eval-from-file --yes" "$(cat "$CAPTURE/gh-calls.log")"

# --- 3. Environment wins over the file ------------------------------------
mkdir -p "$TMP/ws-both"
cat > "$TMP/ws-both/.hook-outputs.yaml" <<'YAML'
env:
  EPHEMERAL_REPO: "halfsend/eval-from-file"
YAML
run_teardown both EPHEMERAL_REPO=halfsend/eval-from-env
check "both: the environment value is the one deleted" \
  "repo delete halfsend/eval-from-env --yes" "$(cat "$CAPTURE/gh-calls.log")"

# --- 4. Nothing names a repo ---------------------------------------------
run_teardown none
check "none: exits zero" "0" "$RC"
check "none: no gh call is made" "" "$(cat "$CAPTURE/gh-calls.log")"
check "none: warns that teardown is skipped" \
  "1" "$(grep -c 'EPHEMERAL_REPO not set, skipping teardown' "$WS/teardown.log")"

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
