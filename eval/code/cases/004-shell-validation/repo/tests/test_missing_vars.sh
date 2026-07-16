#!/usr/bin/env bash
# Test that scripts fail cleanly when required vars are missing.
set -euo pipefail

PASS=0
FAIL=0

check_fails_without_var() {
  local script="$1"
  local var_name="$2"
  local description="$3"
  shift 3

  local env_cmd=(env -u "${var_name}")
  if [[ $# -gt 0 ]]; then
    env_cmd+=("$@")
  fi

  output=$("${env_cmd[@]}" bash "$script" 2>&1) && status=$? || status=$?

  if [[ $status -ne 0 ]] && echo "$output" | grep -qi "${var_name}"; then
    echo "PASS: ${description}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${description} (status=${status})"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Testing missing variable validation ==="
echo ""

check_fails_without_var "scripts/setup.sh" "BUILD_DIR" \
  "setup.sh rejects missing BUILD_DIR" \
  APP_NAME=test

check_fails_without_var "scripts/setup.sh" "APP_NAME" \
  "setup.sh rejects missing APP_NAME" \
  BUILD_DIR=/tmp/test-build

check_fails_without_var "scripts/deploy.sh" "DEPLOY_TARGET" \
  "deploy.sh rejects missing DEPLOY_TARGET"

check_fails_without_var "scripts/rollback.sh" "DEPLOY_TARGET" \
  "rollback.sh rejects missing DEPLOY_TARGET" \
  BACKUP_DIR=/tmp/backup

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
