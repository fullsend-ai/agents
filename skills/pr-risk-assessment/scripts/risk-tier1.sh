#!/usr/bin/env bash
# risk-tier1.sh — Compute deterministic Tier 1 metadata signals for PR risk assessment.
#
# Run by the risk-assessment sub-agent inside the sandbox:
#   bash skills/pr-risk-assessment/scripts/risk-tier1.sh
#
# Required env vars: PR_NUMBER, REPO_FULL_NAME, GH_TOKEN
# Output: KEY=VALUE pairs on stdout, one per line.
# Exit code: always 0 — individual signal failures fall back to UNKNOWN.

set -uo pipefail

: "${PR_NUMBER:?PR_NUMBER is required}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"

# --- Protected paths (synced with post-review.sh line 167–186) ---
PROTECTED_PATHS=(
  ".claude/" ".cursor/" ".gitattributes" ".github/"
  ".pre-commit-config.yaml" "AGENTS.md" "agents/" "api-servers/"
  "CLAUDE.md" "CODEOWNERS" "Containerfile" "Dockerfile"
  "harness/" "images/" "plugins/" "policies/" "profiles/" "providers/" "scripts/" "skills/"
)

# --- Security-sensitive patterns (from security-triage.md) ---
SECURITY_PATTERNS=(
  "mint/" "auth/" "oidc/" "rbac/" "permissions/"
  "secrets/" "crypto/" "token/" "tokens/" "trust/"
  "policies/"
)

# --- Fetch PR file list ---
PR_FILES_JSON=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/files?per_page=100" 2>/dev/null) || PR_FILES_JSON=""

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
  exit 0
fi

# --- Parse file list ---
mapfile -t FILES < <(echo "${PR_FILES_JSON}" | jq -r '.[].filename')
FILES_CHANGED=${#FILES[@]}
LINES_CHANGED=$(echo "${PR_FILES_JSON}" | jq '[.[].additions + .[].deletions] | add // 0')

echo "FILES_CHANGED=${FILES_CHANGED}"
echo "LINES_CHANGED=${LINES_CHANGED}"

# --- Blast radius ---
classify_blast_radius() {
  local files="$1" lines="$2"
  if [ "${files}" -lt 5 ] && [ "${lines}" -lt 100 ]; then echo "small"
  elif [ "${files}" -lt 20 ] && [ "${lines}" -lt 500 ]; then echo "medium"
  else echo "large"; fi
}
echo "BLAST_RADIUS=$(classify_blast_radius "${FILES_CHANGED}" "${LINES_CHANGED}")"

# --- Protected path count ---
protected_count=0
for file in "${FILES[@]}"; do
  for pattern in "${PROTECTED_PATHS[@]}"; do
    if [[ "${file}" == "${pattern}"* ]]; then
      protected_count=$((protected_count + 1))
      break
    fi
  done
done
echo "PROTECTED_PATH_COUNT=${protected_count}"

# --- Security-sensitive count ---
security_count=0
for file in "${FILES[@]}"; do
  for pattern in "${SECURITY_PATTERNS[@]}"; do
    if [[ "${file}" == *"${pattern}"* ]]; then
      security_count=$((security_count + 1))
      break
    fi
  done
done
echo "SECURITY_SENSITIVE_COUNT=${security_count}"

# --- CI/workflow changed ---
ci_changed="false"
for file in "${FILES[@]}"; do
  case "${file}" in
    .github/*|Makefile|Dockerfile|Containerfile) ci_changed="true"; break ;;
  esac
done
echo "CI_WORKFLOW_CHANGED=${ci_changed}"

# --- Dependency files ---
dep_files=()
for file in "${FILES[@]}"; do
  case "${file}" in
    go.mod|go.sum|package.json|package-lock.json|yarn.lock|\
    requirements.txt|requirements*.txt|Pipfile|Pipfile.lock|\
    Gemfile|Gemfile.lock|pom.xml|build.gradle|Cargo.toml|Cargo.lock)
      dep_files+=("${file}") ;;
  esac
done
if [ ${#dep_files[@]} -eq 0 ]; then
  echo "DEPENDENCY_FILES_CHANGED=none"
else
  IFS=','; echo "DEPENDENCY_FILES_CHANGED=${dep_files[*]}"; unset IFS
fi

# --- Test file ratio ---
test_count=0
for file in "${FILES[@]}"; do
  case "${file}" in
    *_test.go|*_test.py|*-test.sh|*-test.py|test_*|*_spec.*|*.test.*)
      test_count=$((test_count + 1)) ;;
  esac
done
if [ "${FILES_CHANGED}" -eq 0 ]; then
  echo "TEST_FILE_RATIO=0.00"
else
  echo "TEST_FILE_RATIO=$(awk -v t="${test_count}" -v a="${FILES_CHANGED}" 'BEGIN { printf "%.2f", t / a }')"
fi

# --- Author signals ---
PR_META=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" --jq '{author: .user.login}' 2>/dev/null) || PR_META=""
if [ -n "${PR_META}" ]; then
  AUTHOR=$(echo "${PR_META}" | jq -r '.author')
  if [[ "${AUTHOR}" == *"[bot]" ]]; then
    echo "AUTHOR_IS_BOT=true"
  else
    echo "AUTHOR_IS_BOT=false"
  fi

  # First-time contributor: check for prior merged PRs
  PRIOR_COUNT=$(gh api "search/issues?q=repo:${REPO_FULL_NAME}+author:${AUTHOR}+type:pr+is:merged&per_page=1" \
    --jq '.total_count' 2>/dev/null) || PRIOR_COUNT=""
  if [ -n "${PRIOR_COUNT}" ] && [ "${PRIOR_COUNT}" = "0" ]; then
    echo "AUTHOR_IS_FIRST_TIME=true"
  else
    echo "AUTHOR_IS_FIRST_TIME=false"
  fi
else
  echo "AUTHOR_IS_BOT=UNKNOWN"
  echo "AUTHOR_IS_FIRST_TIME=UNKNOWN"
fi

exit 0
