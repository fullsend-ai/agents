#!/usr/bin/env bash
# Tests for setup-fixture.sh: the ephemeral repo name reaches
# .hook-outputs.yaml as soon as `gh repo create` succeeds, so that
# teardown-fixture.sh can delete the repo when a later step fails (the
# harness runs after_each on a before_each failure but does not collect
# this file, so it stays in CASE_WORKSPACE).
#
# gh, git and uuidgen are stubbed in a per-run bin/ directory so no GitHub
# call ever runs; yq and jq are the real ones.
#
# Run from the repo root:
#   bash eval/scripts/setup-fixture-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="${SCRIPT_DIR}/setup-fixture.sh"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required to run these tests (not on PATH)" >&2
    exit 1
  fi
done

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

# --- Stubs ---------------------------------------------------------------
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CAPTURE_DIR}/gh-calls.log"
case "${1:-} ${2:-}" in
  "repo create")
    [[ "${STUB_GH_CREATE_FAILS:-}" == 1 ]] && { echo "GraphQL: HTTP 502" >&2; exit 1; }
    ;;
  "issue create") echo "https://github.com/stub/issues/7" ;;
  "pr create") echo "https://github.com/stub/pull/7" ;;
esac
exit 0
STUB

cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CAPTURE_DIR}/git-calls.log"
# Skip leading -c/-C options to find the subcommand.
args=("$@")
while [[ ${#args[@]} -gt 0 ]]; do
  case "${args[0]}" in
    -c|-C) args=("${args[@]:2}") ;;
    *) break ;;
  esac
done
case "${args[0]:-}" in
  clone) mkdir -p "${args[$((${#args[@]} - 1))]}" ;;
  diff) exit 1 ;;  # staged changes present, so setup commits and pushes
  push)
    if [[ "${STUB_GIT_PUSH_FAILS:-}" == 1 ]]; then
      echo "fatal: could not read Username for 'https://github.com'" >&2
      exit 128
    fi
    ;;
  rev-parse) echo 0123456789abcdef0123456789abcdef01234567 ;;
esac
exit 0
STUB

cat > "$TMP/bin/uuidgen" <<'STUB'
#!/usr/bin/env bash
echo "0123ABCD-0000-4000-8000-000000000000"
STUB
chmod +x "$TMP/bin/"*

# --- Case fixture --------------------------------------------------------
CASE_SRC="$TMP/cases/001-issue-case"
mkdir -p "$CASE_SRC"
cat > "$CASE_SRC/input.yaml" <<'YAML'
fixture:
  type: issue
  title: "Stub issue"
  body: "See ${REPO_URL}"
YAML
EXPECTED_REPO="halfsend/eval-001-issue-case-0123abcd"

# run_setup <name> [VAR=value ...]: runs setup-fixture.sh in a fresh
# workspace with the stubs on PATH; sets WS, RC and CAPTURE.
run_setup() {
  local name="$1"; shift
  WS="$TMP/ws-$name"
  CAPTURE="$TMP/capture-$name"
  mkdir -p "$WS" "$CAPTURE"
  RC=0
  env "$@" \
    PATH="$TMP/bin:$PATH" CAPTURE_DIR="$CAPTURE" \
    CASE_WORKSPACE="$WS" CASE_SOURCE_DIR="$CASE_SRC" \
    EVAL_ORG=halfsend GH_TOKEN=stub-token \
    bash "$SETUP" > "$WS/setup.log" 2>&1 || RC=$?
}

hook_output() { yq -r "$1 // \"\"" "$WS/.hook-outputs.yaml"; }

# --- 1. A failure after `gh repo create` still records the repo ----------
run_setup push-fails STUB_GIT_PUSH_FAILS=1
check "push failure exits non-zero" "128" "$RC"
check "repo was created before the failure" \
  "1" "$(grep -c "^repo create ${EXPECTED_REPO} " "$CAPTURE/gh-calls.log")"
check "hook outputs exist after the failure" \
  "yes" "$([[ -f "$WS/.hook-outputs.yaml" ]] && echo yes || echo no)"
check "env.EPHEMERAL_REPO names the created repo" \
  "$EXPECTED_REPO" "$(hook_output .env.EPHEMERAL_REPO)"
check "data.ephemeral_repo names the created repo" \
  "$EXPECTED_REPO" "$(hook_output .data.ephemeral_repo)"
check "no fixture URL is recorded for a failed setup" \
  "" "$(hook_output .env.FIXTURE_URL)"

# --- 2. A failure at `gh repo create` records nothing --------------------
run_setup create-fails STUB_GH_CREATE_FAILS=1
check "create failure exits non-zero" "1" "$RC"
check "no hook outputs when no repo was created" \
  "no" "$([[ -f "$WS/.hook-outputs.yaml" ]] && echo yes || echo no)"

# --- 3. A successful run overwrites the early record with the full one ---
run_setup success
check "successful setup exits zero" "0" "$RC"
check "env.EPHEMERAL_REPO survives the final write" \
  "$EXPECTED_REPO" "$(hook_output .env.EPHEMERAL_REPO)"
check "data.ephemeral_repo survives the final write" \
  "$EXPECTED_REPO" "$(hook_output .data.ephemeral_repo)"
check "env.FIXTURE_URL is the created issue" \
  "https://github.com/stub/issues/7" "$(hook_output .env.FIXTURE_URL)"
check "env.FIXTURE_NUMBER is the issue number" "7" "$(hook_output .env.FIXTURE_NUMBER)"
check "env.FIXTURE_TYPE is issue" "issue" "$(hook_output .env.FIXTURE_TYPE)"

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
