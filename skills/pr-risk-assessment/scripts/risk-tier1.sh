#!/usr/bin/env bash
# risk-tier1.sh — Compute deterministic Tier 1 metadata signals for PR risk assessment.
#
# Run by the risk-assessment sub-agent inside the sandbox:
#   bash "${CLAUDE_CONFIG_DIR}/skills/pr-risk-assessment/scripts/risk-tier1.sh"
#
# Required env vars: PR_NUMBER, REPO_FULL_NAME, GH_TOKEN
# Output: KEY=VALUE pairs on stdout, one per line.
# Exit code: always 0 — individual signal failures fall back to UNKNOWN.
#
# This script is designed to be sourceable for testing. All signal
# computation lives in named functions; the main flow is guarded by a
# BASH_SOURCE check so `source risk-tier1.sh` only defines functions.

# -e omitted: individual signal failures fall back to UNKNOWN (see fallback blocks below).
set -uo pipefail

# --- Protected paths (from REVIEW_PROTECTED_PATHS env var, or hardcoded fallback) ---
if [[ "${REVIEW_PROTECTED_PATHS+set}" != "set" ]]; then
  PROTECTED_PATHS=(
    ".claude/" ".cursor/" ".gitattributes" ".github/"
    ".pre-commit-config.yaml" "AGENTS.md" "agents/" "api-servers/"
    "CLAUDE.md" "CODEOWNERS" "Containerfile" "Dockerfile"
    "harness/" "images/" "plugins/" "policies/" "profiles/" "providers/" "scripts/" "skills/"
  )
elif [[ -z "${REVIEW_PROTECTED_PATHS}" ]]; then
  PROTECTED_PATHS=()
else
  IFS=',' read -ra PROTECTED_PATHS <<< "${REVIEW_PROTECTED_PATHS}"
  _trimmed=()
  for _entry in "${PROTECTED_PATHS[@]}"; do
    _entry="$(echo "${_entry}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${_entry}" ]] && _trimmed+=("${_entry}")
  done
  PROTECTED_PATHS=()
  [[ ${#_trimmed[@]} -gt 0 ]] && PROTECTED_PATHS=("${_trimmed[@]}")
  unset _trimmed _entry
fi

# --- Security-sensitive patterns (from security-triage.md) ---
SECURITY_PATTERNS=(
  "mint/" "auth/" "oidc/" "rbac/" "permissions/"
  "secrets/" "crypto/" "token/" "tokens/" "trust/"
  "policies/"
)

# ---------------------------------------------------------------------------
# Signal computation functions
# ---------------------------------------------------------------------------

classify_blast_radius() {
  local files="$1" lines="$2"
  if [ "${files}" -lt 5 ] && [ "${lines}" -lt 100 ]; then echo "small"
  elif [ "${files}" -lt 20 ] && [ "${lines}" -lt 500 ]; then echo "medium"
  else echo "large"; fi
}

count_protected_paths() {
  local count=0
  for file in "$@"; do
    for pattern in "${PROTECTED_PATHS[@]}"; do
      if [[ "${pattern}" == */ ]]; then
        [[ "${file}" == "${pattern}"* ]] && { count=$((count + 1)); break; }
      else
        [[ "${file}" == "${pattern}" ]] && { count=$((count + 1)); break; }
      fi
    done
  done
  echo "${count}"
}

count_security_sensitive() {
  local count=0
  for file in "$@"; do
    for pattern in "${SECURITY_PATTERNS[@]}"; do
      if [[ "/${file}" == *"/${pattern}"* ]]; then
        count=$((count + 1))
        break
      fi
    done
  done
  echo "${count}"
}

has_ci_files() {
  for file in "$@"; do
    case "${file}" in
      .github/*|Makefile|Dockerfile|Containerfile) echo "true"; return ;;
    esac
  done
  echo "false"
}

find_dependency_files() {
  local deps=()
  for file in "$@"; do
    local base="${file##*/}"
    case "${base}" in
      go.mod|go.sum|package.json|package-lock.json|yarn.lock|\
      requirements.txt|requirements*.txt|Pipfile|Pipfile.lock|\
      Gemfile|Gemfile.lock|pom.xml|build.gradle|Cargo.toml|Cargo.lock)
        deps+=("${file}") ;;
    esac
  done
  if [ ${#deps[@]} -eq 0 ]; then
    echo "none"
  else
    IFS=','; echo "${deps[*]}"; unset IFS
  fi
}

compute_test_ratio() {
  local test_count=0 total=0
  for file in "$@"; do
    total=$((total + 1))
    case "${file}" in
      *_test.go|*_test.py|*-test.sh|*-test.py|test_*|*_spec.*|*.test.*)
        test_count=$((test_count + 1)) ;;
    esac
  done
  if [ "${total}" -eq 0 ]; then
    echo "0.00"
    return
  fi
  awk -v t="${test_count}" -v a="${total}" 'BEGIN { printf "%.2f", t / a }'
}

is_bot_author() {
  local login="$1"
  if [[ "${login}" == *"[bot]" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# ---------------------------------------------------------------------------
# Main flow — orchestrates API calls and signal output
# ---------------------------------------------------------------------------

main() {
  : "${PR_NUMBER:?PR_NUMBER is required}"
  : "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"

  # --- Fetch PR file list ---
  local PR_FILES_JSON
  PR_FILES_JSON=$(gh api --paginate "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/files?per_page=100" 2>/dev/null \
    | jq -s 'add') || PR_FILES_JSON=""

  if [ -z "${PR_FILES_JSON}" ]; then
    echo "FILES_CHANGED=UNKNOWN"
    echo "LINES_CHANGED=UNKNOWN"
    echo "BLAST_RADIUS=UNKNOWN"
    echo "PROTECTED_PATH_COUNT=UNKNOWN"
    echo "SECURITY_SENSITIVE_COUNT=UNKNOWN"
    echo "CI_WORKFLOW_CHANGED=UNKNOWN"
    echo "DEPENDENCY_FILES_CHANGED=UNKNOWN"
    echo "TEST_FILE_RATIO=UNKNOWN"
    echo "AUTHOR_IS_BOT=UNKNOWN"
    echo "AUTHOR_IS_FIRST_TIME=UNKNOWN"
    return 0
  fi

  # --- Parse file list ---
  local FILES FILES_CHANGED LINES_CHANGED
  mapfile -t FILES < <(echo "${PR_FILES_JSON}" | jq -r '.[].filename')
  FILES_CHANGED=${#FILES[@]}
  LINES_CHANGED=$(echo "${PR_FILES_JSON}" | jq '[.[] | .additions + .deletions] | add // 0')

  echo "FILES_CHANGED=${FILES_CHANGED}"
  echo "LINES_CHANGED=${LINES_CHANGED}"
  echo "BLAST_RADIUS=$(classify_blast_radius "${FILES_CHANGED}" "${LINES_CHANGED}")"
  echo "PROTECTED_PATH_COUNT=$(count_protected_paths "${FILES[@]}")"
  echo "SECURITY_SENSITIVE_COUNT=$(count_security_sensitive "${FILES[@]}")"
  echo "CI_WORKFLOW_CHANGED=$(has_ci_files "${FILES[@]}")"
  echo "DEPENDENCY_FILES_CHANGED=$(find_dependency_files "${FILES[@]}")"

  if [ "${FILES_CHANGED}" -eq 0 ]; then
    echo "TEST_FILE_RATIO=0.00"
  else
    echo "TEST_FILE_RATIO=$(compute_test_ratio "${FILES[@]}")"
  fi

  # --- Author signals ---
  local PR_META
  PR_META=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" \
    --jq '{author: .user.login, assoc: .author_association}' 2>/dev/null) || PR_META=""
  if [ -n "${PR_META}" ]; then
    local AUTHOR ASSOC
    AUTHOR=$(echo "${PR_META}" | jq -r '.author')
    ASSOC=$(echo "${PR_META}" | jq -r '.assoc')
    echo "AUTHOR_IS_BOT=$(is_bot_author "${AUTHOR}")"
    if [ "${ASSOC}" = "FIRST_TIME_CONTRIBUTOR" ]; then
      echo "AUTHOR_IS_FIRST_TIME=true"
    else
      echo "AUTHOR_IS_FIRST_TIME=false"
    fi
  else
    echo "AUTHOR_IS_BOT=UNKNOWN"
    echo "AUTHOR_IS_FIRST_TIME=UNKNOWN"
  fi

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
