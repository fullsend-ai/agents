#!/usr/bin/env bash
# risk-tier1.sh — Compute deterministic Tier 1 metadata signals for PR risk assessment.
#
# Run by the risk-assessment sub-agent inside the sandbox:
#   bash "${CLAUDE_CONFIG_DIR}/skills/pr-risk-assessment/scripts/risk-tier1.sh"
#
# Required env vars: PR_NUMBER, REPO_FULL_NAME, GH_TOKEN
# Output: KEY=VALUE pairs on stdout, one per line. The last two,
# TIER1_SCORE and RISK_FLOOR, are the Tier 1 composite and the floor
# computed from the table in ../SKILL.md.
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
    ".claude/" ".cursor/" ".pi/" ".gitattributes" ".github/"
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
      [[ "${file}" == "${pattern}"* ]] && { count=$((count + 1)); break; }
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
      .github/workflows/*|.github/actions/*|.gitlab-ci.yml|Jenkinsfile|azure-pipelines.yml|Makefile|Dockerfile|Containerfile) echo "true"; return ;;
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
      requirements*.txt|Pipfile|Pipfile.lock|\
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
    local base="${file##*/}"
    case "${base}" in
      *_test.go|*_test.py|*-test.sh|*-test.py|test_*|*_spec.*|*.spec.*|*.test.*)
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

# false when every file is docs/config — TEST_FILE_RATIO 0.00 is then
# neutral (score 1), per the Tier 1 table in SKILL.md.
has_source_files() {
  local file
  for file in "$@"; do
    case "${file##*/}" in
      *.md|*.markdown|*.rst|*.adoc|*.txt|*.yaml|*.yml|*.json|*.toml|*.ini|*.cfg|*.conf|LICENSE*|CODEOWNERS|.gitignore|.gitattributes|.editorconfig) ;;
      *) echo "true"; return ;;
    esac
  done
  echo "false"
}

# ---------------------------------------------------------------------------
# Tier 1 composite — the SKILL.md scoring table, computed here so the
# sub-agent copies a number instead of re-deriving one (the LLM re-scoring
# of deterministic signals is what made the same PR flip 1/2 across runs).
# ---------------------------------------------------------------------------

# Change size = max(files score, lines score, blast score); 0 when all UNKNOWN.
_score_size() {
  local f="$1" l="$2" b="$3" s=0 x
  if [[ "${f}" != "UNKNOWN" ]]; then
    x=1
    [ "${f}" -ge 4 ] && x=2
    [ "${f}" -ge 11 ] && x=3
    [ "${f}" -ge 26 ] && x=4
    [ "${f}" -gt 50 ] && x=5
    [ "${x}" -gt "${s}" ] && s=${x}
  fi
  if [[ "${l}" != "UNKNOWN" ]]; then
    x=1
    [ "${l}" -ge 100 ] && x=2
    [ "${l}" -ge 300 ] && x=3
    [ "${l}" -ge 800 ] && x=4
    [ "${l}" -ge 2000 ] && x=5
    [ "${x}" -gt "${s}" ] && s=${x}
  fi
  case "${b}" in small) x=1 ;; medium) x=3 ;; large) x=5 ;; *) x=0 ;; esac
  [ "${x}" -gt "${s}" ] && s=${x}
  echo "${s}"
}

# score_tier1 FILES LINES BLAST PROTECTED SECURITY CI DEPS TEST_RATIO BOT FIRST HAS_SOURCE
# Prints the average of the valid dimension sub-scores (2 decimals), or
# UNKNOWN when nothing could be scored.
score_tier1() {
  local files="$1" lines="$2" blast="$3" prot="$4" sec="$5" ci="$6" depfiles="$7" ratio="$8" bot="$9" first="${10}" src="${11}"
  local sum=0 n=0
  _add() { [[ "$1" == "UNKNOWN" || "$1" == "0" ]] && return 0; sum=$((sum + $1)); n=$((n + 1)); }
  _add "$(_score_size "${files}" "${lines}" "${blast}")"
  case "${prot}"  in UNKNOWN) ;; 0) _add 1 ;; 1) _add 3 ;; *) _add 5 ;; esac
  case "${sec}"   in UNKNOWN) ;; 0) _add 1 ;; 1) _add 3 ;; 2|3) _add 4 ;; *) _add 5 ;; esac
  case "${ci}"    in true) _add 4 ;; false) _add 1 ;; esac
  case "${depfiles}" in UNKNOWN) ;; none) _add 1 ;; *,*) _add 5 ;; *) _add 3 ;; esac
  if [[ "${ratio}" != "UNKNOWN" ]]; then
    if [[ "${src}" == "false" ]]; then
      _add 1
    else
      _add "$(awk -v r="${ratio}" 'BEGIN { if (r >= 0.5) print 1; else if (r >= 0.3) print 2; else if (r >= 0.1) print 3; else if (r >= 0.01) print 4; else print 5 }')"
    fi
  fi
  case "${bot}"   in true) _add 1 ;; false) _add 2 ;; esac
  case "${first}" in true) _add 4 ;; false) _add 1 ;; esac
  if [ "${n}" -eq 0 ]; then
    echo "UNKNOWN"
  else
    awk -v s="${sum}" -v n="${n}" 'BEGIN { printf "%.2f", s / n }'
  fi
}

# 2 when a security-sensitive path is touched (never "low", whatever the
# other tiers say), else 1. Consumers apply score = max(score, RISK_FLOOR).
risk_floor() {
  local sec="$1"
  if [[ "${sec}" != "UNKNOWN" ]] && [ "${sec}" -gt 0 ]; then echo 2; else echo 1; fi
}

# Every signal UNKNOWN — the sub-agent redistributes weights, the
# orchestrator's fallback proceeds without a score.
emit_unknown() {
  local k
  for k in FILES_CHANGED LINES_CHANGED BLAST_RADIUS PROTECTED_PATH_COUNT \
    SECURITY_SENSITIVE_COUNT CI_WORKFLOW_CHANGED DEPENDENCY_FILES_CHANGED \
    TEST_FILE_RATIO AUTHOR_IS_BOT AUTHOR_IS_FIRST_TIME TIER1_SCORE RISK_FLOOR; do
    echo "${k}=UNKNOWN"
  done
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

  # Fail closed: no file list, a non-array, or a valid-but-empty array
  # (seen on pi when env vars did not reach the sub-agent, agents#1227)
  # all mean "nothing was measured" — never a PR with zero risky files.
  if [ -z "${PR_FILES_JSON}" ] \
    || ! echo "${PR_FILES_JSON}" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    emit_unknown
    return 0
  fi

  # --- Parse file list ---
  local FILES FILES_CHANGED LINES_CHANGED
  mapfile -t FILES < <(echo "${PR_FILES_JSON}" | jq -r '.[].filename')
  FILES_CHANGED=${#FILES[@]}
  LINES_CHANGED=$(echo "${PR_FILES_JSON}" | jq '[.[] | .additions + .deletions] | add // 0')

  local BLAST PROTECTED SECURITY CI DEPS RATIO
  BLAST=$(classify_blast_radius "${FILES_CHANGED}" "${LINES_CHANGED}")
  PROTECTED=$(count_protected_paths "${FILES[@]}")
  SECURITY=$(count_security_sensitive "${FILES[@]}")
  CI=$(has_ci_files "${FILES[@]}")
  DEPS=$(find_dependency_files "${FILES[@]}")
  RATIO=$(compute_test_ratio "${FILES[@]}")

  echo "FILES_CHANGED=${FILES_CHANGED}"
  echo "LINES_CHANGED=${LINES_CHANGED}"
  echo "BLAST_RADIUS=${BLAST}"
  echo "PROTECTED_PATH_COUNT=${PROTECTED}"
  echo "SECURITY_SENSITIVE_COUNT=${SECURITY}"
  echo "CI_WORKFLOW_CHANGED=${CI}"
  echo "DEPENDENCY_FILES_CHANGED=${DEPS}"
  echo "TEST_FILE_RATIO=${RATIO}"

  # --- Author signals ---
  local PR_META AUTHOR_IS_BOT=UNKNOWN AUTHOR_IS_FIRST_TIME=UNKNOWN
  PR_META=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" \
    --jq '[.user.login, .author_association] | @tsv' 2>/dev/null) || PR_META=""
  if [ -n "${PR_META}" ]; then
    local AUTHOR ASSOC
    IFS=$'\t' read -r AUTHOR ASSOC <<< "${PR_META}"
    AUTHOR_IS_BOT=$(is_bot_author "${AUTHOR}")
    if [ "${ASSOC}" = "FIRST_TIME_CONTRIBUTOR" ]; then
      AUTHOR_IS_FIRST_TIME=true
    else
      AUTHOR_IS_FIRST_TIME=false
    fi
  fi
  echo "AUTHOR_IS_BOT=${AUTHOR_IS_BOT}"
  echo "AUTHOR_IS_FIRST_TIME=${AUTHOR_IS_FIRST_TIME}"

  # --- Tier 1 composite + floor (last two lines; the sub-agent copies them) ---
  echo "TIER1_SCORE=$(score_tier1 "${FILES_CHANGED}" "${LINES_CHANGED}" "${BLAST}" "${PROTECTED}" "${SECURITY}" "${CI}" "${DEPS}" "${RATIO}" "${AUTHOR_IS_BOT}" "${AUTHOR_IS_FIRST_TIME}" "$(has_source_files "${FILES[@]}")")"
  echo "RISK_FLOOR=$(risk_floor "${SECURITY}")"

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
