#!/usr/bin/env bash
# risk-tier1-test.sh — Unit tests for risk-tier1.sh signal computation.
#
# Tests the deterministic signal logic in isolation. Each test provides
# a known file list and metadata, then verifies the computed signal.
#
# Run from the repo root:
#   bash scripts/risk-tier1-test.sh

set -euo pipefail

FAILURES=0

run_test() {
  local test_name="$1"
  local actual="$2"
  local expected="$3"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# ---------------------------------------------------------------------------
# Blast radius classification
# Mirrors classify_blast_radius() in risk-tier1.sh — keep in sync
# ---------------------------------------------------------------------------
classify_blast_radius() {
  local files="$1"
  local lines="$2"
  if [ "${files}" -lt 5 ] && [ "${lines}" -lt 100 ]; then
    echo "small"
  elif [ "${files}" -lt 20 ] && [ "${lines}" -lt 500 ]; then
    echo "medium"
  else
    echo "large"
  fi
}

run_test "blast-radius-small" \
  "$(classify_blast_radius 2 30)" "small"
run_test "blast-radius-medium" \
  "$(classify_blast_radius 10 300)" "medium"
run_test "blast-radius-large-files" \
  "$(classify_blast_radius 25 100)" "large"
run_test "blast-radius-large-lines" \
  "$(classify_blast_radius 3 600)" "large"
run_test "blast-radius-boundary-small" \
  "$(classify_blast_radius 4 99)" "small"
run_test "blast-radius-boundary-medium" \
  "$(classify_blast_radius 19 499)" "medium"

# ---------------------------------------------------------------------------
# Protected path matching
# Mirrors count_protected_paths() in risk-tier1.sh — keep in sync
# List synced with post-review.sh REVIEW_PROTECTED_PATHS (line 167–186)
# ---------------------------------------------------------------------------
PROTECTED_PATHS=(
  ".claude/" ".cursor/" ".gitattributes" ".github/"
  ".pre-commit-config.yaml" "AGENTS.md" "agents/" "api-servers/"
  "CLAUDE.md" "CODEOWNERS" "Containerfile" "Dockerfile"
  "harness/" "images/" "plugins/" "policies/" "profiles/" "providers/" "scripts/" "skills/"
)

count_protected_paths() {
  local count=0
  for file in "$@"; do
    for pattern in "${PROTECTED_PATHS[@]}"; do
      if [[ "${file}" == "${pattern}"* ]]; then
        count=$((count + 1))
        break
      fi
    done
  done
  echo "${count}"
}

run_test "protected-none" \
  "$(count_protected_paths "src/main.go" "pkg/util.go")" "0"
run_test "protected-one" \
  "$(count_protected_paths "src/main.go" ".github/workflows/ci.yaml")" "1"
run_test "protected-multiple" \
  "$(count_protected_paths "scripts/deploy.sh" "CLAUDE.md" "src/main.go")" "2"
run_test "protected-exact-match" \
  "$(count_protected_paths "CODEOWNERS")" "1"
run_test "protected-nested" \
  "$(count_protected_paths "skills/pr-review/SKILL.md")" "1"

# ---------------------------------------------------------------------------
# Security-sensitive path matching
# Mirrors count_security_sensitive() in risk-tier1.sh — keep in sync
# Patterns from security-triage.md sub-agent classification criteria
# ---------------------------------------------------------------------------
SECURITY_PATTERNS=(
  "mint/" "auth/" "oidc/" "rbac/" "permissions/"
  "secrets/" "crypto/" "token/" "tokens/" "trust/"
  "policies/"
)

count_security_sensitive() {
  local count=0
  for file in "$@"; do
    for pattern in "${SECURITY_PATTERNS[@]}"; do
      if [[ "${file}" == *"${pattern}"* ]]; then
        count=$((count + 1))
        break
      fi
    done
  done
  echo "${count}"
}

run_test "security-none" \
  "$(count_security_sensitive "src/main.go" "pkg/util.go")" "0"
run_test "security-auth" \
  "$(count_security_sensitive "internal/auth/handler.go")" "1"
run_test "security-nested-token" \
  "$(count_security_sensitive "pkg/token/mint.go" "src/main.go")" "1"
run_test "security-multiple" \
  "$(count_security_sensitive "internal/auth/login.go" "internal/rbac/policy.go")" "2"

# ---------------------------------------------------------------------------
# CI/workflow detection
# ---------------------------------------------------------------------------
has_ci_files() {
  for file in "$@"; do
    case "${file}" in
      .github/*|Makefile|Dockerfile|Containerfile) echo "true"; return ;;
    esac
  done
  echo "false"
}

run_test "ci-false" \
  "$(has_ci_files "src/main.go" "pkg/util.go")" "false"
run_test "ci-github-workflow" \
  "$(has_ci_files "src/main.go" ".github/workflows/ci.yaml")" "true"
run_test "ci-dockerfile" \
  "$(has_ci_files "Dockerfile")" "true"
run_test "ci-makefile" \
  "$(has_ci_files "Makefile")" "true"

# ---------------------------------------------------------------------------
# Dependency file detection
# ---------------------------------------------------------------------------
find_dependency_files() {
  local deps=()
  for file in "$@"; do
    case "${file}" in
      go.mod|go.sum|package.json|package-lock.json|yarn.lock|\
      requirements.txt|requirements*.txt|Pipfile|Pipfile.lock|\
      Gemfile|Gemfile.lock|pom.xml|build.gradle|Cargo.toml|Cargo.lock)
        deps+=("${file}")
        ;;
    esac
  done
  if [ ${#deps[@]} -eq 0 ]; then
    echo "none"
  else
    local IFS=','
    echo "${deps[*]}"
  fi
}

run_test "deps-none" \
  "$(find_dependency_files "src/main.go")" "none"
run_test "deps-go-mod" \
  "$(find_dependency_files "go.mod" "src/main.go")" "go.mod"
run_test "deps-multiple" \
  "$(find_dependency_files "go.mod" "go.sum" "src/main.go")" "go.mod,go.sum"

# ---------------------------------------------------------------------------
# Test file ratio
# ---------------------------------------------------------------------------
compute_test_ratio() {
  local test_count=0
  local total=0
  for file in "$@"; do
    total=$((total + 1))
    case "${file}" in
      *_test.go|*_test.py|*-test.sh|*-test.py|test_*|*_spec.*|*.test.*)
        test_count=$((test_count + 1))
        ;;
    esac
  done
  if [ "${total}" -eq 0 ]; then
    echo "0.00"
    return
  fi
  awk -v t="${test_count}" -v a="${total}" 'BEGIN { printf "%.2f", t / a }'
}

run_test "ratio-no-tests" \
  "$(compute_test_ratio "src/main.go" "src/util.go")" "0.00"
run_test "ratio-half" \
  "$(compute_test_ratio "src/main.go" "src/main_test.go")" "0.50"
run_test "ratio-all-tests" \
  "$(compute_test_ratio "main_test.go" "util_test.go")" "1.00"
run_test "ratio-one-third" \
  "$(compute_test_ratio "a.go" "b.go" "a_test.go")" "0.33"

# ---------------------------------------------------------------------------
# Author bot detection
# ---------------------------------------------------------------------------
is_bot_author() {
  local login="$1"
  if [[ "${login}" == *"[bot]" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

run_test "bot-dependabot" \
  "$(is_bot_author "dependabot[bot]")" "true"
run_test "bot-renovate" \
  "$(is_bot_author "renovate[bot]")" "true"
run_test "bot-human" \
  "$(is_bot_author "octocat")" "false"
run_test "bot-empty" \
  "$(is_bot_author "")" "false"

# --- Summary ---

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
