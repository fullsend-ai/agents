#!/usr/bin/env bash
# skill-env-reachability-test.sh — Verify that every SKILL.md file
# references only env vars reachable from its delivering harness's
# env.sandbox, sandbox runtime injection, provider credentials, or
# documented per-invocation inputs.
#
# For each harness file, extract the union of all env.sandbox keys
# (top-level, forge blocks, and overlays), then extract all skill
# paths.  For each skill that resolves to a local SKILL.md, extract
# env var references via two patterns (backtick-delimited uppercase
# identifiers and ${VAR} template expansions) and verify every
# reference is reachable.
#
# Run from the repo root: bash scripts/skill-env-reachability-test.sh

set -euo pipefail

# Bash 4+ required for associative arrays (declare -A KNOWN_GAPS)
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: Bash 4+ required (found ${BASH_VERSION}). On macOS: brew install bash"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

# ---------------------------------------------------------------------------
# Sandbox runtime vars — injected into the sandbox on every runtime by
# the bootstrap (PATH), the fullsend runtime (FULLSEND_*), or the
# gcp-vertex.env host file mounted by every harness
# (GOOGLE_APPLICATION_CREDENTIALS) — not declared in env.sandbox.
# Provider credentials (GH_TOKEN, GITLAB_TOKEN, JIRA_TOKEN) are NOT
# universal: each exists only in harnesses that list the matching
# provider, so they are validated per harness (see
# extract_provider_tokens). Runtime-specific vars (config dirs) and
# host-side-only vars must not be listed here; track per-skill gaps in
# KNOWN_GAPS instead.
# ---------------------------------------------------------------------------
SANDBOX_RUNTIME_VARS=(
  FULLSEND_OUTPUT_DIR
  FULLSEND_OUTPUT_SCHEMA
  FULLSEND_PERSONAS_FILE
  FULLSEND_ROLE
  GOOGLE_APPLICATION_CREDENTIALS
  PATH
)

# ---------------------------------------------------------------------------
# Non-env tokens — uppercase tokens that appear in backtick text or
# code blocks but are NOT env vars (field names, keywords, file
# names, etc.)
# ---------------------------------------------------------------------------
NON_ENV_TOKENS=(
  # Status / severity / verdict tokens
  APPROVE CHANGES CRITICAL HIGH MEDIUM LOW WARN PASS FAIL
  BEHIND BLOCKED CONFLICTING MERGEABLE UNSTABLE FAILED
  INCOMPLETE
  # Format / protocol / language tokens
  JSON JSONL YAML CSV HTTP HTTPS URL API CLI EOF CRLF UTF JQL
  # Boolean / logic / keyword tokens
  TRUE FALSE NULL NOT ONLY BREAKING UNKNOWN AND ALL EMPTY
  # SQL / query tokens
  ASC DESC LIMIT ORDER
  # HTTP methods / API tokens
  PRIVATE POST TOKEN MATCH NO_MATCH FETCH PARSE DIFF ENDPOINT
  # Git concepts
  HEAD SHA BRANCH COMMITS COMMIT MANIFEST
  # Review procedure output markers
  SCOPED FAILURE APPROVED CHANGES_REQUESTED CLOSED MERGED OPEN GIT
  # File / directory / product names
  AGENTS CLAUDE CONTRIBUTING README SKILL TODO FILL STEP
  SYSTEM HARD CURLRC FILES WORK MESSAGES
  # Ruff / linter rule codes
  SIM401 UP038
  # Bash special variables
  IFS OLDMASK
  # Field names / parameter names in risk assessment
  AUTHOR_IS_BOT AUTHOR_IS_FIRST_TIME
  # GitHub Actions env var name referenced in prose
  ACTIONS_ALLOW_UNSECURE_COMMANDS
  # Retry-limit env var referenced in prose only; harnesses whose skills
  # consume it (code, fix) deliver it via env.sandbox
  MAX_RETRIES
  # Review keyword (as in "REQUEST CHANGES")
  REQUEST
)

# ---------------------------------------------------------------------------
# Skill-local variables — assigned within SKILL.md code examples. A var
# in this list is exempted when the referencing skill file assigns it
# (^\s*VAR=); an unassigned reference that is actually consumed — a
# ${VAR} expansion or an unbraced $VAR read — must be reachable from
# env.sandbox or tracked in KNOWN_GAPS. Backtick and code-block
# mentions (placeholders, prose, field names) stay exempt.
# ---------------------------------------------------------------------------
SKILL_LOCAL_VARS=(
  AGENT_START BASE_BRANCH BLAST_RADIUS BRANCH_NAME
  CHANGED_FILES CHANGED_FILES_FILE
  CI_WORKFLOW_CHANGED CODE_ALLOWED_TARGET_BRANCHES
  COMMIT_MESSAGES_AVAILABLE_FILE COMMIT_MESSAGES_FILE
  COMMIT_MESSAGES_INCOMPLETE_FILE COMMITS_FILE
  COMPARE_COMPLETE_FILTER COMPARE_FILE COMPARE_INCOMPLETE_FILE
  BASE_SHA DEFAULT_BRANCH DEP_BASE DEP_HEAD DEP_N DEPENDENCY_FILES_CHANGED
  DIFF_ACCEPT
  DISPATCH_ENCODED DISPATCH_REPO DISPATCH_REPO_ENCODED
  ELAPSED EXACT FEATURE_X_ENABLED
  FETCH_END FETCH_START FILE_COUNT FILES_CHANGED GITLAB_HOST
  HEAD_PIPELINE_ID HEAD_PIPELINE_SHA HEAD_SHA
  IID INCOMPLETE_COMPARE INCREMENTAL_DIFF
  IS_DRAFT ISSUE_KEY
  JOB_ID LAST_DEP LINE_COUNT LINES_CHANGED LOGIN_SELECT
  MERGE_BASE_FILE MR_DATA MR_IID MR_JSON MR_SHA
  NET_COMPLETE NET_N NOW NUMBER OLD_NAME ORG OTHER OTHER_PROJECT_ID OWN_N
  OTHERPROJ OWNER PIPELINE_ID PKG POLL_INTERVAL
  PID PR_COMMIT_COUNT PR_COMMIT_COUNT_FILE PR_DATA PR_HEAD PRBODY
  PR_NUMBER_OR_URL PROJECT_KEY PROTECTED_PATH_COUNT
  REMAINING REPO REPO_ENCODED REVIEW_BODY_FILE REVIEW_COMMENT
  REVIEW_SUB_AGENT_TRUE RUN_FALLBACK RUN_ID
  SECURITY_SENSITIVE_COUNT SHAPE SKIP STATE TARGET_ENCODED TEST_FILE_RATIO
)

# ---------------------------------------------------------------------------
# Known gaps — associative array mapping skill:VAR to tracking reference
# ---------------------------------------------------------------------------
declare -A KNOWN_GAPS=(
  ["pr-risk-assessment:REVIEW_GIT_FETCH_DEPTH"]="#1621 — runner-side var; post-script detects shallow-repo independently (#1624)"
  # Multi-context forge skills document ISSUE_URL for triage context; fix,
  # retro, and review harnesses don't supply it because those workflows
  # don't operate on standalone issues.
  ["github-forge:ISSUE_URL"]="#1664 — forge skill documents triage-context var; not supplied by fix/retro/review harnesses"
  ["gitlab-forge:ISSUE_URL"]="#1664 — forge skill documents triage-context var; not supplied by fix/retro/review harnesses"
  ["issue-labels/gitlab:ISSUE_URL"]="#1664 — label skill references ISSUE_URL for triage; review harness does not supply it"
  # Forge skills derive ISSUE_NUMBER locally from ISSUE_URL via basename;
  # only code.yaml passes it through env.sandbox directly.
  ["github-forge:ISSUE_NUMBER"]="#1664 — forge skill derives ISSUE_NUMBER locally from ISSUE_URL; not in fix/retro/review/prioritize/triage env.sandbox"
  ["gitlab-forge:ISSUE_NUMBER"]="#1664 — forge skill derives ISSUE_NUMBER locally from ISSUE_URL; not in fix/retro/review/prioritize/triage env.sandbox"
  ["issue-labels/gitlab:ISSUE_NUMBER"]="#1664 — label skill derives ISSUE_NUMBER locally from ISSUE_URL; review/triage harnesses do not supply it"
  # pr-risk-assessment scripts hard-reference the runtime-specific config
  # dir (CLAUDE_CONFIG_DIR on claude; CODEX_HOME/PI_CODING_AGENT_DIR on
  # codex/pi). No runtime-neutral skill path exists yet.
  ["pr-risk-assessment:CLAUDE_CONFIG_DIR"]="#1672 — runtime-specific config dir; needs runtime-neutral skill path"
  # Skills below reference these vars as ${VAR} expansions without
  # assigning them, and no delivering harness declares them in
  # env.sandbox.
  ["fix-review:BASE_BRANCH"]="#1665 review — git log escalation references BASE_BRANCH; fix.yaml pre-script uses FORGE_PR_BASE_BRANCH, which doesn't reach env.sandbox under that name"
  ["code-implementation:BRANCH_NAME"]="#1665 review — referenced without assignment or harness delivery"
  ["gitlab-forge:MR_IID"]="#1665 review — referenced without assignment or harness delivery"
  ["fix-review/github:RUN_ID"]="#1665 review — referenced without assignment or harness delivery"
  ["fix-review/gitlab:JOB_ID"]="#1665 review — referenced without assignment or harness delivery"
)

# Per-invocation inputs — supplied by the caller of the documented procedure,
# not static values from the delivering harness's env.sandbox.
declare -A CALLER_INPUTS=(
  ["pr-review/github:DEP_PRS"]="dependency-scope procedure"
  ["pr-review/github:PINNED_SHA"]="dependency-scope procedure"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_pass() { echo "PASS: $1"; }
assert_fail() {
  local test_name="$1" detail="$2"
  echo "FAIL: ${test_name} — ${detail}"
  FAILURES=$((FAILURES + 1))
}
assert_warn() {
  local test_name="$1" detail="$2"
  echo "WARN: ${test_name} — ${detail}"
}

# is_sandbox_runtime_var VAR — return 0 if VAR is a sandbox runtime var
is_sandbox_runtime_var() {
  local var="$1"
  for rtvar in "${SANDBOX_RUNTIME_VARS[@]}"; do
    [[ "$var" == "$rtvar" ]] && return 0
  done
  return 1
}

# is_non_env_token TOKEN — return 0 if TOKEN is a non-env token
is_non_env_token() {
  local token="$1"
  for t in "${NON_ENV_TOKENS[@]}"; do
    [[ "$token" == "$t" ]] && return 0
  done
  return 1
}

# is_skill_local_var VAR — return 0 if VAR is a skill-local variable
is_skill_local_var() {
  local var="$1"
  for t in "${SKILL_LOCAL_VARS[@]}"; do
    [[ "$var" == "$t" ]] && return 0
  done
  return 1
}

# extract_env_sandbox_keys HARNESS_FILE — print the union of all
# env.sandbox keys from top-level, forge blocks, and overlays.
#
# NOTE: unions all forge/overlay keys — does not track per-composition
# isolation. A var present in only one forge (e.g. GitHub) appears
# reachable for all compositions. Per-forge validation is a v2
# enhancement. See #1664.
extract_env_sandbox_keys() {
  local harness_file="$1"
  yq -r '[
    (.env.sandbox // {} | keys),
    (.forge[]? | .env.sandbox // {} | keys),
    (.overlays[]? | .env.sandbox // {} | keys)
  ] | flatten | .[]' "${harness_file}" 2>/dev/null | sort -u
  # 2>/dev/null: yq emits benign warnings when optional key paths
  # (forge, overlays) are absent. Empty output here is fail-closed:
  # all skill vars will fail the env.sandbox check.
}

# extract_skill_paths HARNESS_FILE — print the union of all skill
# paths from top-level, forge blocks, and overlays
extract_skill_paths() {
  local harness_file="$1"
  local output rc=0
  output=$(yq -r '[
    (.skills // []),
    (.forge[]? | .skills // []),
    (.overlays[]? | .skills // [])
  ] | flatten | .[]' "${harness_file}" 2>/dev/null) || rc=$?
  # 2>/dev/null: yq emits benign warnings when optional key paths
  # (forge, overlays) are absent. A non-zero exit code from yq
  # indicates a real failure — fail-close rather than skip.
  if [[ $rc -ne 0 ]]; then
    echo "ERROR: yq failed on ${harness_file} (exit $rc)" >&2
    return 1
  fi
  echo "$output" | sort -u
}

# extract_provider_tokens HARNESS_FILE — print the union of credential
# tokens delivered by the harness's providers across top-level, forge
# blocks, and overlays. File-based providers (providers/*.yaml)
# contribute their credentials keys; built-in github* providers map to
# GH_TOKEN. These tokens are reachable only in harnesses that list the
# matching provider, so they are exempted per harness, never globally.
extract_provider_tokens() {
  local harness_file="$1"
  yq -r '[
    (.providers // []),
    (.forge[]? | .providers // []),
    (.overlays[]? | .providers // [])
  ] | flatten | unique | .[]' "${harness_file}" 2>/dev/null \
    | while IFS= read -r provider; do
        [[ -z "$provider" ]] && continue
        if [[ "$provider" == *.yaml || "$provider" == */* ]]; then
          # File-based provider: print its credentials keys. A missing
          # provider file yields nothing — the token then fails closed.
          # 2>/dev/null: suppresses yq's file-not-found noise.
          yq -r '.credentials // {} | keys | .[]' \
            "${REPO_ROOT}/${provider}" 2>/dev/null || true
        elif [[ "$provider" == github* ]]; then
          echo "GH_TOKEN"
        fi
      done | sort -u
}

# extract_env_var_refs SKILL_FILE — print all env var references
# extracted from a SKILL.md file using two patterns:
#   1. Backtick-delimited uppercase identifiers (inline + code blocks)
#   2. ${VAR} template expansions
extract_env_var_refs() {
  local skill_file="$1"

  # Pattern 1a: inline backtick text
  local backtick_vars
  # 2>/dev/null: file existence is pre-checked; suppresses only
  # benign encoding warnings from grep on binary-like content.
  backtick_vars=$(grep -oE '`[^`]+`' "${skill_file}" 2>/dev/null \
    | grep -oE '[A-Z][A-Z0-9_]{2,}' || true)

  # Pattern 1b: code block text (between ``` markers)
  local code_block_vars
  code_block_vars=$(awk '/^```/{inside=!inside; next} inside{print}' "${skill_file}" \
    | grep -oE '[A-Z][A-Z0-9_]{2,}' || true)

  # Pattern 2: ${VAR} template expansions
  local template_vars
  # 2>/dev/null: file existence is pre-checked; suppresses only
  # benign encoding warnings from grep on binary-like content.
  template_vars=$(grep -oE '\$\{[A-Z][A-Z0-9_]{2,}\}' "${skill_file}" 2>/dev/null \
    | sed 's/\${//;s/}//' || true)

  # Combine and deduplicate — word splitting is intentional here to
  # split multi-line strings from grep output into individual tokens.
  # shellcheck disable=SC2086
  printf '%s\n' ${backtick_vars} ${code_block_vars} ${template_vars} | sort -u
}

# ---------------------------------------------------------------------------
# Discover harness files
# ---------------------------------------------------------------------------
HARNESS_DIR="${REPO_ROOT}/harness"
HARNESS_FILES=()
for f in "${HARNESS_DIR}"/*.yaml "${REPO_ROOT}"/examples/*/harness/*.yaml; do
  [[ -f "$f" ]] && HARNESS_FILES+=("$f")
done

if [[ ${#HARNESS_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no harness YAML files found in ${HARNESS_DIR}"
  exit 1
fi

echo "Scanning ${#HARNESS_FILES[@]} harness file(s) for skill env var reachability"
echo ""

# ---------------------------------------------------------------------------
# Test: each skill's env var references must be reachable from its
# delivering harness's env.sandbox (or allowlisted)
# ---------------------------------------------------------------------------
for harness in "${HARNESS_FILES[@]}"; do
  harness_name="$(basename "$harness" .yaml)"

  # 1. Extract union of ALL env.sandbox keys
  env_sandbox_keys="$(extract_env_sandbox_keys "$harness")"

  # 2. Extract skill paths
  skill_paths="$(extract_skill_paths "$harness")"

  [[ -z "$skill_paths" ]] && continue

  # 2b. Extract provider-delivered credential tokens for this harness
  provider_tokens="$(extract_provider_tokens "$harness")"

  # 3. For each skill path, resolve and validate
  while IFS= read -r skill_path; do
    [[ -z "$skill_path" ]] && continue

    # Resolve SKILL.md
    skill_file="${REPO_ROOT}/${skill_path}/SKILL.md"
    if [[ ! -f "$skill_file" ]]; then
      echo "INFO: ${skill_path} — no local SKILL.md (upstream platform skill), skipping"
      continue
    fi

    skill_name="${skill_path#skills/}"

    # Extract env var references from SKILL.md
    all_vars="$(extract_env_var_refs "$skill_file")"

    if [[ -z "$all_vars" ]]; then
      assert_pass "${skill_name}/${harness_name}"
      continue
    fi

    # Cross-reference each var
    local_pass=true
    while IFS= read -r var; do
      [[ -z "$var" ]] && continue

      # Skip non-env tokens
      if is_non_env_token "$var"; then
        continue
      fi

      # Skip skill-local variables. Exempt when assigned in this skill
      # file (^\s*VAR=); an unassigned reference is only a gap when it
      # is consumed — a ${VAR} template expansion or an unbraced $VAR
      # read. Backtick and code-block mentions (placeholders, prose,
      # field names) remain exempt. A <skill>/<forge> child may also
      # rely on an assignment in its parent skill file when the same
      # harness delivers the parent (e.g. retro-analysis/github reads
      # DISPATCH_REPO that retro-analysis assigns). The unbraced pattern
      # requires a non-identifier character (or end of line) after the
      # var name, so $DISPATCH matches DISPATCH but not DISPATCH_REPO,
      # and ${VAR} expansions (brace between $ and name) never match it.
      # 2>/dev/null: file existence is pre-checked; suppresses only
      # benign encoding warnings from grep on binary-like content.
      if is_skill_local_var "$var"; then
        parent_path="$(dirname "${skill_path}")"
        parent_file="${REPO_ROOT}/${parent_path}/SKILL.md"
        if grep -qE "^[[:space:]]*${var}=" "${skill_file}" 2>/dev/null \
          || { ! grep -qF "\${${var}}" "${skill_file}" 2>/dev/null \
          && ! grep -qE '\$'"${var}"'([^[:alnum:]_]|$)' "${skill_file}" 2>/dev/null; } \
          || { [[ "${parent_path}" == skills/* ]] \
          && grep -qxF "${parent_path}" <<< "$skill_paths" \
          && grep -qE "^[[:space:]]*${var}=" "${parent_file}" 2>/dev/null; }; then
          continue
        fi
      fi

      # Skip sandbox runtime vars
      if is_sandbox_runtime_var "$var"; then
        continue
      fi

      # Skip provider-delivered tokens for this harness (GH_TOKEN,
      # GITLAB_TOKEN, JIRA_TOKEN are only reachable when the harness
      # lists the matching provider)
      if echo "$provider_tokens" | grep -qxF "$var"; then
        continue
      fi

      # Check if it's in env.sandbox
      if echo "$env_sandbox_keys" | grep -qxF "$var"; then
        continue
      fi

      # Check known gaps
      gap_key="${skill_name}:${var}"
      if [[ -n "${CALLER_INPUTS[$gap_key]+x}" ]]; then
        continue
      fi
      if [[ -n "${KNOWN_GAPS[$gap_key]+x}" ]]; then
        assert_warn "${skill_name}/${harness_name}" "${var} unreachable (tracked: ${KNOWN_GAPS[$gap_key]})"
        local_pass=false
        continue
      fi

      # FAIL — not reachable
      assert_fail "${skill_name}/${harness_name}" "${var} not in env.sandbox"
      local_pass=false
    done <<< "$all_vars"

    if $local_pass; then
      assert_pass "${skill_name}/${harness_name}"
    fi

  done <<< "$skill_paths"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All skill env var reachability tests passed"
